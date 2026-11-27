import Foundation
import Network

enum MailIMAPError: Error {
    case server(MailServerError)
    case disconnected, timedOut, invalidResponse, missingMailbox, staleMessage, moveUnsupported, rejected, responseTooLarge, messageTooLarge
}

struct MailInboxSnapshot {
    let validity: UInt32
    var messages: [MailMessage]
    var unread: Int
    var canArchive: Bool
}

protocol MailIMAPTransport {
    func start()
    func close()
    func interrupt()
    func send(_ text: String)
    func receive(until deadline: DispatchTime, interruptible: Bool) async throws -> MailIMAPResponse?
}

/// The account worker owns the command stream. Only close and requestRefresh can be called concurrently.
final class MailIMAP {
    private static let header = "HEADER.FIELDS (FROM SUBJECT DATE CONTENT-TYPE CONTENT-TRANSFER-ENCODING CONTENT-DISPOSITION)"
    private static let previewSize = 16 * 1024
    private static let extendedPreviewSize = 256 * 1024
    fileprivate static let messageSizeLimit = 25 * 1024 * 1024
    private static let commandTimeout = 15

    private let socket: MailIMAPTransport
    private let provider: MailProvider

    convenience init(provider: MailProvider = .gmail) {
        self.init(socket: MailIMAPSocket(host: provider.host, port: provider.port), provider: provider)
    }

    init(socket: MailIMAPTransport, provider: MailProvider = .gmail) {
        self.socket = socket
        self.provider = provider
    }
    private var nextTag = 0
    private var capabilities: Set<String> = []
    private var supportsIdle = false
    private var exists = 0
    private var validity: UInt32?
    private var revision = 0
    private var archiveAvailable: Bool?
    // Latency instrumentation (mail-timing log lines only; no behaviour depends on these).
    /// Set by MailService: whose lines these are ("acct=... op=N" / "sync=N" / "signin" / "idle").
    var timingContext = ""
    /// Set by MailService before synchronize: why it runs.
    var timingReason = ""
    /// How the last waitForInboxChange ended: change, poll, interrupt, idle-change, idle-renew, idle-server-end.
    private(set) var wakeOutcome = ""
    private var bytesReceived = 0
    private var bytesTotal = 0
    private var quietCommands = (count: 0, ms: 0, bytes: 0)

    func close() { socket.close() }
    func requestRefresh() { socket.interrupt() }

    func open(email: String, password: String) async throws {
        try Task.checkCancellation()
        socket.start()
        let deadline = DispatchTime.now() + .seconds(Self.commandTimeout)
        let greeting = try await read(until: deadline)
        guard greeting.line.uppercased().split(separator: " ").starts(with: ["*", "OK"]) else { throw Self.serverError(greeting) }

        let username = provider.username(for: email)
        let secret = try Self.quote(password)
        do {
            _ = try await command("LOGIN \(Self.quote(username)) \(secret)", until: deadline)
        } catch MailIMAPError.server(.authenticationFailed) where username != email {
            _ = try await command("LOGIN \(Self.quote(email)) \(secret)", until: deadline)
        }
        for response in try await command("CAPABILITY") {
            let words = response.line.uppercased().split(separator: " ")
            if words.starts(with: ["*", "CAPABILITY"]) {
                capabilities.formUnion(words.dropFirst(2).map(String.init))
            }
        }
        supportsIdle = capabilities.contains("IDLE")
        _ = try await command("SELECT INBOX")
        guard validity != nil else { throw MailIMAPError.invalidResponse }
    }

    func synchronize(accountID: String) async throws -> MailInboxSnapshot {
        let syncStart = MailTiming.now()
        bytesTotal = 0
        quietCommands = (0, 0, 0)
        MailTiming.line("sync-start \(timingContext) reason=\(timingReason)")
        if archiveAvailable == nil && supportsMove {
            do {
                let boxes = try await listMailboxes()
                archiveAvailable = MailIMAPMailbox.archive(in: boxes, provider: provider) != nil
            } catch MailIMAPError.rejected {
                archiveAvailable = false
            }
        }
        _ = try await command("NOOP")
        guard let validity else { throw MailIMAPError.invalidResponse }
        let startRevision = revision
        var headers: [MailIMAPFetch] = []
        if exists > 0 {
            let first = max(1, exists - 24)
            let gmailIDs = capabilities.contains("X-GM-EXT-1") ? " X-GM-THRID X-GM-MSGID" : ""
            let fields = "UID INTERNALDATE\(gmailIDs) BODY.PEEK[\(Self.header)] BODY.PEEK[TEXT]<0.\(Self.previewSize)>"
            let responses = try await command("FETCH \(first):* (\(fields))")
            headers = responses.compactMap { response in
                let fetch = response.fetch
                return fetch?.body(Self.header) == nil ? nil : fetch
            }
        }
        let unseen = try await unseenUIDs()
        var messages: [UInt32: MailMessage] = [:]
        for fetch in headers {
            guard let uid = fetch.uid, uid > 0, let header = fetch.body(Self.header) else { continue }
            let fields = MailMIME.headers(header)
            let sender = MailMIME.from(fields["from"] ?? "")
            var snippet = ""
            if let preview = fetch.body("TEXT", partial: true) {
                snippet = MailMIME.snippet(preview, headers: fields)
                if snippet.isEmpty && preview.count == Self.previewSize {
                    let responses = try await command("UID FETCH \(uid) (UID BODY.PEEK[TEXT]<0.\(Self.extendedPreviewSize)>)", quiet: true)
                    if let extended = responses.lazy.compactMap(\.fetch)
                        .first(where: { $0.uid == uid && $0.body("TEXT", partial: true) != nil })?
                        .body("TEXT", partial: true) {
                        snippet = MailMIME.snippet(extended, headers: fields)
                    }
                }
            }
            messages[uid] = MailMessage(
                id: "\(accountID)#\(validity)#\(uid)", accountID: accountID, uid: uid,
                fromName: sender.name, fromAddress: sender.address,
                subject: MailMIME.decodeHeader(fields["subject"] ?? ""), snippet: snippet,
                date: fetch.internalDate ?? .distantPast, unread: unseen.contains(uid),
                gmailThreadID: fetch.threadID, gmailMessageID: fetch.messageID, uidValidity: validity
            )
        }
        // If the mailbox changed mid-snapshot, take another pass before waiting for IDLE.
        if revision != startRevision { requestRefresh() }
        let latest = messages.values.sorted { $0.uid > $1.uid }.prefix(25)
        if quietCommands.count > 0 {
            MailTiming.line("sync-extended-previews \(timingContext) n=\(quietCommands.count) ms=\(quietCommands.ms) bytes=\(quietCommands.bytes)")
        }
        MailTiming.line("sync-done \(timingContext) reason=\(timingReason) total_ms=\(MailTiming.ms(since: syncStart)) bytes=\(bytesTotal) messages=\(latest.count) unread=\(unseen.count)")
        return MailInboxSnapshot(validity: validity, messages: Array(latest), unread: unseen.count,
                                 canArchive: archiveAvailable == true)
    }

    func waitForInboxChange() async throws {
        wakeOutcome = ""
        guard supportsIdle else {
            let deadline = DispatchTime.now() + .seconds(120)
            var woke = false
            while let response = try await socket.receive(until: deadline, interruptible: true) {
                try Task.checkCancellation()
                if try observe(response) { woke = true; break }
            }
            wakeOutcome = woke ? "change" : (DispatchTime.now() >= deadline ? "poll" : "interrupt")
            return
        }

        let tag = send("IDLE")
        let startDeadline = DispatchTime.now() + .seconds(Self.commandTimeout)
        var changed = false
        while true {
            let response = try await read(until: startDeadline)
            let words = response.line.split(separator: " ", maxSplits: 2)
            if words.first == "+" { break }
            if words.first == Substring(tag) {
                if words.dropFirst().first?.uppercased() == "BAD" {
                    supportsIdle = false
                    wakeOutcome = "idle-unsupported"
                    return
                }
                throw Self.serverError(response)
            }
            guard words.first == "*" else { throw MailIMAPError.invalidResponse }
            if try observe(response) { changed = true }
        }

        let idleStart = MailTiming.now()
        var outcome = "idle-change"
        if !changed {
            let deadline = DispatchTime.now() + .seconds(25 * 60)
            var woke = false
            while let response = try await socket.receive(until: deadline, interruptible: true) {
                try Task.checkCancellation()
                let words = response.line.split(separator: " ", maxSplits: 2)
                if words.first == Substring(tag) {
                    guard words.dropFirst().first?.uppercased() == "OK" else { throw Self.serverError(response) }
                    wakeOutcome = "idle-server-end"
                    return
                }
                guard words.first == "*" else { throw MailIMAPError.invalidResponse }
                if try observe(response) { woke = true; break }
            }
            if !woke { outcome = DispatchTime.now() >= deadline ? "idle-renew" : "interrupt" }
        }
        try Task.checkCancellation()
        let exitStart = MailTiming.now()
        socket.send("DONE\r\n")
        bytesReceived = 0
        _ = try await completion(tag: tag, until: DispatchTime.now() + .seconds(Self.commandTimeout))
        wakeOutcome = outcome
        MailTiming.line("idle-exit \(timingContext) outcome=\(outcome) idle_ms=\(MailTiming.ms(from: idleStart, to: exitStart)) done_ack_ms=\(MailTiming.ms(since: exitStart)) bytes=\(bytesReceived)")
    }

    func body(of message: MailMessage) async throws -> String {
        try await content(of: message).text
    }

    func content(of message: MailMessage) async throws -> MailContent {
        let contentStart = MailTiming.now()
        try validate(message)
        let sizes = try await command("UID FETCH \(message.uid) (UID RFC822.SIZE)")
        guard let size = sizes.lazy.compactMap(\.fetch)
            .first(where: { $0.uid == message.uid && $0.messageSize != nil })?.messageSize else {
            throw MailIMAPError.staleMessage
        }
        guard size <= Self.messageSizeLimit else { throw MailIMAPError.messageTooLarge }

        let responses = try await command("UID FETCH \(message.uid) (UID BODY.PEEK[])", timeout: 60)
        for response in responses {
            guard let fetch = response.fetch, fetch.uid == message.uid, let bytes = fetch.body("") else { continue }
            guard bytes.count <= Self.messageSizeLimit else { throw MailIMAPError.messageTooLarge }
            let parseStart = MailTiming.now()
            let parsed = MailMIME.content(bytes)
            MailTiming.line("mime-parse \(timingContext) ms=\(MailTiming.ms(since: parseStart)) raw_bytes=\(bytes.count)")
            MailTiming.line("content-fetched \(timingContext) imap_and_parse_ms=\(MailTiming.ms(since: contentStart))")
            return parsed
        }
        throw MailIMAPError.staleMessage
    }

    func markRead(_ message: MailMessage) async throws {
        try validate(message)
        _ = try await command("UID STORE \(message.uid) +FLAGS.SILENT (\\Seen)")
    }

    func markAllRead() async throws {
        let uids = try await unseenUIDs().sorted()
        for first in stride(from: 0, to: uids.count, by: 300) {
            let set = uids[first..<min(first + 300, uids.count)].map(String.init).joined(separator: ",")
            _ = try await command("UID STORE \(set) +FLAGS.SILENT (\\Seen)")
        }
    }

    func archive(_ message: MailMessage) async throws {
        try validate(message)
        try await move(message, toTrash: false)
    }

    func trash(_ message: MailMessage) async throws {
        try validate(message)
        try await move(message, toTrash: true)
    }

    private func move(_ message: MailMessage, toTrash: Bool) async throws {
        // LIST supplies the wire name (including modified UTF-7). Only quote it for the command.
        let boxes = try await listMailboxes()
        let archive = MailIMAPMailbox.archive(in: boxes, provider: provider)
        archiveAvailable = supportsMove && archive != nil
        guard let mailbox = toTrash ? MailIMAPMailbox.trash(in: boxes) : archive else { throw MailIMAPError.missingMailbox }
        let name = try Self.quote(mailbox.name)
        if capabilities.contains("MOVE") {
            _ = try await command("UID MOVE \(message.uid) \(name)")
        } else {
            // Ordinary EXPUNGE could permanently remove other clients' pending deletions.
            guard capabilities.contains("UIDPLUS") else { throw MailIMAPError.moveUnsupported }
            _ = try await command("UID COPY \(message.uid) \(name)")
            _ = try await command("UID STORE \(message.uid) +FLAGS.SILENT (\\Deleted)")
            _ = try await command("UID EXPUNGE \(message.uid)")
        }
    }

    private var supportsMove: Bool { capabilities.contains("MOVE") || capabilities.contains("UIDPLUS") }

    private func listMailboxes() async throws -> [MailIMAPMailbox] {
        if provider != .gmail && capabilities.contains("SPECIAL-USE") {
            do {
                return try await command("LIST \"\" \"*\" RETURN (SPECIAL-USE)").compactMap(\.mailbox)
            } catch MailIMAPError.rejected {
                // A plain listing can still provide the named fallback mailboxes.
            }
        }
        return try await command("LIST \"\" \"*\"").compactMap(\.mailbox)
    }

    private func validate(_ message: MailMessage) throws {
        guard message.uid > 0, let validity, message.uidValidity == validity else {
            throw MailIMAPError.staleMessage
        }
    }

    private func unseenUIDs() async throws -> Set<UInt32> {
        var result: Set<UInt32> = []
        var foundSearch = false
        for response in try await command("UID SEARCH UNSEEN") {
            let words = response.line.split(separator: " ")
            guard words.first == "*", words.dropFirst().first?.uppercased() == "SEARCH" else { continue }
            foundSearch = true
            for word in words.dropFirst(2) {
                guard let uid = UInt32(word), uid > 0 else { throw MailIMAPError.invalidResponse }
                result.insert(uid)
            }
        }
        guard foundSearch else { throw MailIMAPError.invalidResponse }
        return result
    }

    private func send(_ command: String) -> String {
        nextTag += 1
        let tag = "C\(nextTag)"
        socket.send("\(tag) \(command)\r\n")
        return tag
    }

    private func command(_ command: String, timeout: Int = commandTimeout,
                         until deadline: DispatchTime? = nil, quiet: Bool = false) async throws -> [MailIMAPResponse] {
        try Task.checkCancellation()
        let started = MailTiming.now()
        bytesReceived = 0
        do {
            let responses = try await completion(tag: send(command), until: deadline ?? DispatchTime.now() + .seconds(timeout))
            record(command, started: started, outcome: "ok", quiet: quiet)
            return responses
        } catch {
            record(command, started: started, outcome: "err=\(MailTiming.describe(error))", quiet: false)
            throw error
        }
    }

    private func record(_ command: String, started: UInt64, outcome: String, quiet: Bool) {
        let ms = MailTiming.ms(since: started)
        bytesTotal += bytesReceived
        if quiet {
            quietCommands.count += 1
            quietCommands.ms += ms
            quietCommands.bytes += bytesReceived
        } else {
            MailTiming.line("cmd \(timingContext) cmd=\"\(MailTiming.verb(command))\" ms=\(ms) bytes=\(bytesReceived) \(outcome)")
        }
    }

    private func completion(tag: String, until deadline: DispatchTime) async throws -> [MailIMAPResponse] {
        var responses: [MailIMAPResponse] = []
        var reported: MailServerError = .offline
        var temporaryFailure = false
        var retainedBytes = 0
        while true {
            let response = try await read(until: deadline)
            bytesReceived += response.byteCount
            let words = response.line.split(separator: " ", maxSplits: 2)
            let status = words.dropFirst().first?.uppercased()
            if words.first == Substring(tag) {
                if status != "OK" {
                    guard status == "NO" || status == "BAD" else { throw MailIMAPError.invalidResponse }
                    let reason = Self.preferredError(reported, .classify(response.line))
                    if reason == .offline && !temporaryFailure && !response.line.uppercased().contains("[UNAVAILABLE]") {
                        throw MailIMAPError.rejected
                    }
                    throw MailIMAPError.server(reason)
                }
                if words.count == 3, words[2].uppercased().hasPrefix("[READ-ONLY]") {
                    throw MailIMAPError.server(.blocked)
                }
                return responses
            }
            guard words.first == "*" else { throw MailIMAPError.invalidResponse }
            if status == "OK" || status == "NO" || status == "BAD" || status == "BYE" {
                temporaryFailure = temporaryFailure || response.line.uppercased().contains("[UNAVAILABLE]")
                reported = Self.preferredError(reported, .classify(response.line))
            }
            if status == "BYE" { throw MailIMAPError.server(reported) }
            _ = try observe(response)
            // Only these data responses are consumed by callers. Keep unsolicited chatter out of memory.
            if status == "LIST" || status == "SEARCH" || status == "CAPABILITY"
                || (words.count == 3 && UInt32(words[1]) != nil && words[2].prefix(6).uppercased() == "FETCH ") {
                retainedBytes += response.byteCount
                guard retainedBytes <= 80 * 1024 * 1024, responses.count < 100_000 else {
                    throw MailIMAPError.responseTooLarge
                }
                responses.append(response)
            }
        }
    }

    private func read(until deadline: DispatchTime) async throws -> MailIMAPResponse {
        try Task.checkCancellation()
        guard let response = try await socket.receive(until: deadline, interruptible: false) else { throw MailIMAPError.timedOut }
        try Task.checkCancellation()
        return response
    }

    /// Returns whether the response warrants a new inbox snapshot.
    private func observe(_ response: MailIMAPResponse) throws -> Bool {
        let words = response.line.split(separator: " ", maxSplits: 3)
        guard words.first == "*", words.count >= 2 else { throw MailIMAPError.invalidResponse }
        let kind = words[1].uppercased()
        if kind == "BYE" { throw Self.serverError(response) }
        if kind == "OK", words.count >= 4, words[2].uppercased() == "[UIDVALIDITY",
           let end = words[3].firstIndex(of: "]"), let updated = UInt32(words[3][..<end]), updated > 0 {
            if let validity, updated != validity { throw MailIMAPError.invalidResponse }
            validity = updated
        }
        guard words.count >= 3, let number = Int(words[1]), number >= 0 else { return false }
        switch words[2].uppercased() {
        case "EXISTS":
            guard number != exists else { return false }
            exists = number
        case "EXPUNGE":
            exists = max(0, exists - 1)
        case "FETCH":
            if let fetch = response.fetch, fetch.body(Self.header) != nil
                || fetch.body("TEXT", partial: true) != nil || fetch.body("") != nil || fetch.messageSize != nil {
                return false
            }
        default:
            return false
        }
        revision += 1
        return true
    }

    private static func quote(_ text: String) throws -> String {
        guard !text.utf8.contains(where: { $0 == 0 || $0 == 10 || $0 == 13 }) else {
            throw MailIMAPError.invalidResponse
        }
        return "\"" + text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func serverError(_ response: MailIMAPResponse) -> MailIMAPError {
        .server(.classify(response.line))
    }

    private static func preferredError(_ first: MailServerError, _ second: MailServerError) -> MailServerError {
        let priority: [MailServerError] = [.blocked, .appPasswordRequired, .authenticationFailed]
        return priority.first { $0 == first || $0 == second } ?? .offline
    }
}

/// One pending read, a persistent framer, and ordered writes on the connection's serial queue.
private final class MailIMAPSocket: MailIMAPTransport, @unchecked Sendable {
    private let queue = DispatchQueue(label: "Cala.MailIMAP")
    private let connection: NWConnection
    private var framer = MailIMAPFramer(maxResponseSize: MailIMAP.messageSizeLimit + 64 * 1024)
    private var waiter: CheckedContinuation<MailIMAPResponse?, Error>?
    private var timer: DispatchWorkItem?
    private var readInProgress = false
    private var interruptible = false
    private var interrupted = false
    private var failure: MailIMAPError?
    private var ready = false

    init(host: String, port: UInt16) {
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tls)
    }

    func start() {
        queue.async { [self] in
            guard failure == nil else { return }
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    ready = true
                case .waiting where ready, .failed, .cancelled:
                    fail(.disconnected)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    func close() {
        queue.async { [self] in fail(.disconnected) }
    }

    func interrupt() {
        queue.async { [self] in
            if interruptible && waiter != nil {
                finish(.success(nil))
            } else {
                interrupted = true
            }
        }
    }

    func send(_ text: String) {
        queue.async { [self] in
            guard failure == nil else { return }
            connection.send(content: Data(text.utf8), completion: .contentProcessed { [weak self] error in
                if error != nil { self?.fail(.disconnected) }
            })
        }
    }

    func receive(until deadline: DispatchTime, interruptible: Bool = false) async throws -> MailIMAPResponse? {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard waiter == nil else {
                    continuation.resume(throwing: MailIMAPError.invalidResponse)
                    return
                }
                if interruptible && interrupted {
                    interrupted = false
                    continuation.resume(returning: nil)
                    return
                }
                // A busy stream of untagged responses still has to honor the command deadline.
                guard DispatchTime.now() < deadline else {
                    continuation.resume(returning: nil)
                    return
                }
                waiter = continuation
                self.interruptible = interruptible
                let timeout = DispatchWorkItem { [weak self] in self?.finish(.success(nil)) }
                timer = timeout
                queue.asyncAfter(deadline: deadline, execute: timeout)
                deliver()
            }
        }
    }

    private func deliver() {
        guard waiter != nil else { return }
        do {
            if let response = try framer.next() {
                finish(.success(response))
                return
            }
        } catch MailIMAPFramer.Failure.responseTooLarge {
            fail(.responseTooLarge)
            return
        } catch {
            fail(.invalidResponse)
            return
        }
        if let failure {
            finish(.failure(failure))
            return
        }
        guard !readInProgress else { return }
        readInProgress = true
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            readInProgress = false
            if let data { framer.append(data) }
            if complete || error != nil { failure = .disconnected }
            deliver()
        }
    }

    private func finish(_ result: Result<MailIMAPResponse?, Error>) {
        timer?.cancel()
        timer = nil
        let current = waiter
        waiter = nil
        interruptible = false
        current?.resume(with: result)
    }

    private func fail(_ error: MailIMAPError) {
        if failure == nil { failure = error }
        finish(.failure(error))
        connection.stateUpdateHandler = nil
        connection.cancel()
    }
}

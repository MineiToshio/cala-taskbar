import Foundation
import Network
import os

enum MailIMAPError: Error {
    case server(MailServerError)
    case disconnected, timedOut, invalidResponse, missingMailbox, staleMessage, moveUnsupported, rejected, responseTooLarge, messageTooLarge
    /// The server did not acknowledge DONE within MailLink.doneAckTimeout: the connection is silently dead.
    case linkDead
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
    /// True once (then cleared) after the network path lost viability or a better path appeared: the link should be probed.
    func takeLinkSuspect() -> Bool
    /// The current path is Low Data Mode or expensive (cellular, personal hotspot): skip background downloads.
    var isConstrainedPath: Bool { get }
}

extension MailIMAPTransport {
    func takeLinkSuspect() -> Bool { false }
    var isConstrainedPath: Bool { false }
}

/// Which command stream a connection uses. The two differ only in read-only commands; delete, archive and the flag
/// writes are the same commands in both.
struct MailIMAPTuning: Equatable {
    /// One LIST per connection (re-listed once when the cached mailbox is missing or a move is refused).
    var cachesMailboxList: Bool
    /// Syncs fetch UID FLAGS for the newest messages and headers only for UIDs not seen before.
    var incrementalSync: Bool
    /// Opening a message fetches RFC822.SIZE with BODYSTRUCTURE, then only its text and inline-image parts.
    var partialBodies: Bool
    /// Bodies of the top rows may be downloaded ahead of time.
    var prefetch: Bool

    static let fast = MailIMAPTuning(cachesMailboxList: true, incrementalSync: true, partialBodies: true, prefetch: true)
    /// The original stream (a LIST before every move, RFC822.SIZE then BODY.PEEK[], a full FETCH every sync), which the
    /// transcript checks pin. Injected transports use it unless they ask for `.fast`.
    static let conservative = MailIMAPTuning(cachesMailboxList: false, incrementalSync: false, partialBodies: false, prefetch: false)
}

/// The account worker owns the command stream. Only close and requestRefresh can be called concurrently.
final class MailIMAP {
    private static let header = "HEADER.FIELDS (FROM SUBJECT DATE CONTENT-TYPE CONTENT-TRANSFER-ENCODING CONTENT-DISPOSITION)"
    private static let previewSize = 16 * 1024
    private static let extendedPreviewSize = 256 * 1024
    /// BODYSTRUCTURE-guided second look at a preview: one part, from its start.
    private static let partPreviewSize = 32 * 1024
    fileprivate static let messageSizeLimit = 25 * 1024 * 1024
    private static let commandTimeout = MailLink.commandTimeout

    private let socket: MailIMAPTransport
    private let provider: MailProvider
    let tuning: MailIMAPTuning

    convenience init(provider: MailProvider = .gmail) {
        self.init(socket: MailIMAPSocket(host: provider.host, port: provider.port), provider: provider, tuning: .fast)
    }

    init(socket: MailIMAPTransport, provider: MailProvider = .gmail, tuning: MailIMAPTuning = .conservative) {
        self.socket = socket
        self.provider = provider
        self.tuning = tuning
    }
    private var nextTag = 0
    private var capabilities: Set<String> = []
    private var supportsIdle = false
    private var exists = 0
    private var validity: UInt32?
    private var revision = 0
    private var archiveAvailable: Bool?
    private var mailboxCache: [MailIMAPMailbox]?
    /// While our own FETCH runs, its FETCH responses are answers, not news about the mailbox.
    private var solicitedFetch = false
    // Latency instrumentation (mail-timing log lines only; no behaviour depends on these).
    /// Set by MailService: whose lines these are ("acct=... op=N" / "sync=N" / "signin" / "idle").
    var timingContext = ""
    /// Set by MailService before synchronize: why it runs.
    var timingReason = ""
    /// How the last waitForInboxChange ended: change, poll, interrupt, idle-change, idle-renew, idle-server-end, link-check.
    private(set) var wakeOutcome = ""
    private var bytesReceived = 0
    private var bytesTotal = 0
    private var quietCommands = (count: 0, ms: 0, bytes: 0)

    /// Bumped whenever the server reports a change to the mailbox (EXISTS, EXPUNGE, flag FETCH).
    var changeRevision: Int { revision }
    var isConstrainedPath: Bool { socket.isConstrainedPath }

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
        guard let snapshot = try await synchronize(accountID: accountID, known: nil, shouldYield: nil) else {
            throw MailIMAPError.invalidResponse
        }
        return snapshot
    }

    /// One inbox snapshot. `known`: messages read before (incremental tuning only). Returns nil, having changed nothing,
    /// when `shouldYield` asks it to step aside between two commands (the person is waiting for something else).
    func synchronize(accountID: String, known: MailKnownMessages?, shouldYield: (() -> Bool)?) async throws -> MailInboxSnapshot? {
        let syncStart = MailTiming.now()
        bytesTotal = 0
        quietCommands = (0, 0, 0)
        let mode = tuning.incrementalSync ? "incremental" : "full"
        MailTiming.line("sync-start \(timingContext) reason=\(timingReason) mode=\(mode)")
        func yielded(_ step: String) -> Bool {
            guard shouldYield?() == true else { return false }
            MailTiming.line("sync-yield \(timingContext) step=\(step) ms=\(MailTiming.ms(since: syncStart))")
            return true
        }
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
        if yielded("noop") { return nil }
        let startRevision = revision
        let result: (messages: [UInt32: MailMessage], unseen: Set<UInt32>, fetched: Int)?
        if tuning.incrementalSync {
            result = try await incrementalMessages(accountID: accountID, validity: validity, known: known, yielded: yielded)
        } else {
            result = try await fullMessages(accountID: accountID, validity: validity, yielded: yielded)
        }
        guard let result else { return nil }
        // If the mailbox changed mid-snapshot, take another pass before waiting for IDLE.
        if revision != startRevision { requestRefresh() }
        let latest = result.messages.values.sorted { $0.uid > $1.uid }.prefix(MailLink.window)
        if quietCommands.count > 0 {
            MailTiming.line("sync-extended-previews \(timingContext) n=\(quietCommands.count) ms=\(quietCommands.ms) bytes=\(quietCommands.bytes)")
        }
        MailTiming.line("sync-done \(timingContext) reason=\(timingReason) mode=\(mode) total_ms=\(MailTiming.ms(since: syncStart)) bytes=\(bytesTotal) messages=\(latest.count) fetched_headers=\(result.fetched) unread=\(result.unseen.count)")
        return MailInboxSnapshot(validity: validity, messages: Array(latest), unread: result.unseen.count,
                                 canArchive: archiveAvailable == true)
    }

    /// The original sync: headers and a 16 KB preview of the newest 25, a 256 KB second try per empty preview.
    private func fullMessages(accountID: String, validity: UInt32,
                              yielded: (String) -> Bool) async throws -> (messages: [UInt32: MailMessage], unseen: Set<UInt32>, fetched: Int)? {
        var headers: [MailIMAPFetch] = []
        if exists > 0 {
            let first = max(1, exists - 24)
            let fields = "UID INTERNALDATE\(gmailIDs) BODY.PEEK[\(Self.header)] BODY.PEEK[TEXT]<0.\(Self.previewSize)>"
            let responses = try await command("FETCH \(first):* (\(fields))")
            headers = responses.compactMap { response in
                let fetch = response.fetch
                return fetch?.body(Self.header) == nil ? nil : fetch
            }
        }
        if yielded("headers") { return nil }
        let unseen = try await unseenUIDs()
        var messages: [UInt32: MailMessage] = [:]
        for fetch in headers {
            guard let uid = fetch.uid, uid > 0, let header = fetch.body(Self.header) else { continue }
            let fields = MailMIME.headers(header)
            var snippet = ""
            if let preview = fetch.body("TEXT", partial: true) {
                snippet = MailMIME.snippet(preview, headers: fields)
                if snippet.isEmpty && preview.count == Self.previewSize {
                    if yielded("previews") { return nil }
                    let responses = try await command("UID FETCH \(uid) (UID BODY.PEEK[TEXT]<0.\(Self.extendedPreviewSize)>)", quiet: true)
                    if let extended = responses.lazy.compactMap(\.fetch)
                        .first(where: { $0.uid == uid && $0.body("TEXT", partial: true) != nil })?
                        .body("TEXT", partial: true) {
                        snippet = MailMIME.snippet(extended, headers: fields)
                    }
                }
            }
            messages[uid] = Self.message(fetch, uid: uid, fields: fields, snippet: snippet, accountID: accountID,
                                         validity: validity, unread: unseen.contains(uid))
        }
        return (messages, unseen, headers.count)
    }

    /// UID FLAGS for the newest 25, headers and previews only for UIDs not seen before (same validity), and one
    /// BODYSTRUCTURE-guided look at a single text part for previews whose first 16 KB had nothing readable.
    private func incrementalMessages(accountID: String, validity: UInt32, known: MailKnownMessages?,
                                     yielded: (String) -> Bool) async throws -> (messages: [UInt32: MailMessage], unseen: Set<UInt32>, fetched: Int)? {
        var window: [UInt32] = []
        if let range = MailSyncPlanner.window(exists: exists) {
            window = try await solicited { try await command("FETCH \(range.lowerBound):* (UID FLAGS)") }
                .compactMap { $0.fetch?.uid }
        }
        let plan = MailSyncPlanner.plan(window: window, known: known, validity: validity)
        if yielded("window") { return nil }
        var headers: [MailIMAPFetch] = []
        if !plan.missing.isEmpty {
            let fields = "UID INTERNALDATE\(gmailIDs) BODY.PEEK[\(Self.header)] BODY.PEEK[TEXT]<0.\(Self.previewSize)>"
            headers = try await solicited {
                try await command("UID FETCH \(MailSyncPlanner.uidSet(plan.missing)) (\(fields))")
            }.compactMap { response in
                let fetch = response.fetch
                return fetch?.body(Self.header) == nil ? nil : fetch
            }
            if yielded("headers") { return nil }
        }
        let unseen = try await unseenUIDs()
        var messages: [UInt32: MailMessage] = [:]
        for uid in plan.known {
            guard var message = known?.message(uid) else { continue }
            message.unread = unseen.contains(uid)
            messages[uid] = message
        }
        var emptyPreviews: [UInt32: [String: String]] = [:]
        for fetch in headers {
            guard let uid = fetch.uid, uid > 0, plan.missing.contains(uid), let header = fetch.body(Self.header) else { continue }
            let fields = MailMIME.headers(header)
            var snippet = ""
            if let preview = fetch.body("TEXT", partial: true) {
                snippet = MailMIME.snippet(preview, headers: fields)
                if snippet.isEmpty && preview.count == Self.previewSize { emptyPreviews[uid] = fields }
            }
            messages[uid] = Self.message(fetch, uid: uid, fields: fields, snippet: snippet, accountID: accountID,
                                         validity: validity, unread: unseen.contains(uid))
        }
        if !emptyPreviews.isEmpty, !yielded("previews") {
            for (uid, snippet) in try await partPreviews(Array(emptyPreviews.keys)) {
                guard let message = messages[uid] else { continue }
                messages[uid] = message.withSnippet(snippet)
            }
        }
        return (messages, unseen, headers.count)
    }

    /// One BODYSTRUCTURE fetch for all of `uids`, then one partial fetch per distinct text part.
    private func partPreviews(_ uids: [UInt32]) async throws -> [UInt32: String] {
        let started = MailTiming.now()
        let bytesBefore = bytesTotal
        let structures = try await solicited {
            try await command("UID FETCH \(MailSyncPlanner.uidSet(uids)) (UID BODYSTRUCTURE)")
        }
        var groups: [String: [(uid: UInt32, part: MailBodyPart)]] = [:]
        for fetch in structures.compactMap(\.fetch) {
            guard let uid = fetch.uid, uids.contains(uid), let structure = fetch.bodyStructure,
                  let part = MailPartPlan.previewPart(structure) else { continue }
            groups[part.section, default: []].append((uid, part))
        }
        var snippets: [UInt32: String] = [:]
        for (section, members) in groups.sorted(by: { $0.key < $1.key }) {
            let set = MailSyncPlanner.uidSet(members.map(\.uid))
            let responses = try await solicited {
                try await command("UID FETCH \(set) (UID BODY.PEEK[\(section)]<0.\(Self.partPreviewSize)>)", quiet: true)
            }
            for fetch in responses.compactMap(\.fetch) {
                guard let uid = fetch.uid, let member = members.first(where: { $0.uid == uid }),
                      let bytes = fetch.body(section, partial: true) else { continue }
                let snippet = MailMIME.snippet(bytes, headers: MailPartPlan.headerFields(for: member.part))
                if !snippet.isEmpty { snippets[uid] = snippet }
            }
        }
        MailTiming.line("sync-part-previews \(timingContext) n=\(uids.count) parts=\(groups.count) found=\(snippets.count) ms=\(MailTiming.ms(since: started)) bytes=\(bytesTotal - bytesBefore)")
        return snippets
    }

    private var gmailIDs: String { capabilities.contains("X-GM-EXT-1") ? " X-GM-THRID X-GM-MSGID" : "" }

    private static func message(_ fetch: MailIMAPFetch, uid: UInt32, fields: [String: String], snippet: String,
                                accountID: String, validity: UInt32, unread: Bool) -> MailMessage {
        let sender = MailMIME.from(fields["from"] ?? "")
        return MailMessage(
            id: "\(accountID)#\(validity)#\(uid)", accountID: accountID, uid: uid,
            fromName: sender.name, fromAddress: sender.address,
            subject: MailMIME.decodeHeader(fields["subject"] ?? ""), snippet: snippet,
            date: fetch.internalDate ?? .distantPast, unread: unread,
            gmailThreadID: fetch.threadID, gmailMessageID: fetch.messageID, uidValidity: validity
        )
    }

    func waitForInboxChange() async throws {
        wakeOutcome = ""
        guard supportsIdle else {
            let deadline = DispatchTime.now() + .seconds(MailLink.pollInterval)
            var woke = false
            while let response = try await socket.receive(until: deadline, interruptible: true) {
                try Task.checkCancellation()
                if try observe(response) { woke = true; break }
            }
            if woke { wakeOutcome = "change" }
            else if DispatchTime.now() >= deadline { wakeOutcome = "poll" }
            else { wakeOutcome = socket.takeLinkSuspect() ? "link-check" : "interrupt" }
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
            // Re-armed well before Gmail's silent drop (~25 min observed) and the 29-minute IDLE limit.
            let deadline = DispatchTime.now() + .seconds(MailLink.idleRearm)
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
            if !woke {
                if DispatchTime.now() >= deadline { outcome = "idle-renew" }
                else { outcome = socket.takeLinkSuspect() ? "link-check" : "interrupt" }
            }
        }
        try Task.checkCancellation()
        let exitStart = MailTiming.now()
        socket.send("DONE\r\n")
        bytesReceived = 0
        do {
            // A live server answers DONE in a round trip; silence means the link died while idle.
            _ = try await completion(tag: tag, until: DispatchTime.now() + .seconds(MailLink.doneAckTimeout))
        } catch MailIMAPError.timedOut {
            MailTiming.line("link-dead \(timingContext) reason=done-ack-timeout outcome=\(outcome) idle_ms=\(MailTiming.ms(from: idleStart, to: exitStart)) waited_ms=\(MailTiming.ms(since: exitStart))")
            throw MailIMAPError.linkDead
        }
        wakeOutcome = outcome
        MailTiming.line("idle-exit \(timingContext) outcome=\(outcome) idle_ms=\(MailTiming.ms(from: idleStart, to: exitStart)) done_ack_ms=\(MailTiming.ms(since: exitStart)) bytes=\(bytesReceived)")
    }

    func body(of message: MailMessage) async throws -> String {
        try await content(of: message).text
    }

    func content(of message: MailMessage) async throws -> MailContent {
        let contentStart = MailTiming.now()
        try validate(message)
        guard tuning.partialBodies else { return try await wholeContent(of: message, started: contentStart) }

        // One round trip for the size and the structure, one for just the readable parts.
        let responses = try await solicited {
            try await command("UID FETCH \(message.uid) (UID RFC822.SIZE BODYSTRUCTURE)")
        }
        guard let info = responses.lazy.compactMap(\.fetch)
            .first(where: { $0.uid == message.uid && $0.messageSize != nil }), let size = info.messageSize else {
            throw MailIMAPError.staleMessage
        }
        if let structure = info.bodyStructure, let plan = MailPartPlan.plan(structure) {
            if let parsed = try await partialContent(uid: message.uid, structure: structure, plan: plan) {
                MailTiming.line("body-plan \(timingContext) mode=partial sections=\(plan.sections.count) part_bytes=\(plan.bytes) full_bytes=\(size)")
                MailTiming.line("content-fetched \(timingContext) imap_and_parse_ms=\(MailTiming.ms(since: contentStart))")
                return parsed
            }
            MailTiming.line("body-plan \(timingContext) mode=full reason=assemble full_bytes=\(size)")
        } else {
            MailTiming.line("body-plan \(timingContext) mode=full reason=\(info.structureTokens == nil ? "no-structure" : "unsure") full_bytes=\(size)")
        }
        guard size <= Self.messageSizeLimit else { throw MailIMAPError.messageTooLarge }
        return try await fullBody(of: message, started: contentStart)
    }

    /// The original reader fetch: RFC822.SIZE, then the whole message.
    private func wholeContent(of message: MailMessage, started contentStart: UInt64) async throws -> MailContent {
        let sizes = try await command("UID FETCH \(message.uid) (UID RFC822.SIZE)")
        guard let size = sizes.lazy.compactMap(\.fetch)
            .first(where: { $0.uid == message.uid && $0.messageSize != nil })?.messageSize else {
            throw MailIMAPError.staleMessage
        }
        guard size <= Self.messageSizeLimit else { throw MailIMAPError.messageTooLarge }
        return try await fullBody(of: message, started: contentStart)
    }

    private func fullBody(of message: MailMessage, started contentStart: UInt64) async throws -> MailContent {
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

    /// Fetches the planned parts with their MIME headers and reads them as MailMIME reads the whole message.
    /// nil: a part was missing or the rebuild was unsafe, so the caller fetches the whole message.
    private func partialContent(uid: UInt32, structure: MailBodyPart, plan: MailPartPlan) async throws -> MailContent? {
        let items = plan.sections.map { "BODY.PEEK[\($0).MIME] BODY.PEEK[\($0)]" }.joined(separator: " ")
        let responses = try await solicited { try await command("UID FETCH \(uid) (UID \(items))", timeout: 60) }
        var parts: [String: MailPartAssembler.Part] = [:]
        for fetch in responses.compactMap(\.fetch) where fetch.uid == uid {
            for section in plan.sections where parts[section] == nil {
                if let header = fetch.body(section + ".MIME"), let body = fetch.body(section) {
                    parts[section] = MailPartAssembler.Part(header: header, body: body)
                }
            }
        }
        guard parts.count == plan.sections.count else { return nil }
        let seed = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        guard let message = MailPartAssembler.assemble(structure, parts: parts, boundary: seed) else { return nil }
        let parseStart = MailTiming.now()
        let parsed = MailMIME.content(message)
        MailTiming.line("mime-parse \(timingContext) ms=\(MailTiming.ms(since: parseStart)) raw_bytes=\(message.count) partial=true")
        return parsed
    }

    /// Background download of `messages`' readable parts, stopping between messages when `shouldStop` says so or the
    /// mailbox changes. Messages over `maxPart` per part, unknown structures and anything past `budget` are skipped.
    func prefetch(_ messages: [MailMessage], maxPart: Int = MailPrefetchPlanner.maxPart, budget: Int = MailPrefetchPlanner.budget,
                  shouldStop: () -> Bool) async throws -> (contents: [(MailMessage, MailContent)], stop: String) {
        let valid = messages.filter { (try? validate($0)) != nil }
        guard tuning.partialBodies, !valid.isEmpty else { return ([], "none") }
        let startRevision = revision
        let responses = try await solicited {
            try await command("UID FETCH \(MailSyncPlanner.uidSet(valid.map(\.uid))) (UID RFC822.SIZE BODYSTRUCTURE)")
        }
        var plans: [UInt32: (structure: MailBodyPart, plan: MailPartPlan)] = [:]
        var sizes: [UInt32: (bytes: Int, largest: Int)] = [:]
        for fetch in responses.compactMap(\.fetch) {
            guard let uid = fetch.uid, let structure = fetch.bodyStructure, let plan = MailPartPlan.plan(structure) else { continue }
            let largest = structure.leaves.filter { plan.sections.contains($0.section) }.map(\.size).max() ?? 0
            plans[uid] = (structure, plan)
            sizes[uid] = (plan.bytes, largest)
        }
        var contents: [(MailMessage, MailContent)] = []
        for message in MailPrefetchPlanner.select(valid, sizes: sizes, maxPart: maxPart, budget: budget) {
            if shouldStop() { return (contents, "interactive") }
            if revision != startRevision { return (contents, "change") }
            guard let planned = plans[message.uid] else { continue }
            if let content = try await partialContent(uid: message.uid, structure: planned.structure, plan: planned.plan) {
                contents.append((message, content))
            }
        }
        return (contents, revision != startRevision ? "change" : "done")
    }

    func markRead(_ message: MailMessage) async throws {
        try validate(message)
        _ = try await command("UID STORE \(message.uid) +FLAGS.SILENT (\\Seen)")
    }

    func markUnread(_ message: MailMessage) async throws {
        try validate(message)
        _ = try await command("UID STORE \(message.uid) -FLAGS.SILENT (\\Seen)")
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
        var cached = tuning.cachesMailboxList && mailboxCache != nil
        var boxes = try await listMailboxes(reuse: true)
        func target(_ boxes: [MailIMAPMailbox]) -> MailIMAPMailbox? {
            let archive = MailIMAPMailbox.archive(in: boxes, provider: provider)
            archiveAvailable = supportsMove && archive != nil
            return toTrash ? MailIMAPMailbox.trash(in: boxes) : archive
        }
        var mailbox = target(boxes)
        if mailbox == nil && cached {
            // The cached listing may be out of date: list once more before giving up.
            boxes = try await listMailboxes(reuse: false)
            cached = false
            mailbox = target(boxes)
        }
        guard var mailbox else { throw MailIMAPError.missingMailbox }
        if capabilities.contains("MOVE") {
            do {
                _ = try await command("UID MOVE \(message.uid) \(Self.quote(mailbox.name))")
            } catch MailIMAPError.rejected where cached {
                // NO/BAD means nothing moved; a renamed mailbox is the likely cause. One retry with a fresh listing.
                guard let fresh = target(try await listMailboxes(reuse: false)) else { throw MailIMAPError.missingMailbox }
                _ = try await command("UID MOVE \(message.uid) \(Self.quote(fresh.name))")
            }
        } else {
            // Ordinary EXPUNGE could permanently remove other clients' pending deletions.
            guard capabilities.contains("UIDPLUS") else { throw MailIMAPError.moveUnsupported }
            do {
                _ = try await command("UID COPY \(message.uid) \(Self.quote(mailbox.name))")
            } catch MailIMAPError.rejected where cached {
                guard let fresh = target(try await listMailboxes(reuse: false)) else { throw MailIMAPError.missingMailbox }
                mailbox = fresh
                _ = try await command("UID COPY \(message.uid) \(Self.quote(mailbox.name))")
            }
            _ = try await command("UID STORE \(message.uid) +FLAGS.SILENT (\\Deleted)")
            _ = try await command("UID EXPUNGE \(message.uid)")
        }
    }

    private var supportsMove: Bool { capabilities.contains("MOVE") || capabilities.contains("UIDPLUS") }

    /// `reuse`: with the caching tuning, answer from this connection's earlier listing when there is one.
    private func listMailboxes(reuse: Bool = true) async throws -> [MailIMAPMailbox] {
        if reuse, tuning.cachesMailboxList, let mailboxCache { return mailboxCache }
        let boxes = try await freshMailboxes()
        if tuning.cachesMailboxList { mailboxCache = boxes }
        return boxes
    }

    private func freshMailboxes() async throws -> [MailIMAPMailbox] {
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

    /// Runs one of our own FETCH commands: its FETCH responses don't count as mailbox changes.
    private func solicited(_ body: () async throws -> [MailIMAPResponse]) async throws -> [MailIMAPResponse] {
        solicitedFetch = true
        defer { solicitedFetch = false }
        return try await body()
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
            if solicitedFetch { return false }
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

private extension MailMessage {
    func withSnippet(_ snippet: String) -> MailMessage {
        MailMessage(id: id, accountID: accountID, uid: uid, fromName: fromName, fromAddress: fromAddress, subject: subject,
                    snippet: snippet, date: date, unread: unread, gmailThreadID: gmailThreadID,
                    gmailMessageID: gmailMessageID, uidValidity: uidValidity)
    }
}

extension MailIMAPFetch {
    var bodyStructure: MailBodyPart? { structureTokens.flatMap(MailBodyStructure.parse) }
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
    /// Read from the worker's context; written on `queue`.
    private let pathState = OSAllocatedUnfairLock(initialState: (suspect: false, constrained: false))

    init(host: String, port: UInt16) {
        // Keepalive probes keep NAT mappings open and turn a silently dead link into a failed connection in about
        // idle + interval × count seconds, instead of finding out on the next command.
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = MailLink.keepaliveIdle
        tcp.keepaliveInterval = MailLink.keepaliveInterval
        tcp.keepaliveCount = MailLink.keepaliveCount
        tcp.connectionTimeout = MailLink.commandTimeout
        let parameters = NWParameters(tls: NWProtocolTLS.Options(), tcp: tcp)
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: parameters)
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
                    if ready { MailTiming.line("link-state state=\(Self.describe(state))") }
                    fail(.disconnected)
                default:
                    break
                }
            }
            connection.viabilityUpdateHandler = { [weak self] viable in
                guard let self, ready, !viable else { return }
                MailTiming.line("link-viability viable=false")
                suspect()
            }
            connection.betterPathUpdateHandler = { [weak self] better in
                guard let self, ready, better else { return }
                MailTiming.line("link-better-path")
                suspect()
            }
            connection.pathUpdateHandler = { [weak self] path in
                let constrained = path.isConstrained || path.isExpensive
                self?.pathState.withLock { $0.constrained = constrained }
            }
            connection.start(queue: queue)
        }
    }

    /// Wakes the worker out of IDLE so it ends IDLE and finds out within MailLink.doneAckTimeout whether the link lives.
    private func suspect() {
        pathState.withLock { $0.suspect = true }
        if interruptible && waiter != nil {
            finish(.success(nil))
        } else {
            interrupted = true
        }
    }

    private static func describe(_ state: NWConnection.State) -> String {
        switch state {
        case .waiting: "waiting"
        case .failed: "failed"
        case .cancelled: "cancelled"
        default: "other"
        }
    }

    func takeLinkSuspect() -> Bool {
        pathState.withLock { state in
            defer { state.suspect = false }
            return state.suspect
        }
    }

    var isConstrainedPath: Bool { pathState.withLock { $0.constrained } }

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
        connection.viabilityUpdateHandler = nil
        connection.betterPathUpdateHandler = nil
        connection.pathUpdateHandler = nil
        connection.cancel()
    }
}

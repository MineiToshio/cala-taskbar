import Combine
import Foundation

// Oracle checks for the optimistic overlay, the body cache, BODYSTRUCTURE-guided partial bodies, incremental sync and
// the `.fast` command stream. They are written from the behaviour the person and the server should see, not from the
// implementation: a scripted IMAP "world" plays the server (shared mailbox state across reconnects), and an independent
// MIME splitter (below) supplies the BODY[n] / BODY[n.MIME] sections a real server would return.

// MARK: Waiting

@MainActor
func waitFor(_ seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
    while !condition() {
        if ContinuousClock.now >= deadline { return false }
        try? await Task.sleep(for: .milliseconds(3))
    }
    return true
}

// MARK: Independent MIME splitter (what a server returns for BODY[n] and BODY[n.MIME])

/// Leaf and multipart sections of a CRLF message, numbered as RFC 3501 numbers them. Header includes its blank line;
/// body excludes the CRLF that belongs to the next boundary delimiter (RFC 2046 §5.1.1).
func mimeSections(_ raw: Data) -> [String: MailPartAssembler.Part] {
    var result: [String: MailPartAssembler.Part] = [:]
    func split(_ entity: [UInt8]) -> (header: [UInt8], body: [UInt8]) {
        if entity.starts(with: [13, 10]) { return ([13, 10], Array(entity.dropFirst(2))) }
        var index = 0
        while index + 3 < entity.count {
            if entity[index] == 13, entity[index + 1] == 10, entity[index + 2] == 13, entity[index + 3] == 10 {
                return (Array(entity[..<(index + 4)]), Array(entity[(index + 4)...]))
            }
            index += 1
        }
        return (entity, [])
    }
    func boundaryOf(_ header: [UInt8]) -> String? {
        let text = String(decoding: header, as: UTF8.self)
            .replacingOccurrences(of: "\r\n ", with: " ").replacingOccurrences(of: "\r\n\t", with: " ")
        guard let line = text.components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("content-type:") }),
              line.lowercased().contains("multipart/"),
              let range = line.range(of: "boundary=", options: .caseInsensitive) else { return nil }
        let value = line[range.upperBound...]
        if value.hasPrefix("\"") { return String(value.dropFirst().prefix { $0 != "\"" }) }
        return String(value.prefix { $0 != ";" && $0 != " " })
    }
    func walk(_ body: [UInt8], boundary: String, prefix: String) {
        let delimiter = Array("--\(boundary)".utf8)
        var marks: [(partEnd: Int, contentStart: Int, close: Bool)] = []
        var index = 0
        while index + delimiter.count <= body.count {
            let lineStart = index == 0 || (index >= 2 && body[index - 2] == 13 && body[index - 1] == 10)
            if lineStart && Array(body[index..<(index + delimiter.count)]) == delimiter {
                let after = index + delimiter.count
                let close = after + 1 < body.count && body[after] == 45 && body[after + 1] == 45
                var end = after
                while end < body.count && body[end] != 10 { end += 1 }
                marks.append((index >= 2 ? index - 2 : 0, min(end + 1, body.count), close))
                if close { break }
                index = min(end + 1, body.count)
                continue
            }
            index += 1
        }
        for number in 0..<max(0, marks.count - 1) where !marks[number].close {
            let content = Array(body[marks[number].contentStart..<max(marks[number].contentStart, marks[number + 1].partEnd)])
            let section = prefix.isEmpty ? "\(number + 1)" : "\(prefix).\(number + 1)"
            let (header, partBody) = split(content)
            result[section] = MailPartAssembler.Part(header: Data(header), body: Data(partBody))
            if let inner = boundaryOf(header) { walk(partBody, boundary: inner, prefix: section) }
        }
    }
    let (header, body) = split(Array(raw))
    if let top = boundaryOf(header) {
        walk(body, boundary: top, prefix: "")
    } else {
        result["1"] = MailPartAssembler.Part(header: Data(header), body: Data(body))
    }
    return result
}

// MARK: Scripted IMAP world

/// The world of the latest connection, for MAIL_DEBUG=1 dumps when a block of checks throws.
nonisolated(unsafe) var lastWorld: FakeIMAPWorld?
func debugDump(_ label: String) {
    guard ProcessInfo.processInfo.environment["MAIL_DEBUG"] != nil, let world = lastWorld else { return }
    print("DEBUG \(label):")
    for entry in world.log.suffix(30) { print("  c\(entry.connection) \(entry.status) \(entry.command)") }
}

/// Server state shared by every connection the client opens (so a reconnect sees what the previous connection did),
/// plus a log of every command with the status it got and scripted misbehaviour.
final class FakeIMAPWorld: @unchecked Sendable {
    struct Message {
        var uid: UInt32
        var unread: Bool
        var raw: Data
        var structure: String?
        var deleted = false
    }
    enum Action {
        case reply(String)       // "§" is the tag
        case hold                // no answer until `release`
        case drop                // connection closes before answering (nothing done)
        case applyThenDrop       // the server did it, the answer is lost
        case silent              // never answers, connection stays up
        case timeOut             // never answers and the client's wait for it ends at once (its deadline "passed")
    }
    struct Rule { let prefix: String; let action: Action; var times: Int }
    struct Entry { let connection: Int; let command: String; var status: String }

    let lock = NSLock()
    var validity: UInt32 = 7
    var messages: [Message] = []
    var capabilities = "IDLE MOVE UIDPLUS X-GM-EXT-1"
    var list = #"* LIST () "/" INBOX"# + "\r\n" + #"* LIST (\All) "/" "[Gmail]/All Mail""# + "\r\n"
        + #"* LIST (\Trash) "/" "[Gmail]/Trash""# + "\r\n"
    var constrained = true
    var rules: [Rule] = []
    private(set) var entries: [Entry] = []
    private(set) var connectionsStore: [FakeIMAPConnection] = []
    var connections: [FakeIMAPConnection] { locked { connectionsStore } }
    private var held: [(connection: FakeIMAPConnection, tag: String, command: String, entry: Int)] = []

    init(uids: [(UInt32, Bool)] = []) {
        messages = uids.map { Message(uid: $0.0, unread: $0.1, raw: Self.simpleRaw($0.0), structure: Self.simpleStructure($0.0)) }
    }

    static func simpleRaw(_ uid: UInt32) -> Data {
        Data("From: Sender \(uid) <s\(uid)@example.test>\r\nSubject: Subject \(uid)\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nHola \(uid)".utf8)
    }
    static func simpleStructure(_ uid: UInt32) -> String {
        #"("TEXT" "PLAIN" ("CHARSET" "utf-8") NIL NIL "7BIT" \#("Hola \(uid)".utf8.count) 1 NIL NIL NIL)"#
    }

    func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    func connect() -> FakeIMAPConnection {
        lastWorld = self
        return locked {
            let connection = FakeIMAPConnection(world: self, number: connectionsStore.count + 1)
            connectionsStore.append(connection)
            return connection
        }
    }

    func add(_ rule: Rule) { locked { rules.append(rule) } }
    func on(_ prefix: String, _ action: Action, times: Int = 1) { add(Rule(prefix: prefix, action: action, times: times)) }
    var connectionCount: Int { locked { connectionsStore.count } }
    var log: [Entry] { locked { entries } }
    var commands: [String] { log.map(\.command) }
    func count(_ prefix: String) -> Int { log.filter { $0.command.hasPrefix(prefix) }.count }
    var heldCount: Int { locked { held.count } }
    /// The newest connection is open and parked in IDLE (nothing on the wire).
    var isIdle: Bool { locked { connectionsStore.last.map { $0.idleTag != nil && !$0.closed && held.isEmpty } ?? false } }
    var serverUnread: Int { locked { messages.filter(\.unread).count } }
    func mutate(_ body: (FakeIMAPWorld) -> Void) { locked { body(self) } }

    /// Answers the oldest held command: normally (nil) or as `action` says.
    func release(_ action: Action? = nil) {
        locked {
            guard !held.isEmpty else { return }
            let item = held.removeFirst()
            guard !item.connection.closed else { return }
            perform(action, connection: item.connection, tag: item.tag, command: item.command, entry: item.entry)
        }
    }

    // Called by connections, lock held by caller of `receive` paths.
    fileprivate func handle(_ connection: FakeIMAPConnection, _ text: String) {
        locked {
            guard !connection.closed else { return }
            let line = text.utf8.count >= 2 && text.utf8.suffix(2).elementsEqual([13, 10])
                ? String(decoding: text.utf8.dropLast(2), as: UTF8.self) : text
            let tag: String, command: String
            if line == "DONE" {
                tag = connection.idleTag ?? "?"
                connection.idleTag = nil
                command = "DONE"
            } else if let space = line.firstIndex(of: " ") {
                tag = String(line[..<space])
                command = String(line[line.index(after: space)...])
            } else {
                tag = "?"
                command = line
            }
            entries.append(Entry(connection: connection.number, command: command, status: "-"))
            let entry = entries.count - 1
            if let index = rules.firstIndex(where: { command.hasPrefix($0.prefix) && $0.times > 0 }) {
                rules[index].times -= 1
                if case .hold = rules[index].action {
                    held.append((connection, tag, command, entry))
                    return
                }
                perform(rules[index].action, connection: connection, tag: tag, command: command, entry: entry)
                return
            }
            perform(nil, connection: connection, tag: tag, command: command, entry: entry)
        }
    }

    private func perform(_ action: Action?, connection: FakeIMAPConnection, tag: String, command: String, entry: Int) {
        func status(of reply: Data) -> String {
            let text = String(decoding: reply, as: UTF8.self)
            return text.components(separatedBy: "\r\n").last(where: { $0.hasPrefix(tag + " ") })?
                .split(separator: " ").dropFirst().first.map(String.init) ?? "-"
        }
        switch action {
        case nil:
            let reply = normal(connection, tag: tag, command: command)
            entries[entry].status = status(of: reply)
            connection.input.append(reply)
        case let .reply(text)?:
            let body = text.replacingOccurrences(of: "§", with: tag)
            let reply = Data((body.hasSuffix("\r\n") ? body : body + "\r\n").utf8)
            entries[entry].status = status(of: reply)
            connection.input.append(reply)
        case .drop?:
            entries[entry].status = "dropped"
            connection.closed = true
        case .applyThenDrop?:
            _ = normal(connection, tag: tag, command: command)
            entries[entry].status = "applied-dropped"
            connection.closed = true
        case .silent?:
            entries[entry].status = "silent"
        case .timeOut?:
            entries[entry].status = "timeout"
            connection.forceTimeout = true
        case .hold?:
            break
        }
    }

    // MARK: The server's ordinary behaviour (lock held)

    private func uidSet(_ text: String) -> Set<UInt32> {
        var result: Set<UInt32> = []
        for part in text.split(separator: ",") {
            let bounds = part.split(separator: ":").compactMap { UInt32($0) }
            if bounds.count == 2 { result.formUnion(min(bounds[0], bounds[1])...max(bounds[0], bounds[1])) }
            else if bounds.count == 1 { result.insert(bounds[0]) }
        }
        return result
    }

    private func items(_ text: String) -> [String] {
        var body = Substring(text)
        if body.hasPrefix("(") && body.hasSuffix(")") { body = body.dropFirst().dropLast() }
        var result: [String] = [], current = "", depth = 0
        for character in body {
            if character == "[" || character == "(" { depth += 1 }
            if character == "]" || character == ")" { depth -= 1 }
            if character == " " && depth == 0 {
                if !current.isEmpty { result.append(current) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private func section(_ message: Message, _ spec: String) -> Data {
        let upper = spec.uppercased()
        let headerEnd = message.raw.range(of: Data("\r\n\r\n".utf8))
        if upper.hasPrefix("HEADER") { return headerEnd.map { Data(message.raw[..<$0.upperBound]) } ?? message.raw }
        if upper == "TEXT" { return headerEnd.map { Data(message.raw[$0.upperBound...]) } ?? Data() }
        if upper.isEmpty { return message.raw }
        let sections = mimeSections(message.raw)
        if upper.hasSuffix(".MIME") { return sections[String(spec.dropLast(5))]?.header ?? Data() }
        return sections[spec]?.body ?? Data()
    }

    private func fetch(_ selected: [(seq: Int, message: Message)], items: [String]) -> Data {
        var out = Data()
        for (seq, message) in selected {
            var line = Data("* \(seq) FETCH (UID \(message.uid)".utf8)
            for item in items {
                let upper = item.uppercased()
                if upper == "UID" || upper == "INTERNALDATE" || upper.hasPrefix("X-GM-") { continue }
                if upper == "FLAGS" {
                    let flags = [message.unread ? nil : "\\Seen", message.deleted ? "\\Deleted" : nil].compactMap { $0 }
                    line.append(Data(" FLAGS (\(flags.joined(separator: " ")))".utf8))
                } else if upper == "RFC822.SIZE" {
                    line.append(Data(" RFC822.SIZE \(message.raw.count)".utf8))
                } else if upper == "BODYSTRUCTURE" {
                    if let structure = message.structure { line.append(Data(" BODYSTRUCTURE \(structure)".utf8)) }
                } else if upper.hasPrefix("BODY.PEEK["), let close = item.lastIndex(of: "]") {
                    let spec = String(item[item.index(item.startIndex, offsetBy: 10)..<close])
                    var data = section(message, spec)
                    var name = "BODY[\(spec)]"
                    let rest = item[item.index(after: close)...]
                    if rest.hasPrefix("<0."), let size = Int(rest.dropFirst(3).dropLast()) {
                        data = Data(data.prefix(size))
                        name += "<0>"
                    }
                    line.append(Data(" \(name) {\(data.count)}\r\n".utf8))
                    line.append(data)
                }
            }
            line.append(Data(")\r\n".utf8))
            out.append(line)
        }
        return out
    }

    private func expunge(where condition: (Message) -> Bool) -> String {
        var lines = ""
        var index = messages.count - 1
        while index >= 0 {
            if condition(messages[index]) {
                lines += "* \(index + 1) EXPUNGE\r\n"
                messages.remove(at: index)
            }
            index -= 1
        }
        return lines
    }

    private func normal(_ connection: FakeIMAPConnection, tag: String, command: String) -> Data {
        let upper = command.uppercased()
        func ok(_ untagged: String = "") -> Data { Data((untagged + "\(tag) OK done\r\n").utf8) }
        if command == "DONE" { return ok() }
        if upper.hasPrefix("LOGIN") { return ok() }
        if upper.hasPrefix("CAPABILITY") { return ok("* CAPABILITY IMAP4rev1 \(capabilities)\r\n") }
        if upper.hasPrefix("SELECT") {
            return Data("* OK [UIDVALIDITY \(validity)] epoch\r\n* \(messages.count) EXISTS\r\n\(tag) OK [READ-WRITE] selected\r\n".utf8)
        }
        if upper.hasPrefix("LIST") { return ok(list) }
        if upper.hasPrefix("NOOP") { return ok("* \(messages.count) EXISTS\r\n") }
        if upper.hasPrefix("IDLE") {
            connection.idleTag = tag
            return Data("+ idling\r\n".utf8)
        }
        if upper.hasPrefix("UID SEARCH UNSEEN") {
            return ok("* SEARCH" + messages.filter(\.unread).map { " \($0.uid)" }.joined() + "\r\n")
        }
        let words = command.split(separator: " ", maxSplits: 3).map(String.init)
        if upper.hasPrefix("UID SEARCH UID "), words.count >= 4 {
            let set = uidSet(words[3])
            return ok("* SEARCH" + messages.filter { set.contains($0.uid) }.map { " \($0.uid)" }.joined() + "\r\n")
        }
        if upper.hasPrefix("UID STORE"), words.count == 4 {
            let set = uidSet(words[2])
            for index in messages.indices where set.contains(messages[index].uid) {
                if words[3].contains("\\Seen") { messages[index].unread = words[3].hasPrefix("-") }
                if words[3].contains("\\Deleted") { messages[index].deleted = !words[3].hasPrefix("-") }
            }
            return ok()
        }
        if upper.hasPrefix("UID MOVE"), words.count >= 3 {
            let set = uidSet(words[2])
            return ok(expunge { set.contains($0.uid) })
        }
        if upper.hasPrefix("UID COPY") { return ok() }
        if upper.hasPrefix("UID EXPUNGE"), words.count >= 3 {
            let set = uidSet(words[2])
            return ok(expunge { set.contains($0.uid) && $0.deleted })
        }
        if upper.hasPrefix("UID FETCH"), words.count == 4 {
            let set = uidSet(words[2])
            let selected = messages.enumerated().filter { set.contains($0.element.uid) }.map { ($0.offset + 1, $0.element) }
            return fetch(selected, items: items(words[3])) + ok()
        }
        if upper.hasPrefix("FETCH"), words.count >= 3 {
            let range = words[1].split(separator: ":")
            let first = Int(range.first ?? "1") ?? 1
            let selected = messages.enumerated().filter { $0.offset + 1 >= first }.map { ($0.offset + 1, $0.element) }
            return fetch(selected, items: items(command.split(separator: " ", maxSplits: 2).map(String.init)[2])) + ok()
        }
        return Data("\(tag) BAD unknown command\r\n".utf8)
    }
}

final class FakeIMAPConnection: MailIMAPTransport, @unchecked Sendable {
    let world: FakeIMAPWorld
    let number: Int
    fileprivate var input = MailIMAPFramerBox()
    fileprivate var closed = false
    fileprivate var interrupted = false
    fileprivate var idleTag: String?
    fileprivate var forceTimeout = false

    init(world: FakeIMAPWorld, number: Int) { self.world = world; self.number = number }

    func start() { world.locked { input.append(Data("* OK ready\r\n".utf8)) } }
    func close() { world.locked { closed = true } }
    func interrupt() { world.locked { interrupted = true } }
    func send(_ text: String) { world.handle(self, text) }
    var isConstrainedPath: Bool { world.locked { world.constrained } }
    var isClosed: Bool { world.locked { closed } }

    func receive(until deadline: DispatchTime, interruptible: Bool) async throws -> MailIMAPResponse? {
        while true {
            let step: Result<MailIMAPResponse?, Error>? = world.locked {
                if let frame = input.next() { return .success(frame) }
                if closed { return .failure(MailIMAPError.disconnected) }
                if interruptible && interrupted { interrupted = false; return .success(nil) }
                if forceTimeout && !interruptible { forceTimeout = false; return .success(nil) }
                if DispatchTime.now() >= deadline { return .success(nil) }
                return nil
            }
            if let step { return try step.get() }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}

/// MailIMAPFramer is a struct with a mutating API; a box keeps the connection's buffer in one place.
struct MailIMAPFramerBox {
    private var framer = MailIMAPFramer()
    mutating func append(_ data: Data) { framer.append(data) }
    mutating func next() -> MailIMAPResponse? { (try? framer.next()) ?? nil }
}

// MARK: Service harness

@MainActor
final class MailHarness {
    static let account = "unit@gmail.com"
    let world: FakeIMAPWorld
    let service: MailService
    let directory: URL
    var published: [[MailMessage]] = []
    var publishedUnread: [Int] = []
    private var sinks: [AnyCancellable] = []

    static let secondAccount = "unit@yahoo.es"
    let second: FakeIMAPWorld?

    /// `second`: a Yahoo account served by its own world (worlds are picked by provider).
    init(world: FakeIMAPWorld, cache: MailBodyCache? = nil, tuning: MailIMAPTuning = .fast, second: FakeIMAPWorld? = nil) throws {
        self.world = world
        self.second = second
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("cala-mail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("mail-accounts.json")
        var accounts = [MailAccount(id: Self.account, label: "A", colorIndex: 0, enabled: true, provider: .gmail)]
        if second != nil { accounts.append(MailAccount(id: Self.secondAccount, label: "B", colorIndex: 1, enabled: true, provider: .yahoo)) }
        try JSONEncoder().encode(accounts).write(to: url)
        service = MailService(accountsURL: url, makeConnection: { provider in
            MailIMAP(socket: (provider == .yahoo ? second ?? world : world).connect(), provider: provider, tuning: tuning)
        }, readCredential: { _ in "AbcdEfghIjklMnop" }, writeCredential: { _, _ in }, bodyCache: cache)
    }

    /// Starts and waits until `count` rows are listed and the connection is parked in IDLE.
    func start(rows count: Int) async -> Bool {
        service.start()
        return await settle { self.service.messages.count == count }
    }

    func settle(_ seconds: Double = 5, _ condition: () -> Bool = { true }) async -> Bool {
        await waitFor(seconds) { condition() && world.isIdle && (second?.isIdle ?? true) }
    }

    /// Records every value the list and the unread badge publish from now on.
    func record() {
        published.removeAll()
        publishedUnread.removeAll()
        sinks = [service.$messages.dropFirst().sink { [weak self] in self?.published.append($0) },
                 service.$unreadCount.dropFirst().sink { [weak self] in self?.publishedUnread.append($0) }]
    }

    func row(_ uid: UInt32) -> MailMessage? { service.messages.first { $0.uid == uid } }
    func shows(_ uid: UInt32) -> Bool { row(uid) != nil }
    func id(_ uid: UInt32, validity: UInt32 = 7) -> String { "\(Self.account)#\(validity)#\(uid)" }

    func finish() {
        sinks.removeAll()
        service.stop()
        try? FileManager.default.removeItem(at: directory)
    }
}

// MARK: A. Optimistic actions through MailService (.fast)

@MainActor
func checkOptimisticActions() async throws {
    let base: [(UInt32, Bool)] = [(1, false), (2, true), (3, true)]
    func noticeCount(_ h: MailHarness) -> Int { h.service.notices.count }

    // A1. Delete answered NO (the cached-LIST retry is answered NO too).
    do {
        let world = FakeIMAPWorld(uids: base)
        let h = try MailHarness(world: world)
        defer { h.finish() }
        guard await h.start(rows: 3), let target = h.row(3) else { expect("A1 delete NO: harness synced", false); return }
        let before = h.service.messages, beforeUnread = h.service.unreadCount
        world.on("UID MOVE", .hold)
        world.on("UID MOVE", .reply("§ NO [OVERQUOTA] cannot move"), times: 9)
        h.record()
        h.service.trash(target)
        expect("A1 delete: the row and its unread count leave the list synchronously on tap, in the first publish",
               !h.shows(3) && h.service.unreadCount == beforeUnread - 1
                   && h.published.first.map { !$0.contains { $0.uid == 3 } } == true && h.published.count == 1)
        _ = await waitFor { world.heldCount == 1 }
        expect("A1 delete: while UID MOVE waits for its answer the row stays hidden", world.heldCount == 1 && !h.shows(3))
        world.release(.reply("§ NO [OVERQUOTA] cannot move"))
        _ = await h.settle { noticeCount(h) == 1 }
        expect("A1 delete answered NO: the exact original rows and unread count come back",
               h.service.messages == before && h.service.unreadCount == beforeUnread)
        expect("A1 delete answered NO: exactly one notice for that account, naming the refusal",
               h.service.notices.count == 1 && h.service.notices.first?.accountID == MailHarness.account
                   && h.service.notices.first?.text.contains(MailFailure.rejected.localizedDescription) == true)
        expect("A1 delete answered NO: the badge never went below the server count minus one",
               h.publishedUnread.allSatisfy { $0 >= beforeUnread - 1 && $0 >= 0 })
        expect("A1 delete answered NO: the server still has the message and nothing purged it",
               world.locked { world.messages.count } == 3 && wireIsSafe(world.log.map { ($0.command, $0.status) }))
        if let notice = h.service.notices.first { h.service.dismissNotice(notice.id) }
        expect("A1 dismissNotice removes the notice", h.service.notices.isEmpty)
    }

    // A2. Archive answered BAD.
    do {
        let world = FakeIMAPWorld(uids: base)
        let h = try MailHarness(world: world)
        defer { h.finish() }
        guard await h.start(rows: 3), let target = h.row(1) else { expect("A2 archive BAD: harness synced", false); return }
        expect("A2 archive is offered (MOVE and a visible \\All mailbox)", h.service.canArchive(target))
        let before = h.service.messages, beforeUnread = h.service.unreadCount
        world.on("UID MOVE", .reply("§ BAD command unknown"), times: 9)
        h.record()
        h.service.archive(target)
        expect("A2 archive: a read row leaves the list at once and the unread count is untouched",
               !h.shows(1) && h.service.unreadCount == beforeUnread)
        _ = await h.settle { noticeCount(h) == 1 }
        expect("A2 archive answered BAD: rows come back identically with one notice",
               h.service.messages == before && h.service.unreadCount == beforeUnread && h.service.notices.count == 1)
        expect("A2 archive answered BAD: it moved toward \\All, not the trash",
               world.commands.filter { $0.hasPrefix("UID MOVE") }.allSatisfy { $0.hasSuffix("\"[Gmail]/All Mail\"") })
    }

    // A3. Connection drops while UID MOVE is on the wire (the server did not move it).
    do {
        let world = FakeIMAPWorld(uids: base)
        let h = try MailHarness(world: world)
        defer { h.finish() }
        guard await h.start(rows: 3), let target = h.row(2) else { expect("A3 drop mid-MOVE: harness synced", false); return }
        let before = h.service.messages
        world.on("UID MOVE", .hold)
        h.service.trash(target)
        _ = await waitFor { world.heldCount == 1 }
        world.release(.drop)
        _ = await h.settle { noticeCount(h) == 1 && world.connectionCount >= 2 }
        expect("A3 drop mid-MOVE: the row comes back with one notice once the link is lost",
               h.service.messages == before && h.service.notices.count == 1 && h.service.unreadCount == 2)
        expect("A3 drop mid-MOVE: the client reconnected", world.connectionCount >= 2)
        expect("A3 drop mid-MOVE: UID MOVE is never sent again after the reconnect",
               world.count("UID MOVE") == 1 && world.log.filter { $0.command.hasPrefix("UID MOVE") }.allSatisfy { $0.connection == 1 })
    }

    // A3b. The server moved it but the answer was lost.
    do {
        let world = FakeIMAPWorld(uids: base)
        let h = try MailHarness(world: world)
        defer { h.finish() }
        guard await h.start(rows: 3), let target = h.row(2) else { expect("A3b lost OK: harness synced", false); return }
        world.on("UID MOVE", .applyThenDrop)
        h.record()
        h.service.trash(target)
        _ = await h.settle { world.connectionCount >= 2 && h.service.messages.count == 2 }
        _ = await h.settle()
        expect("A3b MOVE done but its answer lost: the move is not repeated and the list ends at the server's truth",
               world.count("UID MOVE") == 1 && !h.shows(2) && h.service.unreadCount == world.serverUnread)
        expect("I5 MOVE done but its answer lost: the row stays hidden across the reconnect (no false \"it's back\" notice)",
                         h.published.allSatisfy { !$0.contains { $0.uid == 2 } } && h.service.notices.isEmpty)
    }

    // A4. An action queued (not yet sent) when the link dies survives the reconnect and runs once.
    do {
        let world = FakeIMAPWorld(uids: base)
        let h = try MailHarness(world: world)
        defer { h.finish() }
        guard await h.start(rows: 3), let target = h.row(2) else { expect("A4 queued action: harness synced", false); return }
        world.on("DONE", .drop)
        h.record()
        h.service.trash(target)
        _ = await h.settle { world.connectionCount >= 2 && world.count("UID MOVE") == 1 }
        let moves = world.log.filter { $0.command.hasPrefix("UID MOVE") }
        expect("A4 queued delete survives the dropped link and is sent exactly once, on the new connection",
               moves.count == 1 && moves.first?.connection == 2 && moves.first?.status == "OK")
        expect("A4 queued delete: the row never reappears across the reconnect and no notice is shown",
               h.published.allSatisfy { !$0.contains { $0.uid == 2 } } && !h.shows(2) && h.service.notices.isEmpty)
        expect("A4 queued delete: unread count follows the server after the reconnect", h.service.unreadCount == 1 && world.serverUnread == 1)
    }

    // A5. Mark read / unread: optimistic, reverted on NO.
    do {
        let world = FakeIMAPWorld(uids: base)
        let h = try MailHarness(world: world)
        defer { h.finish() }
        guard await h.start(rows: 3), let unreadRow = h.row(2), let readRow = h.row(1) else {
            expect("A5 mark read: harness synced", false); return
        }
        let before = h.service.messages
        world.on("UID STORE", .hold)
        h.service.markRead(unreadRow)
        expect("A5 mark read: the row reads as read and the badge drops by one at once",
               h.row(2)?.unread == false && h.service.unreadCount == 1)
        _ = await waitFor { world.heldCount == 1 }
        expect("A5 mark read: still shown read while the STORE is unanswered", h.row(2)?.unread == false)
        world.release(.reply("§ NO [CANNOT] read-only"))
        _ = await h.settle { noticeCount(h) == 1 }
        expect("A5 mark read answered NO: the row is unread again, count restored, one notice",
               h.service.messages == before && h.service.unreadCount == 2 && h.service.notices.count == 1)

        world.on("UID STORE", .reply("§ NO [CANNOT] read-only"))
        h.service.markUnread(readRow)
        expect("A5 mark unread: the row reads as unread and the badge rises by one at once",
               h.row(1)?.unread == true && h.service.unreadCount == 3)
        _ = await h.settle { noticeCount(h) == 2 }
        expect("A5 mark unread answered NO: back to read, count restored, a second notice",
               h.service.messages == before && h.service.unreadCount == 2 && h.service.notices.count == 2)
        expect("A5 mark unread sends -FLAGS \\Seen for that UID only",
               world.commands.contains(#"UID STORE 1 -FLAGS.SILENT (\Seen)"#))

        h.service.markRead(unreadRow)
        _ = await h.settle { world.serverUnread == 1 }
        h.service.refresh()
        _ = await waitFor(0.2) { false }
        _ = await h.settle()
        expect("A5 mark read accepted: stays read after the server confirms and later syncs",
               h.row(2)?.unread == false && h.service.unreadCount == 1 && h.service.notices.count == 2)
    }

    // A6. Unread count: never negative, never counted twice.
    do {
        let world = FakeIMAPWorld(uids: base)
        let h = try MailHarness(world: world)
        defer { h.finish() }
        guard await h.start(rows: 3), let row2 = h.row(2), let row3 = h.row(3) else { expect("A6: harness synced", false); return }
        world.on("UID MOVE", .hold)
        h.record()
        h.service.trash(row3)
        expect("A6 hiding an unread row lowers the badge by exactly one", h.service.unreadCount == 1)
        _ = await waitFor { world.heldCount == 1 }
        world.release()
        _ = await h.settle { world.count("UID MOVE") == 1 && h.service.messages.count == 2 }
        expect("A6 after the server confirms and the next sync, the count is still one lower (not two)",
               h.service.unreadCount == 1 && h.publishedUnread.allSatisfy { $0 == 1 })

        world.on("UID STORE", .hold)
        h.record()
        h.service.markRead(row2)
        h.service.trash(row2)
        expect("A6 read then delete the same unread row: counted once", h.service.unreadCount == 0 && !h.shows(2))
        _ = await waitFor { world.heldCount == 1 }
        world.release()
        _ = await h.settle { world.count("UID MOVE") == 2 && h.service.messages.count == 1 }
        expect("A6 read then delete: every published badge value is 0 (never -1, never back to 1)",
               h.service.unreadCount == 0 && h.publishedUnread.allSatisfy { $0 == 0 })
        expect("A6 read then delete: server ends with the row moved and no unread left",
               world.serverUnread == 0 && !h.shows(2) && h.service.notices.isEmpty)
    }
    do {
        let world = FakeIMAPWorld(uids: base)
        let h = try MailHarness(world: world)
        defer { h.finish() }
        guard await h.start(rows: 3), let row3 = h.row(3) else { expect("A6c: harness synced", false); return }
        world.on("UID STORE", .hold)
        h.record()
        h.service.markAllRead(accountID: MailHarness.account)
        h.service.trash(row3)
        expect("A6 mark all read then delete an unread row: badge is 0, not negative", h.service.unreadCount == 0)
        _ = await waitFor { world.heldCount == 1 }
        world.release()
        _ = await h.settle { world.count("UID MOVE") == 1 && h.service.messages.count == 2 }
        expect("A6 mark all read then delete: no published badge value is ever negative",
               h.publishedUnread.allSatisfy { $0 >= 0 } && h.service.unreadCount == 0 && world.serverUnread == 0)
    }

    // A7. Two quick deletes on different rows.
    do {
        let world = FakeIMAPWorld(uids: base)
        let h = try MailHarness(world: world)
        defer { h.finish() }
        guard await h.start(rows: 3), let a = h.row(1), let b = h.row(2) else { expect("A7: harness synced", false); return }
        h.record()
        h.service.trash(a)
        h.service.trash(b)
        expect("A7 two quick deletes: both rows leave the list at once", !h.shows(1) && !h.shows(2) && h.service.unreadCount == 1)
        _ = await h.settle { world.count("UID MOVE") == 2 && h.service.messages.count == 1 }
        expect("A7 two quick deletes: one UID MOVE each, in tap order, no notice",
               world.commands.filter { $0.hasPrefix("UID MOVE") } == [#"UID MOVE 1 "[Gmail]/Trash""#, #"UID MOVE 2 "[Gmail]/Trash""#]
                   && h.service.notices.isEmpty)
        expect("A7 two quick deletes: neither row flickers back (row 1 gone from the first publish, both from the second on)",
               h.published.count >= 2 && h.published.allSatisfy { !$0.contains { $0.uid == 1 } }
                   && h.published.dropFirst().allSatisfy { !$0.contains { $0.uid == 2 } })
    }
    do {
        let world = FakeIMAPWorld(uids: base)
        let h = try MailHarness(world: world)
        defer { h.finish() }
        guard await h.start(rows: 3), let a = h.row(1), let b = h.row(2) else { expect("A7b: harness synced", false); return }
        let original = h.row(1)
        world.on("UID MOVE 1 ", .reply("§ NO [OVERQUOTA] no"), times: 9)
        h.service.trash(a)
        h.service.trash(b)
        _ = await h.settle { noticeCount(h) == 1 && world.count("UID MOVE 2 ") == 1 && h.service.messages.count == 2 }
        expect("A7b first delete refused, second accepted: only the refused row returns, unchanged, with one notice",
               h.row(1) == original && !h.shows(2) && h.service.notices.count == 1 && h.service.unreadCount == 1)
    }

    // A8. A sync that started before the server's OK does not bring the deleted row back; a later sync prunes.
    do {
        let world = FakeIMAPWorld(uids: base)
        let h = try MailHarness(world: world)
        defer { h.finish() }
        guard await h.start(rows: 3), let target = h.row(3) else { expect("A8: harness synced", false); return }
        let searchesBefore = world.count("UID SEARCH UNSEEN")
        world.on("UID SEARCH UNSEEN", .hold)
        h.service.refresh()
        _ = await waitFor { world.heldCount == 1 }
        expect("A8 setup: a refresh sync is in flight (its SEARCH unanswered)", world.heldCount == 1
                   && world.count("UID SEARCH UNSEEN") == searchesBefore + 1)
        h.record()
        h.service.trash(target)
        world.release()   // that sync read the mailbox before the delete: its snapshot still lists UID 3
        _ = await h.settle { world.count("UID MOVE") == 1 && world.locked { world.messages.count } == 2 }
        _ = await h.settle()
        expect("A8 the stale sync's snapshot (row still on the server) never shows the deleted row",
               h.published.allSatisfy { !$0.contains { $0.uid == 3 } } && !h.shows(3))
        expect("A8 the badge never counts the deleted unread row again", h.publishedUnread.allSatisfy { $0 == 1 })
        // The server brings the message back (same UID: restored by another client). A pruned tombstone lets it show.
        world.mutate { $0.messages.append(.init(uid: 3, unread: true, raw: FakeIMAPWorld.simpleRaw(3), structure: nil)) }
        h.service.refresh()
        _ = await h.settle { h.shows(3) }
        expect("A8 a later sync pruned the tombstone: a message the server lists again is shown again",
               h.shows(3) && h.service.unreadCount == 2)
    }

    // A9. UIDVALIDITY changes while actions wait: they are refused before anything is sent, with notices.
    do {
        let world = FakeIMAPWorld(uids: base)
        let h = try MailHarness(world: world)
        defer { h.finish() }
        guard await h.start(rows: 3), let a = h.row(2), let b = h.row(3) else { expect("A9: harness synced", false); return }
        world.on("DONE", .drop)
        world.mutate { $0.validity = 8 }
        h.service.trash(a)
        h.service.markRead(b)
        expect("A9 both actions show at once", !h.shows(2) && h.row(3)?.unread == false)
        _ = await h.settle { world.connectionCount >= 2 && h.service.messages.allSatisfy { $0.uidValidity == 8 } && noticeCount(h) == 2 }
        expect("A9 new UIDVALIDITY: no UID MOVE or UID STORE is sent for old-epoch UIDs",
               world.count("UID MOVE") == 0 && world.count("UID STORE") == 0)
        expect("A9 new UIDVALIDITY: one notice per refused action and the list shows the new epoch with the server's flags",
               h.service.notices.count == 2 && h.service.messages.count == 3 && h.service.unreadCount == 2
                   && h.service.messages.allSatisfy { $0.id.contains("#8#") })
    }

    // A10. open(): read at once; STORE \Seen after the body; cache serves later opens.
    do {
        let world = FakeIMAPWorld(uids: base)
        let cacheDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("cala-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let h = try MailHarness(world: world, cache: MailBodyCache(directory: cacheDirectory))
        defer { h.finish() }
        guard await h.start(rows: 3), let target = h.row(2) else { expect("A10: harness synced", false); return }
        expect("A10 nothing cached before the first open", h.service.cachedContent(for: target) == nil)
        h.service.open(target)
        expect("A10 open: the row reads as read immediately and nothing is sent yet",
               h.row(2)?.unread == false && h.service.unreadCount == 1 && world.count("UID STORE") == 0)
        let content = try await h.service.content(of: target)
        _ = await h.settle { world.count("UID STORE") == 1 }
        let commands = world.commands
        let bodyIndex = commands.firstIndex { $0.hasPrefix("UID FETCH 2 ") && ($0.contains("BODY.PEEK[]") || $0.contains("BODYSTRUCTURE")) }
        let storeIndex = commands.firstIndex { $0 == #"UID STORE 2 +FLAGS.SILENT (\Seen)"# }
        expect("A10 open: the body is fetched before the deferred STORE \\Seen, which is sent once",
               content.text == "Hola 2" && bodyIndex != nil && storeIndex != nil && bodyIndex! < storeIndex!
                   && world.count("UID STORE") == 1)
        expect("A10 cachedContent serves the opened body from memory", h.service.cachedContent(for: target) == content)
        let sent = world.log.count
        let again = try await h.service.content(of: target)
        expect("A10 a second open is a cache hit that sends nothing", again == content && world.log.count == sent)
        guard let key = MailBodyKey(target) else { expect("A10 key", false); return }
        let file = MailBodyCache(directory: cacheDirectory).fileURL(for: key)
        _ = await waitFor { file.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }

        let otherWorld = FakeIMAPWorld(uids: base)
        let fresh = try MailHarness(world: otherWorld, cache: MailBodyCache(directory: cacheDirectory))
        defer { fresh.finish() }
        guard await fresh.start(rows: 3), let same = fresh.row(2) else { expect("A10 fresh harness synced", false); return }
        let freshSent = otherWorld.log.count
        let fromDisk = try await fresh.service.content(of: same)
        expect("A10 after a restart the body comes from the disk cache without any IMAP command",
               fromDisk == content && otherWorld.log.count == freshSent)

        // open() without an explicit body fetch: the STORE still goes out after about two seconds.
        guard let third = fresh.row(3) else { return }
        fresh.service.open(third)
        let sentStore = await waitFor(4) { otherWorld.count(#"UID STORE 3 +FLAGS.SILENT (\Seen)"#) == 1 }
        expect("A10 open without reading the body still sends STORE \\Seen (within ~2 s)", sentStore && fresh.row(3)?.unread == false)
    }
}

// MARK: B. Pure overlay

func checkOverlayTable() {
    func row(_ uid: UInt32, _ unread: Bool) -> MailMessage {
        MailMessage(id: "a#7#\(uid)", accountID: "a", uid: uid, fromName: "F", fromAddress: "f@x.test", subject: "S\(uid)",
                    snippet: "p\(uid)", date: Date(timeIntervalSince1970: Double(uid)), unread: unread,
                    gmailThreadID: nil, gmailMessageID: nil, uidValidity: 7)
    }
    let rows = [row(4, true), row(3, false), row(2, true), row(1, false)]
    let snapshot = MailInboxSnapshot(validity: 7, messages: rows, unread: 2, canArchive: true)
    typealias E = MailOverlay.Entry
    func uids(_ r: MailOverlay.Result) -> [UInt32] { r.messages.map(\.uid) }
    func unreadUIDs(_ r: MailOverlay.Result) -> [UInt32] { r.messages.filter(\.unread).map(\.uid) }
    struct Case { let name: String; let entries: [E]; let uids: [UInt32]; let unread: [UInt32]; let count: Int }
    let cases: [Case] = [
        Case(name: "no entries is the snapshot", entries: [], uids: [4, 3, 2, 1], unread: [4, 2], count: 2),
        Case(name: "hide a read row", entries: [E(id: 1, effect: .hide(messageID: "a#7#3"), state: .queued)],
             uids: [4, 2, 1], unread: [4, 2], count: 2),
        Case(name: "hide an unread row lowers the count by one", entries: [E(id: 1, effect: .hide(messageID: "a#7#4"), state: .inFlight)],
             uids: [3, 2, 1], unread: [2], count: 1),
        Case(name: "hide a row that is gone changes nothing", entries: [E(id: 1, effect: .hide(messageID: "a#7#9"), state: .queued)],
             uids: [4, 3, 2, 1], unread: [4, 2], count: 2),
        Case(name: "read an unread row", entries: [E(id: 1, effect: .read(messageID: "a#7#2"), state: .queued)],
             uids: [4, 3, 2, 1], unread: [4], count: 1),
        Case(name: "read an already read row is not counted", entries: [E(id: 1, effect: .read(messageID: "a#7#3"), state: .queued)],
             uids: [4, 3, 2, 1], unread: [4, 2], count: 2),
        Case(name: "unread a read row", entries: [E(id: 1, effect: .unread(messageID: "a#7#1"), state: .queued)],
             uids: [4, 3, 2, 1], unread: [4, 2, 1], count: 3),
        Case(name: "unread an already unread row is not counted", entries: [E(id: 1, effect: .unread(messageID: "a#7#4"), state: .queued)],
             uids: [4, 3, 2, 1], unread: [4, 2], count: 2),
        Case(name: "read all", entries: [E(id: 1, effect: .readAll, state: .inFlight)], uids: [4, 3, 2, 1], unread: [], count: 0),
        Case(name: "read then hide the same unread row counts once",
             entries: [E(id: 1, effect: .read(messageID: "a#7#4"), state: .inFlight), E(id: 2, effect: .hide(messageID: "a#7#4"), state: .queued)],
             uids: [3, 2, 1], unread: [2], count: 1),
        Case(name: "hide then read the same row counts once",
             entries: [E(id: 1, effect: .hide(messageID: "a#7#4"), state: .queued), E(id: 2, effect: .read(messageID: "a#7#4"), state: .queued)],
             uids: [3, 2, 1], unread: [2], count: 1),
        Case(name: "read then unread in order ends unread with the original count",
             entries: [E(id: 1, effect: .read(messageID: "a#7#2"), state: .queued), E(id: 2, effect: .unread(messageID: "a#7#2"), state: .queued)],
             uids: [4, 3, 2, 1], unread: [4, 2], count: 2),
        Case(name: "read all then unread one row", entries: [E(id: 1, effect: .readAll, state: .queued), E(id: 2, effect: .unread(messageID: "a#7#3"), state: .queued)],
             uids: [4, 3, 2, 1], unread: [3], count: 1),
        Case(name: "a held entry is not shown", entries: [E(id: 1, effect: .hide(messageID: "a#7#4"), state: .held)],
             uids: [4, 3, 2, 1], unread: [4, 2], count: 2),
        Case(name: "a confirmed entry is still shown", entries: [E(id: 1, effect: .hide(messageID: "a#7#4"), state: .confirmed(afterSync: 3))],
             uids: [3, 2, 1], unread: [2], count: 1),
        Case(name: "read all then hide an unread row never goes negative",
             entries: [E(id: 1, effect: .readAll, state: .queued), E(id: 2, effect: .hide(messageID: "a#7#4"), state: .queued)],
             uids: [3, 2, 1], unread: [], count: 0),
        Case(name: "two hides of different rows", entries: [E(id: 1, effect: .hide(messageID: "a#7#4"), state: .queued), E(id: 2, effect: .hide(messageID: "a#7#1"), state: .queued)],
             uids: [3, 2], unread: [2], count: 1),
    ]
    for test in cases {
        let result = MailOverlay.apply(snapshot, test.entries)
        expect("B overlay apply: \(test.name)",
               uids(result) == test.uids && unreadUIDs(result) == test.unread && result.unread == test.count)
    }
    let inconsistent = MailInboxSnapshot(validity: 7, messages: [row(5, true), row(6, true)], unread: 1, canArchive: false)
    let clamped = MailOverlay.apply(inconsistent, [E(id: 1, effect: .hide(messageID: "a#7#5"), state: .queued),
                                                  E(id: 2, effect: .hide(messageID: "a#7#6"), state: .queued)])
    expect("B overlay apply: the unread count is never negative, even over an inconsistent snapshot", clamped.unread == 0)
    let untouched = MailOverlay.apply(snapshot, [E(id: 1, effect: .hide(messageID: "a#7#3"), state: .queued)])
    expect("B overlay apply keeps every other row byte for byte and in order",
           untouched.messages == rows.filter { $0.uid != 3 } && snapshot.messages == rows)

    var overlay = MailOverlay()
    overlay.add(.hide(messageID: "a#7#4"), id: 1)
    overlay.add(.read(messageID: "a#7#2"), id: 2, state: .inFlight)
    expect("B overlay add: new entries start queued unless told otherwise",
           overlay.entries.map(\.state) == [.queued, .inFlight] && !overlay.isEmpty)
    overlay.add(.unread(messageID: "a#7#3"), id: 1)
    expect("B overlay add with an existing id replaces that entry",
           overlay.entries.count == 2 && overlay.entries.last?.effect == .unread(messageID: "a#7#3"))
    overlay.set(.held, for: 99)
    expect("B overlay set for an unknown id changes nothing", overlay.entries.map(\.state) == [.inFlight, .queued])
    let removed = overlay.remove(2)
    expect("B overlay remove returns the entry and restores the snapshot for it",
           removed?.effect == .read(messageID: "a#7#2") && overlay.remove(2) == nil
               && overlay.apply(to: snapshot).messages.first { $0.uid == 2 }?.unread == true)

    // Reconciliation clock, from the type's contract.
    var clock = MailOverlay()
    clock.add(.hide(messageID: "a#7#4"), id: 1, state: .inFlight)
    clock.confirm(1, latestStartedSync: 5)
    expect("B overlay confirm records the latest started sync", clock.entries.first?.state == .confirmed(afterSync: 5))
    clock.prune(appliedSync: 4)
    expect("B overlay prune: a snapshot from an older sync keeps the confirmed entry", clock.entries.count == 1)
    clock.prune(appliedSync: 5)
    expect("B overlay prune: a snapshot from the sync running when the OK came (it may predate the OK) keeps the entry",
           clock.entries.count == 1 && clock.apply(to: snapshot).messages.allSatisfy { $0.uid != 4 })
    clock.prune(appliedSync: 6)
    expect("B overlay prune: the first sync started after the OK drops the entry", clock.isEmpty)
    var mixed = MailOverlay()
    mixed.add(.hide(messageID: "a#7#1"), id: 1, state: .queued)
    mixed.add(.hide(messageID: "a#7#2"), id: 2, state: .inFlight)
    mixed.add(.hide(messageID: "a#7#3"), id: 3, state: .held)
    mixed.add(.hide(messageID: "a#7#4"), id: 4, state: .confirmed(afterSync: 1))
    mixed.prune(appliedSync: 100)
    expect("B overlay prune never drops entries the server has not confirmed", mixed.entries.map(\.id) == [1, 2, 3])
    var stale = MailOverlay()
    stale.add(.hide(messageID: "a#7#4"), id: 1)
    stale.confirm(1, latestStartedSync: 2)
    stale.prune(appliedSync: 2)
    let staleShown = stale.apply(to: snapshot)   // sync 2's snapshot still lists UID 4
    stale.prune(appliedSync: 3)
    let freshShown = stale.apply(to: MailInboxSnapshot(validity: 7, messages: Array(rows.dropFirst()), unread: 1, canArchive: true))
    expect("B overlay: a stale snapshot does not resurrect a confirmed delete; the next one is shown as is, counted once",
           !staleShown.messages.contains { $0.uid == 4 } && staleShown.unread == 1 && freshShown.unread == 1
               && freshShown.messages.map(\.uid) == [3, 2, 1])
}

// MARK: Sync and prefetch planners (pure)

func checkPlanners() {
    func row(_ uid: UInt32, _ unread: Bool, validity: UInt32? = 7) -> MailMessage {
        MailMessage(id: "a#\(validity ?? 0)#\(uid)", accountID: "a", uid: uid, fromName: "", fromAddress: "", subject: "",
                    snippet: "", date: .distantPast, unread: unread, gmailThreadID: nil, gmailMessageID: nil, uidValidity: validity)
    }
    expect("Planner window: empty mailbox has no range, small mailbox starts at 1, large at exists-24",
           MailSyncPlanner.window(exists: 0) == nil && MailSyncPlanner.window(exists: 3) == 1...3
               && MailSyncPlanner.window(exists: 100) == 76...100)
    expect("Planner uidSet: sorted, deduplicated ranges", MailSyncPlanner.uidSet([13, 3, 5, 4, 9, 12, 5]) == "3:5,9,12:13"
               && MailSyncPlanner.uidSet([7]) == "7" && MailSyncPlanner.uidSet([]) == "")
    let known = MailKnownMessages(validity: 7, messages: [row(1, false), row(2, true), row(9, true, validity: 6)])
    let plan = MailSyncPlanner.plan(window: [3, 1, 2, 3, 0], known: known, validity: 7)
    expect("Planner plan: only unknown UIDs are fetched (newest first), duplicates and UID 0 ignored",
           plan.known == [2, 1] && plan.missing == [3])
    expect("Planner plan: rows of another epoch are not known", known.message(9) == nil)
    expect("Planner plan: a different UIDVALIDITY makes everything missing",
           MailSyncPlanner.plan(window: [1, 2], known: known, validity: 8).missing == [2, 1])
    var big = MailKnownMessages(validity: 7)
    big.merge((1...250).map { row(UInt32($0), false) })
    expect("Known messages keep the newest \(MailKnownMessages.capacity) UIDs",
           big.messages.count == MailKnownMessages.capacity && big.message(50) == nil && big.message(51) != nil && big.message(250) != nil)

    let visible = (1...10).map { row(UInt32(11 - $0), $0 % 3 == 0) }   // uids 10...1, unread 8,5,2
    let candidates = MailPrefetchPlanner.candidates(visible: visible, isCached: { $0.uid == 8 })
    expect("Prefetch candidates: top 8 rows only, cached ones skipped, unread first, otherwise in list order",
           candidates.map(\.uid) == [5, 10, 9, 7, 6, 4, 3])
    expect("Prefetch candidates skip rows without UIDVALIDITY",
           MailPrefetchPlanner.candidates(visible: [row(1, true, validity: nil)], isCached: { _ in false }).isEmpty)
    let chosen = MailPrefetchPlanner.select([row(1, true), row(2, true), row(3, true), row(4, true)],
                                            sizes: [1: (100, 100), 2: (50, 2_000), 3: (900, 400)], maxPart: 1_000, budget: 1_000)
    expect("Prefetch select: unknown sizes and oversized parts are skipped, the budget is never exceeded",
           chosen.map(\.uid) == [1, 3])
}

// MARK: C. Body cache

func checkBodyCache() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cala-bodycache-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("Mail", isDirectory: true)
    let account = "unit@gmail.com", other = "other@example.test"
    let k = MailBodyKey(account: account, validity: 7, uid: 42)
    let body = MailContent(html: "<p>Hola</p>", text: "Hola")

    let cache = MailBodyCache(directory: directory)
    expect("C cache: miss before anything is stored", cache.content(for: k) == nil && !cache.contains(k))
    cache.store(body, for: k)
    let first = cache.content(for: k)
    expect("C cache: a stored body is a memory hit in the same process", first?.content == body && first?.source == .memory)
    let reopened = MailBodyCache(directory: directory)
    expect("C cache: a new process knows the body is on disk", reopened.contains(k) && reopened.memoryContent(for: k) == nil)
    let disk = reopened.content(for: k)
    expect("C cache: a new process reads it from disk", disk?.content == body && disk?.source == .disk)
    expect("C cache: a disk hit is promoted to memory", reopened.content(for: k)?.source == .memory)
    let variants: [(String, MailBodyKey)] = [
        ("another UID", MailBodyKey(account: account, validity: 7, uid: 43)),
        ("another UIDVALIDITY", MailBodyKey(account: account, validity: 8, uid: 42)),
        ("another mailbox", MailBodyKey(account: account, mailbox: "[Gmail]/All Mail", validity: 7, uid: 42)),
        ("another account", MailBodyKey(account: other, validity: 7, uid: 42)),
        ("a bumped format version", MailBodyKey(account: account, validity: 7, uid: 42, format: MailBodyKey.formatVersion + 1)),
    ]
    for (label, key) in variants {
        expect("C cache: \(label) is a miss (memory and disk)",
               cache.content(for: key) == nil && MailBodyCache(directory: directory).content(for: key) == nil && !cache.contains(key))
    }
    let message = MailMessage(id: "x", accountID: account, uid: 42, fromName: "", fromAddress: "", subject: "", snippet: "",
                              date: .distantPast, unread: false, gmailThreadID: nil, gmailMessageID: nil, uidValidity: 7)
    var noEpoch = message
    noEpoch.uidValidity = nil
    expect("C cache key from a message: INBOX, its UIDVALIDITY and UID, current format; none without UIDVALIDITY",
           MailBodyKey(message) == k && MailBodyKey(noEpoch) == nil)

    // Permissions, layout and privacy.
    guard let file = cache.fileURL(for: k) else { expect("C cache file URL", false); return }
    func mode(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
    let folders = [file.deletingLastPathComponent(), file.deletingLastPathComponent().deletingLastPathComponent(),
                   file.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent(), directory]
    expect("C cache: every directory from the cache root down is 0700", folders.allSatisfy { mode($0) & 0o777 == 0o700 })
    expect("C cache: the body file is 0600", mode(file) & 0o777 == 0o600)
    let leftovers = (FileManager.default.enumerator(atPath: directory.path)?.allObjects as? [String] ?? []).filter { $0.hasSuffix(".tmp") }
    expect("C cache: atomic writes leave no temporary files", leftovers.isEmpty)
    expect("C cache: the path never contains the account address or mailbox name",
           !file.path.contains(account) && !file.path.contains("INBOX") && file.path.hasPrefix(directory.path))
    expect("C cache: the cache root is excluded from backups",
           (try? directory.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup == true)

    let raw = fixtureAlternative
    let parsed = MailMIME.content(raw)
    let rawKey = MailBodyKey(account: account, validity: 7, uid: 77)
    cache.store(parsed, for: rawKey)
    let stored = (try? Data(contentsOf: cache.fileURL(for: rawKey)!)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    expect("C cache: the stored file holds the parsed body, never raw RFC 822 headers",
           !stored.isEmpty && stored.contains("las") && !["Received:", "DKIM-Signature", "mx.google.com", "Content-Transfer-Encoding",
                                                          "unit@gmail.com", "MIME-Version"].contains(where: stored.contains))

    // Corrupted and truncated files are misses, not crashes, and can be rewritten.
    let corruptKey = MailBodyKey(account: account, validity: 7, uid: 500)
    cache.store(body, for: corruptKey)
    try Data("{\"html\": nul".utf8).write(to: cache.fileURL(for: corruptKey)!)
    let afterCorruption = MailBodyCache(directory: directory)
    expect("C cache: a corrupted file is a miss and is forgotten", afterCorruption.content(for: corruptKey) == nil
               && !afterCorruption.contains(corruptKey))
    try Data([0xff, 0x00, 0x13]).write(to: cache.fileURL(for: corruptKey)!)
    expect("C cache: a binary-garbage file is a miss", MailBodyCache(directory: directory).content(for: corruptKey) == nil)
    afterCorruption.store(body, for: corruptKey)
    expect("C cache: after a corrupt file the body can be stored and read again",
           MailBodyCache(directory: directory).content(for: corruptKey)?.content == body)

    // UIDVALIDITY purge keeps the current epoch, other mailboxes and other accounts.
    let purgeRoot = root.appendingPathComponent("purge")
    let purger = MailBodyCache(directory: purgeRoot)
    let oldEpoch = MailBodyKey(account: account, validity: 7, uid: 1)
    let newEpoch = MailBodyKey(account: account, validity: 8, uid: 1)
    let otherBox = MailBodyKey(account: account, mailbox: "Archive", validity: 7, uid: 1)
    let otherAccount = MailBodyKey(account: other, validity: 7, uid: 1)
    for key in [oldEpoch, newEpoch, otherBox, otherAccount] { purger.store(body, for: key) }
    purger.purge(account: account, keepingValidity: 8)
    let afterPurge = MailBodyCache(directory: purgeRoot)
    expect("C cache purge on a new UIDVALIDITY drops the old epoch from memory and disk",
           purger.content(for: oldEpoch) == nil && afterPurge.content(for: oldEpoch) == nil && !purger.contains(oldEpoch))
    expect("C cache purge on a new UIDVALIDITY keeps the new epoch, other mailboxes and other accounts",
           [newEpoch, otherBox, otherAccount].allSatisfy { purger.content(for: $0) != nil && afterPurge.content(for: $0)?.source == .disk })
    purger.purge(account: account)
    let afterAccountPurge = MailBodyCache(directory: purgeRoot)
    expect("C cache purge(account:) removes every body of that account, in memory and on disk",
           [newEpoch, otherBox].allSatisfy { purger.content(for: $0) == nil && afterAccountPurge.content(for: $0) == nil }
               && purger.diskBytes(account: account) == 0 && afterAccountPurge.diskBytes(account: account) == 0)
    expect("C cache purge(account:) leaves other accounts alone",
           purger.content(for: otherAccount)?.content == body && afterAccountPurge.content(for: otherAccount)?.content == body)

    // Memory LRU by count and by bytes.
    let byCount = MailBodyCache(directory: nil, memoryCount: 2)
    let m1 = MailBodyKey(account: account, validity: 7, uid: 1), m2 = MailBodyKey(account: account, validity: 7, uid: 2)
    let m3 = MailBodyKey(account: account, validity: 7, uid: 3)
    byCount.store(body, for: m1)
    byCount.store(body, for: m2)
    _ = byCount.memoryContent(for: m1)
    byCount.store(body, for: m3)
    expect("C cache memory LRU by count: the least recently used body goes, a recently read one stays",
           byCount.memoryContent(for: m2) == nil && byCount.memoryContent(for: m1) != nil && byCount.memoryContent(for: m3) != nil)
    let forty = MailContent(html: nil, text: String(repeating: "x", count: 40))
    let byBytes = MailBodyCache(directory: nil, memoryLimit: 100, memoryCount: 30)
    byBytes.rememberInMemory(forty, for: m1)
    byBytes.rememberInMemory(forty, for: m2)
    byBytes.rememberInMemory(forty, for: m3)
    expect("C cache memory LRU by bytes: over the byte limit the oldest body goes",
           byBytes.memoryContent(for: m1) == nil && byBytes.memoryContent(for: m2) == forty && byBytes.memoryContent(for: m3) == forty)
    byBytes.rememberInMemory(MailContent(html: nil, text: String(repeating: "y", count: 101)), for: m1)
    expect("C cache memory: a body larger than the whole memory budget is not kept and evicts nothing",
           byBytes.memoryContent(for: m1) == nil && byBytes.memoryContent(for: m2) != nil)
    expect("C cache without a directory stores nothing on disk", MailBodyCache(directory: nil).fileURL(for: m1) == nil
               && byCount.diskBytes(account: account) == 0)

    // Disk LRU and age, with an injected clock (memory disabled so every read uses the disk).
    var now = Date()
    let lruRoot = root.appendingPathComponent("lru")
    let text = MailContent(html: nil, text: String(repeating: "z", count: 200))
    let lru = MailBodyCache(directory: lruRoot, memoryLimit: 0, diskLimit: 500, maxAge: 1_000, now: { now })
    let d1 = MailBodyKey(account: account, validity: 7, uid: 1), d2 = MailBodyKey(account: account, validity: 7, uid: 2)
    let d3 = MailBodyKey(account: account, validity: 7, uid: 3)
    lru.store(text, for: d1)
    now += 10
    lru.store(text, for: d2)
    now += 10
    _ = lru.content(for: d1)          // d1 is now more recently used than d2
    now += 10
    lru.store(text, for: d3)          // three bodies exceed 500 bytes
    expect("C cache disk LRU: over the byte limit the least recently used body leaves the disk",
           !FileManager.default.fileExists(atPath: lru.fileURL(for: d2)!.path) && lru.content(for: d2) == nil)
    expect("C cache disk LRU: recently read and new bodies stay, and the account fits its limit",
           lru.content(for: d1) != nil && lru.content(for: d3) != nil && lru.diskBytes(account: account) <= 500)
    let ageRoot = root.appendingPathComponent("age")
    var clock = Date()
    let aged = MailBodyCache(directory: ageRoot, memoryLimit: 0, diskLimit: 1_000_000, maxAge: 100, now: { clock })
    let a1 = MailBodyKey(account: account, validity: 7, uid: 1), a2 = MailBodyKey(account: account, validity: 7, uid: 2)
    let a3 = MailBodyKey(account: account, validity: 7, uid: 3)
    aged.store(body, for: a1)
    aged.store(body, for: a2)
    clock += 90
    _ = aged.content(for: a2)         // used at +90
    clock += 30                       // +120: a1 last used 120 s ago, a2 30 s ago
    aged.store(body, for: a3)
    expect("C cache maxAge: a body unused for longer than maxAge is removed on the next store",
           !FileManager.default.fileExists(atPath: aged.fileURL(for: a1)!.path) && MailBodyCache(directory: ageRoot).content(for: a1) == nil)
    expect("C cache maxAge counts from the last use, not from when it was stored",
           FileManager.default.fileExists(atPath: aged.fileURL(for: a2)!.path) && aged.content(for: a2) != nil)
    let sizeBefore = aged.diskBytes(account: account)
    aged.store(body, for: a3)
    expect("C cache: storing the same key again replaces it instead of counting it twice", aged.diskBytes(account: account) == sizeBefore)
}

// MARK: D. BODYSTRUCTURE, part plan and assembler

func parsedStructure(_ text: String) -> MailBodyPart? {
    var framer = MailIMAPFramer()
    framer.append(Data("* 1 FETCH (UID 5 BODYSTRUCTURE \(text))\r\n".utf8))
    return ((try? framer.next()) ?? nil)?.fetch?.bodyStructure
}

func crlfData(_ text: String) -> Data { Data(text.replacingOccurrences(of: "\n", with: "\r\n").utf8) }

let fixtureAlternativeHTML = #"<div dir="ltr">Mañana a las <b>3</b>.</div>"#
let fixtureAlternative = crlfData("""
    Received: from mail-sor-f41.google.com (mail-sor-f41.google.com. [209.85.220.41])
            by mx.google.com with SMTPS id a1;
    DKIM-Signature: v=1; a=rsa-sha256; c=relaxed/relaxed; d=example.test; s=20230601; bh=x; b=y
    From: =?UTF-8?Q?Luc=C3=ADa?= <lucia@example.test>
    To: unit@gmail.com
    Subject: Hola
    MIME-Version: 1.0
    Content-Type: multipart/alternative; boundary="000000000000a1b2c3"

    --000000000000a1b2c3
    Content-Type: text/plain; charset="UTF-8"
    Content-Transfer-Encoding: quoted-printable

    Ma=C3=B1ana a las 3.=20
    Saludos
    --000000000000a1b2c3
    Content-Type: text/html; charset="UTF-8"
    Content-Transfer-Encoding: base64

    \(Data(fixtureAlternativeHTML.utf8).base64EncodedString())
    --000000000000a1b2c3--
    """)
let fixtureAlternativeStructure = #"(("TEXT" "PLAIN" ("CHARSET" "UTF-8") NIL NIL "QUOTED-PRINTABLE" 32 2 NIL NIL NIL NIL)("TEXT" "HTML" ("CHARSET" "UTF-8") NIL NIL "BASE64" 60 1 NIL NIL NIL NIL) "ALTERNATIVE" ("BOUNDARY" "000000000000a1b2c3") NIL NIL NIL)"#

let fixtureMixed = crlfData("""
    From: Equipo <equipo@example.test>
    Subject: Informe
    MIME-Version: 1.0
    Content-Type: multipart/mixed; boundary="mix"

    --mix
    Content-Type: multipart/alternative; boundary="alt"

    --alt
    Content-Type: text/plain; charset="UTF-8"

    Adjunto el informe.
    --alt
    Content-Type: text/html; charset="UTF-8"

    <p>Adjunto el <i>informe</i>.</p>
    --alt--
    --mix
    Content-Type: application/pdf; name="informe.pdf"
    Content-Disposition: attachment; filename="informe.pdf"
    Content-Transfer-Encoding: base64

    \(String(repeating: "JVBERi0xLjQKJcOkw7zDtsOfCjIgMCBvYmoK", count: 40))
    --mix
    Content-Type: text/plain; charset="UTF-8"; name="notas.txt"
    Content-Disposition: attachment; filename="notas.txt"

    Texto del adjunto que no debe leerse.
    --mix--
    """)
let fixtureMixedStructure = #"((("TEXT" "PLAIN" ("CHARSET" "UTF-8") NIL NIL "7BIT" 21 1 NIL NIL NIL NIL)("TEXT" "HTML" ("CHARSET" "UTF-8") NIL NIL "7BIT" 34 1 NIL NIL NIL NIL) "ALTERNATIVE" ("BOUNDARY" "alt") NIL NIL NIL)("APPLICATION" "PDF" ("NAME" "informe.pdf") NIL NIL "BASE64" 1440 NIL ("ATTACHMENT" ("FILENAME" "informe.pdf")) NIL NIL)("TEXT" "PLAIN" ("CHARSET" "UTF-8" "NAME" "notas.txt") NIL NIL "7BIT" 38 1 NIL ("ATTACHMENT" ("FILENAME" "notas.txt")) NIL NIL) "MIXED" ("BOUNDARY" "mix") NIL NIL NIL)"#

let fixtureRelated = crlfData("""
    Subject: Logo
    Content-Type: multipart/alternative; boundary="a"

    --a
    Content-Type: text/plain; charset=UTF-8

    Logo abajo
    --a
    Content-Type: multipart/related; boundary="r"

    --r
    Content-Type: text/html; charset=UTF-8

    <p>Logo</p><img src="cid:logo@example.test">
    --r
    Content-Type: image/png; name="logo.png"
    Content-ID: <logo@example.test>
    Content-Disposition: inline; filename="logo.png"
    Content-Transfer-Encoding: base64

    iVBORw0KGgo=
    --r--
    --a--
    """)
let fixtureRelatedStructure = #"(("TEXT" "PLAIN" ("CHARSET" "UTF-8") NIL NIL "7BIT" 10 1 NIL NIL NIL NIL)(("TEXT" "HTML" ("CHARSET" "UTF-8") NIL NIL "7BIT" 45 1 NIL NIL NIL NIL)("IMAGE" "PNG" ("NAME" "logo.png") "<logo@example.test>" NIL "BASE64" 12 NIL ("INLINE" ("FILENAME" "logo.png")) NIL NIL) "RELATED" ("BOUNDARY" "r") NIL NIL NIL) "ALTERNATIVE" ("BOUNDARY" "a") NIL NIL NIL)"#

let fixtureLatin = crlfData("""
    Subject: Reunion
    Content-Type: multipart/alternative; boundary=iso

    --iso
    Content-Type: text/plain; charset=ISO-8859-1
    Content-Transfer-Encoding: quoted-printable

    Reuni=F3n ma=F1ana en Bogot=E1.
    --iso
    Content-Type: text/html; charset=windows-1252
    Content-Transfer-Encoding: 8bit


    """) + Data([0x3c, 0x70, 0x3e, 0x93, 0x52, 0x65, 0x75, 0x6e, 0x69, 0xf3, 0x6e, 0x94, 0x20, 0x96, 0x20, 0x80, 0x35, 0x3c, 0x2f, 0x70, 0x3e])
    + crlfData("\n--iso--\n")
let fixtureLatinStructure = #"(("TEXT" "PLAIN" ("CHARSET" "ISO-8859-1") NIL NIL "QUOTED-PRINTABLE" 33 1 NIL NIL NIL)("TEXT" "HTML" ("CHARSET" "windows-1252") NIL NIL "8BIT" 21 1 NIL NIL NIL) "ALTERNATIVE" ("BOUNDARY" "iso") NIL NIL)"#

/// main.swift's `nested` fixture: mixed(text attachment, alternative(html, plain QP ISO-8859-1), pdf), with preamble,
/// epilogue and a folded boundary parameter.
let nestedStructure = #"(("TEXT" "PLAIN" ("CHARSET" "UTF-8") NIL NIL "7BIT" 16 1 NIL ("ATTACHMENT" ("FILENAME" "notas.txt")) NIL)(("TEXT" "HTML" ("CHARSET" "UTF-8") NIL NIL "7BIT" 30 1 NIL NIL NIL)("TEXT" "PLAIN" ("CHARSET" "ISO-8859-1") NIL NIL "QUOTED-PRINTABLE" 40 3 NIL NIL NIL) "ALTERNATIVE" ("BOUNDARY" "alt_679") NIL NIL)("APPLICATION" "PDF" NIL NIL NIL "BASE64" 12 NIL NIL NIL) "MIXED" ("BOUNDARY" "mixed_908") NIL NIL)"#
/// main.swift's `richRelated`: related with start=, the cid image first and the HTML root second.
let richRelatedStructure = #"(("IMAGE" "PNG" NIL "<Logo@example.test>" NIL "BASE64" 4 NIL NIL NIL)("TEXT" "HTML" NIL "<root@example.test>" NIL "7BIT" 900 10 NIL NIL NIL) "RELATED" ("BOUNDARY" "images" "START" "<root@example.test>") NIL NIL)"#

func checkBodyStructure() {
    // Parsing realistic Gmail BODYSTRUCTURE values.
    let alternative = parsedStructure(fixtureAlternativeStructure)
    expect("D parse alternative: multipart root with two text children numbered 1 and 2",
           alternative?.mime == "multipart/alternative" && alternative?.children.map(\.section) == ["1", "2"]
               && alternative?.children.map(\.mime) == ["text/plain", "text/html"])
    expect("D parse alternative: parameters lowercased by name, encoding lowercased, size read",
           alternative?.parameters["boundary"] == "000000000000a1b2c3" && alternative?.children.first?.parameters["charset"] == "UTF-8"
               && alternative?.children.first?.encoding == "quoted-printable" && alternative?.children.first?.size == 32)
    let mixed = parsedStructure(fixtureMixedStructure)
    expect("D parse mixed: nested sections 1.1, 1.2, 2, 3",
           mixed?.leaves.map(\.section) == ["1.1", "1.2", "2", "3"] && mixed?.children.first?.section == "1")
    expect("D parse mixed: dispositions of the PDF and of a named text attachment (text parts carry a line count first)",
           mixed?.leaves.map(\.disposition) == [nil, nil, "attachment", "attachment"] && mixed?.leaves[2].isAttachment == true
               && mixed?.leaves[3].parameters["name"] == "notas.txt")
    let related = parsedStructure(fixtureRelatedStructure)
    expect("D parse related: the cid image keeps its Content-ID and inline disposition",
           related?.leaves.map(\.section) == ["1", "2.1", "2.2"] && related?.leaves.last?.contentID == "<logo@example.test>"
               && related?.leaves.last?.disposition == "inline" && related?.children.last?.subtype == "related")
    let single = parsedStructure(#"("text" "Plain" NIL NIL NIL "7bit" 10 1)"#)
    expect("D parse single part without extension data: section 1, types lowercased, NIL parameters empty",
           single?.section == "1" && single?.mime == "text/plain" && single?.parameters.isEmpty == true
               && single?.contentID == nil && single?.disposition == nil && single?.encoding == "7bit")
    let extended = parsedStructure(#"(("TEXT" "PLAIN" ("CHARSET" "US-ASCII") NIL "desc" "7BIT" 5 1 "md5sum" ("INLINE" ("FOO" "bar")) ("EN" "ES") "http://loc")("IMAGE" "GIF" NIL "<g>" NIL "BASE64" 9 "md5" ("ATTACHMENT" NIL) "EN" NIL) "MIXED" ("BOUNDARY" "x" "CHARSET" "y") ("INLINE" NIL) ("EN") "location")"#)
    expect("D parse extension data (md5, disposition, language, location) on parts and multipart",
           extended?.leaves.map(\.disposition) == ["inline", "attachment"] && extended?.disposition == "inline"
               && extended?.parameters == ["boundary": "x", "charset": "y"])
    let escaped = parsedStructure(#"("APPLICATION" "PDF" ("NAME" "Informe \"final\" \\ v2.pdf") NIL NIL "BASE64" 10 NIL ("ATTACHMENT" ("FILENAME" "x")) NIL)"#)
    expect("D parse quoted strings with escaped quotes and backslashes", escaped?.parameters["name"] == #"Informe "final" \ v2.pdf"#)
    let literal = parsedStructure("(\"TEXT\" \"PLAIN\" (\"NAME\" {12}\r\nnota (1).txt) NIL NIL \"7BIT\" 3 1 NIL NIL NIL)")
    expect("D parse literal parameter values (with parentheses inside)", literal?.parameters["name"] == "nota (1).txt" && literal?.size == 3)
    let quotedNil = parsedStructure(#"("TEXT" "PLAIN" ("CHARSET" "NIL") NIL NIL "7BIT" 3 1)"#)
    expect("D parse: a quoted \"NIL\" is a string, not NIL", quotedNil?.parameters["charset"] == "NIL")
    let forwarded = parsedStructure(#"(("TEXT" "PLAIN" ("CHARSET" "UTF-8") NIL NIL "7BIT" 10 1 NIL NIL NIL)("MESSAGE" "RFC822" NIL NIL NIL "7BIT" 300 (NIL "Fwd" NIL NIL NIL NIL NIL NIL NIL NIL) ("TEXT" "HTML" ("CHARSET" "UTF-8") NIL NIL "7BIT" 20 1 NIL NIL NIL) 12 NIL ("ATTACHMENT" ("FILENAME" "fwd.eml")) NIL) "MIXED" ("BOUNDARY" "f") NIL NIL)"#)
    expect("D parse message/rfc822: its own structure is kept and it is an attachment",
           forwarded?.children.last?.isMessage == true && forwarded?.children.last?.message.first?.mime == "text/html"
               && forwarded?.children.last?.disposition == "attachment")
    for (label, text) in [("truncated", #"(("TEXT" "PLAIN" NIL NIL NIL "7BIT" 1 1"#), ("missing size", #"("TEXT" "PLAIN" NIL NIL NIL "7BIT")"#),
                          ("non-numeric size", #"("TEXT" "PLAIN" NIL NIL NIL "7BIT" big 1)"#),
                          ("multipart without subtype", #"(("TEXT" "PLAIN" NIL NIL NIL "7BIT" 1 1))"#), ("empty list", "()")] {
        expect("D parse rejects \(label) structures", parsedStructure(text) == nil)
    }
    var trailing = MailIMAPFramer()
    trailing.append(Data("* 1 FETCH (BODYSTRUCTURE (\"TEXT\" \"PLAIN\" NIL NIL NIL \"7BIT\" 1 1))\r\n".utf8))
    let tokens = ((try? trailing.next()) ?? nil)?.fetch?.structureTokens
    expect("D parse rejects tokens left over after the structure value",
           tokens.map { MailBodyStructure.parse($0) != nil && MailBodyStructure.parse($0 + [.closeList]) == nil } == true)
    let deep = String(repeating: "(", count: 40) + #"("TEXT" "PLAIN" NIL NIL NIL "7BIT" 1 1)"# + String(repeating: " \"MIXED\" (\"BOUNDARY\" \"b\"))", count: 40)
    expect("D parse refuses absurdly deep nesting without crashing", parsedStructure(deep) == nil)

    // Part plan.
    expect("D plan alternative: both text parts", alternative.flatMap(MailPartPlan.plan)?.sections == ["1", "2"])
    expect("D plan mixed: the text alternatives only, never the PDF or the named text attachment",
           mixed.flatMap(MailPartPlan.plan)?.sections == ["1.1", "1.2"])
    expect("D plan related: text parts plus the cid image of the related part",
           related.flatMap(MailPartPlan.plan)?.sections == ["1", "2.1", "2.2"])
    expect("D plan bytes add up the chosen parts' encoded sizes", mixed.flatMap(MailPartPlan.plan)?.bytes == 21 + 34)
    expect("D plan: a single-part message has no partial plan (fetch it whole)", single.flatMap(MailPartPlan.plan) == nil)
    expect("D plan: a forwarded message/rfc822 inside falls back to the whole message", forwarded.flatMap(MailPartPlan.plan) == nil)
    let noBoundary = parsedStructure(#"(("TEXT" "PLAIN" NIL NIL NIL "7BIT" 1 1) "MIXED" NIL NIL NIL)"#)
    expect("D plan: a multipart without a boundary parameter falls back", noBoundary != nil && noBoundary.flatMap(MailPartPlan.plan) == nil)
    let onlyAttachments = parsedStructure(#"(("APPLICATION" "PDF" NIL NIL NIL "BASE64" 10 NIL ("ATTACHMENT" NIL) NIL) "MIXED" ("BOUNDARY" "b") NIL NIL)"#)
    expect("D plan: nothing readable to fetch falls back", onlyAttachments.flatMap(MailPartPlan.plan) == nil)
    let huge = parsedStructure(#"(("TEXT" "HTML" NIL NIL NIL "BASE64" 30000000 1) "ALTERNATIVE" ("BOUNDARY" "b") NIL NIL)"#)
    expect("D plan: parts over the partial limit fall back to the whole message", huge.flatMap(MailPartPlan.plan) == nil)
    let imageRoot = parsedStructure(#"(("IMAGE" "PNG" NIL "<i>" NIL "BASE64" 9 NIL NIL NIL)("TEXT" "HTML" NIL NIL NIL "7BIT" 9 1) "RELATED" ("BOUNDARY" "b") NIL NIL)"#)
    expect("D plan related without start=: the first part is the root, not a cid resource",
           imageRoot.flatMap(MailPartPlan.plan)?.sections == ["2"])
    expect("D previewPart prefers the first non-attachment text/plain",
           mixed.flatMap(MailPartPlan.previewPart)?.section == "1.1" && onlyAttachments.flatMap(MailPartPlan.previewPart) == nil)

    // Assembler: fetching only the planned parts reads exactly like the whole message.
    let fixtures: [(String, Data, String)] = [
        ("alternative QP + base64 HTML with Gmail headers", fixtureAlternative, fixtureAlternativeStructure),
        ("mixed with PDF and text attachments", fixtureMixed, fixtureMixedStructure),
        ("alternative with related cid image", fixtureRelated, fixtureRelatedStructure),
        ("ISO-8859-1 QP and windows-1252 8bit", fixtureLatin, fixtureLatinStructure),
        ("nested fixture with preamble, epilogue and folded boundary", nested, nestedStructure),
        ("related with start= and image first", richRelated, richRelatedStructure),
    ]
    for (label, raw, text) in fixtures {
        guard let root = parsedStructure(text), let plan = MailPartPlan.plan(root) else {
            expect("D assemble \(label): structure parses and plans", false); continue
        }
        let sections = mimeSections(raw)
        let parts = sections.filter { plan.sections.contains($0.key) }
        let assembled = MailPartAssembler.assemble(root, parts: parts, boundary: "0123abcd")
        let whole = MailMIME.content(raw)
        expect("D assemble \(label): the planned parts read exactly like the whole message",
               parts.count == plan.sections.count && assembled.map(MailMIME.content) == whole && !whole.text.isEmpty)
    }
    expect("D assemble: the decoded texts are the expected ones (oracle for the fixtures themselves)",
           MailMIME.content(fixtureAlternative).text == "Mañana a las 3. \nSaludos"
               && MailMIME.content(fixtureLatin).text == "Reunión mañana en Bogotá."
               && MailMIME.content(fixtureLatin).html?.contains("“Reunión” – €5") == true
               && MailMIME.content(fixtureRelated).html?.contains("data:image/png;base64,iVBORw0KGgo=") == true
               && MailMIME.content(fixtureMixed).text == "Adjunto el informe.")
    if let root = parsedStructure(fixtureMixedStructure) {
        let sections = mimeSections(fixtureMixed)
        let assembled = MailPartAssembler.assemble(root, parts: sections.filter { ["1.1", "1.2"].contains($0.key) }, boundary: "s")
        expect("D assemble: unfetched leaves are empty attachments (no PDF or attachment bytes in the rebuilt message)",
               assembled.map { String(decoding: $0, as: UTF8.self) }.map { !$0.contains("JVBERi0") && !$0.contains("no debe leerse") } == true)
        var hostile = sections.filter { ["1.1", "1.2"].contains($0.key) }
        hostile["1.1"] = MailPartAssembler.Part(header: hostile["1.1"]!.header, body: Data("x\r\n--cala-s-1\r\ny".utf8))
        expect("D assemble refuses parts that contain its boundary marker", MailPartAssembler.assemble(root, parts: hostile, boundary: "s") == nil)
        let noHeaderEnd = sections.filter { ["1.1", "1.2"].contains($0.key) }.mapValues {
            MailPartAssembler.Part(header: Data(String(decoding: $0.header, as: UTF8.self).replacingOccurrences(of: "\r\n\r\n", with: "").utf8), body: $0.body)
        }
        expect("D assemble tolerates MIME headers that lack the final empty line",
               MailPartAssembler.assemble(root, parts: noHeaderEnd, boundary: "s").map(MailMIME.content) == MailMIME.content(fixtureMixed))
    }
    if let single {
        expect("D assemble: a single-part root returns nil (fetch the whole message)",
               MailPartAssembler.assemble(single, parts: ["1": MailPartAssembler.Part(header: Data(), body: Data("x".utf8))], boundary: "s") == nil)
    }
    expect("D splitter oracle: sections of the mixed fixture", Set(mimeSections(fixtureMixed).keys) == ["1", "1.1", "1.2", "2", "3"]
               && mimeSections(fixtureMixed)["1.1"].map { String(decoding: $0.body, as: UTF8.self) } == "Adjunto el informe.")
}

// MARK: E. .fast wire transcripts at the connection level

private func connection(_ world: FakeIMAPWorld, tuning: MailIMAPTuning = .fast) async throws -> MailIMAP {
    let imap = MailIMAP(socket: world.connect(), provider: .gmail, tuning: tuning)
    try await imap.open(email: "unit@gmail.com", password: "pw")
    return imap
}

private func peekedSections(_ command: String) -> [String] {
    var result: [String] = []
    var rest = Substring(command)
    while let range = rest.range(of: "BODY.PEEK[") {
        rest = rest[range.upperBound...]
        guard let close = rest.firstIndex(of: "]") else { break }
        result.append(String(rest[..<close]))
        rest = rest[rest.index(after: close)...]
    }
    return result
}

func checkFastWire() async throws {
    // E1. Opening reads the structure, then only the readable parts.
    do {
        let world = FakeIMAPWorld(uids: [(1, false)])
        world.mutate {
            $0.messages.append(.init(uid: 5, unread: true, raw: fixtureMixed, structure: fixtureMixedStructure))
            $0.messages.append(.init(uid: 6, unread: true, raw: FakeIMAPWorld.simpleRaw(6), structure: FakeIMAPWorld.simpleStructure(6)))
            $0.messages.append(.init(uid: 7, unread: true, raw: richRelated, structure: nil))
        }
        let imap = try await connection(world)
        let inbox = try await imap.synchronize(accountID: "unit@gmail.com")
        guard let mixedRow = inbox.messages.first(where: { $0.uid == 5 }), let plainRow = inbox.messages.first(where: { $0.uid == 6 }),
              let noStructure = inbox.messages.first(where: { $0.uid == 7 }) else { expect("E1 rows", false); return }
        let start = world.log.count
        let content = try await imap.content(of: mixedRow)
        let opened = Array(world.commands[start...])
        expect("E1 .fast open: one UID FETCH for RFC822.SIZE and BODYSTRUCTURE, then one for the parts",
               opened.count == 2 && opened.first == "UID FETCH 5 (UID RFC822.SIZE BODYSTRUCTURE)")
        expect("E1 .fast open fetches only the text sections and their MIME headers, never the attachments or the whole message",
               opened.count == 2 && Set(peekedSections(opened[1])) == ["1.1", "1.1.MIME", "1.2", "1.2.MIME"]
                   && !opened.contains { $0.contains("BODY.PEEK[]") || peekedSections($0).contains("2") || peekedSections($0).contains("3") })
        expect("E1 .fast open shows exactly what the whole message shows", content == MailMIME.content(fixtureMixed))
        expect("E1 .fast open never writes flags (BODY.PEEK only)", !world.commands.contains { $0.contains("STORE") }
                   && opened.allSatisfy { !$0.contains("BODY[") })
        let plainStart = world.log.count
        let plain = try await imap.content(of: plainRow)
        expect("E1 .fast open of a single-part message falls back to the whole message",
               Array(world.commands[plainStart...]) == ["UID FETCH 6 (UID RFC822.SIZE BODYSTRUCTURE)", "UID FETCH 6 (UID BODY.PEEK[])"]
                   && plain.text == "Hola 6")
        let bareStart = world.log.count
        let bare = try await imap.content(of: noStructure)
        expect("E1 .fast open without a BODYSTRUCTURE in the reply falls back to the whole message",
               world.commands[bareStart...].last == "UID FETCH 7 (UID BODY.PEEK[])" && bare == MailMIME.content(richRelated))
    }

    // E3. Incremental sync downloads headers only for UIDs it has not seen.
    do {
        let world = FakeIMAPWorld(uids: [(1, false), (2, true), (3, true)])
        let imap = try await connection(world)
        func headerFetches(from start: Int) -> [String] {
            world.commands[start...].filter { $0.hasPrefix("UID FETCH") && $0.contains("HEADER.FIELDS") }
        }
        let s0 = world.log.count
        guard let first = try await imap.synchronize(accountID: "unit@gmail.com", known: nil, shouldYield: nil) else {
            expect("E3 first sync", false); return
        }
        expect("E3 .fast first sync: FLAGS for the window, then headers for every UID",
               world.commands[s0...].contains("FETCH 1:* (UID FLAGS)") && headerFetches(from: s0).count == 1
                   && headerFetches(from: s0).first?.hasPrefix("UID FETCH 1:3 ") == true && first.messages.count == 3 && first.unread == 2)
        expect("E3 .fast sync never uses the conservative full FETCH 1:* of headers",
               !world.commands.contains { $0.hasPrefix("FETCH ") && $0.contains("HEADER.FIELDS") })
        world.mutate {
            $0.messages.append(.init(uid: 4, unread: true, raw: FakeIMAPWorld.simpleRaw(4), structure: nil))
            $0.messages[0].unread = true
            $0.messages[1].unread = false
        }
        let s1 = world.log.count
        let known = MailKnownMessages(validity: 7, messages: first.messages)
        guard let second = try await imap.synchronize(accountID: "unit@gmail.com", known: known, shouldYield: nil) else {
            expect("E3 second sync", false); return
        }
        expect("E3 .fast incremental sync fetches headers for the new UID only",
               headerFetches(from: s1).count == 1 && headerFetches(from: s1).first?.hasPrefix("UID FETCH 4 (") == true)
        expect("E3 .fast incremental sync applies flag changes of known rows and keeps their previews",
               second.messages.map(\.uid) == [4, 3, 2, 1] && second.messages.first { $0.uid == 1 }?.unread == true
                   && second.messages.first { $0.uid == 2 }?.unread == false && second.unread == 3
                   && second.messages.first { $0.uid == 3 }?.snippet == "Hola 3" && second.messages.first { $0.uid == 4 }?.subject == "Subject 4")
        let s2 = world.log.count
        _ = try await imap.synchronize(accountID: "unit@gmail.com", known: MailKnownMessages(validity: 7, messages: second.messages), shouldYield: nil)
        expect("E3 .fast sync with nothing new downloads no headers at all", headerFetches(from: s2).isEmpty)
        let s3 = world.log.count
        _ = try await imap.synchronize(accountID: "unit@gmail.com", known: MailKnownMessages(validity: 6, messages: second.messages), shouldYield: nil)
        expect("E3 .fast sync with rows of another UIDVALIDITY downloads every header again",
               headerFetches(from: s3).first?.hasPrefix("UID FETCH 1:4 ") == true)
        let s4 = world.log.count
        let yielded = try await imap.synchronize(accountID: "unit@gmail.com", known: nil, shouldYield: { true })
        expect("E3 a sync asked to step aside returns nothing after NOOP and sends no FETCH", yielded == nil
                   && !world.commands[s4...].contains { $0.contains("FETCH") })
    }

    // E4. LIST is reused across moves; a refused move lists again once, and retries only toward a renamed mailbox (M1).
    do {
        let world = FakeIMAPWorld(uids: [(1, false), (2, false), (3, false), (4, false)])
        let imap = try await connection(world)
        let inbox = try await imap.synchronize(accountID: "unit@gmail.com")
        let rows = Dictionary(uniqueKeysWithValues: inbox.messages.map { ($0.uid, $0) })
        let lists = world.count("LIST")
        try await imap.trash(rows[1]!)
        try await imap.trash(rows[2]!)
        expect("E4 .fast: two deletes reuse the connection's LIST (no LIST per move)", world.count("LIST") == lists && world.count("UID MOVE") == 2)
        world.on("UID MOVE", .reply("§ NO [OVERQUOTA] cannot move"))
        var sameName: Error?
        do { try await imap.trash(rows[3]!) } catch { sameName = error }
        expect("E4 .fast: a move refused with a cached listing lists the mailboxes again exactly once", world.count("LIST") == lists + 1)
        expect("M1 .fast: when the fresh LIST names the same trash, the refused MOVE is not sent again and the refusal surfaces",
                         world.count("UID MOVE 3 ") == 1 && { if case MailIMAPError.rejected? = sameName { return true }; return false }())
        // Another client renamed the trash: the cached name is refused, the fresh listing gives the new one.
        world.mutate {
            $0.list = #"* LIST () "/" INBOX"# + "\r\n" + #"* LIST (\All) "/" "[Gmail]/All Mail""# + "\r\n"
                + #"* LIST (\Trash) "/" "[Gmail]/Papelera""# + "\r\n"
            $0.rules.removeAll()
        }
        world.on(#"UID MOVE 4 "[Gmail]/Trash""#, .reply("§ NO [TRYCREATE] no such mailbox"))
        try await imap.trash(rows[4]!)
        expect("E4 .fast: a move refused because the trash was renamed lists again once and retries once, to the new name",
               world.commands.filter { $0.hasPrefix("UID MOVE 4 ") } == [#"UID MOVE 4 "[Gmail]/Trash""#, #"UID MOVE 4 "[Gmail]/Papelera""#]
                   && world.count("LIST") == lists + 2 && !world.locked { world.messages.contains { $0.uid == 4 } })
        expect("E4 .fast: the whole move sequence stayed wire-safe (no EXPUNGE, no \\Deleted)",
               wireIsSafe(world.log.map { ($0.command, $0.status) }) && !world.commands.contains { $0.contains("EXPUNGE") || $0.contains("Deleted") })
    }
    do {
        let world = FakeIMAPWorld(uids: [(1, false), (2, false), (3, false)])
        world.mutate { $0.capabilities = "IDLE UIDPLUS" }
        let imap = try await connection(world)
        let inbox = try await imap.synchronize(accountID: "unit@gmail.com")
        try await imap.trash(inbox.messages.first { $0.uid == 1 }!)
        world.on("UID COPY", .reply("§ NO [OVERQUOTA] copy failed"))
        var sameName: Error?
        do { try await imap.trash(inbox.messages.first { $0.uid == 2 }!) } catch { sameName = error }
        expect("M1 .fast UIDPLUS: a refused COPY toward an unchanged trash name is not retried and nothing is flagged",
                         world.count("UID COPY 2 ") == 1 && !world.commands.contains { $0.hasPrefix("UID STORE 2 ") || $0.hasPrefix("UID EXPUNGE 2") }
                             && { if case MailIMAPError.rejected? = sameName { return true }; return false }())
        world.mutate {
            $0.list = #"* LIST (\Trash) "/" "[Gmail]/Papelera""# + "\r\n"
            $0.rules.removeAll()
        }
        world.on(#"UID COPY 3 "[Gmail]/Trash""#, .reply("§ NO [TRYCREATE] no such mailbox"))
        try await imap.trash(inbox.messages.first { $0.uid == 3 }!)
        let log = world.log.map { ($0.command, $0.status) }
        expect("E4 .fast UIDPLUS: a COPY refused because the trash was renamed is copied once more to the new name, then flagged and expunged by UID",
               wireIsSafe(log) && world.commands.filter { $0.hasPrefix("UID COPY 3 ") } == [#"UID COPY 3 "[Gmail]/Trash""#, #"UID COPY 3 "[Gmail]/Papelera""#]
                   && world.commands.contains("UID EXPUNGE 3") && !world.commands.contains("EXPUNGE"))
        expect("E4 .fast UIDPLUS: \\Deleted is only stored after the server accepted a COPY of that UID",
               wireIsSafe(log) && world.log.firstIndex { $0.command == #"UID STORE 3 +FLAGS.SILENT (\Deleted)"# }.map { index in
                   world.log[..<index].contains { $0.command.hasPrefix("UID COPY 3 ") && $0.status == "OK" }
               } == true)
    }

    // Prefetch under .fast: readable parts only, within the limits.
    do {
        let world = FakeIMAPWorld(uids: [])
        world.mutate {
            $0.messages.append(.init(uid: 5, unread: true, raw: fixtureMixed, structure: fixtureMixedStructure))
            $0.messages.append(.init(uid: 6, unread: true, raw: fixtureAlternative, structure: fixtureAlternativeStructure))
            $0.messages.append(.init(uid: 7, unread: true, raw: FakeIMAPWorld.simpleRaw(7), structure: FakeIMAPWorld.simpleStructure(7)))
        }
        let imap = try await connection(world)
        let inbox = try await imap.synchronize(accountID: "unit@gmail.com")
        let start = world.log.count
        let result = try await imap.prefetch(inbox.messages, shouldStop: { false })
        let sent = Array(world.commands[start...])
        expect("E prefetch: one structure fetch for all, then parts of the planned messages only (single-part skipped)",
               sent.first == "UID FETCH 5:7 (UID RFC822.SIZE BODYSTRUCTURE)" && sent.count == 3
                   && !sent.contains { $0.contains("BODY.PEEK[]") } && Set(result.contents.map(\.0.uid)) == [5, 6])
        expect("E prefetch contents equal what opening the whole message shows",
               result.contents.allSatisfy { $0.1 == MailMIME.content($0.0.uid == 5 ? fixtureMixed : fixtureAlternative) })
        let stopped = try await imap.prefetch(inbox.messages, shouldStop: { true })
        expect("E prefetch stops before downloading parts when the person is waiting", stopped.contents.isEmpty && stopped.stop == "interactive")
        let conservative = try await connection(world, tuning: .conservative)
        let none = try await conservative.prefetch(inbox.messages, shouldStop: { false })
        expect("E prefetch is off under the conservative tuning", none.contents.isEmpty && none.stop == "none")
    }
}

// MARK: F. Dead link

func checkDeadLink() async throws {
    let world = FakeIMAPWorld(uids: [(1, false)])
    let imap = try await connection(world)
    _ = try await imap.synchronize(accountID: "unit@gmail.com")
    world.on("DONE", .silent)
    let waiter = Task { () -> Error? in
        do { try await imap.waitForInboxChange(); return nil } catch { return error }
    }
    try await Task.sleep(for: .milliseconds(100))
    let interrupted = ContinuousClock.now
    imap.requestRefresh()
    let error = await waiter.value
    let elapsed = interrupted.duration(to: .now)
    expect("F DONE without an answer is reported as a dead link",
           { if case MailIMAPError.linkDead? = error { return true }; return false }())
    expect("F the dead link is noticed about \(MailLink.doneAckTimeout) s after DONE (between 2.5 and 4.5 s)",
           elapsed >= .milliseconds(2_500) && elapsed <= .milliseconds(4_500))
}

@MainActor
func checkDeadLinkReconnect() async throws {
    let world = FakeIMAPWorld(uids: [(1, false), (2, true)])
    let h = try MailHarness(world: world)
    defer { h.finish() }
    guard await h.start(rows: 2), let target = h.row(2) else { expect("F service: harness synced", false); return }
    world.on("DONE", .silent)
    let started = ContinuousClock.now
    let content = try await h.service.content(of: target)
    let elapsed = started.duration(to: .now)
    let bodyFetches = world.log.filter { $0.command.hasPrefix("UID FETCH 2 ") }
    expect("F service: a queued open survives the dead link and runs on the immediate reconnect",
           content.text == "Hola 2" && world.connectionCount == 2 && bodyFetches.allSatisfy { $0.connection == 2 } && !bodyFetches.isEmpty)
    expect("F service: dead-link detection plus reconnect take ~3 s, with no backoff wait (< 4.5 s)",
           elapsed >= .milliseconds(2_500) && elapsed < .milliseconds(4_500))
    expect("F service: a dead link shows no notice and keeps the list", h.service.notices.isEmpty && h.service.messages.count == 2)
}

// MARK: Review findings on 2e6ccb4 (I1-I6, M1-M3), fixed in 8f2334b: regressions fail the script.

/// multipart/related whose start= root is itself a multipart/alternative (Apple Mail and Outlook send this).
let fixtureRelatedAlternativeRoot = crlfData("""
    Subject: Logo
    Content-Type: multipart/related; boundary="rel"; type="multipart/alternative"; start="<root@example.test>"

    --rel
    Content-Type: image/png; name="logo.png"
    Content-ID: <logo@example.test>
    Content-Transfer-Encoding: base64

    iVBORw0KGgo=
    --rel
    Content-Type: multipart/alternative; boundary="alt"
    Content-ID: <root@example.test>

    --alt
    Content-Type: text/plain; charset=UTF-8

    Hola con logo
    --alt
    Content-Type: text/html; charset=UTF-8

    <p>Hola</p><img src="cid:logo@example.test">
    --alt--
    --rel--
    """)
let fixtureRelatedAlternativeRootStructure = #"(("IMAGE" "PNG" ("NAME" "logo.png") "<logo@example.test>" NIL "BASE64" 12 NIL NIL NIL NIL)(("TEXT" "PLAIN" ("CHARSET" "UTF-8") NIL NIL "7BIT" 13 1 NIL NIL NIL NIL)("TEXT" "HTML" ("CHARSET" "UTF-8") NIL NIL "7BIT" 44 1 NIL NIL NIL NIL) "ALTERNATIVE" ("BOUNDARY" "alt") NIL NIL NIL) "RELATED" ("BOUNDARY" "rel" "TYPE" "multipart/alternative" "START" "<root@example.test>") NIL NIL NIL)"#

@MainActor
func checkReviewFindings() async throws {
    let base: [(UInt32, Bool)] = [(1, false), (2, true), (3, true)]
    let account = MailHarness.account

    // I1. related with start= pointing at a nested alternative.
    let whole = MailMIME.content(fixtureRelatedAlternativeRoot)
    expect("I1 oracle: the whole message reads its alternative root, with the cid logo inlined",
           whole.text == "Hola con logo" && whole.html?.contains("data:image/png;base64,iVBORw0KGgo=") == true)
    if let root = parsedStructure(fixtureRelatedAlternativeRootStructure), let plan = MailPartPlan.plan(root) {
        let parts = mimeSections(fixtureRelatedAlternativeRoot).filter { plan.sections.contains($0.key) }
        let assembled = MailPartAssembler.assemble(root, parts: parts, boundary: "seed").map(MailMIME.content)
        expect("I1 assemble: related with start= naming a nested alternative reads like the whole message",
                         assembled == whole)
    } else {
        expect("I1 structure parses and plans", false)
    }
    do {
        let world = FakeIMAPWorld(uids: [])
        world.mutate { $0.messages.append(.init(uid: 9, unread: true, raw: fixtureRelatedAlternativeRoot, structure: fixtureRelatedAlternativeRootStructure)) }
        let imap = MailIMAP(socket: world.connect(), provider: .gmail, tuning: .fast)
        try await imap.open(email: account, password: "pw")
        let inbox = try await imap.synchronize(accountID: account)
        let opened = try await imap.content(of: inbox.messages[0])
        expect("I1 .fast open of that message shows what the whole message shows", opened == whole)

        let cacheDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("cala-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let serviceWorld = FakeIMAPWorld(uids: [])
        serviceWorld.mutate { $0.messages.append(.init(uid: 9, unread: false, raw: fixtureRelatedAlternativeRoot, structure: fixtureRelatedAlternativeRootStructure)) }
        let h = try MailHarness(world: serviceWorld, cache: MailBodyCache(directory: cacheDirectory))
        defer { h.finish() }
        if await h.start(rows: 1), let row = h.row(9), let key = MailBodyKey(row) {
            let shown = try await h.service.content(of: row)
            let file = MailBodyCache(directory: cacheDirectory).fileURL(for: key)!
            _ = await waitFor(1) { FileManager.default.fileExists(atPath: file.path) }
            let cached = MailBodyCache(directory: cacheDirectory).content(for: key)?.content
            expect("I1 an empty or wrong partial body is never written to the cache",
                             cached == nil || (cached == whole && !(cached!.text.isEmpty && cached!.html == nil)))
        } else {
            expect("I1 service harness synced", false)
        }
    }

    // I2. Mark all read covers what was listed at tap time, not mail that arrives before the command goes out.
    do {
        let world = FakeIMAPWorld(uids: base)
        let h = try MailHarness(world: world)
        defer { h.finish() }
        guard await h.start(rows: 3) else { expect("I2 harness synced", false); return }
        world.on("DONE", .hold)
        h.service.markAllRead(accountID: account)
        _ = await waitFor { world.heldCount == 1 }
        world.mutate { $0.messages.append(.init(uid: 4, unread: true, raw: FakeIMAPWorld.simpleRaw(4), structure: nil)) }
        world.release()
        _ = await h.settle { world.count("UID STORE") >= 1 && h.service.messages.count == 4 }
        expect("I2 mark all read: the rows listed at tap time end read on the server",
               world.locked { world.messages.filter { $0.uid <= 3 }.allSatisfy { !$0.unread } })
        expect("I2 mark all read never marks a message that arrived after the tap (UID > newest listed)",
                         world.locked { world.messages.first { $0.uid == 4 }?.unread == true } && h.row(4)?.unread == true
                             && h.service.unreadCount == 1)
    }

    // I3. A prefetch whose answer times out must not take the connection down (nor loop reconnecting).
    do {
        let world = FakeIMAPWorld(uids: base)
        world.mutate { $0.constrained = false }
        world.on("UID FETCH 1:3 (UID RFC822.SIZE BODYSTRUCTURE)", .timeOut, times: 99)
        let cacheDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("cala-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let h = try MailHarness(world: world, cache: MailBodyCache(directory: cacheDirectory))
        defer { h.finish() }
        h.service.start()
        _ = await waitFor { world.count("UID FETCH 1:3 (UID RFC822.SIZE BODYSTRUCTURE)") >= 1 }
        _ = await waitFor(3.5) { false }   // long enough for a quick reconnect and a 2 s backoff retry
        expect("I3 prefetch timeout: the list stays and no notice is shown", h.service.messages.count == 3 && h.service.notices.isEmpty)
        expect("I3 a timed-out prefetch keeps the connection (no reconnect)", world.connectionCount == 1)
        expect("I3 a prefetch that keeps timing out does not cause repeated reconnects", world.connectionCount <= 2)
    }

    // I4. With no connection, an optimistic delete reverts with a notice within a bounded time.
    do {
        let world = FakeIMAPWorld(uids: base)
        let h = try MailHarness(world: world)
        defer { h.finish() }
        guard await h.start(rows: 3), let target = h.row(2) else { expect("I4 harness synced", false); return }
        let before = h.service.messages
        world.on("LOGIN", .drop, times: 999)
        world.on("DONE", .drop)
        h.service.refresh()
        _ = await waitFor { world.connectionCount >= 2 && world.connections.last?.isClosed == true }
        h.service.trash(target)
        expect("I4 offline delete still hides the row at once", !h.shows(2))
        let reverted = await waitFor(10) { h.service.notices.count == 1 && h.service.messages == before }
        expect("I4 offline delete: the row comes back with one notice within 10 s", reverted)
        expect("I4 offline delete: nothing was ever sent", world.count("UID MOVE") == 0)
    }

    // I6. A late store for an account whose cache was purged (removed account) does not bring its files back.
    do {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cala-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = MailBodyCache(directory: root)
        let key = MailBodyKey(account: "gone@example.test", validity: 7, uid: 1)
        let kept = MailBodyKey(account: "kept@example.test", validity: 7, uid: 1)
        cache.store(MailContent(html: nil, text: "a"), for: key)
        cache.store(MailContent(html: nil, text: "b"), for: kept)
        cache.purge(account: key.account)
        cache.store(MailContent(html: nil, text: "late"), for: key)   // an in-flight write that lands after the removal
        let accountFolder = cache.fileURL(for: key)!.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        expect("I6 a store after purge(account:) does not recreate the removed account's files",
                         !FileManager.default.fileExists(atPath: accountFolder.path) && MailBodyCache(directory: root).content(for: key) == nil)
        expect("I6 purge(account:) leaves other accounts' bodies", MailBodyCache(directory: root).content(for: kept)?.content.text == "b")
    }

    // M3. read -> unread -> read with the first STORE in flight: the last tap wins, on screen and on the server.
    do {
        let world = FakeIMAPWorld(uids: base)
        let h = try MailHarness(world: world)
        defer { h.finish() }
        guard await h.start(rows: 3), let row = h.row(2), let other = h.row(1) else { expect("M3 harness synced", false); return }
        world.on("UID STORE", .hold)
        h.service.markRead(row)
        _ = await waitFor { world.heldCount == 1 }
        h.service.markUnread(row)
        h.service.markRead(row)
        let shownAfterTaps = h.row(2)?.unread
        world.release()
        _ = await h.settle { world.heldCount == 0 }
        _ = await waitFor(0.3) { false }
        _ = await h.settle()
        expect("M3 read, unread, read (first in flight): the list shows read right after the last tap",
                         shownAfterTaps == false)
        expect("M3 read, unread, read (first in flight): the server ends read, matching the last tap",
                         world.locked { world.messages.first { $0.uid == 2 }?.unread == false } && h.row(2)?.unread == false)

        world.on("UID STORE", .hold)
        h.service.markUnread(other)
        _ = await waitFor { world.heldCount == 1 }
        h.service.markRead(other)
        h.service.markUnread(other)
        let otherShown = h.row(1)?.unread
        world.release()
        _ = await h.settle { world.heldCount == 0 }
        _ = await waitFor(0.3) { false }
        _ = await h.settle()
        expect("M3 unread, read, unread (first in flight): shown unread at once and the server ends unread",
               otherShown == true && world.locked { world.messages.first { $0.uid == 1 }?.unread == true } && h.row(1)?.unread == true)
    }
}

// MARK: Follow-up on the fixes: offline grace, half-done UIDPLUS moves (M2), lost-MOVE verification (I5)

@MainActor
func checkFixFollowUps() async throws {
    let base: [(UInt32, Bool)] = [(1, false), (2, true), (3, true)]
    func says(_ notice: MailNotice?, _ english: String, _ spanish: String) -> Bool {
        guard let text = notice?.text.lowercased() else { return false }
        return text.contains(english) || text.contains(spanish)
    }

    // (a) I4 offline grace: a delete queued while the reconnect hangs (no failure to react to) reverts after the grace.
    expect("I4 the default offline grace is 30 s", MailService.offlineGrace == .seconds(30))
    do {
        let saved = MailService.offlineGrace
        MailService.offlineGrace = .milliseconds(400)
        defer { MailService.offlineGrace = saved }
        let world = FakeIMAPWorld(uids: base)
        let h = try MailHarness(world: world)
        defer { h.finish() }
        guard await h.start(rows: 3), let target = h.row(2) else { expect("I4 grace: harness synced", false); return }
        let before = h.service.messages
        world.on("DONE", .drop)
        world.on("LOGIN", .hold)                     // the reconnect's sign-in hangs: no error, no live connection
        h.service.refresh()
        _ = await waitFor { world.connectionCount == 2 && world.heldCount == 1 }
        h.service.trash(target)
        let hidden = !h.shows(2)
        let started = ContinuousClock.now
        let reverted = await waitFor(3) { h.service.notices.count == 1 && h.service.messages == before }
        let elapsed = started.duration(to: .now)
        expect("I4 grace: with the sign-in hanging, the delete hides the row, then reverts with one notice after the grace (not before)",
               hidden && reverted && elapsed >= .milliseconds(350) && elapsed < .seconds(3))
        expect("I4 grace: the notice says there was no connection, not that the server refused or might have moved it",
               !says(h.service.notices.first, "check the inbox", "revisa recibidos")
                   && h.service.notices.first?.text.contains(MailFailure.rejected.localizedDescription) == false)
        world.release()                              // the sign-in completes after all
        _ = await h.settle { h.service.messages.count == 3 }
        _ = await waitFor(0.3) { false }
        expect("I4 grace: the dropped delete never runs later behind the person's back",
               world.count("UID MOVE") == 0 && h.shows(2) && h.service.notices.count == 1)
    }

    // (b) M2: UIDPLUS move that stops half way.
    do {
        let world = FakeIMAPWorld(uids: base)
        world.mutate { $0.capabilities = "IDLE UIDPLUS" }
        let h = try MailHarness(world: world)
        defer { h.finish() }
        guard await h.start(rows: 3), let target = h.row(2) else { expect("M2: harness synced", false); return }
        let before = h.service.messages
        world.on("UID EXPUNGE", .reply("§ NO [CANNOT] expunge refused"))
        h.service.trash(target)
        _ = await h.settle { h.service.notices.count == 1 && world.count(#"UID STORE 2 -FLAGS.SILENT (\Deleted)"#) == 1 }
        _ = await h.settle()
        let log = world.log
        let copy = log.firstIndex { $0.command.hasPrefix("UID COPY 2 ") && $0.status == "OK" }
        let expunge = log.firstIndex { $0.command == "UID EXPUNGE 2" }
        let repair = log.firstIndex { $0.command == #"UID STORE 2 -FLAGS.SILENT (\Deleted)"# }
        expect("M2 COPY OK + STORE OK + EXPUNGE NO: a -FLAGS \\Deleted repair is sent once, for the same UID, after the refused EXPUNGE",
               copy != nil && expunge != nil && repair != nil && expunge! < repair! && world.count("UID STORE 2 -FLAGS") == 1)
        let span = copy.flatMap { first in repair.map { first <= $0 ? Array(log[first...$0]) : [] } } ?? []
        expect("M2 repair is sent in the same UIDVALIDITY epoch as the move (same connection, no re-SELECT in between)",
               !span.isEmpty && Set(span.map(\.connection)).count == 1 && !span.contains { $0.command.hasPrefix("SELECT") }
                   && world.locked { world.validity } == 7)
        expect("M2 EXPUNGE refused: the original keeps no \\Deleted flag, the row is back, and nothing else was expunged",
               world.locked { world.messages.first { $0.uid == 2 }.map { !$0.deleted } == true } && h.service.messages == before
                   && wireIsSafe(log.map { ($0.command, $0.status) }) && !world.commands.contains("EXPUNGE"))
        expect("M2 EXPUNGE refused: one notice saying a copy went to the trash",
               h.service.notices.count == 1 && says(h.service.notices.first, "cop", "cop")
                   && says(h.service.notices.first, "trash", "papelera"))
    }
    do {
        let world = FakeIMAPWorld(uids: base)
        world.mutate { $0.capabilities = "IDLE UIDPLUS" }
        let h = try MailHarness(world: world)
        defer { h.finish() }
        guard await h.start(rows: 3), let target = h.row(2) else { expect("M2b: harness synced", false); return }
        let before = h.service.messages
        world.on(#"UID STORE 2 +FLAGS.SILENT (\Deleted)"#, .reply("§ NO [CANNOT] store refused"))
        h.service.trash(target)
        _ = await h.settle { h.service.notices.count == 1 }
        _ = await waitFor(0.3) { false }
        _ = await h.settle()
        expect("M2 COPY OK + STORE NO: no repair and no EXPUNGE are sent",
               world.count("UID STORE 2 -FLAGS") == 0 && world.count("UID EXPUNGE") == 0 && world.count("UID COPY 2 ") == 1)
        expect("M2 COPY OK + STORE NO: the row is back with the same 'a copy went to the trash' notice",
               h.service.messages == before && h.service.notices.count == 1
                   && says(h.service.notices.first, "cop", "cop") && says(h.service.notices.first, "trash", "papelera"))
    }

    // (c) I5: after a MOVE whose answer was lost, Cala asks the server with UID FETCH <uid> (UID).
    func lostMove(_ action: FakeIMAPWorld.Action, verify: FakeIMAPWorld.Action?) async throws
        -> (h: MailHarness, world: FakeIMAPWorld, before: [MailMessage])? {
        let world = FakeIMAPWorld(uids: base)
        let h = try MailHarness(world: world)
        guard await h.start(rows: 3), let target = h.row(2) else { h.finish(); return nil }
        let before = h.service.messages
        world.on("UID MOVE", action)
        if let verify { world.on("UID FETCH 2 (UID)", verify) }
        h.record()
        h.service.trash(target)
        _ = await h.settle { world.connectionCount >= 2 && world.count("UID FETCH 2 (UID)") >= 1 }
        _ = await waitFor(0.3) { false }
        _ = await h.settle()
        return (h, world, before)
    }
    if let gone = try await lostMove(.applyThenDrop, verify: nil) {
        defer { gone.h.finish() }
        let checks = gone.world.log.filter { $0.command == "UID FETCH 2 (UID)" }
        expect("I5 lost MOVE, message gone: verified once with UID FETCH 2 (UID) on the new connection",
               checks.count == 1 && checks.first?.connection == 2 && gone.world.count("UID MOVE") == 1)
        expect("I5 lost MOVE, message gone: stays hidden in every publish, no notice, MOVE not resent",
               gone.h.published.allSatisfy { !$0.contains { $0.uid == 2 } } && gone.h.service.notices.isEmpty && !gone.h.shows(2))
    } else { expect("I5 gone: harness synced", false) }
    if let present = try await lostMove(.drop, verify: nil) {
        defer { present.h.finish() }
        expect("I5 lost MOVE, message still there: the row comes back unchanged with one notice, MOVE not resent",
               present.h.service.messages == present.before && present.h.service.notices.count == 1
                   && present.world.count("UID MOVE") == 1 && present.world.count("UID FETCH 2 (UID)") == 1)
        expect("I5 lost MOVE, message still there: the notice says it was not moved (no 'check the inbox' uncertainty)",
               !says(present.h.service.notices.first, "check the inbox", "revisa recibidos"))
    } else { expect("I5 present: harness synced", false) }
    if let failed = try await lostMove(.drop, verify: .reply("§ NO [UNAVAILABLE] try later")) {
        defer { failed.h.finish() }
        _ = await failed.h.settle { failed.h.service.notices.count >= 1 }
        expect("I5 lost MOVE, the check itself fails: the row comes back with one 'check the inbox' notice, MOVE not resent",
               failed.h.service.messages.contains { $0.uid == 2 } && failed.h.service.notices.count == 1
                   && says(failed.h.service.notices.first, "check the inbox", "revisa recibidos") && failed.world.count("UID MOVE") == 1)
    } else { expect("I5 verification failure: harness synced", false) }
}

// MARK: Entry point

@MainActor
func runFastMailChecks() async {
    failureHook = { debugDump($0) }
    checkOverlayTable()
    checkPlanners()
    do { try checkBodyCache() } catch { expect("C body cache checks ran (\(error))", false) }
    checkBodyStructure()
    do { try await checkFastWire() } catch { expect("E .fast wire checks ran (\(error))", false) }
    do { try await checkOptimisticActions() } catch { expect("A optimistic action checks ran (\(error))", false) }
    do { try await checkDeadLink() } catch { expect("F dead link check ran (\(error))", false) }
    do { try await checkDeadLinkReconnect() } catch { expect("F dead link reconnect check ran (\(error))", false) }
    do { try await checkReviewFindings() } catch { expect("Review finding checks ran (\(error))", false) }
    do { try await checkFixFollowUps() } catch { expect("Fix follow-up checks ran (\(error))", false) }
    await runFeatureChecks()
}

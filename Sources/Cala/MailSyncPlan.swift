import Foundation

/// Connection timing for the mail link. Gmail silently drops idle connections well before the 29-minute IDLE limit:
/// the debug log showed IDLE cycles ending in a timeout ~25 min after the last sync. These keep the link warm and,
/// when it dies anyway, notice within seconds instead of on the next action.
enum MailLink {
    /// TCP keepalive: first probe after this many idle seconds, then every `keepaliveInterval`, giving up after `keepaliveCount`.
    static let keepaliveIdle = 60
    static let keepaliveInterval = 10
    static let keepaliveCount = 3
    /// IDLE is ended and re-armed after this long without news.
    static let idleRearm = 9 * 60
    /// How long the server may take to acknowledge DONE before the link counts as dead.
    static let doneAckTimeout = 3
    /// Ordinary command timeout.
    static let commandTimeout = 15
    /// Without IDLE: how often the inbox is polled.
    static let pollInterval = 120
    /// A sync runs at least this often even when IDLE reports nothing.
    static let periodicSync = 15 * 60
    /// Rows the list snapshot keeps.
    static let window = 25
}

/// Messages already read from the server for one account, by UIDVALIDITY and UID, so a sync only downloads headers and
/// previews of messages it has not seen.
struct MailKnownMessages: Equatable {
    static let capacity = 200

    let validity: UInt32
    private(set) var messages: [UInt32: MailMessage] = [:]

    init(validity: UInt32, messages: [MailMessage] = []) {
        self.validity = validity
        merge(messages)
    }

    /// Adds or replaces rows of this epoch (others are ignored), keeping the newest `capacity` UIDs.
    mutating func merge(_ rows: [MailMessage]) {
        for row in rows where row.uidValidity == validity && row.uid > 0 { messages[row.uid] = row }
        guard messages.count > Self.capacity else { return }
        for uid in messages.keys.sorted().prefix(messages.count - Self.capacity) { messages[uid] = nil }
    }

    func message(_ uid: UInt32) -> MailMessage? { messages[uid] }
}

enum MailSyncPlanner {
    struct Plan: Equatable {
        /// UIDs in the window whose header and preview are already known.
        var known: [UInt32]
        /// UIDs whose header and preview must be fetched.
        var missing: [UInt32]
    }

    /// Sequence range of the newest `size` messages, or nil for an empty mailbox.
    static func window(exists: Int, size: Int = MailLink.window) -> ClosedRange<Int>? {
        guard exists > 0 else { return nil }
        return max(1, exists - size + 1)...exists
    }

    /// `window`: the UIDs a `FETCH n:* (UID FLAGS)` returned. A different UIDVALIDITY means nothing is known.
    static func plan(window: [UInt32], known: MailKnownMessages?, validity: UInt32) -> Plan {
        var plan = Plan(known: [], missing: [])
        var seen: Set<UInt32> = []
        for uid in window.sorted(by: >) where uid > 0 && seen.insert(uid).inserted {
            if known?.validity == validity, known?.message(uid) != nil { plan.known.append(uid) } else { plan.missing.append(uid) }
        }
        return plan
    }

    /// Compact UID set: "3:5,9,12:13" (ascending, duplicates removed).
    static func uidSet(_ uids: [UInt32]) -> String {
        let sorted = Array(Set(uids)).sorted()
        var parts: [String] = []
        var index = 0
        while index < sorted.count {
            var end = index
            while end + 1 < sorted.count, sorted[end + 1] == sorted[end] + 1 { end += 1 }
            parts.append(end == index ? "\(sorted[index])" : "\(sorted[index]):\(sorted[end])")
            index = end + 1
        }
        return parts.joined(separator: ",")
    }
}

/// Which bodies to download ahead of time after a sync.
enum MailPrefetchPlanner {
    static let rows = 8
    static let maxPart = 1024 * 1024
    static let budget = 4 * 1024 * 1024

    /// The first `rows` visible rows that are not cached yet, unread ones first (stable otherwise).
    static func candidates(visible: [MailMessage], isCached: (MailMessage) -> Bool, rows: Int = rows) -> [MailMessage] {
        let top = visible.prefix(rows).filter { !isCached($0) && $0.uidValidity != nil && $0.uid > 0 }
        return top.filter(\.unread) + top.filter { !$0.unread }
    }

    /// Keeps candidates (in order) whose planned bytes are known, no single part is over `maxPart`, and the running total
    /// stays within `budget`. `sizes`: uid -> (planned bytes, largest part), nil when the message would be fetched whole.
    static func select(_ candidates: [MailMessage], sizes: [UInt32: (bytes: Int, largest: Int)],
                       maxPart: Int = maxPart, budget: Int = budget) -> [MailMessage] {
        var total = 0
        var chosen: [MailMessage] = []
        for message in candidates {
            guard let size = sizes[message.uid], size.largest <= maxPart, total + size.bytes <= budget else { continue }
            total += size.bytes
            chosen.append(message)
        }
        return chosen
    }
}

/// What is waiting in an account's queue, readable from the connection's (non-main) context so a sync or prefetch can
/// step aside between two commands.
final class MailQueueSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var content = 0
    private var actions = 0

    func update(content: Int, actions: Int) { lock.withLock { self.content = content; self.actions = actions } }
    var contentWaiting: Bool { lock.withLock { content > 0 } }
    var anyWaiting: Bool { lock.withLock { content + actions > 0 } }
}

/// Paging into older mail (pure): which UIDs the next "load older" fetches.
enum MailOlderPager {
    /// The `size` highest UIDs below `below` from `candidates` (newest first), and the ones left for later pages.
    static func page(candidates: [UInt32], below: UInt32, above: UInt32 = 0, size: Int) -> (page: [UInt32], rest: [UInt32]) {
        let older = Array(Set(candidates.filter { $0 > above && $0 < below })).sorted(by: >)
        return (Array(older.prefix(max(0, size))), Array(older.dropFirst(max(0, size))))
    }
}

/// A cancel button's state, read from the connection's context while a download runs.
final class MailCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.withLock { cancelled = true } }
    var isCancelled: Bool { lock.withLock { cancelled } }
}

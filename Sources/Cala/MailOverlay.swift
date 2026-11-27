import Foundation

/// Optimistic inbox overlay: what the list shows is the last server snapshot with the person's pending actions applied
/// on top. The snapshot itself is never edited, so a failed action is undone by dropping its entry and the exact
/// original row comes back.
///
/// Reconciliation: every sync gets a sequence number when it STARTS. When the server confirms an action, its entry
/// becomes `.confirmed(afterSync: n)` with n = the latest sync started so far. That entry keeps applying to every
/// snapshot from syncs up to n (they may have read the mailbox before the server's OK, and would otherwise bring a
/// deleted row back) and is dropped once a snapshot from a sync numbered above n is applied.
///
/// Effects are idempotent against the row they find: hiding a row that is gone, or marking read a row that is already
/// read, changes nothing, so a snapshot that already reflects an action is never counted twice.
struct MailOverlay: Equatable {
    enum Effect: Equatable {
        case hide(messageID: String)
        case read(messageID: String)
        case unread(messageID: String)
        case readAll
        /// Mark all as read up to the newest UID the person saw: rows above it (mail that arrived later) keep their state.
        case readAllThrough(uid: UInt32)
        /// A bulk action on selected rows (one entry, so the whole set confirms or reverts together; see `update`).
        case hideMany(messageIDs: [String])
        case readMany(messageIDs: [String])
        case unreadMany(messageIDs: [String])

        var messageID: String? {
            switch self {
            case let .hide(id), let .read(id), let .unread(id): id
            case .readAll, .readAllThrough, .hideMany, .readMany, .unreadMany: nil
            }
        }

        /// Every message the effect names (one for single effects, none for the mark-all ones).
        var messageIDs: [String] {
            switch self {
            case let .hide(id), let .read(id), let .unread(id): [id]
            case let .hideMany(ids), let .readMany(ids), let .unreadMany(ids): ids
            case .readAll, .readAllThrough: []
            }
        }
    }

    enum State: Equatable {
        /// Waiting in the account's queue: shown.
        case queued
        /// Sent, no answer yet: shown.
        case inFlight
        /// The answer was lost with the connection and the command (safe to repeat) will be sent again after
        /// reconnecting: not shown until it is sent again.
        case held
        /// The server said OK while sync number `afterSync` was the latest one started: shown until a later sync applies.
        case confirmed(afterSync: Int)
    }

    struct Entry: Equatable, Identifiable {
        let id: Int
        let effect: Effect
        var state: State
    }

    struct Result: Equatable {
        var messages: [MailMessage]
        var unread: Int
    }

    private(set) var entries: [Entry] = []

    var isEmpty: Bool { entries.isEmpty }

    mutating func add(_ effect: Effect, id: Int, state: State = .queued) {
        entries.removeAll { $0.id == id }
        entries.append(Entry(id: id, effect: effect, state: state))
    }

    mutating func set(_ state: State, for id: Int) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].state = state
    }

    /// The server confirmed entry `id`; `latestStartedSync` is the number of the newest sync that has started.
    mutating func confirm(_ id: Int, latestStartedSync: Int) {
        set(.confirmed(afterSync: latestStartedSync), for: id)
    }

    @discardableResult
    mutating func remove(_ id: Int) -> Entry? {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
        return entries.remove(at: index)
    }

    /// Replaces what entry `id` does, keeping its place and state (a bulk action that only partly happened).
    mutating func update(_ id: Int, effect: Effect) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index] = Entry(id: id, effect: effect, state: entries[index].state)
    }

    /// A snapshot from sync `appliedSync` was applied: confirmed entries from before it started are now in the snapshot.
    /// Returns the entries it dropped (rows kept outside the snapshot, such as older pages, apply them for good).
    @discardableResult
    mutating func prune(appliedSync: Int) -> [Entry] {
        var dropped: [Entry] = []
        entries.removeAll {
            if case let .confirmed(afterSync) = $0.state, afterSync < appliedSync { dropped.append($0); return true }
            return false
        }
        return dropped
    }

    func apply(to snapshot: MailInboxSnapshot) -> Result { Self.apply(snapshot, entries) }

    /// Pure: the rows and unread count the list shows for `snapshot` with `entries` applied in order.
    static func apply(_ snapshot: MailInboxSnapshot, _ entries: [Entry]) -> Result {
        var rows = snapshot.messages
        var unread = snapshot.unread
        for entry in entries where entry.state != .held {
            switch entry.effect {
            case let .hide(id):
                guard let index = rows.firstIndex(where: { $0.id == id }) else { continue }
                if rows.remove(at: index).unread { unread -= 1 }
            case let .read(id):
                guard let index = rows.firstIndex(where: { $0.id == id }), rows[index].unread else { continue }
                rows[index].unread = false
                unread -= 1
            case let .unread(id):
                guard let index = rows.firstIndex(where: { $0.id == id }), !rows[index].unread else { continue }
                rows[index].unread = true
                unread += 1
            case .readAll:
                for index in rows.indices { rows[index].unread = false }
                unread = 0
            case let .readAllThrough(uid):
                // Everything unseen outside the window is older than the window, so only newer rows can stay unread.
                for index in rows.indices where rows[index].uid <= uid { rows[index].unread = false }
                unread = rows.filter(\.unread).count
            case let .hideMany(ids):
                let set = Set(ids)
                unread -= rows.filter { set.contains($0.id) && $0.unread }.count
                rows.removeAll { set.contains($0.id) }
            case let .readMany(ids):
                let set = Set(ids)
                for index in rows.indices where set.contains(rows[index].id) && rows[index].unread {
                    rows[index].unread = false
                    unread -= 1
                }
            case let .unreadMany(ids):
                let set = Set(ids)
                for index in rows.indices where set.contains(rows[index].id) && !rows[index].unread {
                    rows[index].unread = true
                    unread += 1
                }
            }
        }
        return Result(messages: rows, unread: max(0, unread))
    }
}

extension MailOverlay.Effect {
    /// Makes a confirmed effect permanent on rows kept outside any snapshot (older pages). Pure.
    func applied(to rows: [MailMessage]) -> [MailMessage] {
        var rows = rows
        switch self {
        case let .hide(id): rows.removeAll { $0.id == id }
        case let .hideMany(ids): let set = Set(ids); rows.removeAll { set.contains($0.id) }
        case let .read(id): for i in rows.indices where rows[i].id == id { rows[i].unread = false }
        case let .readMany(ids): let set = Set(ids); for i in rows.indices where set.contains(rows[i].id) { rows[i].unread = false }
        case let .unread(id): for i in rows.indices where rows[i].id == id { rows[i].unread = true }
        case let .unreadMany(ids): let set = Set(ids); for i in rows.indices where set.contains(rows[i].id) { rows[i].unread = true }
        case .readAll: for i in rows.indices { rows[i].unread = false }
        case let .readAllThrough(uid): for i in rows.indices where rows[i].uid <= uid { rows[i].unread = false }
        }
        return rows
    }
}

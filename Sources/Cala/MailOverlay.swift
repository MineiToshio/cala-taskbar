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

        var messageID: String? {
            switch self {
            case let .hide(id), let .read(id), let .unread(id): id
            case .readAll: nil
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

    /// A snapshot from sync `appliedSync` was applied: confirmed entries from before it started are now in the snapshot.
    mutating func prune(appliedSync: Int) {
        entries.removeAll {
            if case let .confirmed(afterSync) = $0.state { return afterSync < appliedSync }
            return false
        }
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
            }
        }
        return Result(messages: rows, unread: max(0, unread))
    }
}

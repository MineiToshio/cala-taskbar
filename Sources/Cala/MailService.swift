import AppKit
import Combine
import Foundation
import Security
import os

/// Latency instrumentation for the mail module: log lines only (prefix "mail-timing"), never credentials, addresses,
/// subjects or bodies. Durations are monotonic milliseconds; `op=` ties the lines of one operation together.
enum MailTiming {
    private static let counters = OSAllocatedUnfairLock(initialState: (ids: 0, webViews: 0))

    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    static func ms(since start: UInt64) -> Int { Int((now() &- start) / 1_000_000) }
    static func ms(from start: UInt64, to end: UInt64) -> Int { Int((end &- start) / 1_000_000) }
    static func nextID() -> Int { counters.withLock { $0.ids += 1; return $0.ids } }
    /// True only for the first web view created in this process.
    static func claimFirstWebView() -> Bool { counters.withLock { $0.webViews += 1; return $0.webViews == 1 } }
    static func line(_ text: String) { log("mail-timing " + text) }

    /// Operation identity carried through the queue.
    struct Op {
        let id: Int
        let kind: String
        let tapped: UInt64
        var enqueued: UInt64 = 0
    }

    /// The command verb only (never arguments such as mailbox names or credentials).
    static func verb(_ command: String) -> String {
        let words = command.split(separator: " ", maxSplits: 2).map(String.init)
        guard let first = words.first?.uppercased() else { return "?" }
        let name = first == "UID" && words.count > 1 ? "UID " + words[1].uppercased() : first
        guard name.hasSuffix("FETCH") else { return name }
        if command.contains("RFC822.SIZE") && command.contains("BODYSTRUCTURE") { return name + " RFC822.SIZE+BODYSTRUCTURE" }
        if command.contains("BODYSTRUCTURE") { return name + " BODYSTRUCTURE" }
        if command.contains(".MIME]") { return name + " PARTS" }
        if command.hasSuffix("(UID FLAGS)") { return name + " FLAGS" }
        if command.contains("RFC822.SIZE") { return name + " RFC822.SIZE" }
        if command.contains("HEADER.FIELDS") { return name + " HEADER+TEXT" }
        if command.contains("BODY.PEEK[]") { return name + " BODY.PEEK[]" }
        if command.contains("BODY.PEEK[TEXT]") { return name + " BODY.PEEK[TEXT]" }
        if command.contains("BODY.PEEK[") { return name + " PART-PREVIEW" }
        return name
    }

    static func describe(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let error = error as? MailIMAPError { return "\(error)" }
        if let error = error as? MailFailure { return error.logCode }
        return "other"
    }
}

enum MailAccountStatus: Equatable {
    case connecting, connected, paused
    case authFailed(String)
    case blocked(String)
    case offline(String)
    case operationFailed(String)
}

/// What the flyout's inbox area shows when it has no rows to list. Keeping it here (not in the view) lets the checks pin
/// down that "still waiting / still loading" is never mistaken for "the inbox is empty".
enum MailInboxPhase: Equatable {
    case noAccounts, waitingForKeychainNotice, paused, loading, problem, empty, messages

    /// `synced` holds the accounts that completed at least one inbox sync since sync started.
    static func of(accounts: [String], status: [String: MailAccountStatus], synced: Set<String>,
                   hasMessages: Bool, awaitingKeychainNotice: Bool) -> Self {
        guard !accounts.isEmpty else { return .noAccounts }
        if hasMessages { return .messages }
        if accounts.contains(where: { status[$0]?.problem != nil }) { return .problem }
        if awaitingKeychainNotice { return .waitingForKeychainNotice }
        if accounts.allSatisfy(synced.contains) { return .empty }
        if accounts.contains(where: { status[$0] == .paused || status[$0] == nil }) { return .paused }
        return .loading
    }
}

extension MailAccountStatus {
    var problem: String? {
        switch self {
        case let .authFailed(message), let .blocked(message), let .offline(message), let .operationFailed(message): message
        default: nil
        }
    }
}

struct MailMessage: Identifiable, Equatable {
    let id: String
    let accountID: String
    let uid: UInt32
    let fromName: String
    let fromAddress: String
    let subject: String
    let snippet: String
    let date: Date
    var unread: Bool
    let gmailThreadID: UInt64?
    let gmailMessageID: UInt64?
    var uidValidity: UInt32? = nil
}

/// A dismissible message about an action the server did not carry out (the list already shows the row again).
struct MailNotice: Identifiable, Equatable {
    let id: Int
    let accountID: String
    let text: String
}

/// Which accounts already have their password in the helper's own Keychain item (see MailCredentialStore). One
/// UserDefaults key per account holds the helper identity (its cdhash) that made that item; it is written only after
/// the item was written or read back, so a missing or different value means macOS may still show its windows for that
/// account: up to two (one for the old item's access list, one for its partition) the first time.
struct MailKeychainGate {
    static let keyPrefix = "mailKeychainMigrated."
    let identity: String
    let defaults: UserDefaults
    /// Reads a Keychain item's access list (never its password; see MailKeychainAccess). nil: no prediction, every
    /// account not moved yet is announced as two windows.
    let inspect: ((String) -> MailItemAccess?)?

    init(identity: String = MailKeychain.helperIdentity ?? "helper-unknown", defaults: UserDefaults = .standard,
         inspect: ((String) -> MailItemAccess?)? = nil) {
        self.identity = identity
        self.defaults = defaults
        self.inspect = inspect
    }

    static func live() -> MailKeychainGate {
        let hashes = MailKeychainAccess.helperCDHashes()
        return MailKeychainGate(inspect: { MailKeychainAccess.inspect(account: $0, helperCDHashes: hashes) })
    }

    func isMigrated(_ id: String) -> Bool { defaults.string(forKey: Self.keyPrefix + id) == identity }
    func markMigrated(_ id: String) { if !isMigrated(id) { defaults.set(identity, forKey: Self.keyPrefix + id) } }
    func clearMigrated(_ id: String) { defaults.removeObject(forKey: Self.keyPrefix + id) }

    /// How many macOS windows to announce before reading `ids`: up to two per account not moved yet.
    func expectedPrompts(for ids: [String]) -> Int { 2 * ids.filter { !isMigrated($0) }.count }

    /// Windows one item will make macOS show: one for an access list that does not trust the helper, one for a
    /// partition list without it. nil: cannot tell (part unknown and nothing known to be missing).
    static func windows(for access: MailItemAccess) -> Int? {
        let parts = [access.aclTrustsHelper, access.partitionTrustsHelper]
        if parts.allSatisfy({ $0 == true }) { return 0 }
        if parts.contains(false) { return parts.filter { $0 != true }.count }
        return nil
    }

    /// Windows reading this account will show (pure, pinned by the checks). `own` and `old` are the helper's item
    /// and the pre-helper item; nil when they could not be inspected. nil result: unknown.
    static func expectedWindows(migrated: Bool, own: MailItemAccess?, old: MailItemAccess?) -> Int? {
        if migrated { return 0 }
        guard let own else { return nil }
        if own.exists { return windows(for: own) }   // the read uses the helper's item
        guard let old else { return nil }
        return old.exists ? windows(for: old) : 0
    }

    /// What to do before sync: `windows` to announce now (blocking explanation) and accounts whose first read is
    /// watched instead (the explanation appears only if that read is still waiting after a second: a window is up).
    struct Plan: Equatable { var windows: Int; var watch: [String] }

    func plan(for ids: [String]) -> Plan {
        var plan = Plan(windows: 0, watch: [])
        for id in ids where !isMigrated(id) {
            guard let inspect else { plan.windows += 2; continue }
            let own = inspect(MailCredentialStore.ownAccount(id))
            let old = own?.exists == false ? inspect(id) : nil
            switch Self.expectedWindows(migrated: false, own: own, old: old) {
            case let n? where n > 0: plan.windows += n
            default: plan.watch.append(id) // predicted silent, or unknown: watch the read as a backstop
            }
        }
        return plan
    }
}

/// Where an account's app password lives. Items saved before the Keychain helper (account = the email) trust only the
/// old Cala build that made them, and the helper can neither delete them (errSecInvalidOwnerEdit) nor change who they
/// trust. So the helper keeps its own item per account (account "v2:<email>", same service) and reads only that once
/// it exists. The old item is read at most until the copy succeeds and is never deleted (macOS refuses), so a failed
/// copy can never lose the password.
struct MailCredentialStore: @unchecked Sendable {
    /// Result of reading the helper's own item.
    enum OwnItem: Equatable { case found, missing, denied, broken, refused }
    /// What happens next (pure, pinned by the checks).
    enum Next: Equatable { case use, readOldThenCopy, readOldOnly, forgetAndExplain, fail }

    /// `migrated`: this account's password was already copied into the helper's item (MailKeychainGate). Once it was,
    /// the old item is never read again.
    static func next(after own: OwnItem, migrated: Bool) -> Next {
        switch own {
        case .found: return .use
        case .missing: return migrated ? .forgetAndExplain : .readOldThenCopy // the copy vanished: explain first
        case .denied, .refused: return .fail       // the person said no, or the helper refused this Cala (77/78)
        case .broken: return migrated ? .fail : .readOldOnly // keep mail working from the old item, copy nothing
        }
    }

    static let reservedPrefix = "v2:"
    static func ownAccount(_ id: String) -> String { reservedPrefix + id }
    /// Account ids that would collide with the helper's own items.
    static func isReserved(_ id: String) -> Bool { id.lowercased().hasPrefix(reservedPrefix) }

    /// Per-account generation, bumped by every write: a copy captured before a write (or removal) must not land after
    /// it. `state` also makes "compare, then copy" atomic with respect to writes.
    final class Generations: @unchecked Sendable {
        private var values: [String: UInt64] = [:]
        let state = NSLock()
        /// One account's old-item read and copy at a time, so macOS windows for several accounts do not stack.
        let migration = NSLock()
        func current(_ id: String) -> UInt64 { state.lock(); defer { state.unlock() }; return values[id, default: 0] }
        /// Caller holds `state`.
        func bumpLocked(_ id: String) { values[id, default: 0] &+= 1 }
        func valueLocked(_ id: String) -> UInt64 { values[id, default: 0] }
    }

    let get: (String) throws -> String?
    let set: (String?, String) throws -> Void
    let gate: MailKeychainGate
    let generations: Generations
    /// Test hook: runs after the old item was read, before the copy (simulates a slow macOS dialog).
    var afterOldRead: ((String) -> Void)?

    init(get: @escaping (String) throws -> String?, set: @escaping (String?, String) throws -> Void,
         gate: MailKeychainGate, generations: Generations = Generations(), afterOldRead: ((String) -> Void)? = nil) {
        self.get = get
        self.set = set
        self.gate = gate
        self.generations = generations
        self.afterOldRead = afterOldRead
    }

    static func live() -> MailCredentialStore {
        MailCredentialStore(get: { try MailKeychain.password(for: $0) }, set: { try MailKeychain.set($0, for: $1) },
                            gate: MailKeychainGate.live())
    }

    func read(_ id: String) throws -> String? {
        // Before anything else: a write that lands while this read waits (for the helper or for another account's
        // migration) must make the copy below stale.
        let generation = generations.current(id)
        var own: OwnItem
        var value: String?
        var failure: Error?
        do {
            value = try get(Self.ownAccount(id))
            own = value == nil ? .missing : .found
        } catch let error as MailFailure where error == .keychainRestart || error == .updateRestart || error == .keychainUnverified {
            own = .refused
            failure = error
        } catch let error as MailFailure where error == .keychainDenied {
            own = .denied
            failure = error
        } catch {
            own = .broken
            failure = error
        }
        let next = Self.next(after: own, migrated: gate.isMigrated(id))
        switch next {
        case .use:
            gate.markMigrated(id)
            return value
        case .fail:
            throw failure ?? MailFailure.keychain
        case .forgetAndExplain:
            log("mail: the helper's own Keychain item is gone; explaining before reading the old one")
            gate.clearMigrated(id)
            throw MailFailure.keychainNeedsNotice
        case .readOldOnly:
            log("mail: the helper's own Keychain item could not be read (\(MailFailure.from(failure ?? MailFailure.keychain).logCode)); using the old one")
            return try get(id)
        case .readOldThenCopy:
            generations.migration.lock()
            defer { generations.migration.unlock() }
            // Settings saved or removed this account while we waited, or sync was cancelled: the helper's own item is
            // now the answer, without touching (or asking about) the old one.
            if generations.current(id) != generation || Task.isCancelled { return try get(Self.ownAccount(id)) }
            guard let old = try get(id) else { return nil }
            afterOldRead?(id)
            generations.state.lock()
            defer { generations.state.unlock() }
            // Settings wrote or removed this account while macOS was asking: its value wins, copy nothing.
            guard generations.valueLocked(id) == generation else {
                log("mail: app password changed while copying; keeping the newer one")
                return old
            }
            do {
                try set(old, Self.ownAccount(id))
                gate.markMigrated(id)
                log("mail: app password copied into the helper's own Keychain item")
            } catch {
                log("mail: copying the app password into the helper's item failed (\(MailFailure.from(error).logCode)); will retry")
            }
            return old
        }
    }

    /// The helper's own item only, for rollback in Settings: never touches (or prompts for) the old item.
    func readOwn(_ id: String) throws -> String? { try get(Self.ownAccount(id)) }

    /// New and changed passwords go to the helper's own item only; removing deletes that item (the old one stays).
    func write(_ password: String?, _ id: String) throws {
        generations.state.lock()
        defer { generations.state.unlock() }
        generations.bumpLocked(id)
        try set(password, Self.ownAccount(id))
        if password != nil { gate.markMigrated(id) } else { gate.clearMigrated(id) }
    }
}

@MainActor
final class MailService: ObservableObject {
    static let shared = MailService()

    @Published private(set) var accounts: [MailAccount]
    @Published private(set) var status: [String: MailAccountStatus]
    @Published private(set) var messages: [MailMessage] = []
    @Published private(set) var unreadCount = 0
    /// Accounts whose inbox has been read at least once since sync started (an empty list is then really empty).
    @Published private(set) var syncedAccounts: Set<String> = []
    /// True while sync waits for the person to read the Keychain explanation after an update. Nothing is fetched
    /// until then, so the flyout must say so instead of showing an empty inbox.
    @Published private(set) var awaitingKeychainNotice = false
    /// Actions the server refused or could not confirm, newest last (see dismissNotice).
    @Published private(set) var notices: [MailNotice] = []

    private enum Operation {
        case content(MailMessage)
        case markRead(MailMessage)
        case markUnread(MailMessage)
        case markAllRead
        case archive(MailMessage)
        case trash(MailMessage)

        var kind: String {
            switch self {
            case .content: "open"
            case .markRead: "mark-read"
            case .markUnread: "mark-unread"
            case .markAllRead: "mark-all-read"
            case .archive: "archive"
            case .trash: "trash"
            }
        }

        var isContent: Bool { if case .content = self { return true }; return false }
        /// Touches messages outside the snapshot: the inbox is read again before anything else is sent.
        var isBulk: Bool { if case .markAllRead = self { return true }; return false }
        /// Sending it twice leaves the server as sending it once, so a lost answer is answered by sending it again.
        /// Never true for MOVE/COPY (a second copy).
        var isRepeatable: Bool {
            switch self {
            case .content, .markRead, .markUnread, .markAllRead: true
            case .archive, .trash: false
            }
        }

        var message: MailMessage? {
            switch self {
            case let .content(message), let .markRead(message), let .markUnread(message), let .archive(message),
                 let .trash(message): message
            case .markAllRead: nil
            }
        }

        func perform(on connection: MailIMAP) async throws -> MailContent {
            switch self {
            case let .content(message): return try await connection.content(of: message)
            case let .markRead(message): try await connection.markRead(message)
            case let .markUnread(message): try await connection.markUnread(message)
            case .markAllRead: try await connection.markAllRead()
            case let .archive(message): try await connection.archive(message)
            case let .trash(message): try await connection.trash(message)
            }
            return MailContent(html: nil, text: "")
        }

        /// What the person reads when the server refused it (the row is already back).
        func refusal(_ error: MailFailure) -> String {
            let what: String
            switch self {
            case .content: return error.localizedDescription
            case .trash:
                what = tx("Couldn’t move the message to the trash, so it’s back in the list.",
                          "No se pudo mover el mensaje a la papelera, así que volvió a la lista.")
            case .archive:
                what = tx("Couldn’t archive the message, so it’s back in the list.",
                          "No se pudo archivar el mensaje, así que volvió a la lista.")
            case .markRead: what = tx("Couldn’t mark the message as read.", "No se pudo marcar el mensaje como leído.")
            case .markUnread: what = tx("Couldn’t mark the message as unread.", "No se pudo marcar el mensaje como no leído.")
            case .markAllRead:
                what = tx("Couldn’t mark all messages as read.", "No se pudieron marcar todos los mensajes como leídos.")
            }
            return what + " " + error.localizedDescription
        }

        /// The connection dropped after a move was sent: the server may or may not have done it.
        var unconfirmed: String {
            if case .archive = self {
                return tx("The connection dropped before the server confirmed the archive. Check the inbox before trying again.",
                          "Se cortó la conexión antes de que el servidor confirmara el archivado. Revisa Recibidos antes de volver a intentarlo.")
            }
            return tx("The connection dropped before the server confirmed the delete. Check the inbox before trying again.",
                      "Se cortó la conexión antes de que el servidor confirmara la eliminación. Revisa Recibidos antes de volver a intentarlo.")
        }
    }

    private struct PendingOperation {
        let id: UUID
        let operation: Operation
        let contentResult: CheckedContinuation<MailContent, Error>?
        var timing: MailTiming.Op
        /// The overlay entry that shows this action in the list before the server answers.
        var effect: Int?
        var attempts = 0
    }

    private final class AccountRun {
        var worker: Task<Void, Never>?
        var retryDelay: Task<Void, Never>?
        var connection: MailIMAP?
        /// Content first, then the person's actions in the order they were made.
        var pending: [PendingOperation] = [] {
            didSet {
                let content = pending.filter(\.operation.isContent).count
                signal.update(content: content, actions: pending.count - content)
            }
        }
        let signal = MailQueueSignal()
        var inFlight: UUID?
        /// What interrupted the connection's wait since it last looked (see wake): "operation", "refresh".
        var wakeCauses: Set<String> = []
        /// Messages prefetch already looked at and left out (too big, unknown structure): not asked about again.
        var prefetchSkipped: Set<String> = []
    }

    private struct DeferredRead {
        let message: MailMessage
        let effect: Int
    }

    private(set) var accountsLoadFailed = false
    private var running = false
    private var runs: [String: AccountRun] = [:]
    private var snapshots: [String: MailInboxSnapshot] = [:]
    private var unreadByAccount: [String: Int] = [:]
    /// Pending actions drawn over each account's snapshot (see MailOverlay).
    private var overlays: [String: MailOverlay] = [:]
    /// Number of the latest sync started per account (MailOverlay's reconciliation clock).
    private var syncStarted: [String: Int] = [:]
    /// Rows read before, per account, so syncs only download what is new.
    private var known: [String: MailKnownMessages] = [:]
    /// Opened unread messages whose STORE \Seen waits for the body (see open).
    private var deferredReads: [String: DeferredRead] = [:]
    private var nextEffect = 0
    private var nextNotice = 0
    private let bodyCache: MailBodyCache?
    /// Disk writes and purges of the body cache, in order, off the main thread.
    private let cacheQueue = DispatchQueue(label: "Cala.MailBodyCache", qos: .utility)
    private var pendingSignIns: [String: MailIMAP] = [:]
    private var wakeObserver: NSObjectProtocol?
    private var observesWake = false
    private var runID: UUID?
    /// Only the shared service tracks the build (the checks inject their own credential closures and must not touch
    /// the user's defaults).
    private var keychainGate: MailKeychainGate?
    private var keychainPresenter: ((_ prompts: Int, _ proceed: @escaping @MainActor () -> Void) -> Void)?
    private var keychainDismiss: (() -> Void)?
    /// Accounts whose first credential read shows the explanation only if it is still waiting after a second.
    private var keychainWatch: Set<String> = []
    private var watchedReads: Set<String> = []
    private var watchNoticeShown = false
    private var accountsAwaitingNotice: Set<String> = []

    private let accountsURL: URL?
    private let makeConnection: (MailProvider) -> MailIMAP
    private let readCredential: @Sendable (String) throws -> String?
    private let writeCredential: (String?, String) throws -> Void
    /// What Settings reads before changing a password, to roll back if saving the account list fails.
    private let readCurrentCredential: (String) throws -> String?

    private convenience init() {
        let store = MailCredentialStore.live()
        self.init(accountsURL: AppPaths.supportDirectory.appendingPathComponent("mail-accounts.json"),
                  makeConnection: { MailIMAP(provider: $0) }, readCredential: { try store.read($0) },
                  writeCredential: { try store.write($0, $1) }, readCurrentCredential: { try store.readOwn($0) },
                  keychainGate: store.gate, bodyCache: MailBodyCache(directory: MailBodyCache.defaultDirectory()))
        observesWake = true
    }

    static func snapshot() -> MailService {
        MailService(snapshotAccount: MailAccount(id: "demo@example.com", label: tx("Example account", "Cuenta de ejemplo"),
                                                 colorIndex: 0, enabled: true))
    }

    private init(snapshotAccount: MailAccount) {
        accountsURL = nil
        makeConnection = { _ in preconditionFailure("Mail snapshots do not connect to servers") }
        readCredential = { _ in nil }
        writeCredential = { _, _ in throw MailFailure.accountsFile }
        readCurrentCredential = { _ in nil }
        bodyCache = nil
        accounts = [snapshotAccount]
        status = [snapshotAccount.id: .paused]
    }

    init(accountsURL: URL, makeConnection: @escaping (MailProvider) -> MailIMAP,
         readCredential: @escaping @Sendable (String) throws -> String?,
         writeCredential: @escaping (String?, String) throws -> Void,
         readCurrentCredential: ((String) throws -> String?)? = nil, keychainGate: MailKeychainGate? = nil,
         bodyCache: MailBodyCache? = nil) {
        self.keychainGate = keychainGate
        self.bodyCache = bodyCache
        self.accountsURL = accountsURL
        self.makeConnection = makeConnection
        self.readCredential = readCredential
        self.writeCredential = writeCredential
        self.readCurrentCredential = readCurrentCredential ?? readCredential
        var decoded: [MailAccount] = []
        do {
            decoded = try JSONDecoder().decode([MailAccount].self, from: Data(contentsOf: accountsURL))
        } catch CocoaError.fileReadNoSuchFile {
            // First launch.
        } catch {
            accountsLoadFailed = true
        }
        var seen: Set<String> = []
        let loaded = decoded.compactMap { account -> MailAccount? in
            let id = Self.normalize(account.id)
            if MailCredentialStore.isReserved(id) {
                log("mail: ignored a saved account whose id starts with \"\(MailCredentialStore.reservedPrefix)\" (reserved)")
                return nil
            }
            guard MailCredentialCheck.isEmail(id), seen.insert(id).inserted else { return nil }
            return MailAccount(id: id, label: account.label, colorIndex: Self.clampedColor(account.colorIndex),
                               enabled: account.enabled, provider: account.provider)
        }
        accounts = loaded
        status = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, .paused) })
    }

    func unread(for accountID: String) -> Int { unreadByAccount[Self.normalize(accountID)] ?? 0 }

    func start() {
        guard !running else { return }
        running = true
        let run = UUID()
        runID = run
        if observesWake {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.runID == run else { return }
                    self.refresh()
                }
            }
        }
        for account in accounts where account.enabled { launch(account.id) }
    }

    /// Starts syncing, but while any enabled account's password is not yet in the helper's own Keychain item first
    /// lets `present` explain the macOS windows that may appear (it receives how many, up to two per such account, and a
    /// closure to call once the person has read it). Nothing is read from the Keychain until then; when every enabled
    /// account was moved already, it starts at once. A copy that failed leaves the account unmoved, so the explanation
    /// comes back on the next launch.
    func start(explainingKeychain present: @escaping (_ prompts: Int, _ proceed: @escaping @MainActor () -> Void) -> Void,
               dismissing dismiss: (() -> Void)? = nil) {
        keychainPresenter = present
        keychainDismiss = dismiss
        guard !running, let keychainGate else { start(); return }
        let plan = keychainGate.plan(for: accounts.filter(\.enabled).map(\.id))
        keychainWatch = Set(plan.watch)
        guard plan.windows > 0 else { start(); return }
        awaitingKeychainNotice = true
        present(plan.windows) { [weak self] in self?.continueAfterKeychainNotice() }
    }

    /// A watched read began: if it has not finished a second later, macOS is most likely showing its window, so the
    /// explanation appears next to it (not blocking anything) and goes away when the read ends.
    private func beginCredentialRead(_ id: String) {
        guard keychainWatch.remove(id) != nil, keychainPresenter != nil else { return }
        watchedReads.insert(id)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, self.watchedReads.contains(id), !self.watchNoticeShown, !self.awaitingKeychainNotice,
                  let present = self.keychainPresenter else { return }
            self.watchNoticeShown = true
            log("mail: a Keychain read is waiting; explaining the macOS window")
            present(2 * self.watchedReads.count) {}
        }
    }

    private func endCredentialRead(_ id: String) {
        guard watchedReads.remove(id) != nil, watchedReads.isEmpty, watchNoticeShown else { return }
        watchNoticeShown = false
        keychainDismiss?()
    }

    /// Called when the explanation is dismissed, or from the flyout when the window went unnoticed behind others.
    func continueAfterKeychainNotice() {
        guard awaitingKeychainNotice else { return }
        awaitingKeychainNotice = false
        log("mail: Keychain explanation dismissed, starting sync")
        let waiting = accountsAwaitingNotice
        accountsAwaitingNotice.removeAll()
        keychainWatch.removeAll()
        watchedReads.removeAll()
        if watchNoticeShown { watchNoticeShown = false; keychainDismiss?() }
        guard running else { start(); return }
        for id in waiting where accounts.contains(where: { $0.id == id && $0.enabled }) { launch(id) }
    }

    /// A moved account lost its own Keychain item mid-run: its flag was cleared, so the next read goes to the old item
    /// and macOS will ask. Explain first (as at launch), then read again.
    private func explainKeychainAgain(for id: String) {
        accountsAwaitingNotice.insert(id)
        status[id] = .paused
        guard !awaitingKeychainNotice else { return }
        guard let present = keychainPresenter else {
            Task { @MainActor [weak self] in self?.continueWithoutNotice() }
            return
        }
        awaitingKeychainNotice = true
        present(2 * accountsAwaitingNotice.count) { [weak self] in self?.continueAfterKeychainNotice() }
    }

    private func continueWithoutNotice() {
        awaitingKeychainNotice = true
        continueAfterKeychainNotice()
    }

    func stop() {
        runID = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        awaitingKeychainNotice = false
        accountsAwaitingNotice.removeAll()
        for connection in pendingSignIns.values { connection.close() }
        pendingSignIns.removeAll()
        guard running else { return }
        running = false
        for id in Array(runs.keys) { endRun(id) }
        snapshots.removeAll()
        overlays.removeAll()
        deferredReads.removeAll()
        for account in accounts { status[account.id] = .paused }
        publishInbox()
    }

    func refresh() {
        guard running else { return }
        for account in accounts where account.enabled {
            if let run = runs[account.id] {
                wake(run, cause: "refresh")
            } else {
                launch(account.id)
            }
        }
    }

    func addAccount(email: String, label: String, appPassword: String, provider: MailProvider = .gmail) async throws {
        guard !accountsLoadFailed else { throw MailFailure.accountsFile }
        let id = Self.normalize(email)
        guard MailCredentialCheck.isEmail(id) else { throw MailFailure.invalidEmail }
        guard !MailCredentialStore.isReserved(id) else { throw MailFailure.reservedEmail }
        guard provider.looksLikeAppPassword(appPassword) else { throw MailFailure.invalidAppPassword }
        let password = provider.passwordForLogin(provider.normalizeAppPassword(appPassword))

        let connection = makeConnection(provider)
        pendingSignIns.updateValue(connection, forKey: id)?.close()
        defer {
            connection.close()
            if pendingSignIns[id] === connection { pendingSignIns[id] = nil }
        }
        do {
            try await withTaskCancellationHandler {
                try await connection.open(email: id, password: password)
            } onCancel: {
                connection.close()
            }
            try Task.checkCancellation()
        } catch {
            guard pendingSignIns[id] === connection else { throw MailFailure.cancelled }
            throw MailFailure.from(error)
        }
        guard pendingSignIns[id] === connection else { throw MailFailure.cancelled }

        var updated = accounts
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let providerChanged: Bool
        if let index = updated.firstIndex(where: { $0.id == id }) {
            providerChanged = updated[index].provider != provider
            updated[index].provider = provider
            if !name.isEmpty { updated[index].label = name }
        } else {
            providerChanged = false
            updated.append(MailAccount(id: id, label: name.isEmpty ? id : name,
                                       colorIndex: updated.count % 6, enabled: true, provider: provider))
        }
        try changeCredential(for: id, to: password, accounts: updated)
        accounts = updated
        endRun(id)
        if providerChanged {
            snapshots[id] = nil
            forgetCachedBodies(of: id)
        }
        status[id] = .paused
        publishInbox()
        if running, updated.contains(where: { $0.id == id && $0.enabled }) { launch(id) }
    }

    func updateAccount(_ account: MailAccount) {
        let id = Self.normalize(account.id)
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        let previous = accounts[index]
        var updated = accounts
        updated[index] = MailAccount(id: id, label: account.label, colorIndex: Self.clampedColor(account.colorIndex),
                                     enabled: account.enabled, provider: previous.provider)
        do {
            try save(updated)
        } catch {
            status[id] = MailFailure.from(error).status
            return
        }
        accounts = updated
        if !account.enabled {
            pendingSignIns.removeValue(forKey: id)?.close()
            endRun(id)
            snapshots[id] = nil
            forgetCachedBodies(of: id)
            status[id] = .paused
            publishInbox()
        } else if !previous.enabled && running {
            launch(id)
        }
    }

    func removeAccount(_ id: String) {
        let id = Self.normalize(id)
        pendingSignIns.removeValue(forKey: id)?.close()
        guard accounts.contains(where: { $0.id == id }) else { return }
        let updated = accounts.filter { $0.id != id }
        do {
            try changeCredential(for: id, to: nil, accounts: updated)
        } catch {
            status[id] = MailFailure.from(error).status
            return
        }
        endRun(id)
        accounts = updated
        status[id] = nil
        snapshots[id] = nil
        forgetCachedBodies(of: id)
        publishInbox()
    }

    /// Account removed, disabled or moved to another provider: its cached bodies and known rows go.
    private func forgetCachedBodies(of id: String) {
        known[id] = nil
        guard let bodyCache else { return }
        cacheQueue.async { bodyCache.purge(account: id) }
    }

    func dismissNotice(_ id: Int) {
        notices.removeAll { $0.id == id }
    }

    private func notify(_ accountID: String, _ text: String) {
        nextNotice += 1
        notices.append(MailNotice(id: nextNotice, accountID: accountID, text: text))
        if notices.count > 3 { notices.removeFirst(notices.count - 3) }
    }

    /// The body of a message already in memory, so the reader can show it in the first frame.
    func cachedContent(for message: MailMessage) -> MailContent? {
        guard let bodyCache, let key = MailBodyKey(currentValidity(for: message)) else { return nil }
        return bodyCache.memoryContent(for: key)
    }

    func body(of message: MailMessage) async throws -> String {
        try await content(of: message).text
    }

    func content(of message: MailMessage, timingID: Int = MailTiming.nextID(),
                 requestedAt: UInt64 = MailTiming.now()) async throws -> MailContent {
        let id = message.accountID
        guard accounts.contains(where: { $0.id == id && $0.enabled }), running else {
            throw MailFailure.unavailable
        }
        let message = currentValidity(for: message)
        let key = bodyCache == nil ? nil : MailBodyKey(message)
        if let bodyCache, let key {
            let lookup = MailTiming.now()
            var hit = bodyCache.memoryContent(for: key).map { (content: $0, source: MailBodyCache.Source.memory) }
            if hit == nil { hit = await Task.detached(priority: .userInitiated) { bodyCache.content(for: key) }.value }
            if let hit {
                MailTiming.line("cache-hit op=\(timingID) acct=\(logName(id)) source=\(hit.source.rawValue) lookup_ms=\(MailTiming.ms(since: lookup)) since_request_ms=\(MailTiming.ms(since: requestedAt))")
                flushDeferredRead(message.id)
                return hit.content
            }
            MailTiming.line("cache-miss op=\(timingID) acct=\(logName(id)) source=network lookup_ms=\(MailTiming.ms(since: lookup))")
        }
        guard accounts.contains(where: { $0.id == id && $0.enabled }), running else { throw MailFailure.unavailable }
        if runs[id] == nil { launch(id) }
        guard let run = runs[id] else { throw MailFailure.unavailable }

        let operationID = UUID()
        do {
            let content = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { continuation in
                    var timing = MailTiming.Op(id: timingID, kind: "open", tapped: requestedAt)
                    timing.enqueued = MailTiming.now()
                    MailTiming.line("enqueue op=\(timingID) kind=open acct=\(logName(id)) since_request_ms=\(MailTiming.ms(from: requestedAt, to: timing.enqueued)) queued=\(run.pending.count) connected=\(run.connection != nil)")
                    insert(PendingOperation(id: operationID, operation: .content(message), contentResult: continuation,
                                            timing: timing), into: run)
                    wake(run, cause: "operation")
                }
            } onCancel: {
                Task { @MainActor in
                    guard let index = run.pending.firstIndex(where: { $0.id == operationID }) else { return }
                    run.pending.remove(at: index).contentResult?.resume(throwing: CancellationError())
                }
            }
            if let bodyCache, let key, accounts.contains(where: { $0.id == id && $0.enabled }) {
                bodyCache.rememberInMemory(content, for: key)
                cacheQueue.async { bodyCache.store(content, for: key) }
                MailTiming.line("cache-store op=\(timingID) acct=\(logName(id)) bytes=\(MailBodyCache.size(of: content))")
            }
            flushDeferredRead(message.id)
            return content
        } catch {
            flushDeferredRead(message.id)
            throw error
        }
    }

    /// The reader opened `message`: it shows as read at once, and the STORE \Seen is sent after the body arrives (or
    /// after two seconds), so it never sits in front of the body fetch.
    func open(_ message: MailMessage) {
        guard message.unread else { return }
        let message = currentValidity(for: message)
        let id = message.accountID
        guard running, accounts.contains(where: { $0.id == id && $0.enabled }), deferredReads[message.id] == nil else { return }
        let effect = addEffect(.read(messageID: message.id), for: id, kind: "mark-read-on-open")
        deferredReads[message.id] = DeferredRead(message: message, effect: effect)
        publishInbox()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.flushDeferredRead(message.id)
        }
    }

    private func flushDeferredRead(_ messageID: String) {
        guard let read = deferredReads.removeValue(forKey: messageID) else { return }
        enqueue(.markRead(read.message), for: read.message.accountID, effect: .read(messageID: messageID), existing: read.effect)
    }

    /// Drops a not-yet-sent read for a message that is going away or becoming unread.
    private func dropDeferredRead(_ messageID: String) {
        guard let read = deferredReads.removeValue(forKey: messageID) else { return }
        overlays[read.message.accountID]?.remove(read.effect)
    }

    func markRead(_ message: MailMessage) {
        let tapped = MailTiming.now()
        if deferredReads[message.id] != nil { flushDeferredRead(message.id); return }
        enqueue(.markRead(currentValidity(for: message)), for: message.accountID, tapped: tapped,
                effect: .read(messageID: message.id))
    }

    func markUnread(_ message: MailMessage) {
        let tapped = MailTiming.now()
        dropDeferredRead(message.id)
        enqueue(.markUnread(currentValidity(for: message)), for: message.accountID, tapped: tapped,
                effect: .unread(messageID: message.id))
    }

    func markAllRead(accountID: String?) {
        let tapped = MailTiming.now()
        let id = accountID.map(Self.normalize)
        for account in accounts where account.enabled && (id == nil || account.id == id) {
            enqueue(.markAllRead, for: account.id, tapped: tapped, effect: .readAll)
        }
    }

    func canArchive(_ message: MailMessage) -> Bool {
        guard let snapshot = snapshots[message.accountID], snapshot.canArchive else { return false }
        return snapshot.messages.contains { $0.id == message.id }
    }

    func archive(_ message: MailMessage) {
        let tapped = MailTiming.now()
        guard canArchive(message) else { return }
        dropDeferredRead(message.id)
        enqueue(.archive(currentValidity(for: message)), for: message.accountID, tapped: tapped,
                effect: .hide(messageID: message.id))
    }

    func trash(_ message: MailMessage) {
        let tapped = MailTiming.now()
        dropDeferredRead(message.id)
        enqueue(.trash(currentValidity(for: message)), for: message.accountID, tapped: tapped,
                effect: .hide(messageID: message.id))
    }


    func webURL(for message: MailMessage) -> URL {
        let provider = accounts.first { $0.id == message.accountID }?.provider ?? .gmail
        return provider.webInboxURL(accountID: message.accountID, thread: message.gmailThreadID ?? message.gmailMessageID)
    }

    nonisolated static func inboxURL(accountID: String, thread: UInt64? = nil) -> URL {
        MailProvider.gmail.webInboxURL(accountID: accountID, thread: thread)
    }

    nonisolated static func appPasswordsURL(for email: String) -> URL {
        MailProvider.gmail.appPasswordsURL(for: email)
    }

    private func currentValidity(for message: MailMessage) -> MailMessage {
        guard message.uidValidity == nil, let snapshot = snapshots[message.accountID],
              snapshot.messages.contains(where: { $0.id == message.id && $0.uid == message.uid }) else {
            return message
        }
        var message = message
        message.uidValidity = snapshot.validity
        return message
    }

    private func addEffect(_ effect: MailOverlay.Effect, for id: String, kind: String) -> Int {
        nextEffect += 1
        overlays[id, default: MailOverlay()].add(effect, id: nextEffect)
        MailTiming.line("optimistic-apply effect=\(nextEffect) kind=\(kind) acct=\(logName(id))")
        return nextEffect
    }

    /// `effect`: what the list shows right away. `existing`: an overlay entry already showing it (see open).
    private func enqueue(_ operation: Operation, for id: String, tapped: UInt64 = MailTiming.now(),
                         effect: MailOverlay.Effect? = nil, existing: Int? = nil) {
        func discardExisting() {
            if let existing, overlays[id]?.remove(existing) != nil { publishInbox() }
        }
        guard running, accounts.contains(where: { $0.id == id && $0.enabled }) else { discardExisting(); return }
        if runs[id] == nil { launch(id) }
        guard let run = runs[id] else { discardExisting(); return }
        if case let .markRead(message) = operation, run.pending.contains(where: {
            if case let .markRead(queued) = $0.operation { return queued.id == message.id }
            return false
        }) { discardExisting(); return }
        // A read and an unread of the same message that was not sent yet cancel out: only the newest is sent.
        if let message = operation.message, case .markRead = operation {
            dropQueued(in: run, id: id) { if case let .markUnread(queued) = $0 { return queued.id == message.id }; return false }
        } else if let message = operation.message, case .markUnread = operation {
            dropQueued(in: run, id: id) { if case let .markRead(queued) = $0 { return queued.id == message.id }; return false }
        }
        var timing = MailTiming.Op(id: MailTiming.nextID(), kind: operation.kind, tapped: tapped)
        timing.enqueued = MailTiming.now()
        var pending = PendingOperation(id: UUID(), operation: operation, contentResult: nil, timing: timing)
        if let existing {
            pending.effect = existing
        } else if let effect {
            pending.effect = addEffect(effect, for: id, kind: operation.kind)
        }
        MailTiming.line("enqueue op=\(timing.id) kind=\(timing.kind) acct=\(logName(id)) since_tap_ms=\(MailTiming.ms(from: tapped, to: timing.enqueued)) queued=\(run.pending.count) connected=\(run.connection != nil) effect=\(pending.effect.map(String.init) ?? "-")")
        insert(pending, into: run)
        if pending.effect != nil {
            let publishStart = MailTiming.now()
            publishInbox()
            MailTiming.line("optimistic-shown op=\(timing.id) kind=\(timing.kind) publish_ms=\(MailTiming.ms(since: publishStart)) since_tap_ms=\(MailTiming.ms(since: tapped))")
        }
        wake(run, cause: "operation")
    }

    private func dropQueued(in run: AccountRun, id: String, where matches: (Operation) -> Bool) {
        run.pending.removeAll { pending in
            guard pending.id != run.inFlight, pending.contentResult == nil, matches(pending.operation) else { return false }
            if let effect = pending.effect { overlays[id]?.remove(effect) }
            MailTiming.line("dequeue op=\(pending.timing.id) kind=\(pending.timing.kind) acct=\(logName(id)) reason=superseded")
            return true
        }
    }

    /// Content requests go ahead of every action that is not already on the wire; actions keep their order.
    private func insert(_ pending: PendingOperation, into run: AccountRun) {
        if pending.operation.isContent,
           let index = run.pending.firstIndex(where: { !$0.operation.isContent && $0.id != run.inFlight }) {
            run.pending.insert(pending, at: index)
        } else {
            run.pending.append(pending)
        }
    }

    private func wake(_ run: AccountRun, cause: String) {
        run.wakeCauses.insert(cause)
        run.connection?.requestRefresh()
        run.retryDelay?.cancel()
    }

    private func launch(_ id: String) {
        guard runs[id] == nil else { return }
        let run = AccountRun()
        runs[id] = run
        status[id] = .connecting
        run.worker = Task { [weak self] in
            await self?.monitor(id, run: run)
        }
    }

    private func endRun(_ id: String) {
        for (messageID, read) in deferredReads where read.message.accountID == id { deferredReads[messageID] = nil }
        overlays[id] = nil
        notices.removeAll { $0.accountID == id }
        guard let run = runs.removeValue(forKey: id) else { return }
        run.worker?.cancel()
        run.retryDelay?.cancel()
        run.connection?.close()
        failOperations(in: run, id: id, with: .unavailable)
        overlays[id] = nil
    }

    private func monitor(_ id: String, run: AccountRun) async {
        var backoff = 2
        var connectAttempt = 0
        /// The first reconnect after a dead link (or a dropped connection that had been working) happens at once.
        var quickRetryUsed = false
        defer {
            run.worker = nil
            if runs[id] === run { runs[id] = nil }
        }
        while runs[id] === run && !Task.isCancelled {
            status[id] = .connecting
            guard let account = accounts.first(where: { $0.id == id }) else { return }
            let connection = makeConnection(account.provider)
            run.connection = connection
            connectAttempt += 1
            if connectAttempt > 1 { MailTiming.line("reconnect acct=\(logName(id)) attempt=\(connectAttempt)") }
            var syncedAt: ContinuousClock.Instant?
            var signedIn = false
            do {
                try await withTaskCancellationHandler {
                    defer { connection.close() }
                    try await signIn(id, name: logName(id), on: connection)
                    signedIn = true
                    var syncReason = "connect"
                    var lastSync: ContinuousClock.Instant?
                    while runs[id] === run && !Task.isCancelled {
                        let revision = connection.changeRevision
                        let hadOperations = !run.pending.isEmpty
                        let barrier = try await performOperations(for: id, run: run, on: connection)
                        guard runs[id] === run, !Task.isCancelled else { return }
                        if barrier {
                            syncReason = "after-bulk-operation"
                        } else if connection.changeRevision != revision && syncReason.isEmpty {
                            syncReason = "server-change"
                        } else if hadOperations && syncReason.isEmpty {
                            MailTiming.line("sync-skip acct=\(logName(id)) reason=no-server-change-after-operations")
                        }
                        // More actions arrived while these ran: send them before reading the inbox again.
                        if !barrier && !run.pending.isEmpty { continue }
                        if !syncReason.isEmpty {
                            guard let snapshot = try await synchronize(id, run: run, on: connection, reason: syncReason,
                                                                       yieldOnlyToContent: barrier) else { continue }
                            syncReason = ""
                            lastSync = .now
                            status[id] = .connected
                            if syncedAt == nil {
                                syncedAt = .now
                                quickRetryUsed = false
                                log("mail: \(logName(id)) synced messages=\(snapshot.messages.count) unread=\(snapshot.unread)")
                            }
                        }
                        guard run.pending.isEmpty else { continue }
                        let beforePrefetch = connection.changeRevision
                        try await prefetch(id, run: run, on: connection)
                        guard runs[id] === run, !Task.isCancelled else { return }
                        if connection.changeRevision != beforePrefetch { syncReason = "server-change" }
                        guard run.pending.isEmpty, syncReason.isEmpty else { continue }
                        connection.timingContext = "acct=\(logName(id)) idle"
                        try await connection.waitForInboxChange()
                        let outcome = connection.wakeOutcome
                        let causes = run.wakeCauses
                        run.wakeCauses.removeAll()
                        let periodic = lastSync.map { $0.duration(to: .now) >= .seconds(MailLink.periodicSync) } ?? true
                        switch outcome {
                        case "idle-renew":
                            if periodic { syncReason = "periodic" }
                        case "link-check":
                            MailTiming.line("link-check acct=\(logName(id)) alive=true")
                        case "interrupt":
                            // A refresh (panel open, wake from sleep) reads the inbox; an action alone does not.
                            if causes.contains("refresh") { syncReason = "refresh" }
                            else if causes.isEmpty { syncReason = "interrupt" }
                        default:
                            syncReason = outcome.isEmpty ? "wake" : outcome
                        }
                    }
                } onCancel: {
                    connection.close()
                }
                return
            } catch {
                connection.close()
                run.connection = nil
                guard runs[id] === run, !Task.isCancelled else { return }
                let failure = MailFailure.from(error)
                MailTiming.line("connection-lost acct=\(logName(id)) failure=\(failure.logCode) timed_out=\({ if case MailIMAPError.timedOut = error { return true }; return false }()) context=\(connection.timingContext)")
                if failure == .keychainNeedsNotice {
                    failOperations(in: run, id: id, with: .unavailable)
                    publishInbox()
                    explainKeychainAgain(for: id)
                    return
                }
                if failure != .updateRestart {
                    log("mail: \(logName(id)) sync failed \(failure.logCode) retry=\(!failure.requiresUserAction)")
                }
                status[id] = failure.status
                let linkFailure: Bool
                switch error as? MailIMAPError {
                case .linkDead?, .disconnected?, .timedOut?: linkFailure = true
                default: linkFailure = false
                }
                let quick = signedIn && linkFailure && !quickRetryUsed && !failure.requiresUserAction
                failOperations(in: run, id: id, with: failure, afterDisconnect: !failure.requiresUserAction, keepContent: quick)
                publishInbox()
                if failure.requiresUserAction { return }

                if let syncedAt, syncedAt.duration(to: .now) >= .seconds(60) { backoff = 2 }
                if quick {
                    quickRetryUsed = true
                    MailTiming.line("reconnect-immediate acct=\(logName(id)) failure=\(failure.logCode) queued=\(run.pending.count)")
                    continue
                }
                let wait = backoff
                MailTiming.line("retry-wait acct=\(logName(id)) seconds=\(wait)")
                let retry = Task { _ = try? await Task.sleep(for: .seconds(wait)) }
                run.retryDelay = retry
                await retry.value
                run.retryDelay = nil
                backoff = min(300, backoff * 2)
            }
        }
    }

    /// Reads the inbox and applies it. nil: it stepped aside for something the person is waiting for (an open, or any
    /// action unless `yieldOnlyToContent`), having applied nothing; the caller runs that and syncs again.
    private func synchronize(_ id: String, run: AccountRun, on connection: MailIMAP, reason: String,
                             yieldOnlyToContent: Bool) async throws -> MailInboxSnapshot? {
        connection.timingContext = "acct=\(logName(id)) sync=\(MailTiming.nextID())"
        connection.timingReason = reason
        let sequence = (syncStarted[id] ?? 0) + 1
        syncStarted[id] = sequence
        let signal = run.signal
        guard let snapshot = try await connection.synchronize(
            accountID: id, known: known[id],
            shouldYield: { yieldOnlyToContent ? signal.contentWaiting : signal.anyWaiting }
        ) else {
            MailTiming.line("sync-preempted acct=\(logName(id)) sync_seq=\(sequence) reason=\(reason) queued=\(run.pending.count)")
            return nil
        }
        guard runs[id] === run, !Task.isCancelled else { return nil }
        let previous = snapshots[id]
        if let previous, previous.validity != snapshot.validity {
            // A new UIDVALIDITY epoch: old UIDs name other messages now. Pending actions on them fail as stale.
            MailTiming.line("validity-change acct=\(logName(id))")
            for (messageID, read) in deferredReads where read.message.accountID == id && read.message.uidValidity != snapshot.validity {
                dropDeferredRead(messageID)
            }
            if let bodyCache {
                let validity = snapshot.validity
                cacheQueue.async { bodyCache.purge(account: id, keepingValidity: validity) }
            }
        }
        if known[id]?.validity == snapshot.validity {
            known[id]?.merge(snapshot.messages)
        } else {
            known[id] = MailKnownMessages(validity: snapshot.validity, messages: snapshot.messages)
        }
        snapshots[id] = snapshot
        overlays[id]?.prune(appliedSync: sequence)
        if previous?.messages.count != snapshot.messages.count || previous?.unread != snapshot.unread {
            log("mail: \(logName(id)) synced messages=\(snapshot.messages.count) unread=\(snapshot.unread)")
        }
        publishInbox()
        return snapshot
    }

    /// After a sync, with nothing queued: bodies of the top visible rows not cached yet, unread first, within
    /// MailPrefetchPlanner's limits; skipped on constrained or expensive networks, stopped by any queued work.
    private func prefetch(_ id: String, run: AccountRun, on connection: MailIMAP) async throws {
        guard connection.tuning.prefetch, let bodyCache, run.pending.isEmpty else { return }
        if connection.isConstrainedPath {
            MailTiming.line("prefetch-skip acct=\(logName(id)) reason=constrained-network")
            return
        }
        let skipped = run.prefetchSkipped
        let rows = messages.filter { $0.accountID == id && !skipped.contains($0.id) }
        let candidates = await Task.detached(priority: .utility) {
            MailPrefetchPlanner.candidates(visible: rows, isCached: { MailBodyKey($0).map(bodyCache.contains) ?? true })
        }.value
        guard !candidates.isEmpty, runs[id] === run, run.pending.isEmpty else { return }
        let started = MailTiming.now()
        MailTiming.line("prefetch-start acct=\(logName(id)) candidates=\(candidates.count)")
        connection.timingContext = "acct=\(logName(id)) prefetch"
        let signal = run.signal
        let result = try await connection.prefetch(candidates, shouldStop: { signal.anyWaiting })
        let fetched = Set(result.contents.map(\.0.id))
        if result.stop == "done" || result.stop == "none" {
            run.prefetchSkipped.formUnion(candidates.map(\.id).filter { !fetched.contains($0) })
        }
        var bytes = 0
        for (message, content) in result.contents {
            guard let key = MailBodyKey(message) else { continue }
            bytes += MailBodyCache.size(of: content)
            bodyCache.rememberInMemory(content, for: key)
            cacheQueue.async { bodyCache.store(content, for: key) }
        }
        MailTiming.line("prefetch-done acct=\(logName(id)) fetched=\(result.contents.count) of=\(candidates.count) content_bytes=\(bytes) ms=\(MailTiming.ms(since: started)) stop=\(result.stop)")
    }

    /// Account position only: the debug log never names the address.
    private func logName(_ id: String) -> String {
        "account[\(accounts.firstIndex { $0.id == id }.map(String.init) ?? "?")]"
    }

    private nonisolated func signIn(_ id: String, name: String, on connection: MailIMAP) async throws {
        let began = MailTiming.now()
        MailTiming.line("signin-start acct=\(name)")
        connection.timingContext = "acct=\(name) signin"
        var keychainMS = 0
        do {
            await beginCredentialRead(id)
            let stored: String?
            do { stored = try readCredential(id) } catch { await endCredentialRead(id); throw error }
            await endCredentialRead(id)
            keychainMS = MailTiming.ms(since: began)
            guard let password = stored else { throw MailFailure.appPasswordRequired }
            try await connection.open(email: id, password: password)
        } catch {
            MailTiming.line("signin-end acct=\(name) err=\(MailTiming.describe(error)) keychain_ms=\(keychainMS) total_ms=\(MailTiming.ms(since: began))")
            throw error
        }
        MailTiming.line("signin-end acct=\(name) ok keychain_ms=\(keychainMS) imap_ms=\(MailTiming.ms(since: began) - keychainMS) total_ms=\(MailTiming.ms(since: began))")
    }

    /// Sends the queue in order. Returns true right after a bulk operation (mark all read) succeeded: the caller reads the
    /// inbox before sending anything else.
    private func performOperations(for id: String, run: AccountRun, on connection: MailIMAP) async throws -> Bool {
        while runs[id] === run, var pending = run.pending.first {
            pending.attempts += 1
            run.pending[0].attempts = pending.attempts
            run.inFlight = pending.id
            if let effect = pending.effect, let entry = overlays[id]?.entries.first(where: { $0.id == effect }) {
                overlays[id]?.set(.inFlight, for: effect)
                if entry.state == .held { publishInbox() }
            }
            let timing = pending.timing
            let performStart = MailTiming.now()
            MailTiming.line("start op=\(timing.id) kind=\(timing.kind) acct=\(logName(id)) queue_wait_ms=\(MailTiming.ms(from: timing.enqueued, to: performStart)) since_tap_ms=\(MailTiming.ms(from: timing.tapped, to: performStart)) attempt=\(pending.attempts)")
            connection.timingContext = "acct=\(logName(id)) op=\(timing.id)"
            let result: Result<MailContent, MailFailure>
            do {
                result = .success(try await pending.operation.perform(on: connection))
            } catch MailIMAPError.staleMessage {
                result = .failure(.staleMessage)
            } catch MailIMAPError.missingMailbox {
                result = .failure(.missingMailbox)
            } catch MailIMAPError.moveUnsupported {
                result = .failure(.moveUnsupported)
            } catch MailIMAPError.rejected {
                result = .failure(.rejected)
            } catch MailIMAPError.messageTooLarge {
                result = .failure(.messageTooLarge)
            } catch {
                MailTiming.line("end op=\(timing.id) kind=\(timing.kind) acct=\(logName(id)) err=\(MailTiming.describe(error)) perform_ms=\(MailTiming.ms(since: performStart)) since_tap_ms=\(MailTiming.ms(since: timing.tapped))")
                // The answer is lost with the connection. Settle the list now, before the connection closes.
                if runs[id] === run, !Task.isCancelled { lostAnswer(pending, id: id) }
                throw error
            }
            let performed: String
            if case .success = result { performed = "ok" } else { performed = "failed" }
            MailTiming.line("end op=\(timing.id) kind=\(timing.kind) acct=\(logName(id)) result=\(performed) perform_ms=\(MailTiming.ms(since: performStart)) since_tap_ms=\(MailTiming.ms(since: timing.tapped))")
            guard runs[id] === run, !Task.isCancelled else { return false }
            run.inFlight = nil
            guard let index = run.pending.firstIndex(where: { $0.id == pending.id }) else { continue }

            run.pending.remove(at: index)
            switch result {
            case let .success(content):
                if let effect = pending.effect {
                    let sequence = syncStarted[id] ?? 0
                    overlays[id]?.confirm(effect, latestStartedSync: sequence)
                    MailTiming.line("optimistic-confirm op=\(timing.id) kind=\(timing.kind) acct=\(logName(id)) effect=\(effect) after_sync=\(sequence)")
                }
                if pending.contentResult != nil {
                    MailTiming.line("content-resume op=\(timing.id) acct=\(logName(id)) since_request_ms=\(MailTiming.ms(since: timing.tapped))")
                }
                pending.contentResult?.resume(returning: content)
            case let .failure(error):
                if pending.contentResult == nil {
                    if let effect = pending.effect, overlays[id]?.remove(effect) != nil {
                        MailTiming.line("optimistic-revert op=\(timing.id) kind=\(timing.kind) acct=\(logName(id)) reason=\(error.logCode)")
                    }
                    notify(id, pending.operation.refusal(error))
                }
                pending.contentResult?.resume(throwing: error)
            }
            let publishStart = MailTiming.now()
            publishInbox()
            if pending.contentResult == nil {
                // The server's answer for archive / trash / mark read; the list already showed the change at tap time.
                MailTiming.line("row-gone op=\(timing.id) kind=\(timing.kind) acct=\(logName(id)) result=\(performed) publish_ms=\(MailTiming.ms(since: publishStart)) total_tap_ms=\(MailTiming.ms(since: timing.tapped))")
            }
            if case .success = result, pending.operation.isBulk { return true }
        }
        return false
    }

    /// The connection failed while `pending` was on the wire. A repeatable action stops showing until it is sent again
    /// after reconnecting; a move is never resent (it could copy twice): its row comes back with a notice.
    private func lostAnswer(_ pending: PendingOperation, id: String) {
        guard pending.contentResult == nil, let effect = pending.effect else { return }
        if pending.operation.isRepeatable {
            overlays[id]?.set(.held, for: effect)
            MailTiming.line("optimistic-hold op=\(pending.timing.id) kind=\(pending.timing.kind) acct=\(logName(id)) reason=connection-lost")
        } else {
            overlays[id]?.remove(effect)
            MailTiming.line("optimistic-revert op=\(pending.timing.id) kind=\(pending.timing.kind) acct=\(logName(id)) reason=connection-lost")
            notify(id, pending.operation.unconfirmed)
        }
        publishInbox()
    }

    /// `afterDisconnect`: actions not sent yet, and repeatable ones, survive the reconnect; a move that was on the wire
    /// does not (lostAnswer already put its row back). `keepContent`: the reconnect is immediate, so opens wait for it
    /// (each is tried at most twice) instead of failing.
    private func failOperations(in run: AccountRun, id: String, with error: MailFailure, afterDisconnect: Bool = false,
                                keepContent: Bool = false) {
        defer { run.inFlight = nil }
        run.pending.removeAll { pending in
            if afterDisconnect {
                if pending.contentResult == nil {
                    if pending.operation.isRepeatable || run.inFlight != pending.id { return false }
                } else if keepContent && pending.attempts < 2 {
                    return false
                }
            }
            if let effect = pending.effect { overlays[id]?.remove(effect) }
            pending.contentResult?.resume(throwing: error)
            return true
        }
    }

    private func publishInbox() {
        var combined: [MailMessage] = []
        var counts: [String: Int] = [:]
        for account in accounts where account.enabled {
            guard let snapshot = snapshots[account.id] else { continue }
            let shown = overlays[account.id]?.apply(to: snapshot)
                ?? MailOverlay.Result(messages: snapshot.messages, unread: snapshot.unread)
            combined.append(contentsOf: shown.messages)
            counts[account.id] = shown.unread
        }
        combined.sort {
            if $0.date != $1.date { return $0.date > $1.date }
            if $0.accountID != $1.accountID { return $0.accountID < $1.accountID }
            return $0.uid > $1.uid
        }
        unreadByAccount = counts
        let synced = Set(counts.keys)
        if syncedAccounts != synced { syncedAccounts = synced }
        if messages != combined { messages = combined }
        let total = counts.values.reduce(0, +)
        if unreadCount != total { unreadCount = total }
    }

    private func changeCredential(for id: String, to password: String?, accounts: [MailAccount]) throws {
        let previous = try readCurrentCredential(id)
        try writeCredential(password, id)
        do {
            try save(accounts)
        } catch {
            try writeCredential(previous, id)
            throw error
        }
    }

    private func save(_ accounts: [MailAccount]) throws {
        guard let accountsURL else { throw MailFailure.accountsFile }
        do {
            try FileManager.default.createDirectory(at: accountsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(accounts).write(to: accountsURL, options: .atomic)
        } catch {
            throw MailFailure.accountsFile
        }
    }

    private nonisolated static func normalize(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func clampedColor(_ index: Int) -> Int { min(5, max(0, index)) }
}

/// Mail passwords live in the Keychain (service "Cala Mail"), but Cala never touches them itself: every read and write
/// goes through Contents/Helpers/cala-keychain (source in Helpers/cala-keychain). That helper is signed once and shipped
/// unchanged, so the Keychain keeps trusting it across Cala updates, while Cala's own ad-hoc signature changes with
/// every build. The request travels on stdin and the password on stdin/stdout, never in argv or the environment.
enum MailKeychain {
    private enum Exit: Int32 { case ok = 0, notFound = 1, denied = 2, refused = 77, unverified = 78 }

    // UpdateService publishes this flag on main. The helper can finish on a Mail worker.
    private static let updateRestart = OSAllocatedUnfairLock(initialState: false)
    static var isRestartingForUpdate: Bool {
        get { updateRestart.withLock { $0 } }
        set { updateRestart.withLock { $0 = newValue } }
    }

    static var helperURL: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/cala-keychain") }

    /// The helper's cdhash: the Keychain prompts again only when this changes (see MailKeychainGate).
    static var helperIdentity: String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(helperURL as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, [], &info) == errSecSuccess,
              let unique = (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data else { return nil }
        return "helper-" + unique.map { String(format: "%02x", $0) }.joined()
    }

    static func password(for id: String) throws -> String? {
        let (status, output) = try run("get", id)
        if status == Exit.notFound.rawValue { return nil }
        // Deny / Cancel on the macOS prompt, or no way to show it: retrying would only ask again every few seconds.
        if status == Exit.denied.rawValue { throw MailFailure.keychainDenied }
        try refusal(status)
        guard status == Exit.ok.rawValue, let password = String(data: output, encoding: .utf8) else { throw MailFailure.keychain }
        return password
    }

    static func set(_ password: String?, for id: String) throws {
        guard let password else {
            let (status, _) = try run("delete", id)
            try refusal(status)
            guard status == Exit.ok.rawValue || status == Exit.notFound.rawValue else { throw MailFailure.keychain }
            return
        }
        let (status, _) = try run("set", id, secret: Data(password.utf8))
        try refusal(status)
        guard status == Exit.ok.rawValue else { throw MailFailure.keychain }
    }

    private static func refusal(_ status: Int32) throws {
        if status == Exit.refused.rawValue {
            throw isRestartingForUpdate ? MailFailure.updateRestart : MailFailure.keychainRestart
        }
        if status == Exit.unverified.rawValue { throw MailFailure.keychainUnverified }
    }

    /// Blocks the calling thread while macOS may show its prompt, as SecItem calls did. It does not spin the run loop
    /// (unlike `waitUntilExit`), so nothing else runs re-entrantly on the main thread meanwhile.
    private static func run(_ command: String, _ id: String, secret: Data? = nil) throws -> (Int32, Data) {
        guard !id.contains("\n"), !id.contains("\r") else { throw MailFailure.keychain }
        let process = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
        process.executableURL = helperURL
        process.arguments = []
        process.environment = [:]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch {
            log("mail: Keychain helper did not start: \(error.localizedDescription)")
            throw MailFailure.keychain
        }
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        var request = Data("\(command)\n\(id)\n".utf8)
        if let secret { request.append(secret) }
        // A helper that exits early (it refused the caller) closes the pipe; the exit status says why.
        try? input.fileHandleForWriting.write(contentsOf: request)
        request.resetBytes(in: 0..<request.count)
        try? input.fileHandleForWriting.close()
        let result = output.fileHandleForReading.readDataToEndOfFile()
        let message = errors.fileHandleForReading.readDataToEndOfFile()
        exited.wait()
        try? output.fileHandleForReading.close()
        try? errors.fileHandleForReading.close()
        let status = process.terminationStatus
        let updateRestart = status == Exit.refused.rawValue && isRestartingForUpdate
        if !updateRestart && (status > Exit.denied.rawValue || process.terminationReason != .exit) {
            let text = String(decoding: message.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            log("mail: Keychain helper \(command) failed (\(status)): \(text)")
        }
        return (process.terminationReason == .exit ? status : -1, result)
    }
}

enum MailFailure: LocalizedError {
    case invalidEmail, invalidAppPassword, authenticationFailed, appPasswordRequired, blocked, offline, timedOut
    /// The Keychain helper refused this process, typically because Cala.app was replaced while this copy kept running.
    case keychainRestart, updateRestart
    /// The Keychain helper could not confirm who called it (an OS check failed; Developer ID builds only).
    case keychainUnverified
    /// The helper's own item vanished for an account already moved: explain the coming macOS windows, then read again.
    case keychainNeedsNotice
    /// An address starting with "v2:", which Cala reserves for its own Keychain entries.
    case reservedEmail
    case accountsFile, keychain, keychainDenied, unavailable, staleMessage, missingMailbox, moveUnsupported, rejected, responseTooLarge, messageTooLarge, cancelled

    static func from(_ error: Error) -> Self {
        if let failure = error as? Self { return failure }
        if error is CancellationError { return .cancelled }
        switch error as? MailIMAPError {
        case .server(.authenticationFailed): return .authenticationFailed
        case .server(.appPasswordRequired): return .appPasswordRequired
        case .server(.blocked): return .blocked
        case .responseTooLarge: return .responseTooLarge
        case .messageTooLarge: return .messageTooLarge
        case .rejected: return .rejected
        case .moveUnsupported: return .moveUnsupported
        case .timedOut: return .timedOut
        case .staleMessage: return .staleMessage
        case .missingMailbox: return .missingMailbox
        default: return .offline
        }
    }

    var requiresUserAction: Bool {
        switch self {
        case .authenticationFailed, .appPasswordRequired, .blocked, .keychainDenied, .keychainRestart, .updateRestart, .keychainUnverified: return true
        default: return false
        }
    }

    var status: MailAccountStatus {
        let message = localizedDescription
        switch self {
        case .authenticationFailed, .appPasswordRequired, .keychainDenied: return .authFailed(message)
        case .blocked, .keychainRestart, .updateRestart, .keychainUnverified: return .blocked(message)
        default: return .offline(message)
        }
    }

    /// Error class for the debug log (no addresses, passwords or server text).
    var logCode: String { String(describing: self) }

    var errorDescription: String? {
        switch self {
        case .invalidEmail:
            return tx("Enter a valid email address.", "Introduce una dirección de correo válida.")
        case .invalidAppPassword:
            return tx("This doesn’t look like an app password. Use the 16-letter code your mail provider generated for Cala.",
                      "Esto no parece una contraseña de aplicación. Usa el código de 16 letras que tu proveedor de correo generó para Cala.")
        case .authenticationFailed, .appPasswordRequired:
            return tx("Cala needs an app password to sign in. Create a new one in your mail account’s security settings and try again.",
                      "Cala necesita una contraseña de aplicación para iniciar sesión. Crea una nueva en la configuración de seguridad de tu cuenta de correo y vuelve a intentarlo.")
        case .blocked:
            return tx("Your mail provider blocked IMAP or app password access. For a work account, ask your administrator to enable access.",
                      "Tu proveedor de correo bloqueó el acceso por IMAP o mediante contraseñas de aplicación. Si es una cuenta de trabajo, pide a tu administrador que habilite el acceso.")
        case .offline:
            return tx("Cala couldn’t connect to the mail server. Try again in a moment.",
                      "Cala no pudo conectarse al servidor de correo. Vuelve a intentarlo en un momento.")
        case .timedOut:
            return tx("The mail server took too long to respond. Try again in a moment.",
                      "El servidor de correo tardó demasiado en responder. Vuelve a intentarlo en un momento.")
        case .accountsFile:
            return tx("Cala couldn’t save the mail accounts.", "Cala no pudo guardar las cuentas de correo.")
        case .keychain:
            return tx("Cala couldn’t access the app password in Keychain.",
                      "Cala no pudo acceder a la contraseña de aplicación en el Llavero.")
        case .keychainDenied:
            return tx("macOS didn’t let Cala read the app password from the Keychain. Press Refresh and choose “Always Allow”.",
                      "macOS no dejó que Cala leyera la contraseña de aplicación del Llavero. Pulsa Actualizar y elige «Permitir siempre».")
        case .updateRestart:
            return tx("Restarting to finish the update", "Reiniciando para terminar la actualización")
        case .keychainRestart:
            return tx("Restart Cala to refresh its Keychain access.", "Reinicia Cala para actualizar el acceso al llavero.")
        case .keychainNeedsNotice:
            return tx("macOS will ask for Keychain access again.", "macOS volverá a pedir acceso al Llavero.")
        case .reservedEmail:
            return tx("Addresses that start with “v2:” can’t be used: Cala reserves that prefix for its Keychain entries.",
                      "No se pueden usar direcciones que empiecen por «v2:»: Cala reserva ese prefijo para sus entradas del Llavero.")
        case .keychainUnverified:
            return tx("macOS couldn’t confirm that the Keychain request came from Cala. Restart your Mac; if it keeps happening, reinstall Cala.",
                      "macOS no pudo confirmar que la petición al Llavero venía de Cala. Reinicia tu Mac; si se repite, reinstala Cala.")
        case .unavailable:
            return tx("This mail account is paused or unavailable.", "Esta cuenta de correo está en pausa o no está disponible.")
        case .staleMessage:
            return tx("This message is no longer available in the inbox.", "Este mensaje ya no está disponible en Recibidos.")
        case .missingMailbox:
            return tx("The mail server didn’t report the mailbox needed to move this message.",
                      "El servidor de correo no indicó el buzón necesario para mover este mensaje.")
        case .messageTooLarge:
            return tx("This message exceeds Cala’s 25 MB limit. Open it in your web inbox.",
                      "Este mensaje supera el límite de 25 MB de Cala. Ábrelo en tu bandeja web.")
        case .responseTooLarge:
            return tx("This response is too large to display in Cala. Open your inbox in the browser.",
                      "Esta respuesta es demasiado grande para mostrarla en Cala. Abre tu bandeja de entrada en el navegador.")
        case .moveUnsupported:
            return tx("The mail server did not offer a way to move just this message.", "El servidor de correo no ofreció una forma de mover solo este mensaje.")
        case .rejected:
            return tx("The mail server declined the operation. Refresh and try again.", "El servidor de correo rechazó la operación. Actualiza y vuelve a intentarlo.")
        case .cancelled:
            return tx("The mail operation was cancelled.", "Se canceló la operación de correo.")
        }
    }
}

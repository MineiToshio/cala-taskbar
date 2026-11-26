import AppKit
import Combine
import Foundation
import Security

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

/// Which accounts already have their password in the helper's own Keychain item (see MailCredentialStore). One
/// UserDefaults key per account holds the helper identity (its cdhash) that made that item; it is written only after
/// the item was written or read back, so a missing or different value means macOS may still show its windows for that
/// account: up to two (one for the old item's access list, one for its partition) the first time.
struct MailKeychainGate {
    static let keyPrefix = "mailKeychainMigrated."
    let identity: String
    let defaults: UserDefaults

    init(identity: String = MailKeychain.helperIdentity ?? "helper-unknown", defaults: UserDefaults = .standard) {
        self.identity = identity
        self.defaults = defaults
    }

    func isMigrated(_ id: String) -> Bool { defaults.string(forKey: Self.keyPrefix + id) == identity }
    func markMigrated(_ id: String) { if !isMigrated(id) { defaults.set(identity, forKey: Self.keyPrefix + id) } }
    func clearMigrated(_ id: String) { defaults.removeObject(forKey: Self.keyPrefix + id) }

    /// How many macOS windows to announce before reading `ids`: up to two per account not moved yet.
    func expectedPrompts(for ids: [String]) -> Int { 2 * ids.filter { !isMigrated($0) }.count }
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
                            gate: MailKeychainGate())
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
        } catch let error as MailFailure where error == .keychainRestart || error == .keychainUnverified {
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

    private enum Operation {
        case content(MailMessage)
        case markRead(MailMessage)
        case markAllRead
        case archive(MailMessage)
        case trash(MailMessage)

        func perform(on connection: MailIMAP) async throws -> MailContent {
            switch self {
            case let .content(message): return try await connection.content(of: message)
            case let .markRead(message): try await connection.markRead(message)
            case .markAllRead: try await connection.markAllRead()
            case let .archive(message): try await connection.archive(message)
            case let .trash(message): try await connection.trash(message)
            }
            return MailContent(html: nil, text: "")
        }

        func apply(to snapshot: inout MailInboxSnapshot) {
            switch self {
            case .content:
                break
            case .markAllRead:
                for index in snapshot.messages.indices { snapshot.messages[index].unread = false }
                snapshot.unread = 0
            case let .markRead(message):
                guard message.uidValidity == snapshot.validity,
                      let index = snapshot.messages.firstIndex(where: { $0.uid == message.uid }),
                      snapshot.messages[index].unread else { return }
                snapshot.messages[index].unread = false
                snapshot.unread = max(0, snapshot.unread - 1)
            case let .archive(message), let .trash(message):
                guard message.uidValidity == snapshot.validity,
                      let index = snapshot.messages.firstIndex(where: { $0.uid == message.uid }) else { return }
                if snapshot.messages.remove(at: index).unread {
                    snapshot.unread = max(0, snapshot.unread - 1)
                }
            }
        }
    }

    private struct PendingOperation {
        let id: UUID
        let operation: Operation
        let contentResult: CheckedContinuation<MailContent, Error>?
    }

    private final class AccountRun {
        var worker: Task<Void, Never>?
        var retryDelay: Task<Void, Never>?
        var connection: MailIMAP?
        var pending: [PendingOperation] = []
        var operationFailure: MailAccountStatus?
        var inFlight: UUID?
    }

    private(set) var accountsLoadFailed = false
    private var running = false
    private var runs: [String: AccountRun] = [:]
    private var snapshots: [String: MailInboxSnapshot] = [:]
    private var unreadByAccount: [String: Int] = [:]
    private var pendingSignIns: [String: MailIMAP] = [:]
    private var wakeObserver: NSObjectProtocol?
    private var observesWake = false
    private var runID: UUID?
    /// Only the shared service tracks the build (the checks inject their own credential closures and must not touch
    /// the user's defaults).
    private var keychainGate: MailKeychainGate?
    private var keychainPresenter: ((_ prompts: Int, _ proceed: @escaping @MainActor () -> Void) -> Void)?
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
                  keychainGate: store.gate)
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
        accounts = [snapshotAccount]
        status = [snapshotAccount.id: .paused]
    }

    init(accountsURL: URL, makeConnection: @escaping (MailProvider) -> MailIMAP,
         readCredential: @escaping @Sendable (String) throws -> String?,
         writeCredential: @escaping (String?, String) throws -> Void,
         readCurrentCredential: ((String) throws -> String?)? = nil, keychainGate: MailKeychainGate? = nil) {
        self.keychainGate = keychainGate
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
    func start(explainingKeychain present: @escaping (_ prompts: Int, _ proceed: @escaping @MainActor () -> Void) -> Void) {
        keychainPresenter = present
        let prompts = keychainGate?.expectedPrompts(for: accounts.filter(\.enabled).map(\.id)) ?? 0
        guard !running, prompts > 0 else { start(); return }
        awaitingKeychainNotice = true
        present(prompts) { [weak self] in self?.continueAfterKeychainNotice() }
    }

    /// Called when the explanation is dismissed, or from the flyout when the window went unnoticed behind others.
    func continueAfterKeychainNotice() {
        guard awaitingKeychainNotice else { return }
        awaitingKeychainNotice = false
        log("mail: Keychain explanation dismissed, starting sync")
        let waiting = accountsAwaitingNotice
        accountsAwaitingNotice.removeAll()
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
        for account in accounts { status[account.id] = .paused }
        publishInbox()
    }

    func refresh() {
        guard running else { return }
        for account in accounts where account.enabled {
            if let run = runs[account.id] {
                wake(run)
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
        if providerChanged { snapshots[id] = nil }
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
        publishInbox()
    }

    func body(of message: MailMessage) async throws -> String {
        try await content(of: message).text
    }

    func content(of message: MailMessage) async throws -> MailContent {
        let id = message.accountID
        guard accounts.contains(where: { $0.id == id && $0.enabled }), running else {
            throw MailFailure.unavailable
        }
        if runs[id] == nil { launch(id) }
        guard let run = runs[id] else { throw MailFailure.unavailable }

        let operationID = UUID()
        let message = currentValidity(for: message)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                run.pending.append(PendingOperation(id: operationID, operation: .content(message), contentResult: continuation))
                wake(run)
            }
        } onCancel: {
            Task { @MainActor in
                guard let index = run.pending.firstIndex(where: { $0.id == operationID }) else { return }
                run.pending.remove(at: index).contentResult?.resume(throwing: CancellationError())
            }
        }
    }

    func markRead(_ message: MailMessage) {
        enqueue(.markRead(currentValidity(for: message)), for: message.accountID)
    }

    func markAllRead(accountID: String?) {
        let id = accountID.map(Self.normalize)
        for account in accounts where account.enabled && (id == nil || account.id == id) {
            enqueue(.markAllRead, for: account.id)
        }
    }

    func canArchive(_ message: MailMessage) -> Bool {
        guard let snapshot = snapshots[message.accountID], snapshot.canArchive else { return false }
        return snapshot.messages.contains { $0.id == message.id }
    }

    func archive(_ message: MailMessage) {
        guard canArchive(message) else { return }
        enqueue(.archive(currentValidity(for: message)), for: message.accountID)
    }

    func trash(_ message: MailMessage) {
        enqueue(.trash(currentValidity(for: message)), for: message.accountID)
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

    private func enqueue(_ operation: Operation, for id: String) {
        guard running, accounts.contains(where: { $0.id == id && $0.enabled }) else { return }
        if runs[id] == nil { launch(id) }
        guard let run = runs[id] else { return }
        if case let .markRead(message) = operation, run.pending.contains(where: {
            if case let .markRead(queued) = $0.operation { return queued.id == message.id }
            return false
        }) { return }
        run.pending.append(PendingOperation(id: UUID(), operation: operation, contentResult: nil))
        wake(run)
    }

    private func wake(_ run: AccountRun) {
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
        guard let run = runs.removeValue(forKey: id) else { return }
        run.worker?.cancel()
        run.retryDelay?.cancel()
        run.connection?.close()
        failOperations(in: run, with: .unavailable)
    }

    private func monitor(_ id: String, run: AccountRun) async {
        var backoff = 2
        defer {
            run.worker = nil
            if runs[id] === run { runs[id] = nil }
        }
        while runs[id] === run && !Task.isCancelled {
            status[id] = .connecting
            guard let account = accounts.first(where: { $0.id == id }) else { return }
            let connection = makeConnection(account.provider)
            run.connection = connection
            var syncedAt: ContinuousClock.Instant?
            do {
                try await withTaskCancellationHandler {
                    defer { connection.close() }
                    try await signIn(id, on: connection)
                    while runs[id] === run && !Task.isCancelled {
                        try await performOperations(for: id, run: run, on: connection)
                        let snapshot = try await connection.synchronize(accountID: id)
                        guard runs[id] === run, !Task.isCancelled else { return }
                        let previous = snapshots[id]
                        snapshots[id] = snapshot
                        status[id] = run.operationFailure ?? .connected
                        if syncedAt == nil || previous?.messages.count != snapshot.messages.count || previous?.unread != snapshot.unread {
                            log("mail: \(logName(id)) synced messages=\(snapshot.messages.count) unread=\(snapshot.unread)")
                        }
                        if syncedAt == nil { syncedAt = .now }
                        publishInbox()
                        if run.pending.isEmpty {
                            try await connection.waitForInboxChange()
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
                if failure == .keychainNeedsNotice {
                    failOperations(in: run, with: .unavailable)
                    explainKeychainAgain(for: id)
                    return
                }
                log("mail: \(logName(id)) sync failed \(failure.logCode) retry=\(!failure.requiresUserAction)")
                status[id] = failure.status
                failOperations(in: run, with: failure, afterDisconnect: !failure.requiresUserAction)
                publishInbox()
                if failure.requiresUserAction { return }

                if let syncedAt, syncedAt.duration(to: .now) >= .seconds(60) { backoff = 2 }
                let wait = backoff
                let retry = Task { _ = try? await Task.sleep(for: .seconds(wait)) }
                run.retryDelay = retry
                await retry.value
                run.retryDelay = nil
                backoff = min(300, backoff * 2)
            }
        }
    }

    /// Account position only: the debug log never names the address.
    private func logName(_ id: String) -> String {
        "account[\(accounts.firstIndex { $0.id == id }.map(String.init) ?? "?")]"
    }

    private nonisolated func signIn(_ id: String, on connection: MailIMAP) async throws {
        let stored = try readCredential(id)
        guard let password = stored else { throw MailFailure.appPasswordRequired }
        try await connection.open(email: id, password: password)
    }

    private func performOperations(for id: String, run: AccountRun, on connection: MailIMAP) async throws {
        while runs[id] === run, let pending = run.pending.first {
            run.inFlight = pending.id
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
            }
            guard runs[id] === run, !Task.isCancelled else { return }
            run.inFlight = nil
            guard let index = run.pending.firstIndex(where: { $0.id == pending.id }) else { continue }

            run.pending.remove(at: index)
            switch result {
            case let .success(content):
                if pending.contentResult == nil { run.operationFailure = nil }
                if var snapshot = snapshots[id] {
                    pending.operation.apply(to: &snapshot)
                    snapshots[id] = snapshot
                }
                pending.contentResult?.resume(returning: content)
            case let .failure(error):
                if pending.contentResult == nil {
                    run.operationFailure = .operationFailed(error.localizedDescription)
                    status[id] = run.operationFailure
                }
                pending.contentResult?.resume(throwing: error)
            }
            publishInbox()
        }
    }

    private func failOperations(in run: AccountRun, with error: MailFailure, afterDisconnect: Bool = false) {
        defer { run.inFlight = nil }
        run.pending.removeAll { pending in
            // Repeating +Seen with the original UIDVALIDITY is safe after a lost acknowledgement.
            if afterDisconnect && pending.contentResult == nil {
                if case .markRead = pending.operation { return false }
                if run.inFlight != pending.id { return false }
                run.operationFailure = .operationFailed(tx("The connection was interrupted. Check the inbox before retrying the action.",
                                                           "Se interrumpió la conexión. Revisa Recibidos antes de repetir la acción."))
            }
            pending.contentResult?.resume(throwing: error)
            return true
        }
    }

    private func publishInbox() {
        var combined: [MailMessage] = []
        var counts: [String: Int] = [:]
        for account in accounts where account.enabled {
            guard let snapshot = snapshots[account.id] else { continue }
            combined.append(contentsOf: snapshot.messages)
            counts[account.id] = snapshot.unread
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
        if status == Exit.refused.rawValue { throw MailFailure.keychainRestart }
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
        if status > Exit.denied.rawValue || process.terminationReason != .exit {
            let text = String(decoding: message.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            log("mail: Keychain helper \(command) failed (\(status)): \(text)")
        }
        return (process.terminationReason == .exit ? status : -1, result)
    }
}

enum MailFailure: LocalizedError {
    case invalidEmail, invalidAppPassword, authenticationFailed, appPasswordRequired, blocked, offline, timedOut
    /// The Keychain helper refused this process, typically because Cala.app was replaced while this copy kept running.
    case keychainRestart
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
        case .authenticationFailed, .appPasswordRequired, .blocked, .keychainDenied, .keychainRestart, .keychainUnverified: return true
        default: return false
        }
    }

    var status: MailAccountStatus {
        let message = localizedDescription
        switch self {
        case .authenticationFailed, .appPasswordRequired, .keychainDenied: return .authFailed(message)
        case .blocked, .keychainRestart, .keychainUnverified: return .blocked(message)
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

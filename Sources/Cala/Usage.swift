import AppKit
import Foundation
import Combine
import CoreServices
import CryptoKit
import Darwin

struct UsageState: Identifiable {
    var provider: UsageProvider
    var id: String { provider.rawValue }
    var enabled = true
    var signedIn = false
    var didDetectSession = false
    var detection = tx("Checking…", "Comprobando…")
    var reading: UsageReading?
    var windowObservations: [String: UsageWindowObservation] = [:]
    var error: String?
    var plan: String?
    var fetching = false
    var cooldownUntil: Date?
    var available: Bool { enabled && signedIn }
    var orderedWindows: [UsageWindow] {
        (reading?.windows ?? []).enumerated().sorted { a, b in
            let lhs = a.element.presentationOrder, rhs = b.element.presentationOrder
            if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
            if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
            return a.offset < b.offset
        }.map(\.element)
    }
    func remaining(_ now: Date) -> Int? {
        guard let first = orderedWindows.first else { return nil }
        return Int((100 - first.effectiveUsed(now)).rounded())
    }

    mutating func acceptReading(_ reading: UsageReading, original: UsageReading?) {
        let observed = original ?? reading
        var observations = UsageWindowObservation.capture(observed, provider: provider)
        if original != nil {
            for window in reading.windows where observations[window.id] == nil {
                observations[window.id] = observation(for: window)
            }
        }
        self.reading = reading
        windowObservations = observations
    }

    func observation(for window: UsageWindow) -> UsageWindowObservation? {
        guard let reading else { return nil }
        return windowObservations[window.id] ?? .cached(window, in: reading, provider: provider)
    }
}

// Bounded, nonblocking stdout reader. Called only off-main; stderr is intentionally discarded.
// Every child is reaped, including a child that ignores SIGTERM.
enum UsageProcess {
    struct Result { var data: Data; var status: Int32; var timedOut: Bool }
    static func run(_ executable: String, _ args: [String], timeout: TimeInterval,
                    environment: [String: String]? = nil, rpc: Bool = false, cancel: ModuleCancellation? = nil) -> Result {
        guard cancel?.isCancelled != true else { return Result(data: Data(), status: -1, timedOut: false) }
        let p = Process(), output = Pipe(), input = Pipe()
        p.executableURL = URL(fileURLWithPath: executable); p.arguments = args
        p.environment = environment
        p.standardOutput = output; p.standardError = FileHandle.nullDevice
        p.standardInput = rpc ? input : FileHandle.nullDevice
        guard (try? p.run()) != nil else { return Result(data: Data(), status: -1, timedOut: false) }
        let fd = output.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        func send(_ object: [String: Any]) {
            if let data = try? JSONSerialization.data(withJSONObject: object) {
                try? input.fileHandleForWriting.write(contentsOf: data + Data([10]))
            }
        }
        if rpc { send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "cala", "title": "Cala", "version": "1.0"]]]) }
        var data = Data(), pending = Data(), reply = Data(), initialized = false
        let deadline = Date().addingTimeInterval(timeout)
        var complete = false
        while Date() < deadline && !complete && cancel?.isCancelled != true {
            var buffer = [UInt8](repeating: 0, count: 8192)
            let n = read(fd, &buffer, buffer.count)
            if n > 0 {
                let chunk = Data(buffer.prefix(n))
                if rpc {
                    pending.append(chunk)
                    while let end = pending.firstIndex(of: 10) {
                        let line = Data(pending[..<end]); pending.removeSubrange(...end)
                        guard let obj = UsageJSON.object(line), let id = obj["id"] as? Int else { continue }
                        if id == 1 && !initialized {
                            initialized = true
                            send(["method": "initialized"])
                            send(["id": 2, "method": "account/rateLimits/read", "params": ["excludeResetCreditDetails": true]])
                        } else if id == 2 { reply = line; complete = true; break }
                    }
                    if pending.count > 1_048_576 { break }
                } else {
                    data.append(chunk)
                    if data.count > 1_048_576 { break }
                }
            } else if n == 0 { break }
            else if errno != EAGAIN && errno != EINTR { break }
            else { Thread.sleep(forTimeInterval: 0.01) }
        }
        let timedOut = Date() >= deadline
        if !rpc && !timedOut && p.isRunning {
            let exitDeadline = Date().addingTimeInterval(0.1)
            while p.isRunning && Date() < exitDeadline { Thread.sleep(forTimeInterval: 0.005) }
        }
        if p.isRunning {
            p.terminate()
            let grace = Date().addingTimeInterval(0.25)
            while p.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.01) }
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
        p.waitUntilExit()
        try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close()
        return Result(data: rpc ? reply : data, status: p.terminationStatus, timedOut: timedOut)
    }
}

enum UsageCredentials {
    static let environmentMarker = "__CALA_ENV__"
    static func shellFields(_ data: Data) -> [String]? {
        let text = String(decoding: data, as: UTF8.self)
        guard let marker = text.range(of: environmentMarker, options: .backwards) else { return nil }
        let fields = text[marker.upperBound...].split(separator: "\0", omittingEmptySubsequences: false)
        guard fields.count >= 6 else { return nil } // Trailing NUL separates logout/profile output too.
        return fields.prefix(5).map(String.init)
    }
    static func fingerprint(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func accounts(_ user: String) -> [String] {
        let valid = !user.isEmpty && user.range(of: "^[a-zA-Z0-9._-]+$", options: .regularExpression) != nil
        return valid && user != "claude-code-user" ? [user, "claude-code-user"] : ["claude-code-user"]
    }
    static func services(custom: String, rawEnvironment: String?, secure: String?, directory: String, defaultDirectory: String) -> [String] {
        let base = "Claude Code-credentials"
        var candidates: [String] = []
        func add(_ value: String) { if !candidates.contains(value) { candidates.append(value) } }
        func hashed(_ value: String) -> String { base + "-" + fingerprint(value.precomposedStringWithCanonicalMapping).prefix(8) }
        let custom = custom.trimmingCharacters(in: .whitespacesAndNewlines)
        let isDefault = directory.precomposedStringWithCanonicalMapping == defaultDirectory.precomposedStringWithCanonicalMapping
        if !custom.isEmpty {
            if isDefault { return [base] }
            add(hashed(custom)); add(hashed(directory))
        } else if let secure, !secure.isEmpty {
            add(hashed(secure)); add(hashed((secure as NSString).standardizingPath))
        } else if let rawEnvironment, !rawEnvironment.isEmpty {
            add(hashed(rawEnvironment)); add(hashed(directory))
        }
        let nothingExplicit = custom.isEmpty && (rawEnvironment ?? "").isEmpty && (secure ?? "").isEmpty
        if isDefault || nothingExplicit { add(base) }
        return candidates
    }
}

// Deny redirects for both bearer-authenticated HTTP integrations.
final class UsageNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

// FSEvents watches trees without opening a descriptor per session directory. Queue confined.
final class UsageWatcher {
    private static let failureLock = NSLock()
    private static var startFailureLogged = false
    private static func reportStartFailure() {
        failureLock.lock()
        let shouldLog = !startFailureLogged
        startFailureLogged = true
        failureLock.unlock()
        if shouldLog { log("usage: FSEvents failed to start; local Codex session events unavailable") }
    }
    static func resolvedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
    private var stream: FSEventStreamRef?
    private let changed: ([String]) -> Void
    init(paths: [String], queue: DispatchQueue, changed: @escaping ([String]) -> Void) {
        self.changed = changed
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        stream = FSEventStreamCreate(nil, { _, info, _, paths, _, _ in
            guard let info else { return }
            let events = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            Unmanaged<UsageWatcher>.fromOpaque(info).takeUnretainedValue().changed(events)
        }, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1,
        FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            if !FSEventStreamStart(stream) { Self.reportStartFailure() }
        }
    }
    deinit { if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) } }
}

// Watch the exact Claude file descriptor, rearming after atomic replacement. A missing
// file is retried by cheap maintenance checks, without subscribing to the support directory.
final class UsageFileWatcher {
    private let path: String
    private let queue: DispatchQueue
    private let changed: () -> Void
    private let descriptors: DispatchGroup
    private var source: DispatchSourceFileSystemObject?
    init(path: String, queue: DispatchQueue, descriptors: DispatchGroup, changed: @escaping () -> Void) {
        self.path = path; self.queue = queue; self.descriptors = descriptors; self.changed = changed
        refresh()
    }
    func refresh(notify: Bool = true) {
        guard source == nil else { return }
        let fd = open(path, O_EVTONLY | O_CLOEXEC)
        guard fd >= 0 else { return }
        let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename, .revoke], queue: queue)
        source = watcher
        descriptors.enter()
        watcher.setCancelHandler { [descriptors] in
            close(fd)
            descriptors.leave()
        }
        watcher.setEventHandler { [weak self] in
            guard let self, let source = self.source else { return }
            if !source.data.intersection([.delete, .rename, .revoke]).isEmpty {
                source.cancel(); self.source = nil; self.refresh(notify: false)
            }
            self.changed()
        }
        watcher.resume()
        if notify { changed() }
    }
    deinit { source?.cancel() }
}

enum UsageQuotaEvent {
    case observations([QuotaObservation])
    case discontinuity
    case importUpdated
}

final class UsageService: ObservableObject {
    static let shared = UsageService()
    @Published private(set) var providers = UsageProvider.allCases.map { UsageState(provider: $0) }
    @Published private(set) var statusLineMessage = ""
    private let queue = DispatchQueue(label: "local.cala.usage", qos: .utility)
    // Keep resource teardown independent of credential subprocesses and file reads on the service queue.
    private let resourceQueue = DispatchQueue(label: "local.cala.usage.resources", qos: .utility)
    private let fileDescriptors = DispatchGroup()
    private var states = UsageProvider.allCases.map { UsageState(provider: $0) }
    private var config = Config()
    private var subscription: AnyCancellable?
    // Accessed only on resourceQueue.
    private var timer: DispatchSourceTimer?
    private var codexWatcher: UsageWatcher?
    private var watchedCodexPath: String?
    private var claudeWatcher: UsageFileWatcher?
    private var environment: [String: String] = [:]
    private var shellLoaded = false
    private var claudeDir = "", codexHome = "", executable: String?
    private var services = ["Claude Code-credentials"]
    private var lastDetection = Date.distantPast
    private var nextPeriodic = Date.distantPast
    private var failures: [UsageProvider: Int] = [:]
    private var errorCounts: [UsageProvider: Int] = [:]
    private var retryNotBefore: [UsageProvider: Date] = [:]
    private var blockedClaudeStamp: CredentialStamp?
    private var knownClaudeStamp: CredentialStamp?
    private var lastCredentialCheck = Date.distantPast
    private var lastAttempt: [UsageProvider: Date] = [:]
    private var consumedResets = Set<String>()
    private var visible = false
    // These two are accessed only by the main-thread visibility hook.
    private var mainVisible = false, mainAlwaysVisible = false
    private var mainRun: ModuleCancellation?
    private var run: ModuleCancellation? // service queue only
    private var generations: [UsageProvider: Int] = [:]
    private var active = Set<UsageProvider>()
    private var refreshAfterDetection = false
    private let support = AppPaths.supportDirectory
    private let quotaHistory = UsageQuotaHistory(directory: AppPaths.supportDirectory.appendingPathComponent("usage-forecast-v1"),
                                                report: { log($0) })
    private var quotaLogins: [UsageProvider: QuotaLogin] = [:]
    private var quotaAccounts: [UsageProvider: QuotaAccount] = [:]
    private var quotaLocalSince: [UsageProvider: Date] = [:]
    private var quotaWakeObservers: [NSObjectProtocol] = []
    private var asleep = false
    private var lastQuotaWake = Date.distantPast
    private var quotaEpoch = 0
    private var quotaContext: [UsageProvider: Set<QuotaSeries>] = [:]
    private struct BackfillJob {
        let key: QuotaImportKey
        let cancel: ModuleCancellation
        let scanner: UsageCodexBackfill
    }
    private var backfill: BackfillJob?
    private let quotaFeed = PassthroughSubject<UsageQuotaEvent, Never>()
    var quotaEvents: AnyPublisher<UsageQuotaEvent, Never> { quotaFeed.eraseToAnyPublisher() }

    /// The next wave can take an immutable history snapshot from its forecast worker.
    func quotaHistorySnapshot() -> QuotaHistorySnapshot { quotaHistory.snapshot() }

    private func index(_ p: UsageProvider) -> Int { p == .claude ? 0 : 1 }
    private func publish() {
        let copy = states
        let run = run
        DispatchQueue.main.async {
            guard let run, self.mainRun === run else { return }
            self.providers = copy
        }
    }

    private func message(_ message: String) {
        let run = run
        DispatchQueue.main.async {
            guard self.mainRun === run else { return }
            self.statusLineMessage = message
        }
    }

    func start(store: ConfigStore, visible: Bool) {
        guard mainRun == nil else { return }
        let run = ModuleCancellation()
        mainRun = run
        let workspace = NSWorkspace.shared.notificationCenter
        quotaWakeObservers = [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification].map { name in
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.workspacePowerChanged(asleep: name == NSWorkspace.willSleepNotification, run: run)
            }
        }
        let alwaysVisible = !store.config.autoHide
        mainVisible = visible; mainAlwaysVisible = alwaysVisible
        resourceQueue.sync {
            let timer = DispatchSource.makeTimerSource(queue: resourceQueue)
            timer.schedule(deadline: .now() + 5, repeating: 5)
            timer.setEventHandler { [weak self] in
                self?.queue.async { [weak self] in
                    guard !run.isCancelled else { return }
                    self?.maintenance()
                }
            }
            self.timer = timer; timer.resume()
        }
        queue.async {
            guard !run.isCancelled else { return }
            self.run = run
            self.asleep = false
            self.visible = visible
            self.lastDetection = .distantPast
        }
        subscription = store.$config.removeDuplicates().sink { [weak self] config in
            self?.queue.async {
                guard !run.isCancelled else { return }
                self?.configure(config)
            }
        }
    }

    func stop() {
        guard let run = mainRun else { return }
        mainRun = nil
        run.cancel()
        for observer in quotaWakeObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        quotaWakeObservers.removeAll()
        let stoppedAt = Date()
        // Order the final flush after this run's service work and before a subsequent start.
        queue.async {
            self.quotaHistory.breakCoverage(at: stoppedAt, allowsQuiet: true, flush: true)
            guard self.run === run else { return }
            self.run = nil
            self.cancelBackfill()
            self.visible = false
            self.nextPeriodic = .distantPast
            for provider in self.active {
                self.lastAttempt[provider] = nil
                self.states[self.index(provider)].fetching = false
            }
            self.active.removeAll()
        }
        quotaFeed.send(.discontinuity)
        subscription?.cancel()
        subscription = nil
        resourceQueue.sync {
            timer?.cancel()
            timer = nil
            codexWatcher = nil
            watchedCodexPath = nil
            claudeWatcher = nil
        }
        fileDescriptors.wait()
        mainVisible = false; mainAlwaysVisible = false
        providers = providers.map { provider in
            var provider = provider
            provider.fetching = false
            provider.didDetectSession = false
            return provider
        }
    }
    func setStatusLineEnabled(_ enabled: Bool, store: ConfigStore) {
        store.config.usageClaudeStatusLine = enabled
        // Also queue removal explicitly: stopping the tray can cancel an update queued by the live subscription.
        if !enabled {
            let config = store.config
            queue.async { self.reconcileDisabledStatusLine(config: config) }
        }
    }

    /// Finishes an interrupted opt-out even if the tray stays off after relaunch.
    func finishStatusLineCleanup(config: Config) {
        guard config.usageClaudeStatusLine == false else { return }
        queue.async { self.reconcileDisabledStatusLine(config: config) }
    }

    /// Complete cleanup before the uninstaller removes the script or the recorded directory.
    func removeStatusLineNow(config: Config) throws {
        try queue.sync {
            let installationExpected = config.usageClaudeStatusLine == true || statusLine.hasInstallationEvidence
            _ = try statusLine.reconcile(enabled: false, directory: statusLineDirectory(config),
                                         previousDirectory: previousStatusLineDirectory,
                                         requireReadableCandidates: installationExpected)
        }
        stop()
    }

    private func statusLineDirectory(_ config: Config) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return folder(config.usageClaudeConfigDir, "CLAUDE_CONFIG_DIR",
                      ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? home + "/.claude")
    }

    private func reconcileDisabledStatusLine(config: Config) {
        reconcileStatusLine(preference: config.usageClaudeStatusLine, directory: statusLineDirectory(config))
    }

    func settingsOpened() {
        guard let run = mainRun else { return }
        queue.async {
            guard !run.isCancelled else { return }
            self.detect(force: true); self.publish()
        }
    }
    func refresh(_ provider: UsageProvider? = nil, force: Bool = false) {
        guard let run = mainRun else { return }
        queue.async {
            guard !run.isCancelled, !self.asleep else { return }
            if provider == nil && !force && Date().timeIntervalSince(self.lastQuotaWake) < 1 { return }
            self.detect(force: false)
            for p in provider.map({ [$0] }) ?? UsageProvider.allCases { self.fetch(p, force: force) }
        }
    }
    func visibility(visible: Bool, alwaysVisible: Bool) {
        guard let run = mainRun, mainVisible != visible || mainAlwaysVisible != alwaysVisible else { return }
        let revealed = visible && !mainVisible
        mainVisible = visible; mainAlwaysVisible = alwaysVisible
        queue.async {
            guard !run.isCancelled else { return }
            self.visible = visible
            if revealed { for p in UsageProvider.allCases { self.fetch(p, force: false) } }
        }
    }
    private func configure(_ new: Config) {
        guard let run, !run.isCancelled else { return }
        let first = !shellLoaded
        let reconcileIntegration = lastDetection == .distantPast
            || new.usageClaudeStatusLine != config.usageClaudeStatusLine
            || new.usageClaudeConfigDir != config.usageClaudeConfigDir
        if lastDetection != .distantPast && shellLoaded && new.usageEnabled == config.usageEnabled && new.usageClaudeEnabled == config.usageClaudeEnabled && new.usageCodexEnabled == config.usageCodexEnabled && new.usageClaudeConfigDir == config.usageClaudeConfigDir && new.usageCodexHome == config.usageCodexHome && new.usageClaudeStatusLine == config.usageClaudeStatusLine {
            config = new; return
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let changedProviders = UsageProvider.allCases.filter {
            $0 == .claude ? folder(new.usageClaudeConfigDir, "CLAUDE_CONFIG_DIR", home + "/.claude") != claudeDir : folder(new.usageCodexHome, "CODEX_HOME", home + "/.codex") != codexHome
        }
        let enabled = new.usageEnabled && (!config.usageEnabled || (new.usageClaudeEnabled && !config.usageClaudeEnabled) || (new.usageCodexEnabled && !config.usageCodexEnabled))
        config = new
        if !shellLoaded {
            loadLoginEnvironment(cancel: run)
            guard !run.isCancelled else { return }
            loadCache()
            refreshAfterDetection = true
        }
        if !first && !changedProviders.isEmpty {
            for p in changedProviders {
                if let old = quotaLogins.removeValue(forKey: p) { quotaHistory.deactivate(old, at: Date()) }
                quotaLocalSince[p] = Date()
                quotaContext[p] = nil
                if p == .codex { cancelBackfill() }
                let i = index(p), cooldown = states[index(p)].cooldownUntil
                generations[p] = (generations[p] ?? 0) + 1
                states[i] = UsageState(provider: p)
                states[i].cooldownUntil = cooldown
                states[i].fetching = active.contains(p)
                errorCounts[p] = 0; retryNotBefore[p] = nil
                if p == .claude { blockedClaudeStamp = nil; knownClaudeStamp = nil }
            }
            consumedResets.removeAll()
            refreshAfterDetection = true
        }
        if reconcileIntegration {
            let directory = folder(config.usageClaudeConfigDir, "CLAUDE_CONFIG_DIR", home + "/.claude")
            reconcileStatusLine(preference: config.usageClaudeStatusLine, directory: directory)
        }
        guard !run.isCancelled else { return }
        detect(force: true)
        guard !run.isCancelled else { return }
        if enabled || refreshAfterDetection {
            refreshAfterDetection = false
            if visible || !config.autoHide { for p in UsageProvider.allCases { fetch(p, force: false) } }
        }
        publish()
    }
    private func loadLoginEnvironment(cancel: ModuleCancellation? = nil) {
        // One bounded login-shell invocation, even for GUI launches with an incomplete environment.
        let command = "printf '__CALA_ENV__%s\\0%s\\0%s\\0%s\\0%s\\0' \"$CLAUDE_CONFIG_DIR\" \"$CODEX_HOME\" \"$PATH\" \"$CLAUDE_SECURESTORAGE_CONFIG_DIR\" \"${CLAUDE_SECURESTORAGE_CONFIG_DIR+x}\""
        let r = UsageProcess.run("/bin/zsh", ["-lc", command], timeout: 3, cancel: cancel)
        guard cancel?.isCancelled != true else { return }
        if !r.timedOut, let fields = UsageCredentials.shellFields(r.data) {
            for (key, value) in zip(["CLAUDE_CONFIG_DIR", "CODEX_HOME", "PATH", "CLAUDE_SECURESTORAGE_CONFIG_DIR", "SECURE_STORAGE_SET"], fields) { environment[key] = value }
        }
        shellLoaded = true
    }

    private func folder(_ custom: String, _ env: String, _ fallback: String) -> String {
        let raw = custom.trimmingCharacters(in: .whitespacesAndNewlines)
        let chosen = raw.isEmpty ? (environment[env].flatMap { $0.isEmpty ? nil : $0 } ?? fallback) : raw
        let expanded = (chosen as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, relativeTo: FileManager.default.homeDirectoryForCurrentUser).standardizedFileURL.path.precomposedStringWithCanonicalMapping
    }
    private func detect(force: Bool) {
        guard let run, !run.isCancelled, shellLoaded, force || Date().timeIntervalSince(lastDetection) >= 300 else { return }
        lastDetection = Date()
        let fm = FileManager.default, home = fm.homeDirectoryForCurrentUser.path
        claudeDir = folder(config.usageClaudeConfigDir, "CLAUDE_CONFIG_DIR", home + "/.claude")
        codexHome = folder(config.usageCodexHome, "CODEX_HOME", home + "/.codex")
        services = UsageCredentials.services(custom: config.usageClaudeConfigDir, rawEnvironment: environment["CLAUDE_CONFIG_DIR"],
                                             secure: environment["SECURE_STORAGE_SET"] == "x" ? environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"] : nil,
                                             directory: claudeDir, defaultDirectory: home + "/.claude")
        states[0].enabled = config.usageEnabled && config.usageClaudeEnabled
        let credential = states[0].enabled ? Self.readClaudeCredential(directory: claudeDir, services: services, cancel: run) : nil
        guard !run.isCancelled else { return }
        if states[0].enabled { observeCredential(credential) }
        let foundClaude = credential != nil || fm.fileExists(atPath: claudeDir) || findExecutable("claude") != nil || fm.fileExists(atPath: "/Applications/Claude.app") || fm.fileExists(atPath: home + "/Applications/Claude.app")
        states[0].didDetectSession = states[0].enabled
        states[0].signedIn = credential != nil
        states[0].plan = credential?.plan
        if let credential, credential.expired { states[0].detection = tx("Session expired — open Claude Code to refresh", "Sesión caducada: abre Claude Code para renovarla") }
        else { states[0].detection = credential != nil ? tx("Detected, signed in", "Detectado, con sesión iniciada") : (foundClaude ? tx("Found but not signed in — run `claude` and /login", "Encontrado, pero sin sesión: ejecuta `claude` y /login") : tx("Claude Code not found — install Claude Code (CLI or app) and sign in to enable", "No se encontró Claude Code: instálalo (CLI o app) e inicia sesión para activarlo")) }
        if !states[0].enabled { states[0].detection = tx("Usage disabled", "Uso desactivado") }
        else if blockedClaudeStamp != nil && blockedClaudeStamp == knownClaudeStamp { states[0].detection = tx("Session expired — open Claude Code to refresh", "Sesión caducada: abre Claude Code para renovarla") }
        executable = codexExecutable()
        states[1].enabled = config.usageEnabled && config.usageCodexEnabled
        let auth = states[1].enabled && fm.fileExists(atPath: codexHome + "/auth.json")
        states[1].didDetectSession = states[1].enabled
        states[1].signedIn = auth
        states[1].detection = auth ? tx("Detected, signed in", "Detectado, con sesión iniciada") : (executable != nil ? tx("Found but not signed in — open Codex and sign in with ChatGPT", "Encontrado, pero sin sesión: abre Codex e inicia sesión con ChatGPT") : tx("Codex not found — install Codex CLI or app and sign in with ChatGPT", "No se encontró Codex: instala la CLI o la app e inicia sesión con ChatGPT"))
        if !states[1].enabled { states[1].detection = tx("Usage disabled", "Uso desactivado") }
        for provider in UsageProvider.allCases {
            updateQuotaLogin(provider, signedIn: states[index(provider)].signedIn)
        }
        let codexPath = UsageWatcher.resolvedPath(codexHome + "/sessions")
        let claudePath = states[0].enabled && config.usageClaudeStatusLine == true
            ? support.appendingPathComponent("claude-usage.json").path : nil
        updateWatchers(codexPath: codexPath, claudePath: claudePath, run: run)
        readLocal(); publish()
    }

    private func updateWatchers(codexPath: String, claudePath: String?, run: ModuleCancellation) {
        resourceQueue.async { [weak self] in
            guard let self, !run.isCancelled else { return }
            if self.watchedCodexPath != codexPath {
                self.codexWatcher = UsageWatcher(paths: [codexPath], queue: self.resourceQueue) { [weak self] paths in
                    self?.enqueueLocalEvents(paths, run: run)
                }
                self.watchedCodexPath = codexPath
            }
            if let claudePath {
                if self.claudeWatcher == nil {
                    self.claudeWatcher = UsageFileWatcher(path: claudePath, queue: self.resourceQueue,
                                                          descriptors: self.fileDescriptors) { [weak self] in
                        self?.enqueueLocalEvents([claudePath], run: run)
                    }
                }
                self.claudeWatcher?.refresh()
            } else {
                self.claudeWatcher = nil
            }
        }
    }

    private func enqueueLocalEvents(_ paths: [String], run: ModuleCancellation) {
        queue.async { [weak self] in
            guard !run.isCancelled else { return }
            self?.localEvents(paths)
        }
    }

    private struct CredentialStamp: Equatable { var fingerprint: String?; var expiresAt: Double? }
    private struct Credential {
        var token: String; var plan: String?; var expiresAt: Double?
        var expired: Bool { expiresAt.map { $0 / 1000 <= Date().timeIntervalSince1970 } ?? false }
        var stamp: CredentialStamp { CredentialStamp(fingerprint: UsageCredentials.fingerprint(token), expiresAt: expiresAt) }
    }
    private func observeCredential(_ credential: Credential?) {
        knownClaudeStamp = credential?.stamp ?? CredentialStamp()
        lastCredentialCheck = Date()
        if let blockedClaudeStamp, blockedClaudeStamp != knownClaudeStamp {
            self.blockedClaudeStamp = nil; errorCounts[.claude] = 0; retryNotBefore[.claude] = nil
        }
    }
    private static func readClaudeCredential(directory: String, services: [String], cancel: ModuleCancellation) -> Credential? {
        func parse(_ object: [String: Any]?) -> Credential? {
            guard let oauth = object?["claudeAiOauth"] as? [String: Any], let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
            return Credential(token: token, plan: oauth["rateLimitTier"] as? String ?? oauth["subscriptionType"] as? String, expiresAt: UsageJSON.number(oauth["expiresAt"]))
        }
        for service in services {
            for account in UsageCredentials.accounts(NSUserName()) {
                guard !cancel.isCancelled else { return nil }
                let result = UsageProcess.run("/usr/bin/security", ["find-generic-password", "-s", service, "-a", account, "-w"], timeout: 3, cancel: cancel)
                if result.status == 0, let credential = parse(UsageJSON.object(result.data)) { return credential }
            }
        }
        return cancel.isCancelled ? nil : parse(readJSON(URL(fileURLWithPath: directory + "/.credentials.json")))
    }
    private func findExecutable(_ name: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dirs = [home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", home + "/.npm-global/bin"] + (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return dirs.map { $0 + "/" + name }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    private func codexExecutable() -> String? {
        let fm = FileManager.default, home = fm.homeDirectoryForCurrentUser.path
        let releases = URL(fileURLWithPath: codexHome + "/packages/standalone/releases")
        let versions = ((try? fm.contentsOfDirectory(at: releases, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []).sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
        let candidates = versions.map { $0.appendingPathComponent("bin/codex").path } + [findExecutable("codex") ?? "", home + "/.npm-global/lib/node_modules/@openai/codex/bin/codex.js", "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex", "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex.js", "/usr/local/lib/node_modules/@openai/codex/bin/codex.js", "/Applications/Codex.app/Contents/Resources/codex", home + "/Applications/Codex.app/Contents/Resources/codex"]
        return candidates.first { !$0.isEmpty && fm.isExecutableFile(atPath: $0) }
    }
    private func maintenance() {
        guard let run, !run.isCancelled, !asleep else { return }
        resourceQueue.async { [weak self] in
            if !run.isCancelled { self?.claudeWatcher?.refresh() }
        }
        detect(force: false)
        let now = Date()
        for state in states where visible && state.available {
            for w in state.reading?.windows ?? [] where w.isResetting(now) {
                let key = state.id + w.id + String(w.resetsAt?.timeIntervalSince1970 ?? 0)
                if !consumedResets.contains(key), canFetch(state.provider, force: false) {
                    consumedResets.insert(key); fetch(state.provider, force: false)
                }
            }
        }
        if config.usageEnabled && now >= nextPeriodic {
            nextPeriodic = now.addingTimeInterval(900 + Double.random(in: 0...90))
            for p in UsageProvider.allCases { fetch(p, force: false, scheduled: true) }
        }
    }
    private func canFetch(_ p: UsageProvider, force: Bool) -> Bool {
        let s = states[index(p)], now = Date()
        guard !asleep, s.available, !s.fetching, !active.contains(p), (s.cooldownUntil ?? .distantPast) <= now else { return false }
        if p == .claude, let blockedClaudeStamp, blockedClaudeStamp == knownClaudeStamp { return false }
        if force {
            return (errorCounts[p] ?? 0) == 0 || now.timeIntervalSince(lastAttempt[p] ?? .distantPast) >= 15
        }
        let sourceDate = p == .claude ? s.reading?.apiDate : s.reading?.date
        return (retryNotBefore[p] ?? .distantPast) <= now && now.timeIntervalSince(sourceDate ?? .distantPast) >= p.interval && now.timeIntervalSince(lastAttempt[p] ?? .distantPast) >= p.interval
    }
    private static func failureDelay(_ count: Int) -> TimeInterval { min(1800, 120 * pow(2, Double(max(0, min(count, 4))))) }
    private func recordOutcome(_ result: FetchResult, provider p: UsageProvider, captureQuota: Bool, scheduled: Bool) {
        let i = index(p)
        if result.skipped { return }
        if result.status == 429 {
            let count = failures[p] ?? 0
            let delay = min(1800, max(60, result.retryAfter, 60 * pow(2, Double(min(count, 5)))))
            failures[p] = count + 1; states[i].cooldownUntil = Date().addingTimeInterval(delay)
        } else if result.status == 200, let reading = result.reading {
            failures[p] = 0; states[i].cooldownUntil = nil
            errorCounts[p] = 0; retryNotBefore[p] = nil
            if p == .claude { blockedClaudeStamp = nil }
            accept(reading, provider: p, source: captureQuota ? .api : nil)
        } else {
            let count = errorCounts[p] ?? 0
            retryNotBefore[p] = Date().addingTimeInterval(Self.failureDelay(count))
            errorCounts[p] = min(30, count + 1)
            if p == .claude && result.expired && !scheduled {
                knownClaudeStamp = result.credentialStamp ?? CredentialStamp()
                blockedClaudeStamp = knownClaudeStamp
            }
        }
        saveCache()
    }
    private struct FetchResult {
        var reading: UsageReading?
        var status = 0
        var error: String?
        var retryAfter: TimeInterval = 0
        var expired = false
        var credentialStamp: CredentialStamp?
        var skipped = false
    }
    private func fetch(_ p: UsageProvider, force: Bool, scheduled: Bool = false) {
        guard let run, !run.isCancelled, !asleep else { return }
        if scheduled, p == .claude, knownClaudeStamp?.expiresAt.map({ $0 / 1_000 <= Date().timeIntervalSince1970 }) == true { return }
        if p == .claude, states[0].available, blockedClaudeStamp != nil, !active.contains(p), Date().timeIntervalSince(lastCredentialCheck) >= 15 {
            observeCredential(Self.readClaudeCredential(directory: claudeDir, services: services, cancel: run))
        }
        guard !run.isCancelled, canFetch(p, force: force) else { return }
        let i = index(p), started = Date(), currentGeneration = generations[p] ?? 0
        let login = quotaLogins[p], epoch = quotaEpoch
        active.insert(p)
        states[i].fetching = true; lastAttempt[p] = started; publish()
        // Capture paths on the service queue. The independent worker never touches mutable service state.
        let dir = claudeDir, home = codexHome, exe = executable, keychainServices = services, claudeExe = findExecutable("claude")
        var env = ProcessInfo.processInfo.environment
        env["CODEX_HOME"] = home
        if let path = environment["PATH"], !path.isEmpty { env["PATH"] = path }
        let processEnvironment = env
        DispatchQueue.global(qos: .utility).async {
            let result: FetchResult
            if p == .claude {
                let renew: (() -> Void)? = scheduled ? nil : claudeExe.map { exe in
                    { Self.renewClaudeCredential(executable: exe, environment: processEnvironment, cancel: run) }
                }
                result = Self.fetchClaude(directory: dir, services: keychainServices, cancel: run, renew: renew, scheduled: scheduled)
            }
            else { result = Self.fetchCodex(home: home, executable: exe, environment: processEnvironment, cancel: run) }
            self.queue.async {
                guard self.run === run, !run.isCancelled else { return }
                self.active.remove(p)
                self.states[i].fetching = false
                guard currentGeneration == (self.generations[p] ?? 0) else { self.publish(); self.fetch(p, force: false); return }
                if result.skipped {
                    self.lastAttempt[p] = nil
                    self.publish()
                    return
                }
                if result.reading != nil { self.updateQuotaLogin(p, signedIn: self.states[i].signedIn) }
                self.states[i].error = result.error
                self.recordOutcome(result, provider: p, captureQuota: login?.profile == self.quotaLogins[p]?.profile
                                   && epoch == self.quotaEpoch && !self.asleep, scheduled: scheduled)
                if result.expired { self.states[i].detection = p == .claude ? tx("Session expired — open Claude Code to refresh", "Sesión caducada: abre Claude Code para renovarla") : tx("Session expired — open Codex to refresh", "Sesión caducada: abre Codex para renovarla") }
                let cooldown = max(0, self.states[i].cooldownUntil?.timeIntervalSinceNow ?? 0)
                log("usage: \(p.rawValue) fetch status=\(result.status) duration=\(Int(Date().timeIntervalSince(started) * 1000))ms cooldown=\(Int(cooldown))s outcome=\(result.reading == nil ? "unavailable" : "ok")")
                self.publish()
            }
        }
    }
    private static func http(_ address: String, headers: [String: String], cancel: ModuleCancellation) -> (Data, HTTPURLResponse?) {
        guard !cancel.isCancelled, let url = URL(string: address) else { return (Data(), nil) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10; configuration.timeoutIntervalForResource = 10
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: UsageNoRedirect(), delegateQueue: nil)
        var request = URLRequest(url: url); request.allHTTPHeaderFields = headers
        final class Response: @unchecked Sendable { var data = Data(); var response: HTTPURLResponse? }
        let output = Response(), semaphore = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { data, response, _ in
            output.data = data ?? Data(); output.response = response as? HTTPURLResponse; semaphore.signal()
        }
        task.resume()
        defer { session.invalidateAndCancel() }
        let deadline = DispatchTime.now() + 11
        while !cancel.isCancelled, DispatchTime.now() < deadline {
            if semaphore.wait(timeout: min(deadline, .now() + .milliseconds(100))) == .success {
                return (output.data, output.response)
            }
        }
        return (Data(), nil)
    }
    private static func retryAfter(_ response: HTTPURLResponse?) -> TimeInterval {
        guard let s = response?.value(forHTTPHeaderField: "Retry-After") else { return 0 }
        if let n = Double(s), n.isFinite { return n }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f.date(from: s)?.timeIntervalSinceNow ?? 0
    }
    /// Claude Code's access token lasts about 8 hours and only Claude Code renews it. When nobody has used it
    /// for a while the token sits expired, so ask Claude Code itself for one tiny non-interactive turn (it
    /// renews and stores its own credentials; Cala never touches the refresh token) and read the credential again.
    private static func renewClaudeCredential(executable: String, environment: [String: String], cancel: ModuleCancellation) {
        let r = UsageProcess.run(executable, ["-p", "ok", "--model", "haiku", "--max-turns", "1", "--tools", ""], timeout: 60, environment: environment, cancel: cancel)
        guard !cancel.isCancelled else { return }
        log("usage: claude token renewed via Claude Code status=\(r.status) timedOut=\(r.timedOut)")
    }
    private static func fetchClaude(directory: String, services: [String], cancel: ModuleCancellation, credentialReader: (() -> Credential?)? = nil,
                                    transport: ((String, [String: String]) -> (Data, HTTPURLResponse?))? = nil,
                                    renew: (() -> Void)? = nil, scheduled: Bool = false) -> FetchResult {
        let read = credentialReader ?? { readClaudeCredential(directory: directory, services: services, cancel: cancel) }
        let send = transport ?? { http($0, headers: $1, cancel: cancel) }
        var credential = read()
        if scheduled && (credential == nil || credential?.expired == true) { return FetchResult(skipped: true) }
        if let renew, credential?.expired == true { renew(); credential = read() }
        for attempt in 0...1 {
            guard !cancel.isCancelled else { return FetchResult() }
            guard let current = credential, !current.expired else {
                return FetchResult(status: 401, error: tx("Session expired — open Claude Code to refresh", "Sesión caducada: abre Claude Code para renovarla"), expired: true, credentialStamp: credential?.stamp ?? CredentialStamp())
            }
            let (data, response) = send("https://api.anthropic.com/api/oauth/usage", ["Authorization": "Bearer " + current.token, "anthropic-beta": "oauth-2025-04-20", "Accept": "application/json"])
            let status = response?.statusCode ?? 0
            if status == 401 && attempt == 0 {
                let reread = read()
                if let reread, reread.token != current.token { credential = reread; continue }
                return FetchResult(status: 401, error: tx("Session expired — open Claude Code to refresh", "Sesión caducada: abre Claude Code para renovarla"), expired: true, credentialStamp: reread?.stamp ?? CredentialStamp())
            }
            if status == 429 { return FetchResult(status: status, error: tx("Rate-limited", "Límite de uso alcanzado"), retryAfter: retryAfter(response)) }
            guard status == 200, let obj = UsageJSON.object(data) else {
                return FetchResult(status: status, error: status == 401 ? tx("Session expired — open Claude Code to refresh", "Sesión caducada: abre Claude Code para renovarla") : tx("n/a — usage unavailable", "n/d: uso no disponible"), expired: status == 401, credentialStamp: current.stamp)
            }
            var reading = UsageJSON.claude(obj, at: Date())
            reading.plan = current.plan
            return FetchResult(reading: reading, status: status, error: reading.windows.isEmpty ? tx("n/a — unrecognized usage data", "n/d: datos de uso no reconocidos") : nil)
        }
        return FetchResult(error: "n/a")
    }
    private static func fetchCodex(home: String, executable: String?, environment: [String: String], cancel: ModuleCancellation) -> FetchResult {
        guard !cancel.isCancelled else { return FetchResult() }
        if let executable {
            let result = UsageProcess.run(executable, ["app-server"], timeout: 10, environment: environment, rpc: true, cancel: cancel)
            guard let obj = UsageJSON.object(result.data) else { return FetchResult(error: result.timedOut ? tx("n/a — Codex timed out", "n/d: Codex tardó demasiado") : tx("n/a — Codex unavailable", "n/d: Codex no disponible")) }
            if let error = obj["error"] as? [String: Any] {
                // Inspect the message for classification, never publish or log arbitrary server text.
                let text = (error["message"] as? String ?? "").lowercased()
                let rateLimited = text.contains("429") || text.contains("rate limit")
                let expired = text.contains("unauthorized") || text.contains("not logged") || text.contains("401")
                return FetchResult(status: rateLimited ? 429 : (expired ? 401 : -1), error: rateLimited ? tx("Rate-limited", "Límite de uso alcanzado") : (expired ? tx("Session expired — open Codex to refresh", "Sesión caducada: abre Codex para renovarla") : tx("n/a — Codex unavailable", "n/d: Codex no disponible")), expired: expired)
            }
            guard let limits = (obj["result"] as? [String: Any])?["rateLimits"] as? [String: Any] else { return FetchResult(error: tx("n/a — unrecognized usage data", "n/d: datos de uso no reconocidos")) }
            let reading = UsageJSON.codex(limits, at: Date(), format: "rpc")
            return FetchResult(reading: reading, status: 200, error: reading.windows.isEmpty ? tx("n/a — unrecognized usage data", "n/d: datos de uso no reconocidos") : nil)
        }
        guard let tokens = readJSON(URL(fileURLWithPath: home + "/auth.json"))?["tokens"] as? [String: Any], let token = tokens["access_token"] as? String, !token.isEmpty, let account = tokens["account_id"] as? String, !account.isEmpty else { return FetchResult(error: tx("n/a — sign in to Codex with ChatGPT", "n/d: inicia sesión en Codex con ChatGPT")) }
        let (data, response) = http("https://chatgpt.com/backend-api/wham/usage", headers: ["Authorization": "Bearer " + token, "ChatGPT-Account-Id": account, "Accept": "application/json"], cancel: cancel)
        let status = response?.statusCode ?? 0
        if status == 429 { return FetchResult(status: status, error: tx("Rate-limited", "Límite de uso alcanzado"), retryAfter: retryAfter(response)) }
        guard status == 200, let obj = UsageJSON.object(data), var limits = obj["rate_limit"] as? [String: Any] else { return FetchResult(status: status, error: status == 401 ? tx("Session expired — open Codex to refresh", "Sesión caducada: abre Codex para renovarla") : tx("n/a — usage unavailable", "n/d: uso no disponible"), expired: status == 401) }
        limits["plan_type"] = obj["plan_type"]
        let reading = UsageJSON.codex(limits, at: Date(), format: "http")
        return FetchResult(reading: reading, status: status, error: reading.windows.isEmpty ? tx("n/a — unrecognized usage data", "n/d: datos de uso no reconocidos") : nil)
    }
    private static func readJSON(_ url: URL) -> [String: Any]? {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= 1_048_576,
              let data = try? Data(contentsOf: url) else { return nil }
        return UsageJSON.object(data)
    }
    private func readJSON(_ url: URL) -> [String: Any]? { Self.readJSON(url) }

    private static func quotaIdentifier(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty, text.utf8.count <= 256 else { return nil }
        return text
    }

    private static func codexAccount(_ auth: [String: Any]?) -> QuotaAccount? {
        guard let tokens = auth?["tokens"] as? [String: Any],
              let account = quotaIdentifier(tokens["account_id"]) else { return nil }
        var subject = quotaIdentifier(tokens["user_id"])
        // Claims are used only as a local partition hint, never as authentication.
        if subject == nil, let token = tokens["id_token"] as? String, token.utf8.count <= 32_768,
           let payload = token.split(separator: ".").dropFirst().first {
            var base64 = payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
            if let bytes = Data(base64Encoded: base64) { subject = quotaIdentifier(UsageJSON.object(bytes)?["sub"]) }
        }
        return QuotaAccount(account: account, subject: subject)
    }

    private func updateQuotaLogin(_ provider: UsageProvider, signedIn: Bool, rotate: Bool = false) {
        let state = states[index(provider)]
        let now = Date()
        let previous = quotaLogins[provider]
        guard state.enabled else {
            if let previous {
                quotaHistory.deactivate(previous, at: now)
                quotaFeed.send(.discontinuity)
            }
            quotaLogins[provider] = nil
            quotaAccounts[provider] = nil
            quotaContext[provider] = nil
            quotaLocalSince[provider] = now
            quotaContext[provider] = nil
            if provider == .codex { cancelBackfill() }
            return
        }
        let directory = UsageWatcher.resolvedPath(provider == .codex ? codexHome : claudeDir)
        var signedIn = signedIn
        var account: QuotaAccount?
        if signedIn && provider == .codex {
            let auth = readJSON(URL(fileURLWithPath: directory).appendingPathComponent("auth.json"))
            account = Self.codexAccount(auth)
            if let auth, (auth["tokens"] == nil || auth["tokens"] is NSNull), auth["OPENAI_API_KEY"] == nil || auth["OPENAI_API_KEY"] is NSNull {
                signedIn = false
            }
        } else if signedIn {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let configHome = URL(fileURLWithPath: directory).appendingPathComponent(".claude.json")
            let standard = UsageWatcher.resolvedPath(home.appendingPathComponent(".claude").path)
            let metadata = readJSON(configHome) ?? (directory == standard ? readJSON(home.appendingPathComponent(".claude.json")) : nil)
            if let oauth = metadata?["oauthAccount"] as? [String: Any],
               let user = Self.quotaIdentifier(oauth["accountUuid"]).flatMap(UUID.init(uuidString:)) {
                let org = Self.quotaIdentifier(oauth["organizationUuid"]).flatMap(UUID.init(uuidString:))
                account = QuotaAccount(account: user.uuidString, subject: org?.uuidString)
            }
        }
        let login = quotaHistory.login(provider: provider, directory: directory, account: account, signedIn: signedIn, now: now, rotate: rotate)
        quotaLogins[provider] = login
        quotaAccounts[provider] = account
        if (previous != nil && previous?.profile != login?.profile) || login?.switchedAt != previous?.switchedAt {
            quotaLocalSince[provider] = now
            if provider == .codex { cancelBackfill() }
            quotaFeed.send(.discontinuity)
        }
    }

    private func captureQuota(_ reading: UsageReading, provider: UsageProvider, source: QuotaSource, rolloutAccount: QuotaAccount?) {
        guard let run, !run.isCancelled, !asleep, reading.quota != nil else { return }
        guard let login = quotaLogins[provider] else { return }
        let now = Date()
        let zone = TimeZone.current.identifier
        let key = QuotaImportKey(profile: login.profile, timeZoneID: zone)
        if source != .api && reading.date < (quotaLocalSince[provider] ?? login.switchedAt ?? .distantPast) { return }
        if source == .statusLine {
            // The existing hook writes one shared file. Require the installation record for this CLI profile.
            let record = support.appendingPathComponent("claude-statusline-directory")
            guard let size = (try? record.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= 4096,
                  let path = try? String(contentsOf: record, encoding: .utf8),
                  UsageWatcher.resolvedPath(path) == UsageWatcher.resolvedPath(claudeDir) else { return }
        }
        let fallback = provider == .claude ? states[index(provider)].plan : nil
        var observations: [QuotaObservation]
        if source == .rollout {
            observations = UsageCodexBackfill.attributed(
                [.init(reading: reading, identified: rolloutAccount != nil)], key: key,
                anchors: quotaHistory.liveAnchors(for: key), switchedAt: login.switchedAt, now: now, realtime: true
            )
            // A labeled event from the currently active login is positive live evidence.
            if rolloutAccount != nil {
                for i in observations.indices { observations[i].attribution = .live }
            }
        } else {
            observations = UsageQuotaCapture.observations(reading, provider: provider, profile: login.profile,
                                                          timeZoneID: zone, source: source, attribution: .live,
                                                          now: now, fallbackPlan: fallback)
        }
        if source != .api {
            observations.removeAll { $0.date < (quotaLocalSince[provider] ?? login.switchedAt ?? .distantPast) }
        }
        let previousAPI = !login.identified && source == .api ? quotaHistory.liveAnchors(for: key) : []
        if observations.contains(where: { observation in
            guard let previous = previousAPI.first(where: { $0.series == observation.series }),
                  observation.date > previous.date else { return false }
            return (previous.reset == observation.reset && observation.used < previous.used - 1) || observation.reset < previous.reset
        }) {
            updateQuotaLogin(provider, signedIn: true, rotate: true)
            guard let rotated = quotaLogins[provider] else { return }
            observations = UsageQuotaCapture.observations(reading, provider: provider, profile: rotated.profile,
                                                          timeZoneID: zone, source: source, attribution: .live,
                                                          now: now, fallbackPlan: fallback)
        }
        if source == .api && !observations.isEmpty {
            let current = Set(observations.map(\.series))
            if let previous = quotaContext[provider],
               Set(previous.map(\.plan)) != Set(current.map(\.plan)) || Set(previous.map(\.timeZoneID)) != Set(current.map(\.timeZoneID)) {
                quotaHistory.breakCoverage(for: login.profile, at: observations.map(\.date).min() ?? now)
                quotaFeed.send(.discontinuity)
            }
            quotaContext[provider] = current
        }
        let epoch = quotaEpoch
        quotaHistory.ingest(observations, now: now) { [weak self] accepted in
            self?.queue.async { [weak self] in
                guard let self, self.run === run, !run.isCancelled, self.quotaEpoch == epoch,
                      self.quotaLogins[provider]?.profile == accepted.first?.series.profile else { return }
                self.quotaFeed.send(.observations(accepted))
            }
        }
        if provider == .codex, source == .api, !observations.isEmpty { startBackfill(now: now) }
    }

    private func workspacePowerChanged(asleep: Bool, run: ModuleCancellation) {
        let date = Date()
        queue.async {
            guard self.run === run, !run.isCancelled else { return }
            self.asleep = asleep
            self.quotaEpoch += 1
            self.quotaHistory.breakCoverage(at: date, allowsQuiet: true, flush: asleep)
            self.quotaFeed.send(.discontinuity)
            if asleep { self.cancelBackfill() }
            else {
                self.lastQuotaWake = date
                for provider in UsageProvider.allCases { self.quotaLocalSince[provider] = date }
                self.detect(force: false)
                self.nextPeriodic = date.addingTimeInterval(900 + Double.random(in: 0...90))
                for provider in UsageProvider.allCases { self.fetch(provider, force: false, scheduled: true) }
            }
        }
    }

    private func cancelBackfill() {
        backfill?.cancel.cancel()
        backfill = nil
    }

    private func startBackfill(now: Date) {
        guard let run, !run.isCancelled, !asleep, let login = quotaLogins[.codex] else { return }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let key = QuotaImportKey(profile: login.profile, timeZoneID: calendar.timeZone.identifier)
        if let backfill, backfill.key == key { return }
        cancelBackfill()
        guard !quotaHistory.importComplete(key) else { return }
        let cancel = ModuleCancellation()
        let scanner = UsageCodexBackfill(sessionsRoot: URL(fileURLWithPath: codexHome).appendingPathComponent("sessions"),
                                         now: now, calendar: calendar, account: quotaAccounts[.codex],
                                         cancelled: { cancel.isCancelled || run.isCancelled })
        let job = BackfillJob(key: key, cancel: cancel, scanner: scanner)
        backfill = job
        scanBackfill(job, login: login, run: run, final: false)
    }

    private func scanBackfill(_ job: BackfillJob, login: QuotaLogin, run: ModuleCancellation, final: Bool) {
        let cancelled = { job.cancel.isCancelled || run.isCancelled }
        job.scanner.scanNextPass { [weak self] pass in
            guard let self, !cancelled() else { return }
            let now = Date()
            let observations = UsageCodexBackfill.attributed(pass.candidates, key: job.key,
                                                            anchors: self.quotaHistory.liveAnchors(for: job.key),
                                                            switchedAt: login.switchedAt, now: now)
            self.quotaHistory.replaceImport(observations, for: job.key, complete: final || !pass.moreFiles,
                                            now: now, cancelled: cancelled,
                                            updated: { [weak self] in self?.quotaFeed.send(.importUpdated) })
            if pass.truncated { log("usage forecast: Codex history reached a backfill budget") }
            if !final && pass.moreFiles { self.continueBackfillWhenIdle(job, login: login, run: run) }
        }
    }

    private func continueBackfillWhenIdle(_ job: BackfillJob, login: QuotaLogin, run: ModuleCancellation) {
        queue.asyncAfter(deadline: .now() + 1) {
            guard !job.cancel.isCancelled, !run.isCancelled, !self.asleep, self.backfill?.cancel === job.cancel else { return }
            if self.active.isEmpty {
                self.scanBackfill(job, login: login, run: run, final: true)
            } else { self.continueBackfillWhenIdle(job, login: login, run: run) }
        }
    }

    private func accept(_ reading: UsageReading, provider: UsageProvider, source: QuotaSource? = nil,
                        original: UsageReading? = nil, rolloutAccount: QuotaAccount? = nil) {
        if source == .statusLine { updateQuotaLogin(provider, signedIn: states[index(provider)].signedIn) }
        if let source { captureQuota(original ?? reading, provider: provider, source: source, rolloutAccount: rolloutAccount) }
        let i = index(provider)
        guard reading.date <= Date().addingTimeInterval(5), reading.date > (states[i].reading?.date ?? .distantPast) else { return }
        var reading = reading
        if reading.plan == nil { reading.plan = states[i].reading?.plan ?? states[i].plan }
        states[i].acceptReading(reading, original: original)
        if !reading.windows.isEmpty { states[i].error = nil }
        saveCache()
    }
    private func localEvents(_ paths: [String]) {
        guard run?.isCancelled == false, !asleep else { return }
        let root = UsageWatcher.resolvedPath(codexHome + "/sessions")
        let local = UsageWatcher.resolvedPath(support.appendingPathComponent("claude-usage.json").path)
        let resolved = paths.map(UsageWatcher.resolvedPath)
        let codex = resolved.contains { $0 == root || $0.hasPrefix(root + "/") }
        let claude = resolved.contains(local)
        if codex || claude { readLocal(codex: codex, claude: claude) }
    }
    static func mergingClaudeLocal(_ reading: UsageReading, previous: UsageReading?) -> UsageReading {
        var merged = reading
        merged.apiDate = previous?.apiDate
        for window in previous?.windows ?? [] where window.id.hasPrefix("weekly_scoped") || window.id == "seven_day_opus" || window.id == "seven_day_sonnet" {
            if !merged.windows.contains(where: { $0.id == window.id || $0.titleKey == window.titleKey }) { merged.windows.append(window) }
        }
        return merged
    }
    private func readLocal(codex: Bool = true, claude: Bool = true) {
        guard let run, !run.isCancelled, !asleep else { return }
        let fm = FileManager.default
        let root = URL(fileURLWithPath: codexHome + "/sessions")
        var newest: [(URL, Date)] = []
        if codex && states[1].enabled, let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey], options: [.skipsHiddenFiles]) {
            // Walk metadata only; retain just three paths and read at most 256 KiB per file.
            let deadline = Date().addingTimeInterval(2)
            for case let url as URL in enumerator {
                if run.isCancelled { return }
                if Date() >= deadline { log("usage: local scan reached time budget"); break }
                guard url.lastPathComponent.hasPrefix("rollout-"), url.pathExtension == "jsonl" else { continue }
                if let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]), values.isRegularFile == true {
                    newest.append((url, values.contentModificationDate ?? .distantPast)); newest.sort { $0.1 > $1.1 }
                    if newest.count > 3 { newest.removeLast() }
                }
            }
        }
        // The active login may have changed since the last periodic identity check.
        if !newest.isEmpty { updateQuotaLogin(.codex, signedIn: states[index(.codex)].signedIn) }
        let activeAccount = quotaAccounts[.codex]
        var best: (reading: UsageReading, account: String?, subject: String?)?
        for (url, _) in newest {
            guard !run.isCancelled else { return }
            guard let h = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? h.close() }
            guard let size = try? h.seekToEnd() else { continue }
            let offset = size > 262_144 ? size - 262_144 : 0
            guard (try? h.seek(toOffset: offset)) != nil, let data = try? h.read(upToCount: 262_144) else { continue }
            var lines = data.split(separator: 10)
            if offset > 0 && !lines.isEmpty { lines.removeFirst() }
            for line in lines {
                guard let event = UsageJSON.codexRollout(Data(line)), !event.reading.windows.isEmpty,
                      event.reading.date > (best?.reading.date ?? .distantPast),
                      Self.canAcceptRollout(account: event.account, subject: event.subject, activeAccount: activeAccount) else { continue }
                best = event
            }
        }
        if let best {
            let account = best.account.map { QuotaAccount(account: $0, subject: best.subject) }
            accept(best.reading, provider: .codex, source: .rollout, rolloutAccount: account)
        }
        if claude && states[0].enabled && config.usageClaudeStatusLine == true, let obj = readJSON(support.appendingPathComponent("claude-usage.json")),
           let date = UsageJSON.date(obj["timestamp"]), let limits = obj["rate_limits"] as? [String: Any] {
            let reading = UsageJSON.claude(limits, at: date, local: true)
            if !reading.windows.isEmpty {
                accept(Self.mergingClaudeLocal(reading, previous: states[0].reading), provider: .claude,
                       source: .statusLine, original: reading)
            }
        }
        publish()
    }
    static func canAcceptRollout(account: String?, subject: String?, activeAccount: QuotaAccount?) -> Bool {
        guard let account else { return subject == nil }
        return activeAccount?.matches(QuotaAccount(account: account, subject: subject)) == true
    }

    struct Cache: Codable {
        var directories: [String: String]
        var readings: [String: UsageReading]
        var cooldowns: [String: Date]
        var failures: [String: Int]
        var observations: [String: [String: UsageWindowObservation]]? = nil
    }
    private func loadCache() {
        let url = support.appendingPathComponent("usage-cache.json")
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= 1_048_576,
              let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(Cache.self, from: data) else { return }
        for p in UsageProvider.allCases {
            let path = p == .claude ? folder(config.usageClaudeConfigDir, "CLAUDE_CONFIG_DIR", FileManager.default.homeDirectoryForCurrentUser.path + "/.claude") : folder(config.usageCodexHome, "CODEX_HOME", FileManager.default.homeDirectoryForCurrentUser.path + "/.codex")
            guard cache.directories[p.rawValue] == path else { continue }
            if var reading = cache.readings[p.rawValue], UsageJSON.boundedDate(reading.date) != nil, reading.date <= Date().addingTimeInterval(5) {
                reading.windows = reading.windows.filter { $0.used.isFinite }.map { w in var w = w; w.used = max(0, min(100, w.used)); w.resetsAt = UsageJSON.boundedDate(w.resetsAt); return w }
                reading.apiDate = UsageJSON.boundedDate(reading.apiDate)
                states[index(p)].reading = reading
                states[index(p)].windowObservations = cache.observations?[p.rawValue] ?? [:]
            }
            if let cooldown = cache.cooldowns[p.rawValue], cooldown > Date() {
                states[index(p)].cooldownUntil = min(cooldown, Date().addingTimeInterval(1800))
            }
            failures[p] = cache.failures[p.rawValue].map { max(0, min(30, $0)) }
        }
        publish()
    }
    private func saveCache() {
        var readings: [String: UsageReading] = [:], cooldowns: [String: Date] = [:], counts: [String: Int] = [:]
        for s in states { readings[s.id] = s.reading; cooldowns[s.id] = s.cooldownUntil; counts[s.id] = failures[s.provider] }
        let observations = Dictionary(uniqueKeysWithValues: states.map { ($0.id, $0.windowObservations) })
        let cache = Cache(directories: ["claude": claudeDir, "codex": codexHome], readings: readings,
                          cooldowns: cooldowns, failures: counts, observations: observations)
        do {
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            try JSONEncoder().encode(cache).write(to: support.appendingPathComponent("usage-cache.json"), options: .atomic)
        } catch { log("usage: cache write failed") }
    }
    private var statusLine: ClaudeStatusLine {
        ClaudeStatusLine(support: support, legacySupport: AppPaths.legacySupportDirectory)
    }

    private var previousStatusLineDirectory: String? {
        let cacheURL = support.appendingPathComponent("usage-cache.json")
        return (try? Data(contentsOf: cacheURL))
            .flatMap { try? JSONDecoder().decode(Cache.self, from: $0) }?.directories["claude"]
    }

    private func reconcileStatusLine(preference: Bool?, directory: String) {
        do {
            guard let result = try statusLine.reconcilePreference(preference, directory: directory,
                                                                  previousDirectory: previousStatusLineDirectory) else { return }
            switch result {
            case .installed: message(tx("Live updates enabled for new Claude Code sessions.", "Actualizaciones en vivo activadas para las nuevas sesiones de Claude Code."))
            case .alreadyInstalled: message(tx("Live updates already configured.", "Las actualizaciones en vivo ya están configuradas."))
            case .removed: message("")
            case .folderMissing:
                message(tx("Claude’s configuration folder must already exist.", "La carpeta de configuración de Claude debe existir."))
            case let .existingCommand(snippet):
                message(tx("You already have a statusLine; add this line to your script: ", "Ya tienes una statusLine; añade esta línea a tu script: ") + snippet)
            }
        } catch {
            message(tx("Could not update Claude settings. Check that settings.json is valid and writable.",
                       "No se pudieron actualizar los ajustes de Claude. Comprueba el formato y los permisos de settings.json."))
            log("usage: statusLine configuration failed")
        }
    }
}

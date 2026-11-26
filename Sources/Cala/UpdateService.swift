import AppKit
import Combine
import IOKit.pwr_mgt

enum UpdateState: Codable, Equatable {
    case idle, checking, upToDate(Date), available(String), skipped(String)
    case downloading(Int), verifying, installing, pendingRestart(String)
    case rolledBack(String, String), offline, feedUnavailable, verificationFailed
    case diskFull(Int64), busy, blockedByMacOS, needsAdmin, needsNewerMacOS(String, String)
    case manualInstall, unsupported, unavailable, failed, restartFailed
}

final class UpdateService: ObservableObject {
    static let shared = UpdateService()
    static let releases = URL(string: "https://github.com/MineiToshio/cala-taskbar/releases/latest")!
    static let feed = URL(string: "https://github.com/MineiToshio/cala-taskbar/releases/latest/download/latest.json")!

    @Published var state: UpdateState = .idle
    @Published var available: UpdateManifest?
    @Published var pendingRestart = false {
        didSet { MailKeychain.isRestartingForUpdate = pendingRestart }
    }
    @Published private(set) var installPath: InstallPath = .unsupported
    @Published private(set) var offer: UpdateManifest?

    private struct Build: Codable {
        let version: String
        let build: String
        var identity: String { "\(version)+\(build)" }
        var parsed: AppVersion? { AppVersion(version: version, build: build) }

        init(_ version: String, _ build: String) {
            self.version = version
            self.build = build
        }

        init(_ manifest: UpdateManifest) { self.init(manifest.version, String(manifest.build)) }
    }

    private struct Saved: Codable {
        var lastAttempt: Date?
        var lastManualAttempt: Date?
        var lastSuccess: Date?
        var failures = 0
        var retryNotBefore: Date?
        var highestSeen: Build?
        var skippedVersion: String?
        var blockedBuilds: Set<String> = []
        var envelope: Data?
        var downloaded: URL?
        var installFailed: Bool?
        var lastResult: UpdateState?
    }

    private struct Site {
        let running = Build(Telemetry.appVersion(), Telemetry.appBuild())
        let bundleId = Bundle.main.bundleIdentifier ?? "local.cala"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let target = AppLocation.bundleURL
        let url: URL?
        let keys: [Data]
        let test: Bool
        let idleThreshold: Double
        let installerFaults: InstallerFaults

        init() {
            let info = Bundle.main.infoDictionary ?? [:]
            #if CALA_UPDATE_TEST
            let testMode = info["CalaUpdateTest"] as? Bool == true
            let env = testMode ? ProcessInfo.processInfo.environment : [:]
            let idle = testMode ? info["CalaUpdateTestIdleSeconds"] as? Double : nil
            installerFaults = testMode ? InstallerFaults(rawValue: info["CalaUpdateTestFault"] as? String ?? "") ?? .none : .none
            #else
            let testMode = false
            let env: [String: String] = [:]
            let idle: Double? = nil
            installerFaults = .none
            #endif
            test = testMode
            let configuredKeys = env["CALA_UPDATE_PUBLIC_KEYS"]?.split(whereSeparator: \.isWhitespace).map(String.init)
                ?? info["CalaUpdatePublicKeys"] as? [String] ?? []
            keys = configuredKeys.prefix(2).compactMap { Data(base64Encoded: $0) }.filter { $0.count == 32 }
            let configuredURL = env["CALA_UPDATE_FEED_URL"] ?? info["CalaUpdateFeedURL"] as? String ?? UpdateService.feed.absoluteString
            url = URL(string: configuredURL).flatMap { UpdateTransfer.allows($0, test: testMode) ? $0 : nil }
            idleThreshold = idle.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? 600
        }

        var isEnabled: Bool { !keys.isEmpty && url != nil && running.parsed != nil }

        func path() -> InstallPath {
            let location: AppLocationKind
            if AppLocation.isTranslocated { location = .translocated }
            else if AppLocation.onDiskImage { location = .diskImage }
            else { location = AppLocation.isInstalled ? .applications : .other }
            return UpdateRules.installPath(location: location,
                                           bundleWritable: access(target.path, W_OK) == 0
                                            && access(target.appendingPathComponent("Contents").path, W_OK) == 0,
                                           parentWritable: access(target.deletingLastPathComponent().path, W_OK) == 0)
        }

        func evaluate(_ manifest: UpdateManifest, saved: Saved, sharedBlocks: Set<String>?) -> UpdateEvaluation {
            guard let sharedBlocks, let running = running.parsed else { return .upToDate }
            return UpdateRules.evaluate(manifest, running: running, bundleId: bundleId, os: os,
                                        highestSeen: saved.highestSeen?.parsed, skipped: saved.skippedVersion,
                                        blocked: saved.blockedBuilds.union(sharedBlocks), testURLs: test)
        }
    }

    private enum Activity { case checking, preparing, downloading, cancelling, installing }
    private static let key = "update.state"
    private let work = DispatchQueue(label: "Cala.update", qos: .utility)
    private weak var store: ConfigStore?
    private var site: Site?
    private var sharedBlocks: Set<String>?
    private var nextBlockRefresh = Date.distantPast
    private var saved = Saved()
    private var activity: Activity?
    private var transfer: URLSessionTask?
    private var resume: (build: String, data: Data)?
    private var retryInstall = false
    private var restart: (manifest: UpdateManifest, previous: URL, userStarted: Bool)?
    private var installer: UpdateInstaller?
    private var checkingRestart = false
    private var restartRetryAfter = Date.distantPast
    private var nextCheck = Date.distantFuture
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var configObserver: AnyCancellable?
    private var sessionActive = true
    private var autoProbeInFlight = false
    private var nextAutoProbe = Date.distantPast
    private var windowOpen = false

    private init() {}

    /// Main-thread view of work that must hold off the other-account bundle monitor.
    var blocksRelaunch: Bool {
        windowOpen || activity == .preparing || activity == .downloading || activity == .cancelling
            || activity == .installing || pendingRestart
    }

    var canAutoInstall: Bool { installPath == .ready }
    var currentVersion: String { site?.running.version ?? Telemetry.appVersion() }
    var releasePage: URL {
        if let url = offer?.notesURL, UpdateTransfer.allows(url, test: site?.test == true) { return url }
        return Self.releases
    }

    func start(store: ConfigStore) {
        guard self.store == nil else { return }
        self.store = store
        let center = NSWorkspace.shared.notificationCenter
        sessionActive = (CGSessionCopyCurrentDictionary() as? [String: Any])?["kCGSSessionOnConsoleKey"] as? Bool ?? true
        observers = [
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.tick() },
            center.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.sessionActive = true
                self?.tick()
            },
            center.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.sessionActive = false
            }
        ]
        configObserver = store.$config.map { [$0.updateChecks, $0.updateAutoInstall] }.removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.tick() } }
        let launched = Date()
        work.async { [weak self] in
            guard let self else { return }
            let site = Site()
            let path = site.path()
            var saved = Self.load()
            self.recoverLaunch(site: site, launched: launched)
            let newlyBlocked = Self.readBlocked().subtracting(saved.blockedBuilds)
            saved.blockedBuilds.formUnion(newlyBlocked)
            if let pending = try? UpdateJournal.read(in: AppPaths.supportDirectory), newlyBlocked.contains(pending.to), pending.from == site.running.identity {
                saved.lastResult = .rolledBack(Self.marketingVersion(pending.to), site.running.version)
            } else if let failed = newlyBlocked.compactMap({ id -> (String, AppVersion)? in
                let parts = id.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 2, let version = AppVersion(version: parts[0], build: parts[1]) else { return nil }
                return (id, version)
            }).max(by: { $0.1 < $1.1 }) {
                saved.lastResult = .rolledBack(Self.marketingVersion(failed.0), site.running.version)
            }
            let cached = saved.envelope.flatMap { try? UpdateSignature.verify(feed: $0, publicKeys: site.keys).manifest }
            if cached == nil { saved.envelope = nil }
            let shared = try? UpdateJournal.sharedBlocks(target: site.target)
            let loaded = saved
            DispatchQueue.main.async {
                guard self.store != nil else { return }
                self.site = site
                self.saved = loaded
                self.sharedBlocks = shared
                self.installPath = path
                self.nextCheck = Self.checkDate(now: launched, lastAttempt: nil, failures: 0)
                if loaded.failures > 0 {
                    self.nextCheck = max(self.nextCheck, loaded.retryNotBefore ?? .distantPast,
                                         Self.checkDate(now: Date(), lastAttempt: loaded.lastAttempt, failures: loaded.failures))
                }
                self.restoreState(cached: cached)
                self.persist()
                let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }
                self.timer = timer
                RunLoop.main.add(timer, forMode: .common)
                self.tick()
            }
        }
    }

    // AppKit has committed to quitting. Persist before returning to its exit path,
    // including a quit that arrived before the asynchronous startup read finished.
    func recordVoluntaryQuit() {
        let support = AppPaths.supportDirectory
        do {
            if let pending = try UpdateJournal.read(in: support) {
                try pending.record("quit", in: support, runningBundle: Bundle.main.bundleURL,
                                   runningID: UpdateJournal.runningExecutableID())
            }
        } catch { log("update: quit receipt failed: \(error)") }
    }

    func stop() {
        store = nil
        timer?.invalidate()
        timer = nil
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        configObserver = nil
        transfer?.cancel()
        transfer = nil
        activity = nil
    }

    func checkNow() { check(manual: true) }

    func install() { beginInstall(userStarted: true) }

    func retry() {
        if retryInstall { install() }
        else { checkNow() }
    }

    func cancel() {
        guard activity == .downloading else { return }
        activity = .cancelling
        transfer?.cancel()
    }

    func skip() {
        guard let offer, activity == nil, !pendingRestart else { return }
        saved.skippedVersion = offer.version
        available = nil
        setResult(installPath == .ready ? .skipped(offer.version) : .needsAdmin)
        later()
    }

    func later() { UpdateWindowController.shared.close() }

    func setWindowOpen(_ open: Bool) {
        windowOpen = open
        if !open { tick() }
    }

    func restartNow() { tryRestart(force: true) }

    private func tick() {
        guard let store, let site else { return }
        if pendingRestart {
            tryRestart()
            return
        }
        guard site.isEnabled, installPath != .unsupported, activity == nil else { return }
        // A second account can roll back after we cached or displayed this offer.
        if (offer != nil || sharedBlocks == nil), Date() >= nextBlockRefresh {
            nextBlockRefresh = Date().addingTimeInterval(15)
            let envelope = saved.envelope
            let retryCached = sharedBlocks == nil
            work.async {
                let blocks = try? UpdateJournal.sharedBlocks(target: site.target)
                let cached = retryCached && blocks != nil ? envelope.flatMap { try? UpdateSignature.verify(feed: $0, publicKeys: site.keys).manifest } : nil
                DispatchQueue.main.async {
                    guard self.store != nil, self.activity == nil, !self.pendingRestart,
                          self.saved.envelope == envelope, blocks != self.sharedBlocks else { return }
                    self.sharedBlocks = blocks
                    if let offer = self.offer, let candidate = Build(offer).parsed,
                       let blocks, UpdateRules.isBlocked(candidate, by: blocks) {
                        self.apply(.upToDate, manifest: offer, checked: Date())
                    } else if blocks == nil {
                        self.offer = nil
                        self.available = nil
                        self.state = .busy
                    } else if retryCached {
                        self.restoreState(cached: cached)
                    }
                }
            }
        }
        guard store.config.updateChecks else { return }
        if Date() >= nextCheck { check(manual: false); return }
        guard store.config.updateAutoInstall, installPath == .ready, available != nil, !retryInstall,
              Date() >= nextAutoProbe, !autoProbeInFlight,
              BundleUpdateMonitor.blockers(sessionActive: sessionActive).isEmpty else { return }
        autoProbeInFlight = true
        nextAutoProbe = Date().addingTimeInterval(15)
        work.async {
            let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState,
                                                               eventType: CGEventType(rawValue: UInt32.max)!)
            let presenting = idle >= site.idleThreshold && Self.isPresenting()
            DispatchQueue.main.async {
                self.autoProbeInFlight = false
                guard let config = self.store?.config, let manifest = self.available, self.activity == nil,
                      !self.pendingRestart, !self.retryInstall else { return }
                let blockers = BundleUpdateMonitor.blockers(sessionActive: self.sessionActive)
                if UpdateRules.autoInstall(enabled: config.updateChecks && config.updateAutoInstall, path: self.installPath,
                                           idleSeconds: idle, blockers: blockers.count, presenting: presenting,
                                           skipped: self.saved.skippedVersion == manifest.version,
                                           blocked: self.saved.blockedBuilds.contains(Build(manifest).identity),
                                           idleThreshold: site.idleThreshold) {
                    self.beginInstall(userStarted: false)
                }
            }
        }
    }

    private func check(manual: Bool) {
        guard let site, let url = site.url, site.isEnabled, installPath != .unsupported,
              activity == nil, !pendingRestart else { return }
        let now = Date()
        if manual {
            guard now.timeIntervalSince(saved.lastManualAttempt ?? .distantPast) >= 60 else { return }
            saved.lastManualAttempt = now
        }
        saved.lastAttempt = now
        retryInstall = false
        saved.installFailed = false
        persist()
        activity = .checking
        state = .checking
        transfer = UpdateTransfer(queue: work, siteIsTest: site.test, version: site.running.version, background: !manual)
            .fetch(url) { [weak self] result in
                let verified = result.map { payload -> (Data, UpdateManifest?) in
                    let manifest = try? UpdateSignature.verify(feed: payload, publicKeys: site.keys).manifest
                    return (payload, manifest)
                }
                let shared = try? UpdateJournal.sharedBlocks(target: site.target)
                DispatchQueue.main.async {
                    self?.sharedBlocks = shared
                    self?.finishCheck(verified)
                }
            }
    }

    private func finishCheck(_ result: Result<(Data, UpdateManifest?), UpdateTransfer.FeedError>) {
        guard let site, activity == .checking, store != nil else { return }
        transfer = nil
        activity = nil
        let now = Date()
        guard sharedBlocks != nil else {
            offer = nil
            available = nil
            setResult(.busy)
            nextCheck = now.addingTimeInterval(15)
            return
        }
        var retryAfter: TimeInterval?
        switch result {
        case let .success((envelope, manifest?)):
            let evaluation = site.evaluate(manifest, saved: saved, sharedBlocks: sharedBlocks)
            // Only a recognized, eligible release can advance the replay floor.
            switch evaluation {
            case .available, .skipped, .needsNewerMacOS:
                let build = Build(manifest)
                if let parsed = build.parsed, saved.highestSeen?.parsed.map({ $0 < parsed }) ?? true {
                    saved.highestSeen = build
                }
            default: break
            }
            saved.lastSuccess = now
            saved.failures = 0
            if let candidate = Build(manifest).parsed, let highest = saved.highestSeen?.parsed, candidate < highest {
                // A replay doesn't replace a newer signed offer already on this Mac.
                if let offer { apply(site.evaluate(offer, saved: saved, sharedBlocks: sharedBlocks), manifest: offer, checked: now) }
                else { apply(evaluation, manifest: manifest, checked: now) }
            } else {
                saved.envelope = envelope
                apply(evaluation, manifest: manifest, checked: now)
            }
        case .success, .failure(.response(.tooLarge)):
            available = nil
            offer = nil
            setResult(.verificationFailed)
            saved.failures = min(saved.failures + 1, 6)
        case let .failure(.response(error)):
            switch error {
            case .offline: setResult(.offline)
            case .rateLimited(let delay):
                retryAfter = delay
                setResult(.feedUnavailable)
            case .feedUnavailable, .tooLarge: setResult(.feedUnavailable)
            }
            saved.failures = min(saved.failures + 1, 6)
        }
        nextCheck = Self.checkDate(now: now, lastAttempt: saved.lastAttempt, failures: saved.failures)
        if saved.failures > 0 {
            nextCheck = max(nextCheck, saved.retryNotBefore ?? .distantPast, now.addingTimeInterval(retryAfter ?? 0))
            saved.retryNotBefore = nextCheck
        } else {
            saved.retryNotBefore = nil
        }
        persist()
    }

    private static func checkDate(now: Date, lastAttempt: Date?, failures: Int) -> Date {
        UpdateRules.nextCheck(now: now, lastAttempt: lastAttempt, failures: failures,
                              retryAfter: nil, jitter: Double.random(in: 0...1))
    }

    private func restoreState(cached: UpdateManifest?) {
        guard let site else { return }
        guard installPath != .unsupported else { state = .unsupported; return }
        guard site.isEnabled else { state = .unavailable; return }
        guard sharedBlocks != nil else { state = .busy; return }
        let lastResult = saved.lastResult
        if let cached, let checked = saved.lastSuccess {
            apply(site.evaluate(cached, saved: saved, sharedBlocks: sharedBlocks), manifest: cached, checked: checked, remember: false)
        }
        retryInstall = saved.installFailed == true && offer != nil && installPath == .ready
        guard let lastResult else { return }
        switch lastResult {
        case .rolledBack, .offline, .feedUnavailable:
            state = lastResult
        case .verificationFailed:
            if !retryInstall { available = nil; offer = nil }
            state = lastResult
        case .diskFull, .busy, .blockedByMacOS, .failed:
            if retryInstall { state = lastResult }
        default: break
        }
    }

    private func apply(_ evaluation: UpdateEvaluation, manifest: UpdateManifest, checked: Date, remember: Bool = true) {
        let result: UpdateState
        var newOffer: UpdateManifest?
        var newIndicator: UpdateManifest?
        switch evaluation {
        case .upToDate:
            if let previous = saved.lastResult, case .rolledBack = previous { result = previous }
            else { result = .upToDate(checked) }
        case .available(let manifest):
            newOffer = manifest
            newIndicator = manifest
            result = installPath == .ready ? .available(manifest.version) : .needsAdmin
        case .skipped(let manifest):
            newOffer = manifest
            result = installPath == .ready ? .skipped(manifest.version) : .needsAdmin
        case .manualInstall:
            newOffer = manifest
            result = .manualInstall
        case .needsNewerMacOS(let macOS):
            result = .needsNewerMacOS(manifest.version, macOS)
        }
        if offer != newOffer { offer = newOffer }
        if available != newIndicator { available = newIndicator }
        if remember { setResult(result) }
        else { state = result }
    }

    private func beginInstall(userStarted: Bool) {
        guard let site, let manifest = offer, let envelope = saved.envelope,
              activity == nil, !pendingRestart, installPath == .ready else { return }
        switch site.evaluate(manifest, saved: saved, sharedBlocks: sharedBlocks) {
        case .available: break
        case .skipped where userStarted: break
        default: return
        }
        let cached = saved.downloaded
        let blocked = saved.blockedBuilds
        activity = .preparing
        state = .verifying
        retryInstall = false
        saved.installFailed = false
        work.async {
            let helper = site.target.appendingPathComponent("Contents/Helpers/cala-update")
            guard FileManager.default.isExecutableFile(atPath: helper.path) else {
                DispatchQueue.main.async { self.failInstall(.failed) }
                return
            }
            guard let shared = try? UpdateJournal.sharedBlocks(target: site.target) else {
                DispatchQueue.main.async { self.failInstall(.busy) }
                return
            }
            if let candidate = Build(manifest).parsed, UpdateRules.isBlocked(candidate, by: shared.union(blocked).union(Self.readBlocked())) {
                DispatchQueue.main.async {
                    self.sharedBlocks = shared
                    self.activity = nil
                    self.apply(.upToDate, manifest: manifest, checked: Date())
                }
                return
            }
            guard (try? UpdateSignature.verify(feed: envelope, publicKeys: site.keys).manifest) == manifest else {
                DispatchQueue.main.async { self.failInstall(.verificationFailed) }
                return
            }
            let reserve: Int64 = 100 * 1024 * 1024
            let size = Int64(manifest.dmg.size)
            let unpacked = Int64(manifest.app.unpackedSize)
            guard (1...200 * 1024 * 1024).contains(size), unpacked > 0, unpacked <= (Int64.max - size - reserve) / 2 else {
                DispatchQueue.main.async { self.failInstall(.verificationFailed) }
                return
            }
            let required = size + 2 * unpacked + reserve
            guard let capacity = try? site.target.deletingLastPathComponent()
                .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage else {
                DispatchQueue.main.async { self.failInstall(.failed) }
                return
            }
            if capacity < required {
                DispatchQueue.main.async { self.failInstall(.diskFull(required)) }
                return
            }
            do {
                let file = try DownloadFile(base: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0],
                                            manifest: manifest, saved: cached)
                DispatchQueue.main.async {
                    guard self.store != nil, self.activity == .preparing else { if !file.cached { file.discard() }; return }
                    if file.cached { self.installDownloaded(file, manifest: manifest, site: site, userStarted: userStarted) }
                    else { self.download(file, manifest: manifest, site: site, userStarted: userStarted) }
                }
            } catch {
                DispatchQueue.main.async { self.failInstall(Self.isDiskFull(error) ? .diskFull(required) : .failed) }
            }
        }
    }

    private func download(_ dmg: DownloadFile, manifest: UpdateManifest, site: Site, userStarted: Bool) {
        activity = .downloading
        state = .downloading(0)
        let build = Build(manifest).identity
        let resumeData = resume?.build == build ? resume?.data : nil
        resume = nil
        transfer = UpdateTransfer(queue: work, siteIsTest: site.test, version: site.running.version, background: !userStarted)
            .download(manifest.dmg.url, to: dmg, size: Int64(manifest.dmg.size), resume: resumeData, progress: { [weak self] percent in
                DispatchQueue.main.async {
                    guard let self, self.activity == .downloading else { return }
                    self.state = .downloading(percent)
                }
            }, done: { [weak self] result in
                DispatchQueue.main.async {
                    guard let self, self.store != nil, self.activity == .downloading || self.activity == .cancelling else {
                        dmg.discard()
                        return
                    }
                    self.transfer = nil
                    if self.activity == .cancelling {
                        // A successful transfer can already be queued when Cancel reaches the main thread.
                        dmg.discard()
                        if case .failure(let failure) = result, let data = failure.resume { self.resume = (build, data) }
                        self.activity = nil
                        self.nextAutoProbe = Date().addingTimeInterval(600)
                        self.apply(site.evaluate(manifest, saved: self.saved, sharedBlocks: self.sharedBlocks), manifest: manifest,
                                   checked: self.saved.lastSuccess ?? Date())
                        return
                    }
                    switch result {
                    case .success:
                        self.installDownloaded(dmg, manifest: manifest, site: site, userStarted: userStarted)
                    case .failure(let failure):
                        dmg.discard()
                        if let data = failure.resume { self.resume = (build, data) }
                        if let response = failure.error as? UpdateTransfer.FeedError,
                                  case .response(.tooLarge) = response {
                            self.failInstall(.verificationFailed)
                        } else if failure.error is InstallResult {
                            self.failInstall(.verificationFailed)
                        } else if Self.isDiskFull(failure.error) {
                            self.failInstall(.diskFull(Int64(manifest.dmg.size)))
                        } else {
                            self.failInstall(failure.error is URLError ? .offline : .feedUnavailable)
                        }
                    }
                }
            })
    }

    private func installDownloaded(_ dmg: DownloadFile, manifest: UpdateManifest, site: Site, userStarted: Bool) {
        saved.downloaded = dmg.savedURL
        persist()
        activity = .installing
        state = .installing
        var tools = InstallerTools.system
        if !userStarted {
            tools.beforeSwap = {
                let presenting = Self.isPresenting()
                let ready = DispatchSemaphore(value: 0)
                var allowed = false
                DispatchQueue.main.async {
                    allowed = self.autoAllowed(manifest, site: site, presenting: presenting)
                    ready.signal()
                }
                ready.wait()
                guard allowed else { throw InstallResult.deferred }
            }
        }
        let installer = UpdateInstaller(target: site.target, tools: tools, faults: site.installerFaults)
        self.installer = installer
        installer.install(manifest: manifest, dmg: dmg.pinnedURL) { [weak self] result in
            guard let self, self.store != nil else { return }
            switch result {
            case .installed(let previous):
                self.pendingRestart = true
                self.restart = (manifest, previous, userStarted)
                self.available = nil
                self.clearDownload(dmg)
                self.activity = nil
                self.tryRestart()
            case .deferred:
                self.activity = nil
                self.nextAutoProbe = Date().addingTimeInterval(15)
                self.apply(site.evaluate(manifest, saved: self.saved, sharedBlocks: self.sharedBlocks), manifest: manifest, checked: self.saved.lastSuccess ?? Date())
            case .upToDate:
                self.clearDownload(dmg)
                self.activity = nil
                self.offer = nil
                self.available = nil
                self.setResult(.upToDate(Date()))
            case .verificationFailed(let detail):
                log("update: install verification failed (\(detail))")
                self.clearDownload(dmg)
                self.failInstall(.verificationFailed)
            case .diskFull(let required): self.failInstall(.diskFull(required))
            case .busy: self.failInstall(.busy)
            case .blockedByMacOS: self.failInstall(.blockedByMacOS)
            case .failed(let detail):
                log("update: installation failed (\(detail))")
                self.failInstall(.failed)
            }
        }
    }

    private func clearDownload(_ dmg: DownloadFile) {
        saved.downloaded = nil
        persist()
        work.async { dmg.discard() }
    }

    private func failInstall(_ result: UpdateState) {
        guard store != nil else { return }
        activity = nil
        retryInstall = true
        saved.installFailed = true
        setResult(result)
    }

    private func autoAllowed(_ manifest: UpdateManifest, site: Site, presenting: Bool) -> Bool {
        guard let config = store?.config else { return false }
        let blockers = BundleUpdateMonitor.blockers(sessionActive: sessionActive).filter { $0 != .updater || windowOpen }
        return UpdateRules.autoInstall(enabled: config.updateChecks && config.updateAutoInstall, path: site.path(),
                                       idleSeconds: CGEventSource.secondsSinceLastEventType(.combinedSessionState,
                                                                                    eventType: CGEventType(rawValue: UInt32.max)!),
                                       blockers: blockers.count, presenting: presenting, skipped: saved.skippedVersion == manifest.version,
                                       blocked: saved.blockedBuilds.contains(Build(manifest).identity), idleThreshold: site.idleThreshold)
    }

    private func tryRestart(force: Bool = false) {
        guard let site, let restart, let installer, !checkingRestart, force || Date() >= restartRetryAfter else { return }
        checkingRestart = true
        work.async {
            let ready: Bool
            do {
                try installer.confirmWatch(previous: restart.previous)
                ready = true
            } catch InstallResult.upToDate {
                DispatchQueue.main.async {
                    self.checkingRestart = false
                    self.pendingRestart = false
                    self.restart = nil
                    self.installer = nil
                    self.offer = nil
                    self.setResult(.upToDate(Date()))
                }
                return
            } catch {
                log("update: restart handoff failed: \(error)")
                ready = false
            }
            let presenting = !force && !restart.userStarted && Self.isPresenting()
            DispatchQueue.main.async {
                self.checkingRestart = false
                guard self.store != nil else { return }
                guard ready, installer.watcher?.isRunning == true else {
                    self.state = .restartFailed
                    self.restartRetryAfter = Date().addingTimeInterval(15)
                    return
                }
                let decision = UpdatePolicy.restart(force: force, userStarted: restart.userStarted,
                    blockers: BundleUpdateMonitor.blockers(sessionActive: self.sessionActive),
                    autoAllowed: self.autoAllowed(restart.manifest, site: site, presenting: presenting))
                if case .deferred(let reason) = decision { self.state = .pendingRestart(reason.rawValue); return }
                self.restartRetryAfter = Date().addingTimeInterval(5)
                NSApp.terminate(nil)
            }
        }
    }

    private func recoverLaunch(site: Site, launched: Date) {
        let support = AppPaths.supportDirectory
        guard let pending = try? UpdateJournal.read(in: support) else {
            if FileManager.default.fileExists(atPath: support.appendingPathComponent("update-rollback").path) {
                recover(nil, site: site)
            }
            return
        }
        guard pending.target.path == site.target.path else { return }
        if pending.to == site.running.identity {
            pending.scheduleHealth(in: support, runningBundle: site.target, delay: max(0, 20 - Date().timeIntervalSince(launched)),
                                   work: work) {
                self.recover(pending, site: site)
            }
        } else {
            recover(pending, site: site)
        }
    }

    private func recover(_ pending: UpdateJournal?, site: Site) {
        let support = AppPaths.supportDirectory
        guard (try? UpdateJournal.read(in: support)) == pending else { return }
        let path = site.target.deletingLastPathComponent().appendingPathComponent(".cala-update.lock")
        let fd = open(path.path, O_CREAT | O_RDONLY | O_NOFOLLOW | O_CLOEXEC, 0o664)
        guard fd >= 0 else { return }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            work.asyncAfter(deadline: .now() + 2) { self.recover(pending, site: site) }
            return
        }
        do {
            guard try UpdateJournal.read(in: support) == pending else { return }
            guard let pending else {
                try UpdateJournal.reconcileRestored(in: support, target: site.target)
                return
            }
            let disk = try pending.diskState(at: site.target)
            if disk == .original {
                try UpdateJournal.reconcileRestored(in: support, target: site.target)
                DispatchQueue.main.async {
                    guard self.site != nil else { return } // start() imports the list before setting site.
                    self.saved.blockedBuilds.insert(pending.to)
                    if self.offer.map(Build.init)?.identity == pending.to { self.offer = nil; self.available = nil }
                    self.setResult(.rolledBack(Self.marketingVersion(pending.to), site.running.version))
                }
            } else if disk == .superseded {
                try UpdateJournal.reconcileRestored(in: support, target: site.target)
            } else if pending.to == site.running.identity, try pending.acceptsReceipt(in: support),
                      !Self.readBlocked().contains(pending.to) {
                try pending.cleanStage(for: site.target)
                try UpdateJournal.remove("update-rollback", in: support)
                try UpdateJournal.remove("update-pending.json", in: support)
                try UpdateJournal.remove(pending.marker, in: support)
            }
        } catch {
            log("update: recovery failed: \(error)")
            work.asyncAfter(deadline: .now() + 60) { self.recover(pending, site: site) }
        }
    }

    private func setResult(_ value: UpdateState) {
        state = value
        saved.lastResult = value
        persist()
    }

    private func persist() {
        let snapshot = saved
        work.async {
            if let data = try? JSONEncoder().encode(snapshot) { UserDefaults.standard.set(data, forKey: Self.key) }
        }
    }

    private static func load() -> Saved {
        guard let data = UserDefaults.standard.data(forKey: key) else { return Saved() }
        return (try? JSONDecoder().decode(Saved.self, from: data)) ?? Saved()
    }

    private static func readBlocked() -> Set<String> {
        let url = AppPaths.supportDirectory.appendingPathComponent("update-blocked.json")
        guard let data = try? Data(contentsOf: url), let builds = try? JSONDecoder().decode(Set<String>.self, from: data)
        else { return [] }
        return builds
    }

    private static func marketingVersion(_ identity: String) -> String {
        String(identity.prefix { $0 != "+" })
    }

    private static func isDiskFull(_ error: Error) -> Bool {
        let error = error as NSError
        return (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOSPC))
            || (error.domain == NSCocoaErrorDomain && error.code == NSFileWriteOutOfSpaceError)
    }

    private static func isPresenting() -> Bool {
        let type = "PreventUserIdleDisplaySleep"
        var status: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsStatus(&status) == kIOReturnSuccess,
              let levels = status?.takeRetainedValue() as? [String: NSNumber] else { return true }
        guard (levels[type]?.intValue ?? 0) > 0 else { return false }
        var assertions: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&assertions) == kIOReturnSuccess,
              let owners = assertions?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return true }
        return owners.contains { pid, entries in
            pid.int32Value != ProcessInfo.processInfo.processIdentifier && entries.contains {
                $0["AssertType"] as? String == type && (($0["AssertLevel"] as? NSNumber)?.intValue ?? 0) > 0
            }
        }
    }
}

/// Each ephemeral session owns one request. All delegate callbacks run on the update queue.
private final class UpdateTransfer: NSObject, URLSessionDataDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    enum FeedError: Error { case response(FeedFailure) }
    struct DownloadError: Error {
        let error: Error
        let resume: Data?
    }

    private let test: Bool
    private let version: String
    private let background: Bool
    private let queue: OperationQueue
    private var feedDone: ((Result<Data, FeedError>) -> Void)?
    private var downloadDone: ((Result<Void, DownloadError>) -> Void)?
    private var progress: ((Int) -> Void)?
    private var destination: DownloadFile?
    private var downloadSize: Int64 = 0
    private var bytes = Data()
    private var feedError: FeedFailure?
    private var downloadError: Error?
    private var lastPercent = 0
    private var downloaded = false
    private static let maxFeedSize = 64 * 1024

    init(queue: DispatchQueue, siteIsTest: Bool, version: String, background: Bool) {
        let operations = OperationQueue()
        operations.maxConcurrentOperationCount = 1
        operations.underlyingQueue = queue
        self.queue = operations
        self.test = siteIsTest
        self.version = version
        self.background = background
    }

    static func allows(_ url: URL, test: Bool) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil else { return false }
        if components.scheme == "https" { return true }
        return test && components.scheme == "http" && host == "127.0.0.1"
            && components.port.map { (1...65535).contains($0) } == true
    }

    private func session(timeout: TimeInterval) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.allowsConstrainedNetworkAccess = !background
        config.httpAdditionalHeaders = ["User-Agent": "Cala/\(version)"]
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        return URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }

    func fetch(_ url: URL, done: @escaping (Result<Data, FeedError>) -> Void) -> URLSessionTask {
        feedDone = done
        let task = session(timeout: 30).dataTask(with: url)
        task.resume()
        return task
    }

    func download(_ url: URL, to destination: DownloadFile, size: Int64, resume: Data?, progress: @escaping (Int) -> Void,
                  done: @escaping (Result<Void, DownloadError>) -> Void) -> URLSessionTask {
        self.destination = destination
        downloadSize = size
        self.progress = progress
        downloadDone = done
        let session = session(timeout: 300)
        let task = resume.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: url)
        task.resume()
        return task
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, Self.allows(url, test: test) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse {
            let headers = Dictionary(http.allHeaderFields.compactMap { key, value in
                (key as? String).map { ($0, String(describing: value)) }
            }, uniquingKeysWith: { _, last in last })
            feedError = UpdateRules.classify(status: http.statusCode, headers: headers, error: nil)
            if feedError == nil && !(200..<300).contains(http.statusCode) { feedError = .feedUnavailable }
        } else {
            feedError = .feedUnavailable
        }
        if feedError == nil, response.expectedContentLength > Int64(Self.maxFeedSize) { feedError = .tooLarge }
        completionHandler(feedError == nil ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard data.count <= Self.maxFeedSize - bytes.count else {
            feedError = .tooLarge
            dataTask.cancel()
            return
        }
        bytes.append(data)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        // Resumed transfers can report the remaining content length, so cap by bytes written.
        if totalBytesWritten > downloadSize {
            downloadError = FeedError.response(.tooLarge)
            downloadTask.cancel()
            return
        }
        guard totalBytesExpectedToWrite > 0 else { return }
        let percent = Int(min(100, max(0, 100 * Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))))
        guard percent != lastPercent else { return }
        lastPercent = percent
        progress?(percent)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let destination, let response = downloadTask.response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            downloadError = FeedError.response(.feedUnavailable)
            return
        }
        do {
            try destination.receive(location, size: downloadSize)
            downloaded = true
        } catch { downloadError = error }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { session.finishTasksAndInvalidate() }
        if let feedDone {
            let failure = feedError ?? error.map {
                UpdateRules.classify(status: 0, headers: [:], error: $0 as? URLError) ?? .offline
            }
            feedDone(failure.map { .failure(.response($0)) } ?? .success(bytes))
        } else if let downloadDone {
            if let failure = downloadError ?? error {
                let resume = (failure as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
                downloadDone(.failure(DownloadError(error: failure, resume: resume)))
            } else if downloaded {
                downloadDone(.success(()))
            } else {
                downloadDone(.failure(DownloadError(error: FeedError.response(.feedUnavailable), resume: nil)))
            }
        }
    }
}

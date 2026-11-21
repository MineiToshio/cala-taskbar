import Foundation
import Combine
import CoreServices
import CryptoKit
import Darwin

// Usage values are safe to cache. Credentials never enter a published or persisted object.
enum UsageProvider: String, Codable, CaseIterable {
    case claude, codex
    var title: String { self == .claude ? "Claude" : "Codex" }
    var glyph: String { self == .claude ? "✳" : "⬡" }
    var trayID: String { "__t_usage_" + rawValue }
    var interval: TimeInterval { self == .claude ? 120 : 60 }
}

struct UsageWindow: Codable, Identifiable {
    var id: String
    var title: String
    var used: Double
    var resetsAt: Date?
    var durationMinutes: Double? = nil
    // Provider categories take precedence; old caches can recover duration from their title.
    fileprivate var presentationOrder: (Int, Double) {
        let label = title.lowercased()
        let hours = label.hasSuffix(" h") ? Double(label.dropLast(2)) : nil
        let duration = [durationMinutes, hours.map { $0 * 60 }].compactMap { $0 }
            .first { $0.isFinite && $0 > 0 } ?? .infinity
        if id == "five_hour" || id == "session" || id.hasPrefix("session-") || label == "5-hour session" || duration == 300 {
            return (0, 300)
        }
        let scoped = id.hasPrefix("weekly_scoped") || id.hasPrefix("seven_day_") ||
            (label.hasPrefix("weekly ·") && label != "weekly · all models")
        if scoped { return (2, 10080) }
        if id == "seven_day" || id.hasPrefix("weekly_all") || label == "weekly" || label == "weekly · all models" || duration == 10080 {
            return (1, 10080)
        }
        return (3, duration)
    }
    func isResetting(_ now: Date) -> Bool { resetsAt.map { $0 <= now } ?? false }
    func effectiveUsed(_ now: Date) -> Double { isResetting(now) ? 0 : used }
}

struct UsageReading: Codable {
    var windows: [UsageWindow]
    var plan: String?
    var date: Date
    var apiDate: Date? = nil
}

struct UsageState: Identifiable {
    var provider: UsageProvider
    var id: String { provider.rawValue }
    var enabled = true
    var signedIn = false
    var detection = "Checking…"
    var reading: UsageReading?
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
}

// Bounded, nonblocking stdout reader. Called only off-main; stderr is intentionally discarded.
// Every child is reaped, including a child that ignores SIGTERM.
enum UsageProcess {
    struct Result { var data: Data; var status: Int32; var timedOut: Bool }
    static func run(_ executable: String, _ args: [String], timeout: TimeInterval,
                    environment: [String: String]? = nil, rpc: Bool = false) -> Result {
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
        if rpc { send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "mactaskbar", "title": "MacTaskbar", "version": "1.0"]]]) }
        var data = Data(), pending = Data(), reply = Data(), initialized = false
        let deadline = Date().addingTimeInterval(timeout)
        var complete = false
        while Date() < deadline && !complete {
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

enum UsageJSON {
    static func object(_ data: Data) -> [String: Any]? { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] }
    static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }
    static func boundedDate(_ value: Date?) -> Date? {
        guard let value, value.timeIntervalSince1970.isFinite, value.timeIntervalSince1970 >= 0, value.timeIntervalSince1970 < 253_402_300_800 else { return nil }
        return value
    }
    static func date(_ value: Any?) -> Date? {
        if let n = number(value), n > 0 { return boundedDate(Date(timeIntervalSince1970: n)) }
        guard let s = value as? String else { return nil }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = boundedDate(f.date(from: s)) { return d }
        f.formatOptions = [.withInternetDateTime]; return boundedDate(f.date(from: s))
    }
    static func window(_ id: String, _ title: String, _ used: Any?, _ reset: Any?, durationMinutes: Double? = nil) -> UsageWindow? {
        guard let n = number(used) else { return nil }
        return UsageWindow(id: id, title: title, used: max(0, min(100, n)), resetsAt: date(reset), durationMinutes: durationMinutes)
    }
    static func claude(_ obj: [String: Any], at date: Date, local: Bool = false) -> UsageReading {
        var windows: [UsageWindow] = []
        if let limits = obj["limits"] as? [[String: Any]], !limits.isEmpty {
            for (index, limit) in limits.enumerated() {
                let kind = limit["kind"] as? String ?? ""
                let model = ((limit["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
                let title: String
                switch kind {
                case "session": title = "5-hour session"
                case "weekly_all": title = "Weekly · all models"
                case "weekly_scoped": title = "Weekly · " + (model ?? "model")
                default: continue
                }
                if let w = window("\(kind)-\(index)", title, limit["percent"], limit["resets_at"]) { windows.append(w) }
            }
        } else {
            for (key, title) in [("five_hour", "5-hour session"), ("seven_day", "Weekly · all models"), ("seven_day_opus", "Weekly · Opus"), ("seven_day_sonnet", "Weekly · Sonnet")] {
                if let d = obj[key] as? [String: Any], let w = window(key, title, d[local ? "used_percentage" : "utilization"], d["resets_at"]) { windows.append(w) }
            }
        }
        return UsageReading(windows: windows, plan: nil, date: date, apiDate: local ? nil : date)
    }
    static func codex(_ obj: [String: Any], at date: Date, format: String) -> UsageReading {
        var windows: [UsageWindow] = []
        for key in ["primary", "secondary"] {
            guard let d = obj[key + (format == "http" ? "_window" : "")] as? [String: Any],
                  let duration = number(d[format == "rpc" ? "windowDurationMins" : (format == "http" ? "limit_window_seconds" : "window_minutes")]), duration > 0 else { continue }
            let minutes = format == "http" ? duration / 60 : duration
            let title = minutes == 300 ? "5-hour session" : (minutes == 10080 ? "Weekly" : String(format: "%g h", minutes / 60))
            var reset = d[format == "rpc" ? "resetsAt" : (format == "http" ? "reset_at" : "resets_at")]
            if reset == nil, let after = number(d["reset_after_seconds"]) { reset = date.timeIntervalSince1970 + after }
            if let w = window(key, title, d[format == "rpc" ? "usedPercent" : "used_percent"], reset, durationMinutes: minutes) { windows.append(w) }
        }
        return UsageReading(windows: windows, plan: obj[format == "rpc" ? "planType" : "plan_type"] as? String, date: date)
    }
}

enum UsageCredentials {
    static let environmentMarker = "__MACTASKBAR_ENV__"
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
        }, &context, paths.map(Self.resolvedPath) as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1,
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
    private var source: DispatchSourceFileSystemObject?
    init(path: String, queue: DispatchQueue, changed: @escaping () -> Void) {
        self.path = path; self.queue = queue; self.changed = changed
        refresh()
    }
    func refresh(notify: Bool = true) {
        guard source == nil else { return }
        let fd = open(path, O_EVTONLY | O_CLOEXEC)
        guard fd >= 0 else { return }
        let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename, .revoke], queue: queue)
        source = watcher
        watcher.setCancelHandler { close(fd) }
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

final class UsageService: ObservableObject {
    static let shared = UsageService()
    @Published private(set) var providers = UsageProvider.allCases.map { UsageState(provider: $0) }
    @Published private(set) var statusLineMessage = ""
    private let queue = DispatchQueue(label: "local.mactaskbar.usage", qos: .utility)
    private var states = UsageProvider.allCases.map { UsageState(provider: $0) }
    private var config = Config()
    private var subscription: AnyCancellable?
    private var timer: DispatchSourceTimer?
    private var watchers: [UsageWatcher] = []
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
    private var visible = false, alwaysVisible = false
    // These two are accessed only by the main-thread visibility hook.
    private var mainVisible = false, mainAlwaysVisible = false
    private var generations: [UsageProvider: Int] = [:]
    private var active = Set<UsageProvider>()
    private var statusLineConfigured = false
    private var configuredDirectory = ""
    private var refreshAfterDetection = false
    private let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MacTaskbar")

    private func index(_ p: UsageProvider) -> Int { p == .claude ? 0 : 1 }
    private func publish() {
        let copy = states
        DispatchQueue.main.async { self.providers = copy }
    }
    private func message(_ s: String) { DispatchQueue.main.async { self.statusLineMessage = s } }

    func start(store: ConfigStore, visible: Bool) {
        guard subscription == nil else { return }
        let alwaysVisible = !store.config.autoHide
        mainVisible = visible; mainAlwaysVisible = alwaysVisible
        queue.async { self.visible = visible; self.alwaysVisible = alwaysVisible }
        subscription = store.$config.removeDuplicates().sink { [weak self] config in
            self?.queue.async { self?.configure(config) }
        }
        queue.async {
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 5, repeating: 5)
            timer.setEventHandler { [weak self] in self?.maintenance() }
            self.timer = timer; timer.resume()
        }
    }
    func settingsOpened() { queue.async { self.detect(force: true); self.publish() } }
    func refresh(_ provider: UsageProvider? = nil, force: Bool = false) {
        queue.async {
            self.detect(force: false)
            for p in provider.map({ [$0] }) ?? UsageProvider.allCases { self.fetch(p, force: force) }
        }
    }
    func visibility(visible: Bool, alwaysVisible: Bool) {
        guard mainVisible != visible || mainAlwaysVisible != alwaysVisible else { return }
        let revealed = visible && !mainVisible
        mainVisible = visible; mainAlwaysVisible = alwaysVisible
        queue.async {
            self.visible = visible; self.alwaysVisible = alwaysVisible
            if revealed { for p in UsageProvider.allCases { self.fetch(p, force: false) } }
        }
    }
    private func configure(_ new: Config) {
        let first = !shellLoaded
        if shellLoaded && new.usageEnabled == config.usageEnabled && new.usageClaudeEnabled == config.usageClaudeEnabled && new.usageCodexEnabled == config.usageCodexEnabled && new.usageClaudeConfigDir == config.usageClaudeConfigDir && new.usageCodexHome == config.usageCodexHome && new.usageClaudeStatusLine == config.usageClaudeStatusLine {
            config = new; return
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let changedProviders = UsageProvider.allCases.filter {
            $0 == .claude ? folder(new.usageClaudeConfigDir, "CLAUDE_CONFIG_DIR", home + "/.claude") != claudeDir : folder(new.usageCodexHome, "CODEX_HOME", home + "/.codex") != codexHome
        }
        let enabled = new.usageEnabled && (!config.usageEnabled || (new.usageClaudeEnabled && !config.usageClaudeEnabled) || (new.usageCodexEnabled && !config.usageCodexEnabled))
        config = new
        if !shellLoaded {
            // One bounded login-shell invocation, even for GUI launches with an incomplete environment.
            let command = "printf '__MACTASKBAR_ENV__%s\\0%s\\0%s\\0%s\\0%s\\0' \"$CLAUDE_CONFIG_DIR\" \"$CODEX_HOME\" \"$PATH\" \"$CLAUDE_SECURESTORAGE_CONFIG_DIR\" \"${CLAUDE_SECURESTORAGE_CONFIG_DIR+x}\""
            let r = UsageProcess.run("/bin/zsh", ["-lc", command], timeout: 3)
            if !r.timedOut, let fields = UsageCredentials.shellFields(r.data) {
                for (key, value) in zip(["CLAUDE_CONFIG_DIR", "CODEX_HOME", "PATH", "CLAUDE_SECURESTORAGE_CONFIG_DIR", "SECURE_STORAGE_SET"], fields) { environment[key] = value }
            }
            shellLoaded = true
            loadCache()
            refreshAfterDetection = true
        }
        if !first && !changedProviders.isEmpty {
            for p in changedProviders {
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
        detect(force: true)
        if config.usageClaudeStatusLine != statusLineConfigured || (statusLineConfigured && configuredDirectory != claudeDir) {
            if statusLineConfigured && configuredDirectory != claudeDir { statusLine(enable: false, directory: configuredDirectory) }
            statusLine(enable: config.usageClaudeStatusLine, directory: claudeDir)
            statusLineConfigured = config.usageClaudeStatusLine; configuredDirectory = claudeDir
        }
        if enabled || refreshAfterDetection {
            refreshAfterDetection = false
            if visible || !config.autoHide { for p in UsageProvider.allCases { fetch(p, force: false) } }
        }
        publish()
    }
    private func folder(_ custom: String, _ env: String, _ fallback: String) -> String {
        let raw = custom.trimmingCharacters(in: .whitespacesAndNewlines)
        let chosen = raw.isEmpty ? (environment[env].flatMap { $0.isEmpty ? nil : $0 } ?? fallback) : raw
        let expanded = (chosen as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, relativeTo: FileManager.default.homeDirectoryForCurrentUser).standardizedFileURL.path.precomposedStringWithCanonicalMapping
    }
    private func detect(force: Bool) {
        guard shellLoaded, force || Date().timeIntervalSince(lastDetection) >= 300 else { return }
        lastDetection = Date()
        let fm = FileManager.default, home = fm.homeDirectoryForCurrentUser.path
        let oldClaude = claudeDir, oldCodex = codexHome
        claudeDir = folder(config.usageClaudeConfigDir, "CLAUDE_CONFIG_DIR", home + "/.claude")
        codexHome = folder(config.usageCodexHome, "CODEX_HOME", home + "/.codex")
        services = UsageCredentials.services(custom: config.usageClaudeConfigDir, rawEnvironment: environment["CLAUDE_CONFIG_DIR"],
                                             secure: environment["SECURE_STORAGE_SET"] == "x" ? environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"] : nil,
                                             directory: claudeDir, defaultDirectory: home + "/.claude")
        states[0].enabled = config.usageEnabled && config.usageClaudeEnabled
        let credential = states[0].enabled ? Self.readClaudeCredential(directory: claudeDir, services: services) : nil
        if states[0].enabled { observeCredential(credential) }
        let foundClaude = credential != nil || fm.fileExists(atPath: claudeDir) || findExecutable("claude") != nil || fm.fileExists(atPath: "/Applications/Claude.app") || fm.fileExists(atPath: home + "/Applications/Claude.app")
        states[0].signedIn = credential != nil
        states[0].plan = credential?.plan
        if let credential, credential.expired { states[0].detection = "Session expired — open Claude Code to refresh" }
        else { states[0].detection = credential != nil ? "Detected, signed in" : (foundClaude ? "Found but not signed in — run `claude` and /login" : "Claude Code not found — install Claude Code (CLI or app) and sign in to enable") }
        if !states[0].enabled { states[0].detection = "Usage disabled" }
        else if blockedClaudeStamp != nil && blockedClaudeStamp == knownClaudeStamp { states[0].detection = "Session expired — open Claude Code to refresh" }
        executable = codexExecutable()
        states[1].enabled = config.usageEnabled && config.usageCodexEnabled
        let auth = states[1].enabled && fm.fileExists(atPath: codexHome + "/auth.json")
        states[1].signedIn = auth
        states[1].detection = auth ? "Detected, signed in" : (executable != nil ? "Found but not signed in — open Codex and sign in with ChatGPT" : "Codex not found — install Codex CLI or app and sign in with ChatGPT")
        if !states[1].enabled { states[1].detection = "Usage disabled" }
        if oldClaude != claudeDir || oldCodex != codexHome || watchers.isEmpty {
            watchers.removeAll()
            watchers.append(UsageWatcher(paths: [codexHome + "/sessions"], queue: queue) { [weak self] paths in self?.localEvents(paths) })
        }
        if states[0].enabled && config.usageClaudeStatusLine {
            if claudeWatcher == nil {
                let path = support.appendingPathComponent("claude-usage.json").path
                claudeWatcher = UsageFileWatcher(path: path, queue: queue) { [weak self] in self?.localEvents([path]) }
            }
            claudeWatcher?.refresh()
        } else { claudeWatcher = nil }
        readLocal(); publish()
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
    private static func readClaudeCredential(directory: String, services: [String]) -> Credential? {
        func parse(_ object: [String: Any]?) -> Credential? {
            guard let oauth = object?["claudeAiOauth"] as? [String: Any], let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
            return Credential(token: token, plan: oauth["rateLimitTier"] as? String ?? oauth["subscriptionType"] as? String, expiresAt: UsageJSON.number(oauth["expiresAt"]))
        }
        for service in services {
            for account in UsageCredentials.accounts(NSUserName()) {
                let result = UsageProcess.run("/usr/bin/security", ["find-generic-password", "-s", service, "-a", account, "-w"], timeout: 3)
                if result.status == 0, let credential = parse(UsageJSON.object(result.data)) { return credential }
            }
        }
        return parse(readJSON(URL(fileURLWithPath: directory + "/.credentials.json")))
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
        claudeWatcher?.refresh()
        detect(force: false)
        guard visible else { return }
        let now = Date()
        for state in states where state.available {
            for w in state.reading?.windows ?? [] where w.isResetting(now) {
                let key = state.id + w.id + String(w.resetsAt?.timeIntervalSince1970 ?? 0)
                if !consumedResets.contains(key), canFetch(state.provider, force: false) {
                    consumedResets.insert(key); fetch(state.provider, force: false)
                }
            }
        }
        if alwaysVisible && now >= nextPeriodic {
            nextPeriodic = now.addingTimeInterval(900 + Double.random(in: 0...90))
            for p in UsageProvider.allCases { fetch(p, force: false) }
        }
    }
    private func canFetch(_ p: UsageProvider, force: Bool) -> Bool {
        let s = states[index(p)], now = Date()
        guard s.available, !s.fetching, !active.contains(p), (s.cooldownUntil ?? .distantPast) <= now else { return false }
        if p == .claude, let blockedClaudeStamp, blockedClaudeStamp == knownClaudeStamp { return false }
        if force {
            return (errorCounts[p] ?? 0) == 0 || now.timeIntervalSince(lastAttempt[p] ?? .distantPast) >= 15
        }
        let sourceDate = p == .claude ? s.reading?.apiDate : s.reading?.date
        return (retryNotBefore[p] ?? .distantPast) <= now && now.timeIntervalSince(sourceDate ?? .distantPast) >= p.interval && now.timeIntervalSince(lastAttempt[p] ?? .distantPast) >= p.interval
    }
    private static func failureDelay(_ count: Int) -> TimeInterval { min(1800, 120 * pow(2, Double(max(0, min(count, 4))))) }
    private func recordOutcome(_ result: FetchResult, provider p: UsageProvider) {
        let i = index(p)
        if result.status == 429 {
            let count = failures[p] ?? 0
            let delay = min(1800, max(60, result.retryAfter, 60 * pow(2, Double(min(count, 5)))))
            failures[p] = count + 1; states[i].cooldownUntil = Date().addingTimeInterval(delay)
        } else if result.status == 200, let reading = result.reading {
            failures[p] = 0; states[i].cooldownUntil = nil
            errorCounts[p] = 0; retryNotBefore[p] = nil
            if p == .claude { blockedClaudeStamp = nil }
            accept(reading, provider: p)
        } else {
            let count = errorCounts[p] ?? 0
            retryNotBefore[p] = Date().addingTimeInterval(Self.failureDelay(count))
            errorCounts[p] = min(30, count + 1)
            if p == .claude && result.expired {
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
    }
    private func fetch(_ p: UsageProvider, force: Bool) {
        if p == .claude, states[0].available, blockedClaudeStamp != nil, !active.contains(p), Date().timeIntervalSince(lastCredentialCheck) >= 15 {
            observeCredential(Self.readClaudeCredential(directory: claudeDir, services: services))
        }
        guard canFetch(p, force: force) else { return }
        let i = index(p), started = Date(), currentGeneration = generations[p] ?? 0
        active.insert(p)
        states[i].fetching = true; lastAttempt[p] = started; publish()
        // Capture paths on the service queue. The independent worker never touches mutable service state.
        let dir = claudeDir, home = codexHome, exe = executable, keychainServices = services
        var env = ProcessInfo.processInfo.environment
        env["CODEX_HOME"] = home
        if let path = environment["PATH"], !path.isEmpty { env["PATH"] = path }
        let processEnvironment = env
        DispatchQueue.global(qos: .utility).async {
            let result: FetchResult
            if p == .claude { result = Self.fetchClaude(directory: dir, services: keychainServices) }
            else { result = Self.fetchCodex(home: home, executable: exe, environment: processEnvironment) }
            self.queue.async {
                self.active.remove(p)
                self.states[i].fetching = false
                guard currentGeneration == (self.generations[p] ?? 0) else { self.publish(); self.fetch(p, force: false); return }
                self.states[i].error = result.error
                self.recordOutcome(result, provider: p)
                if result.expired { self.states[i].detection = p == .claude ? "Session expired — open Claude Code to refresh" : "Session expired — open Codex to refresh" }
                let cooldown = max(0, self.states[i].cooldownUntil?.timeIntervalSinceNow ?? 0)
                log("usage: \(p.rawValue) fetch status=\(result.status) duration=\(Int(Date().timeIntervalSince(started) * 1000))ms cooldown=\(Int(cooldown))s outcome=\(result.reading == nil ? "unavailable" : "ok")")
                self.publish()
            }
        }
    }
    private static func http(_ address: String, headers: [String: String]) -> (Data, HTTPURLResponse?) {
        guard let url = URL(string: address) else { return (Data(), nil) }
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
        if semaphore.wait(timeout: .now() + 11) == .timedOut { task.cancel(); session.invalidateAndCancel(); return (Data(), nil) }
        session.invalidateAndCancel(); return (output.data, output.response)
    }
    private static func retryAfter(_ response: HTTPURLResponse?) -> TimeInterval {
        guard let s = response?.value(forHTTPHeaderField: "Retry-After") else { return 0 }
        if let n = Double(s), n.isFinite { return n }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f.date(from: s)?.timeIntervalSinceNow ?? 0
    }
    private static func fetchClaude(directory: String, services: [String], credentialReader: (() -> Credential?)? = nil,
                                    transport: ((String, [String: String]) -> (Data, HTTPURLResponse?))? = nil) -> FetchResult {
        let read = credentialReader ?? { readClaudeCredential(directory: directory, services: services) }
        let send = transport ?? http
        var credential = read()
        for attempt in 0...1 {
            guard let current = credential, !current.expired else {
                return FetchResult(status: 401, error: "Session expired — open Claude Code to refresh", expired: true, credentialStamp: credential?.stamp ?? CredentialStamp())
            }
            let (data, response) = send("https://api.anthropic.com/api/oauth/usage", ["Authorization": "Bearer " + current.token, "anthropic-beta": "oauth-2025-04-20", "Accept": "application/json"])
            let status = response?.statusCode ?? 0
            if status == 401 && attempt == 0 {
                let reread = read()
                if let reread, reread.token != current.token { credential = reread; continue }
                return FetchResult(status: 401, error: "Session expired — open Claude Code to refresh", expired: true, credentialStamp: reread?.stamp ?? CredentialStamp())
            }
            if status == 429 { return FetchResult(status: status, error: "Rate-limited", retryAfter: retryAfter(response)) }
            guard status == 200, let obj = UsageJSON.object(data) else {
                return FetchResult(status: status, error: status == 401 ? "Session expired — open Claude Code to refresh" : "n/a — usage unavailable", expired: status == 401, credentialStamp: current.stamp)
            }
            var reading = UsageJSON.claude(obj, at: Date())
            reading.plan = current.plan
            return FetchResult(reading: reading, status: status, error: reading.windows.isEmpty ? "n/a — unrecognized usage data" : nil)
        }
        return FetchResult(error: "n/a")
    }
    private static func fetchCodex(home: String, executable: String?, environment: [String: String]) -> FetchResult {
        if let executable {
            let result = UsageProcess.run(executable, ["app-server"], timeout: 10, environment: environment, rpc: true)
            guard let obj = UsageJSON.object(result.data) else { return FetchResult(error: result.timedOut ? "n/a — Codex timed out" : "n/a — Codex unavailable") }
            if let error = obj["error"] as? [String: Any] {
                // Inspect the message for classification, never publish or log arbitrary server text.
                let text = (error["message"] as? String ?? "").lowercased()
                let rateLimited = text.contains("429") || text.contains("rate limit")
                let expired = text.contains("unauthorized") || text.contains("not logged") || text.contains("401")
                return FetchResult(status: rateLimited ? 429 : (expired ? 401 : -1), error: rateLimited ? "Rate-limited" : (expired ? "Session expired — open Codex to refresh" : "n/a — Codex unavailable"), expired: expired)
            }
            guard let limits = (obj["result"] as? [String: Any])?["rateLimits"] as? [String: Any] else { return FetchResult(error: "n/a — unrecognized usage data") }
            let reading = UsageJSON.codex(limits, at: Date(), format: "rpc")
            return FetchResult(reading: reading, status: 200, error: reading.windows.isEmpty ? "n/a — unrecognized usage data" : nil)
        }
        guard let tokens = readJSON(URL(fileURLWithPath: home + "/auth.json"))?["tokens"] as? [String: Any], let token = tokens["access_token"] as? String, !token.isEmpty, let account = tokens["account_id"] as? String, !account.isEmpty else { return FetchResult(error: "n/a — sign in to Codex with ChatGPT") }
        let (data, response) = http("https://chatgpt.com/backend-api/wham/usage", headers: ["Authorization": "Bearer " + token, "ChatGPT-Account-Id": account, "Accept": "application/json"])
        let status = response?.statusCode ?? 0
        if status == 429 { return FetchResult(status: status, error: "Rate-limited", retryAfter: retryAfter(response)) }
        guard status == 200, let obj = UsageJSON.object(data), var limits = obj["rate_limit"] as? [String: Any] else { return FetchResult(status: status, error: status == 401 ? "Session expired — open Codex to refresh" : "n/a — usage unavailable", expired: status == 401) }
        limits["plan_type"] = obj["plan_type"]
        let reading = UsageJSON.codex(limits, at: Date(), format: "http")
        return FetchResult(reading: reading, status: status, error: reading.windows.isEmpty ? "n/a — unrecognized usage data" : nil)
    }
    private static func readJSON(_ url: URL) -> [String: Any]? {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= 1_048_576,
              let data = try? Data(contentsOf: url) else { return nil }
        return UsageJSON.object(data)
    }
    private func readJSON(_ url: URL) -> [String: Any]? { Self.readJSON(url) }
    private func accept(_ reading: UsageReading, provider: UsageProvider) {
        let i = index(provider)
        guard reading.date <= Date().addingTimeInterval(5), reading.date > (states[i].reading?.date ?? .distantPast) else { return }
        var reading = reading
        if reading.plan == nil { reading.plan = states[i].reading?.plan ?? states[i].plan }
        states[i].reading = reading
        if !reading.windows.isEmpty { states[i].error = nil }
        saveCache()
    }
    private func localEvents(_ paths: [String]) {
        let root = UsageWatcher.resolvedPath(codexHome + "/sessions")
        let local = UsageWatcher.resolvedPath(support.appendingPathComponent("claude-usage.json").path)
        let resolved = paths.map(UsageWatcher.resolvedPath)
        let codex = resolved.contains { $0 == root || $0.hasPrefix(root + "/") }
        let claude = resolved.contains(local)
        if codex || claude { readLocal(codex: codex, claude: claude) }
    }
    private static func mergingClaudeLocal(_ reading: UsageReading, previous: UsageReading?) -> UsageReading {
        var merged = reading
        merged.apiDate = previous?.apiDate
        for window in previous?.windows ?? [] where window.id.hasPrefix("weekly_scoped") || window.id == "seven_day_opus" || window.id == "seven_day_sonnet" {
            if !merged.windows.contains(where: { $0.id == window.id || $0.title == window.title }) { merged.windows.append(window) }
        }
        return merged
    }
    private func readLocal(codex: Bool = true, claude: Bool = true) {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: codexHome + "/sessions")
        var newest: [(URL, Date)] = []
        if codex && states[1].enabled, let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey], options: [.skipsHiddenFiles]) {
            // Walk metadata only; retain just three paths and read at most 256 KiB per file.
            let deadline = Date().addingTimeInterval(2)
            for case let url as URL in enumerator {
                if Date() >= deadline { log("usage: local scan reached time budget"); break }
                guard url.lastPathComponent.hasPrefix("rollout-"), url.pathExtension == "jsonl" else { continue }
                if let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]), values.isRegularFile == true {
                    newest.append((url, values.contentModificationDate ?? .distantPast)); newest.sort { $0.1 > $1.1 }
                    if newest.count > 3 { newest.removeLast() }
                }
            }
        }
        var best: UsageReading?
        for (url, _) in newest {
            guard let h = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? h.close() }
            guard let size = try? h.seekToEnd() else { continue }
            let offset = size > 262_144 ? size - 262_144 : 0
            guard (try? h.seek(toOffset: offset)) != nil, let data = try? h.read(upToCount: 262_144) else { continue }
            var lines = data.split(separator: 10)
            if offset > 0 && !lines.isEmpty { lines.removeFirst() }
            for line in lines {
                guard line.range(of: Data("token_count".utf8)) != nil,
                      let obj = UsageJSON.object(Data(line)), obj["type"] as? String == "event_msg",
                      let payload = obj["payload"] as? [String: Any], payload["type"] as? String == "token_count",
                      let limits = payload["rate_limits"] as? [String: Any],
                      limits["limit_id"] == nil || limits["limit_id"] is NSNull || limits["limit_id"] as? String == "codex",
                      let date = UsageJSON.date(obj["timestamp"]), date > (best?.date ?? .distantPast) else { continue }
                let reading = UsageJSON.codex(limits, at: date, format: "local")
                if !reading.windows.isEmpty { best = reading }
            }
        }
        if let best { accept(best, provider: .codex) }
        if claude && states[0].enabled && config.usageClaudeStatusLine, let obj = readJSON(support.appendingPathComponent("claude-usage.json")),
           let date = UsageJSON.date(obj["timestamp"]), let limits = obj["rate_limits"] as? [String: Any] {
            let reading = UsageJSON.claude(limits, at: date, local: true)
            if !reading.windows.isEmpty { accept(Self.mergingClaudeLocal(reading, previous: states[0].reading), provider: .claude) }
        }
        publish()
    }
    private struct Cache: Codable { var directories: [String: String]; var readings: [String: UsageReading]; var cooldowns: [String: Date]; var failures: [String: Int] }
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
        let cache = Cache(directories: ["claude": claudeDir, "codex": codexHome], readings: readings, cooldowns: cooldowns, failures: counts)
        do {
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            try JSONEncoder().encode(cache).write(to: support.appendingPathComponent("usage-cache.json"), options: .atomic)
        } catch { log("usage: cache write failed") }
    }
    private func statusLine(enable: Bool, directory: String) {
        let fm = FileManager.default, script = support.appendingPathComponent("claude-statusline.sh")
        let settings = URL(fileURLWithPath: directory).appendingPathComponent("settings.json")
        // Shell quoting also handles home directories containing apostrophes/spaces.
        func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let command = quote(script.path)
        let snippet = "printf '%s' \"$input\" | " + quote(script.path) + " >/dev/null # input must contain your original stdin JSON"
        do {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
                message("Claude config folder must already exist; no settings were changed."); return
            }
            var object: [String: Any] = [:]
            let exists = fm.fileExists(atPath: settings.path)
            let original = exists ? try Data(contentsOf: settings) : Data()
            if exists {
                guard let parsed = UsageJSON.object(original) else { message("Cannot edit malformed settings.json"); return }
                object = parsed
            }
            let entry = object["statusLine"] as? [String: Any]
            let ours = entry?["type"] as? String == "command" && (entry?["command"] as? String == command || entry?["command"] as? String == script.path)
            if enable && ours { message("Live updates already configured."); return }
            if enable {
                try fm.createDirectory(at: support, withIntermediateDirectories: true)
                // JXA is provided by macOS: no jq, Python or third-party runtime is required.
                let body = """
                #!/bin/sh
                exec /usr/bin/osascript -l JavaScript -e '\
                ObjC.import("Foundation");
                var input = $.NSFileHandle.fileHandleWithStandardInput.readDataToEndOfFile;
                var text = ObjC.unwrap($.NSString.alloc.initWithDataEncoding(input, $.NSUTF8StringEncoding));
                try {
                  var d = JSON.parse(text);
                  var out = JSON.stringify({timestamp: Date.now()/1000, rate_limits: d.rate_limits || {}});
                  var base = $.NSHomeDirectory().stringByAppendingPathComponent("Library/Application Support/MacTaskbar/claude-usage.json");
                  var data = $(out).dataUsingEncoding($.NSUTF8StringEncoding);
                  data.writeToFileAtomically(base, true);
                  var name = (d.model || {}).display_name || "Claude";
                  $.NSFileHandle.fileHandleWithStandardOutput.writeData($(name + "\\n").dataUsingEncoding($.NSUTF8StringEncoding));
                } catch (_) {}
                '
                """
                try Data(body.utf8).write(to: script, options: .atomic)
                try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
                if object["statusLine"] != nil && !ours { message("You already have a statusLine; add this line to your script: " + snippet); return }
                object["statusLine"] = ["type": "command", "command": command]
            } else {
                guard ours else { message(""); return }
                object.removeValue(forKey: "statusLine")
            }
            let backup = settings.appendingPathExtension("mactaskbar.bak")
            if exists && !fm.fileExists(atPath: backup.path) { try original.write(to: backup, options: .withoutOverwriting) }
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: settings, options: .atomic)
            message(enable ? "Live updates enabled for new Claude Code sessions." : "")
        } catch { message("Could not update Claude settings; check folder permissions."); log("usage: statusLine configuration failed") }
    }
}

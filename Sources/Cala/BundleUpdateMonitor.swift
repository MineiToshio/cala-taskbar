import AppKit

/// Checks the installed bundle directly, since Bundle.main caches the running build's Info.plist.
final class BundleUpdateMonitor: NSObject {
    private let bundleURL = Bundle.main.bundleURL
    private let runningVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    private let bundleID = Bundle.main.bundleIdentifier
    private var poll: Timer?
    private var retry: Timer?
    private var retryNotBefore: TimeInterval = 0
    private var lastBlocker: UpdatePolicy.Blocker?
    private var candidate: (version: String, seenAt: TimeInterval)?
    private var sessionActive = true

    func start() {
        guard runningVersion != nil else { return }
        let notifications = NSWorkspace.shared.notificationCenter
        notifications.addObserver(self, selector: #selector(sessionBecameActive(_:)),
                                  name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        notifications.addObserver(self, selector: #selector(sessionResignedActive(_:)),
                                  name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        notifications.addObserver(self, selector: #selector(woke(_:)), name: NSWorkspace.didWakeNotification, object: nil)
        poll = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.check() }
        check()
    }

    func stop() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        poll?.invalidate()
        poll = nil
        retry?.invalidate()
        retry = nil
    }

    @objc private func sessionBecameActive(_ notification: Notification) {
        DispatchQueue.main.async {
            self.sessionActive = true
            self.check()
        }
    }

    @objc private func sessionResignedActive(_ notification: Notification) {
        DispatchQueue.main.async { self.sessionActive = false }
    }

    @objc private func woke(_ notification: Notification) {
        DispatchQueue.main.async { self.check() }
    }

    private func diskVersion() -> String? {
        let contents = bundleURL.appendingPathComponent("Contents")
        guard let bundleID, let data = try? Data(contentsOf: contents.appendingPathComponent("Info.plist")),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              plist["CFBundleIdentifier"] as? String == bundleID,
              let executable = plist["CFBundleExecutable"] as? String,
              executable == Bundle.main.executableURL?.lastPathComponent,
              FileManager.default.isExecutableFile(atPath: contents.appendingPathComponent("MacOS")
                  .appendingPathComponent(executable).path) else { return nil }
        return plist["CFBundleVersion"] as? String
    }

    private func check() {
        guard poll != nil else { return }
        retry?.invalidate()
        retry = nil
        let now = ProcessInfo.processInfo.systemUptime
        if now < retryNotBefore {
            scheduleRetry(after: retryNotBefore - now)
            return
        }
        guard let disk = diskVersion(),
              UpdatePolicy.decide(running: runningVersion, disk: disk, blockers: []) == .relaunch else {
            lastBlocker = nil
            candidate = nil
            return
        }

        if candidate?.version != disk {
            candidate = (disk, now)
            lastBlocker = nil
        }
        if let candidate, now - candidate.seenAt < 5 {
            scheduleRetry()
            return
        }

        let blockers = Self.blockers(sessionActive: sessionActive)

        switch UpdatePolicy.decide(running: runningVersion, disk: disk, blockers: blockers) {
        case .none:
            return
        case .deferred(let reason):
            if reason != lastBlocker { log("update: deferred (\(reason.rawValue))") }
            lastBlocker = reason
            if reason == .inactiveSession { return }
        case .relaunch:
            lastBlocker = nil
            log("update: new build \(disk) found, relaunching")
            Relaunch.open(bundleURL, inBackground: true)
            // A successful termination never returns here.
            guard poll != nil else { return }
            log("update: deferred (termination cancelled)")
            retryNotBefore = ProcessInfo.processInfo.systemUptime + 60
            scheduleRetry(after: 60)
            return
        }

        scheduleRetry()
    }

    static func blockers(sessionActive: Bool) -> [UpdatePolicy.Blocker] {
        var blockers: [UpdatePolicy.Blocker] = []
        if !sessionActive { blockers.append(.inactiveSession) }
        // A pressed button also covers a window drag when the Zones module is disabled.
        if NSEvent.pressedMouseButtons != 0 || ZonesModule.current?.isInZonesMode == true { blockers.append(.drag) }
        if ZonesModule.editorOpen { blockers.append(.zonesEditor) }
        if let window = SettingsWindowController.shared.window, window.isVisible || window.isMiniaturized {
            blockers.append(.settings)
        }
        if OnboardingWindowController.shared.isOpen { blockers.append(.onboarding) }
        if NSApp.modalWindow != nil || NSApp.windows.contains(where: { $0.attachedSheet != nil }) {
            blockers.append(.modal)
        }

        if UpdateService.shared.blocksRelaunch { blockers.append(.updater) }
        return blockers
    }

    private func scheduleRetry(after delay: TimeInterval = 5) {
        retry = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in self?.check() }
    }
}

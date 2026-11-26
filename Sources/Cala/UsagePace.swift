import Foundation
import Combine
import UserNotifications

/// Burn-rate projection and quota alerts for the Claude / Codex usage windows.
///
/// The rate comes from recent readings and falls back to the average since the window started.
/// No credentials are involved: it only looks at the usage percentages already published.
final class UsagePace: NSObject, UNUserNotificationCenterDelegate {
    static let shared = UsagePace()
    private var history = UsagePaceHistory()
    private var bag = Set<AnyCancellable>()
    private var store: ConfigStore?
    private var run: ModuleCancellation?
    private var pendingAlerts = Set<String>()
    private let firedKey = "usageAlertsFired"

    private var canNotify: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    func start(store: ConfigStore) {
        guard self.store == nil else { return }
        self.store = store
        let run = ModuleCancellation()
        self.run = run
        loadHistory()
        if canNotify { UNUserNotificationCenter.current().delegate = self }
        UsageService.shared.$providers.receive(on: DispatchQueue.main).sink { [weak self] states in
            guard !run.isCancelled else { return }
            self?.ingest(states)
        }.store(in: &bag)
    }

    func stop() {
        run?.cancel()
        run = nil
        bag.removeAll()
        if canNotify {
            let center = UNUserNotificationCenter.current()
            if center.delegate === self { center.delegate = nil }
        }
        store = nil
    }

    func pace(_ provider: UsageProvider, _ window: UsageWindow, now: Date = Date()) -> PaceResult? {
        history.pace(provider, window, now: now)
    }

    // MARK: History and alerts

    private func ingest(_ states: [UsageState]) {
        let now = Date()
        for state in states where state.available {
            guard let reading = state.reading else { continue }
            history.ingest(reading, for: state.provider, now: now)
            if store?.config.usageAlertsEnabled == true { evaluate(state, now: now) }
        }
        saveHistory(now)
    }

    // MARK: History persistence (so the weekly rate survives a restart)

    private var historyURL: URL { AppPaths.supportDirectory.appendingPathComponent("usage-history.json") }
    private var lastHistorySave = Date.distantPast

    private func loadHistory() {
        guard let size = (try? historyURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size < 2_000_000,
              let data = try? Data(contentsOf: historyURL),
              let raw = try? JSONDecoder().decode([String: [[Double]]].self, from: data) else { return }
        history.restore(raw, now: Date())
    }

    private func saveHistory(_ now: Date) {
        guard now.timeIntervalSince(lastHistorySave) > 60 else { return }
        lastHistorySave = now
        guard let data = try? JSONEncoder().encode(history.persistedSamples) else { return }
        try? FileManager.default.createDirectory(at: AppPaths.supportDirectory, withIntermediateDirectories: true)
        try? data.write(to: historyURL, options: .atomic)
    }

    private func evaluate(_ state: UsageState, now: Date) {
        let threshold = Double(store?.config.usageAlertThreshold ?? 20)
        for w in state.orderedWindows where !w.isResetting(now) {
            let remaining = 100 - w.used
            guard remaining > 0, let reset = w.resetsAt, reset > now,
                  let key = UsagePaceHistory.key(state.provider, w) else { continue }
            let cycle = String(Int(reset.timeIntervalSince1970 / 60))
            let base = key + "|" + cycle
            let resetIn = UsagePaceProjection.formatted(reset.timeIntervalSince(now))
            if remaining <= threshold {
                fire(base + "|thr", title: calendarText("\(state.provider.title): \(Int(remaining.rounded()))% left", "\(state.provider.title): te queda \(Int(remaining.rounded()))%"),
                     body: calendarText("\(w.title) · resets in \(resetIn)", "\(w.title) · se reinicia en \(resetIn)"))
            } else if let p = pace(state.provider, w, now: now), p.warn, p.secondsToEmpty <= 3600 {
                fire(base + "|proj", title: calendarText("\(state.provider.title) may run out in \(UsagePaceProjection.formatted(p.secondsToEmpty))", "\(state.provider.title) se podría agotar en \(UsagePaceProjection.formatted(p.secondsToEmpty))"),
                     body: calendarText("\(w.title) · at this pace it ends before the reset in \(resetIn)", "\(w.title) · a este ritmo se acaba antes del reinicio en \(resetIn)"))
            }
        }
    }

    private func fire(_ id: String, title: String, body: String) {
        guard canNotify, let run else { return }
        let defaults = UserDefaults.standard
        guard defaults.dictionary(forKey: firedKey)?[id] == nil, pendingAlerts.insert(id).inserted else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self else { return }
                guard !run.isCancelled, self.store?.config.usageAlertsEnabled == true,
                      [.authorized, .provisional].contains(settings.authorizationStatus) else {
                    self.pendingAlerts.remove(id)
                    return
                }
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                content.sound = .default
                center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { [weak self] error in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.pendingAlerts.remove(id)
                        guard error == nil else { return }
                        let now = Date().timeIntervalSince1970
                        let fired = defaults.dictionary(forKey: self.firedKey) as? [String: Double] ?? [:]
                        var recent = fired.filter { $0.value > now - 10 * 86400 }
                        recent[id] = now
                        defaults.set(recent, forKey: self.firedKey)
                        log("usage: alert \(id.split(separator: "|").last ?? "")")
                    }
                }
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

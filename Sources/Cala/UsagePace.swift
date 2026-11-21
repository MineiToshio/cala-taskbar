import Foundation
import Combine
import UserNotifications

struct PaceResult {
    var text: String
    /// The quota is projected to run out before it resets.
    var warn: Bool
    var secondsToEmpty: TimeInterval
    var secondsToReset: TimeInterval
}

/// Burn-rate projection and quota alerts for the Claude / Codex usage windows.
///
/// The rate comes from recent readings (last 30 min, kept in memory) and falls back to the average since the
/// window started. No credentials are involved: it only looks at the usage percentages already published.
final class UsagePace: NSObject, UNUserNotificationCenterDelegate {
    static let shared = UsagePace()
    private var samples: [String: [(date: Date, used: Double)]] = [:]
    private var bag = Set<AnyCancellable>()
    private var store: ConfigStore?
    private let firedKey = "usageAlertsFired"

    private func key(_ p: UsageProvider, _ w: UsageWindow) -> String { p.rawValue + "|" + w.id }
    private var canNotify: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    func start(store: ConfigStore) {
        guard self.store == nil else { return }
        self.store = store
        if canNotify { UNUserNotificationCenter.current().delegate = self }
        UsageService.shared.$providers.receive(on: DispatchQueue.main).sink { [weak self] in self?.ingest($0) }.store(in: &bag)
    }

    // MARK: Projection

    static func duration(_ w: UsageWindow) -> TimeInterval? {
        let minutes = w.durationMinutes ?? w.presentationOrder.1
        return minutes.isFinite && minutes > 0 ? minutes * 60 : nil
    }

    static func formatted(_ seconds: TimeInterval) -> String {
        let m = max(1, Int((seconds / 60).rounded()))
        if m >= 1440 { let d = m / 1440, h = (m % 1440) / 60; return h > 0 ? "\(d) d \(h) h" : "\(d) d" }
        if m >= 60 { let h = m / 60, r = m % 60; return r > 0 ? "\(h) h \(r) min" : "\(h) h" }
        return "\(m) min"
    }

    func pace(_ provider: UsageProvider, _ window: UsageWindow, now: Date = Date()) -> PaceResult? {
        guard let reset = window.resetsAt, reset > now, !window.isResetting(now) else { return nil }
        let remaining = 100 - window.used
        guard remaining > 0 else { return nil }
        let untilReset = reset.timeIntervalSince(now)
        var rate: Double?   // percentage points per second
        let recent = (samples[key(provider, window)] ?? []).filter { now.timeIntervalSince($0.date) <= 1800 }
        if let first = recent.first, let last = recent.last, last.date.timeIntervalSince(first.date) >= 300 {
            let r = (last.used - first.used) / last.date.timeIntervalSince(first.date)
            if r <= 1e-7 { return nil }      // idle lately: nothing to project
            rate = r
        } else if let total = Self.duration(window) {
            let elapsed = total - untilReset
            if elapsed >= 600, window.used > 0 { rate = window.used / elapsed }
        }
        guard let rate else { return nil }
        let toEmpty = remaining / rate
        if toEmpty < untilReset - 60 {
            let text = calendarText("At this pace it runs out in \(Self.formatted(toEmpty)), before the reset",
                                    "A este ritmo se agota en \(Self.formatted(toEmpty)), antes del reinicio")
            return PaceResult(text: text, warn: true, secondsToEmpty: toEmpty, secondsToReset: untilReset)
        }
        let left = max(0, Int((remaining - rate * untilReset).rounded()))
        let text = calendarText("At this pace you reach the reset with ~\(left)% left",
                                "A este ritmo llegas al reinicio con ~\(left)% disponible")
        return PaceResult(text: text, warn: false, secondsToEmpty: toEmpty, secondsToReset: untilReset)
    }

    // MARK: History and alerts

    private func ingest(_ states: [UsageState]) {
        let now = Date()
        for state in states where state.available {
            guard let reading = state.reading else { continue }
            for w in reading.windows where w.used.isFinite {
                let k = key(state.provider, w)
                var list = samples[k] ?? []
                if let last = list.last {
                    if last.date == reading.date { continue }
                    if w.used < last.used - 5 { list.removeAll() }     // the window reset
                }
                list.append((reading.date, w.used))
                list = list.filter { now.timeIntervalSince($0.date) <= 10_800 }
                if list.count > 240 { list.removeFirst(list.count - 240) }
                samples[k] = list
            }
            if store?.config.usageAlertsEnabled == true { evaluate(state, now: now) }
        }
    }

    private func evaluate(_ state: UsageState, now: Date) {
        let threshold = Double(store?.config.usageAlertThreshold ?? 20)
        for w in state.orderedWindows where !w.isResetting(now) {
            let remaining = 100 - w.used
            guard remaining > 0, let reset = w.resetsAt, reset > now else { continue }
            let cycle = String(Int(reset.timeIntervalSince1970 / 60))
            let base = state.provider.rawValue + "|" + w.id + "|" + cycle
            let resetIn = Self.formatted(reset.timeIntervalSince(now))
            if remaining <= threshold {
                fire(base + "|thr", title: calendarText("\(state.provider.title): \(Int(remaining.rounded()))% left", "\(state.provider.title): te queda \(Int(remaining.rounded()))%"),
                     body: calendarText("\(w.title) · resets in \(resetIn)", "\(w.title) · se reinicia en \(resetIn)"))
            } else if let p = pace(state.provider, w, now: now), p.warn, p.secondsToEmpty <= 3600 {
                fire(base + "|proj", title: calendarText("\(state.provider.title) may run out in \(Self.formatted(p.secondsToEmpty))", "\(state.provider.title) se podría agotar en \(Self.formatted(p.secondsToEmpty))"),
                     body: calendarText("\(w.title) · at this pace it ends before the reset in \(resetIn)", "\(w.title) · a este ritmo se acaba antes del reinicio en \(resetIn)"))
            }
        }
    }

    private func fire(_ id: String, title: String, body: String) {
        let defaults = UserDefaults.standard
        var fired = defaults.dictionary(forKey: firedKey) as? [String: Double] ?? [:]
        guard fired[id] == nil else { return }
        let cutoff = Date().timeIntervalSince1970 - 10 * 86400
        fired = fired.filter { $0.value > cutoff }
        fired[id] = Date().timeIntervalSince1970
        defaults.set(fired, forKey: firedKey)
        log("usage: alert \(id.split(separator: "|").last ?? "")")
        deliver(id: id, title: title, body: body)
    }

    private func deliver(id: String, title: String, body: String) {
        guard canNotify else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            let send = {
                let c = UNMutableNotificationContent()
                c.title = title; c.body = body; c.sound = .default
                center.add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
            }
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: send()
            case .notDetermined: center.requestAuthorization(options: [.alert, .sound]) { ok, _ in if ok { send() } }
            default: break
            }
        }
    }

    /// Called when the user turns alerts on, so the macOS permission prompt appears in a clear context.
    func requestAuthorization() {
        guard canNotify else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

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
    private var run: ModuleCancellation?
    private let firedKey = "usageAlertsFired"

    private func key(_ p: UsageProvider, _ w: UsageWindow) -> String { p.rawValue + "|" + w.id }
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

    // MARK: Projection

    static func duration(_ w: UsageWindow) -> TimeInterval? {
        let minutes = w.durationMinutes ?? w.presentationOrder.1
        return minutes.isFinite && minutes > 0 ? minutes * 60 : nil
    }

    /// Exact remaining time, never rounded up: "2 d 3 h 12 min", "4 h 47 min", "16 min", "42 s".
    static func formatted(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))      // truncated: a countdown never claims more time than there is
        let d = total / 86400, h = (total % 86400) / 3600, m = (total % 3600) / 60
        var parts: [String] = []
        if d > 0 { parts.append("\(d) d") }
        if h > 0 { parts.append("\(h) h") }
        if m > 0 { parts.append("\(m) min") }
        return parts.isEmpty ? "\(total) s" : parts.joined(separator: " ")
    }

    /// Always answers for a window that is counting (so the line never comes and goes): a projection, "no recent use",
    /// or "measuring". The recent rate uses a lookback proportional to the window (30 min for the 5-hour session, ~8 h
    /// for the weekly one), because the percentages are whole numbers and a weekly window moves too slowly to read a
    /// rate from half an hour of data.
    func pace(_ provider: UsageProvider, _ window: UsageWindow, now: Date = Date()) -> PaceResult? {
        guard let reset = window.resetsAt, reset > now, !window.isResetting(now) else { return nil }
        let remaining = 100 - window.used
        guard remaining > 0 else { return nil }
        let untilReset = reset.timeIntervalSince(now)
        let total = Self.duration(window)
        func result(_ text: String, warn: Bool = false, toEmpty: TimeInterval = .infinity) -> PaceResult {
            PaceResult(text: text, warn: warn, secondsToEmpty: toEmpty, secondsToReset: untilReset)
        }

        let lookback = max(1800, (total ?? 0) * 0.05)
        let recent = (samples[key(provider, window)] ?? []).filter { now.timeIntervalSince($0.date) <= lookback }
        var rate: Double?   // percentage points per second
        if let first = recent.first, let last = recent.last {
            let span = last.date.timeIntervalSince(first.date), delta = last.used - first.used
            if span >= 300 {
                if delta >= 2 || (delta > 0 && span >= lookback * 0.5) { rate = delta / span }
                else if delta <= 0 && span >= lookback * 0.8 {
                    return result(calendarText("No recent use", "Sin uso reciente"))
                }
            }
        }
        if rate == nil, let total {
            let elapsed = total - untilReset
            if window.used <= 0 { return result(calendarText("Not used yet", "Sin uso todavía")) }
            if elapsed >= 600 { rate = window.used / elapsed }
        }
        guard let rate, rate > 0 else { return result(calendarText("Measuring pace…", "Midiendo el ritmo…")) }

        let toEmpty = remaining / rate
        if toEmpty < untilReset - 60 {
            let text = calendarText("At this pace it runs out in \(Self.formatted(toEmpty)), before the reset",
                                    "A este ritmo se agota en \(Self.formatted(toEmpty)), antes del reinicio")
            return result(text, warn: true, toEmpty: toEmpty)
        }
        let left = max(0, Int((remaining - rate * untilReset).rounded()))
        let text = calendarText("At this pace you reach the reset with ~\(left)% left",
                                "A este ritmo llegas al reinicio con ~\(left)% disponible")
        return result(text, toEmpty: toEmpty)
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
                list = list.filter { now.timeIntervalSince($0.date) <= 43_200 }
                if list.count > 600 { list.removeFirst(list.count - 600) }
                samples[k] = list
            }
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
        let now = Date()
        for (k, rows) in raw {
            let list = rows.compactMap { r -> (date: Date, used: Double)? in
                guard r.count == 2, r[0].isFinite, r[1].isFinite else { return nil }
                let d = Date(timeIntervalSince1970: r[0])
                return d <= now.addingTimeInterval(5) && now.timeIntervalSince(d) <= 43_200 ? (d, min(100, max(0, r[1]))) : nil
            }.sorted { $0.date < $1.date }
            if !list.isEmpty { samples[k] = list }
        }
    }

    private func saveHistory(_ now: Date) {
        guard now.timeIntervalSince(lastHistorySave) > 60 else { return }
        lastHistorySave = now
        let raw = samples.mapValues { $0.map { [$0.date.timeIntervalSince1970, $0.used] } }
        guard let data = try? JSONEncoder().encode(raw) else { return }
        try? FileManager.default.createDirectory(at: AppPaths.supportDirectory, withIntermediateDirectories: true)
        try? data.write(to: historyURL, options: .atomic)
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
        guard canNotify, let run else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard !run.isCancelled else { return }
            let send = {
                guard !run.isCancelled else { return }
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

import AppKit
import Combine
import Foundation
import UserNotifications

/// Coordinates learned quota forecasts. State and cache access stay on main; snapshots and replay run on a worker.
final class UsagePace: NSObject, UNUserNotificationCenterDelegate {
    static let shared = UsagePace()

    struct Line {
        let text: String
        var warn = false
    }

    private struct MeterKey: Hashable {
        let provider: UsageProvider
        let meter: QuotaMeter
    }

    private struct ForecastKey: Equatable {
        let series: QuotaSeries
        let cycle: QuotaCycle
        let generation = UUID()
    }

    private struct CachedForecast {
        let result: ForecastResult
        let calculatedAt: Date
    }

    private struct Entry {
        let key: ForecastKey
        var current: QuotaObservation
        var highWater: Double
        var cached: CachedForecast?
    }

    private struct WindowKey: Hashable {
        let provider: UsageProvider
        let id: String
    }

    private struct DisplayWindow {
        let readingDate: Date
        let used: Double
        let reset: Date?
        let observedAt: Date
        let meter: QuotaMeter?
        let observedReset: Date?
        let plan: String?
        let inactive: Bool
    }

    private enum CapRegime: Equatable {
        case absent, unknown, unresolved, inactive, active(Int, Date)
    }

    private let worker = DispatchQueue(label: "local.cala.usage.forecast", qos: .utility)
    private var entries: [MeterKey: Entry] = [:]
    private var nextAllowed: [MeterKey: TimeInterval] = [:]
    private var windows: [WindowKey: DisplayWindow] = [:]
    private var states: [UsageState] = []
    private var refreshTimer: Timer?
    private var computing = false
    private var sleeping = false
    private var refreshedAfter = Date.distantPast

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
        if canNotify { UNUserNotificationCenter.current().delegate = self }

        let service = UsageService.shared
        service.quotaEvents.receive(on: DispatchQueue.main).sink { [weak self] event in
            guard let self, !run.isCancelled else { return }
            switch event {
            case .observations(let readings): self.accept(readings)
            case .discontinuity: self.entries.removeAll()
            case .importUpdated: break
            }
            self.refreshForecasts()
        }.store(in: &bag)
        service.$providers.receive(on: DispatchQueue.main).sink { [weak self] states in
            guard !run.isCancelled else { return }
            self?.ingest(states)
        }.store(in: &bag)
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification] {
            let observer = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // Workspace power notifications arrive on main, before queued service work.
                guard let self, !run.isCancelled else { return }
                self.sleeping = name == NSWorkspace.willSleepNotification
                self.refreshedAfter = Date()
                self.entries.removeAll()
                self.refreshForecasts()
            }
            AnyCancellable { workspace.removeObserver(observer) }.store(in: &bag)
        }
    }

    func stop() {
        run?.cancel()
        run = nil
        bag.removeAll()
        refreshTimer?.invalidate()
        refreshTimer = nil
        entries.removeAll()
        nextAllowed.removeAll()
        windows.removeAll()
        states.removeAll()
        sleeping = false
        refreshedAfter = .distantPast
        if canNotify {
            let center = UNUserNotificationCenter.current()
            if center.delegate === self { center.delegate = nil }
        }
        store = nil
    }

    // MARK: Observations and scheduling

    private func ingest(_ states: [UsageState]) {
        for state in states where !state.available && self.states.contains(where: { $0.provider == state.provider && $0.available }) {
            entries = entries.filter { $0.key.provider != state.provider }
        }
        self.states = states
        let now = Date()
        var visible: [WindowKey: DisplayWindow] = [:]
        for state in states where state.available {
            guard let reading = state.reading else { continue }
            for window in reading.windows {
                let key = WindowKey(provider: state.provider, id: window.id)
                visible[key] = Self.displayWindow(window, in: reading, provider: state.provider,
                                                  plan: state.plan, previous: windows[key])
            }
            evaluateThreshold(state, now: now)
        }
        windows = visible
        refreshForecasts()
    }

    private func accept(_ readings: [QuotaObservation]) {
        guard !sleeping else { return }
        let now = Date()
        for current in readings where current.attribution == .live && current.date >= refreshedAfter && current.reset > now {
            let series = current.series
            entries = entries.filter { $0.key.provider != series.provider ||
                ($0.value.key.series.profile == series.profile && $0.value.key.series.timeZoneID == series.timeZoneID) }
            let meter = MeterKey(provider: series.provider, meter: series.meter)
            let previous = entries[meter]
            if let old = previous?.current, old.date > current.date ||
                (old.date == current.date && old.source.rawValue > current.source.rawValue) { continue }

            if var entry = previous, entry.key.series == series, entry.key.cycle.reset == current.reset,
               current.used >= entry.highWater - 1 {
                if Self.capChanged(from: entry.current, to: current) {
                    entry = Entry(key: ForecastKey(series: series, cycle: entry.key.cycle),
                                  current: current, highWater: entry.highWater)
                }
                entry.current = current
                entry.highWater = max(entry.highWater, current.used)
                entries[meter] = entry
            } else {
                let cycle = QuotaCycle(reset: current.reset, segmentStart: current.date)
                entries[meter] = Entry(key: ForecastKey(series: series, cycle: cycle),
                                       current: current, highWater: current.used)
            }
        }
    }

    private static func capRegime(_ state: QuotaCapState, at date: Date) -> CapRegime {
        switch state {
        case .absent: return .absent
        case .unknown: return .unknown
        case .present(.unknown): return .unresolved
        case .present(.inactive): return .inactive
        case .present(.active(let used, let reset)):
            guard reset > date else { return .unresolved }
            if used >= 100 { return .active(100, reset) }
            if used >= 80 { return .active(80, reset) }
            return .active(0, reset)
        }
    }

    private static func capChanged(from prior: QuotaObservation, to next: QuotaObservation) -> Bool {
        func band(_ used: Double) -> Int {
            if used >= 100 { return 100 }
            if used >= 80 { return 80 }
            return used >= 50 ? 50 : 0
        }
        return capRegime(prior.companion, at: prior.date) != capRegime(next.companion, at: next.date)
            || capRegime(prior.bindingWeekly, at: prior.date) != capRegime(next.bindingWeekly, at: next.date)
            || prior.hardBlockUntil != next.hardBlockUntil
            || (prior.series.meter.durationSeconds == 18_000 && band(prior.used) != band(next.used))
    }

    private func refreshForecasts() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        guard let run, !sleeping, !computing else { return }
        let now = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        nextAllowed = nextAllowed.filter { $0.value > uptime }
        entries = entries.filter { $0.value.current.reset > now }
        let ready = Set(windows.compactMap { key, display -> MeterKey? in
            guard display.used < 100, let meter = display.meter,
                  meter.durationSeconds == 18_000 || meter.durationSeconds == 604_800 else { return nil }
            let meterKey = MeterKey(provider: key.provider, meter: meter)
            guard let entry = entries[meterKey], matches(entry, display: display, now: now) else { return nil }
            return meterKey
        })
        let due = ready.filter { nextAllowed[$0] == nil }
        guard !due.isEmpty else {
            if let next = ready.compactMap({ nextAllowed[$0] }).min() {
                let timer = Timer(timeInterval: max(0.01, next - uptime), repeats: false) { [weak self] _ in
                    self?.refreshForecasts()
                }
                RunLoop.main.add(timer, forMode: .common)
                refreshTimer = timer
            }
            return
        }

        let batch = due.compactMap { entries[$0] }
        computing = true
        worker.async { [weak self] in
            let snapshot = UsageService.shared.quotaHistorySnapshot()
            let engine: any UsageForecasting = UsageForecast()
            let results = batch.compactMap { entry -> (ForecastKey, CachedForecast, TimeInterval)? in
                guard !run.isCancelled else { return nil }
                let current = entry.current
                let calculatedAt = Date()
                guard current.reset > calculatedAt,
                      !Self.isStale(current.date, meter: current.series.meter, now: calculatedAt) else { return nil }
                var calendar = Calendar.current
                calendar.timeZone = TimeZone(identifier: current.series.timeZoneID) ?? .current
                let started = ProcessInfo.processInfo.systemUptime
                let result = engine.forecast(snapshot: snapshot, current: current, calendar: calendar, now: calculatedAt)
                return (entry.key, CachedForecast(result: result, calculatedAt: calculatedAt), started)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.computing = false
                if !run.isCancelled { self.complete(results) }
                self.refreshForecasts()
            }
        }
    }

    private func complete(_ results: [(ForecastKey, CachedForecast, TimeInterval)]) {
        for (key, forecast, started) in results {
            let meter = MeterKey(provider: key.series.provider, meter: key.series.meter)
            nextAllowed[meter] = started + (meter.meter.durationSeconds == 18_000 ? 60 : 300)
            if entries[meter]?.key == key { entries[meter]?.cached = forecast }
        }
        let now = Date()
        for state in states where state.available {
            evaluatePrediction(state, now: now)
        }
    }

    // MARK: Display identity and freshness

    private static func displayWindow(_ window: UsageWindow, in reading: UsageReading, provider: UsageProvider,
                                      plan: String?, previous: DisplayWindow?) -> DisplayWindow {
        let duration = window.durationMinutes ?? window.presentationOrder.1
        let payload = reading.quota?.windows ?? []
        let candidates = payload.filter { raw in
            if provider == .claude { return raw.id == window.id }
            guard raw.durationMinutes == duration, raw.used == window.used else { return false }
            let displayedReset = raw.calculated ? raw.reset?.addingTimeInterval(reading.date.timeIntervalSince(raw.date)) : raw.reset
            if let displayedReset, let shownReset = window.resetsAt {
                return abs(displayedReset.timeIntervalSince(shownReset)) < 0.001
            }
            return displayedReset == window.resetsAt
        }
        if candidates.isEmpty, provider == .claude, window.presentationOrder.0 == 2,
           let previous, previous.used == window.used, previous.reset == window.resetsAt {
            // Claude's status line can keep an older scoped API window alongside fresh shared counters.
            return DisplayWindow(readingDate: reading.date, used: window.used, reset: window.resetsAt,
                                 observedAt: previous.observedAt, meter: previous.meter, observedReset: previous.observedReset,
                                 plan: previous.plan, inactive: previous.inactive)
        }
        let raw = candidates.count == 1 ? candidates.first : nil
        let meter = raw.flatMap { raw -> QuotaMeter? in
            guard let seconds = raw.durationMinutes.map({ ($0 * 60).rounded() }),
                  (1...31_536_000).contains(seconds), let scope = scope(raw.id, provider: provider) else { return nil }
            return QuotaMeter(scope: scope, durationSeconds: Int(seconds))
        }
        let observedReset = raw?.reset.map { Date(timeIntervalSince1970: floor($0.timeIntervalSince1970)) }
        let normalizedPlan = UsageQuotaCapture.plan(reading.quota?.plan) ?? UsageQuotaCapture.plan(reading.plan)
            ?? UsageQuotaCapture.plan(plan)
        let explicitlyInactive = duration == 300 && reading.quota?.short == .inactive
        return DisplayWindow(readingDate: reading.date, used: window.used, reset: window.resetsAt,
                             observedAt: raw?.date ?? reading.date, meter: meter, observedReset: observedReset,
                             plan: normalizedPlan, inactive: raw?.inactive == true || explicitlyInactive)
    }

    private static func scope(_ id: String, provider: UsageProvider) -> QuotaMeterScope? {
        if provider == .codex {
            if id == "shared" { return .shared }
            return id.hasPrefix("model:") ? .modelID(String(id.dropFirst(6))) : nil
        }
        switch id {
        case "session", "five_hour", "weekly_all", "seven_day": return .shared
        case "seven_day_opus", "seven_day_sonnet": return .legacyClaude(id)
        default:
            if id.hasPrefix("weekly_scoped:id:") { return .modelID(String(id.dropFirst(17))) }
            if id.hasPrefix("weekly_scoped:name:") { return .modelName(String(id.dropFirst(19))) }
            return nil
        }
    }

    private static func isStale(_ date: Date, meter: QuotaMeter?, now: Date, short: Bool = false) -> Bool {
        let short = meter.map { $0.durationSeconds == 18_000 } ?? short
        return now.timeIntervalSince(date) > (short ? 600 : 1800)
    }

    private func matches(_ entry: Entry, display: DisplayWindow, now: Date) -> Bool {
        let current = entry.current
        return !sleeping && !display.inactive && current.date >= refreshedAfter && current.date == display.observedAt
            && current.used == display.used && current.reset == display.observedReset
            && (display.plan == nil || current.series.plan == display.plan)
            && current.reset > now && (display.reset ?? .distantPast) > now
            && current.series.timeZoneID == TimeZone.current.identifier
            && !Self.isStale(current.date, meter: current.series.meter, now: now)
    }

    private func forecast(_ provider: UsageProvider, _ display: DisplayWindow, now: Date) -> ForecastResult? {
        guard let meter = display.meter, let entry = entries[MeterKey(provider: provider, meter: meter)],
              matches(entry, display: display, now: now), let cached = entry.cached else { return nil }
        let current = entry.current
        // Time can change a cap regime without a new provider observation.
        for cap in [current.companion, current.bindingWeekly] {
            if Self.capRegime(cap, at: cached.calculatedAt) != Self.capRegime(cap, at: now) { return nil }
        }
        if let unlock = current.hardBlockUntil, cached.calculatedAt < unlock && unlock <= now { return nil }
        return cached.result
    }

    private func display(_ state: UsageState, _ window: UsageWindow) -> DisplayWindow? {
        let display = windows[WindowKey(provider: state.provider, id: window.id)]
        guard display?.readingDate == state.reading?.date, display?.used == window.used,
              display?.reset == window.resetsAt else { return nil }
        return display
    }

    func staleReadingDate(_ state: UsageState, _ window: UsageWindow, now: Date) -> Date? {
        guard let date = display(state, window)?.observedAt ?? state.reading?.date else { return nil }
        if sleeping || date < refreshedAfter || Self.isStale(date, meter: nil, now: now, short: window.presentationOrder.0 == 0) {
            return date
        }
        return nil
    }

    func line(_ state: UsageState, _ window: UsageWindow, now: Date) -> Line? {
        let display = display(state, window)
        guard !window.isResetting(now), display?.inactive != true,
              staleReadingDate(state, window, now: now) == nil else { return nil }
        if window.used == 100 { return Line(text: tx("Quota used up", "Cuota agotada")) }
        let learning = Line(text: tx("Learning your usage pattern…", "Aprendiendo tu patrón de uso…"))
        guard let display, let result = forecast(state.provider, display, now: now) else { return learning }
        switch result.readiness {
        case .learning: return learning
        case .exhausted: return learning
        case .normal, .provisional:
            guard let expected = result.expectedUsed, expected.isFinite else { return learning }
            let rounded = (min(100, max(0, expected)) / 5).rounded() * 5
            let used = max(Int(rounded), 100 - Int((100 - window.used).rounded()))
            if result.readiness == .provisional {
                return Line(text: tx("Early estimate · ~\(used)% used at reset", "Estimación inicial · ~\(used)% usado al reinicio"))
            }
            return Line(text: tx("Usual use · ~\(used)% used at reset", "Uso habitual · ~\(used)% usado al reinicio"))
        case .risk, .likely:
            if let eta = validETA(result, display: display, now: now), let phrase = etaPhrase(eta, display: display, now: now) {
                return Line(text: tx("Likely to hit the limit \(phrase)", "Probablemente agotes la cuota \(phrase)"), warn: true)
            }
            return Line(text: tx("You may hit the limit before reset", "Podrías agotar la cuota antes del reinicio"), warn: true)
        }
    }

    private func validETA(_ result: ForecastResult, display: DisplayWindow, now: Date) -> Date? {
        guard result.readiness == .likely, let eta = result.eta, let reset = display.reset,
              now < eta, eta < min(reset, display.observedReset ?? reset) else { return nil }
        return eta
    }

    private func etaPhrase(_ eta: Date, display: DisplayWindow, now: Date) -> String? {
        if display.meter?.durationSeconds == 18_000 {
            let offset = Double(TimeZone.current.secondsFromGMT(for: eta))
            let rounded = ((eta.timeIntervalSince1970 + offset) / 1800).rounded() * 1800 - offset
            let time = Date(timeIntervalSince1970: rounded)
            guard let reset = display.reset, now < time, time < min(reset, display.observedReset ?? reset) else { return nil }
            let clock = time.formatted(.dateTime.hour().minute())
            return tx("around \(clock)", "alrededor de las \(clock)")
        }
        var locale = Locale.Components(locale: .current)
        locale.languageComponents.languageCode = Locale.LanguageCode(tx("en", "es"))
        let day = eta.formatted(.dateTime.weekday(.wide).locale(Locale(components: locale)))
        switch Calendar.current.component(.hour, from: eta) {
        case 6..<12: return tx("around \(day) morning", "el \(day) por la mañana")
        case 12..<18: return tx("around \(day) afternoon", "el \(day) por la tarde")
        case 18..<24: return tx("around \(day) evening", "el \(day) por la noche")
        default: return tx("early \(day) morning", "el \(day) de madrugada")
        }
    }

    // MARK: Alerts

    private func alertContext(_ state: UsageState, _ window: UsageWindow, now: Date) -> (base: String, resetIn: String)? {
        guard store?.config.usageAlertsEnabled == true, window.used < 100,
              let reset = window.resetsAt, reset > now,
              let key = UsagePaceHistory.key(state.provider, window) else { return nil }
        let cycle = String(Int(reset.timeIntervalSince1970 / 60))
        return (key + "|" + cycle, UsagePaceProjection.formatted(reset.timeIntervalSince(now)))
    }

    private func evaluateThreshold(_ state: UsageState, now: Date) {
        let threshold = Double(store?.config.usageAlertThreshold ?? 20)
        for window in state.orderedWindows {
            let remaining = 100 - window.used
            guard remaining <= threshold, let context = alertContext(state, window, now: now) else { continue }
            fire(context.base + "|thr",
                 title: tx("\(state.provider.title): \(Int(remaining.rounded()))% left", "\(state.provider.title): te queda \(Int(remaining.rounded()))%"),
                 body: tx("\(window.title) · resets in \(context.resetIn)", "\(window.title) · se reinicia en \(context.resetIn)"))
        }
    }

    private func predictiveETA(_ state: UsageState, _ window: UsageWindow, now: Date) -> Date? {
        let threshold = Double(store?.config.usageAlertThreshold ?? 20)
        guard 100 - window.used > threshold, let display = display(state, window),
              let result = forecast(state.provider, display, now: now),
              let eta = validETA(result, display: display, now: now), eta.timeIntervalSince(now) <= 3600 else { return nil }
        return eta
    }

    private func evaluatePrediction(_ state: UsageState, now: Date) {
        for window in state.orderedWindows {
            guard let context = alertContext(state, window, now: now),
                  let eta = predictiveETA(state, window, now: now) else { continue }
            let remaining = UsagePaceProjection.formatted(eta.timeIntervalSince(now))
            fire(context.base + "|proj",
                 title: tx("\(state.provider.title): estimated to hit the limit in \(remaining)",
                           "\(state.provider.title): se estima que agote la cuota en \(remaining)"),
                 body: tx("\(window.title) · resets in \(context.resetIn)", "\(window.title) · se reinicia en \(context.resetIn)")) { [weak self] in
                guard let self, let current = self.states.first(where: { $0.provider == state.provider && $0.available }),
                      let visible = current.orderedWindows.first(where: { $0.id == window.id && $0.resetsAt == window.resetsAt }) else { return false }
                return self.predictiveETA(current, visible, now: Date()) == eta
            }
        }
    }

    private func fire(_ id: String, title: String, body: String, stillValid: @escaping () -> Bool = { true }) {
        guard canNotify, let run else { return }
        let defaults = UserDefaults.standard
        guard defaults.dictionary(forKey: firedKey)?[id] == nil, pendingAlerts.insert(id).inserted else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self else { return }
                guard !run.isCancelled, self.store?.config.usageAlertsEnabled == true,
                      [.authorized, .provisional].contains(settings.authorizationStatus), stillValid() else {
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

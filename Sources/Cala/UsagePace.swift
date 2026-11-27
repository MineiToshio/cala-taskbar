import AppKit
import Combine
import Foundation
import UserNotifications

/// Display metadata travels with the accepted balance, including across a cache round trip.
struct UsageWindowObservation: Codable {
    let observedAt: Date
    let meter: QuotaMeter?
    let reset: Date?
    var inactive = false

    static func capture(_ reading: UsageReading, provider: UsageProvider) -> [String: Self] {
        var observations: [String: Self] = [:]
        for window in reading.windows {
            let duration = window.durationMinutes ?? window.presentationOrder.1
            let candidates = (reading.quota?.windows ?? []).filter { ($0.displayID ?? $0.id) == window.id }
            let raw = candidates.count == 1 ? candidates.first : nil
            let canonicalMeter = raw.flatMap { meter(id: $0.id, minutes: $0.durationMinutes, provider: provider) }
            observations[window.id] = Self(
                observedAt: raw?.date ?? reading.date, meter: canonicalMeter, reset: cycleReset(raw?.reset),
                inactive: raw?.inactive == true || (duration == 300 && reading.quota?.short == .inactive)
            )
        }
        return observations
    }

    static func cached(_ window: UsageWindow) -> Self {
        // Provider dates cannot establish when an individual quota was observed.
        Self(observedAt: .distantPast, meter: nil, reset: cycleReset(window.resetsAt))
    }

    private static func cycleReset(_ reset: Date?) -> Date? {
        UsageJSON.boundedDate(reset).map { Date(timeIntervalSince1970: floor($0.timeIntervalSince1970)) }
    }

    private static func meter(id: String, minutes: Double?, provider: UsageProvider) -> QuotaMeter? {
        guard let seconds = minutes.map({ $0 * 60 }), (1...31_536_000).contains(seconds), id.utf8.count <= 180,
              let scope = scope(id, provider: provider) else { return nil }
        return QuotaMeter(scope: scope, durationSeconds: Int(seconds.rounded()))
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

    struct AlertCycle {
        let base: String
        let previousBases: Set<String>
    }

    func alertCycle(provider: UsageProvider, window: UsageWindow) -> AlertCycle? {
        guard let meter, let reset = Self.cycleReset(reset) else { return nil }
        let scope: String
        switch meter.scope {
        case .shared: scope = "shared"
        case .modelID(let id): scope = "id:" + id
        case .modelName(let name): scope = "name:" + name
        case .legacyClaude(let id): scope = "legacy:" + id
        }
        // Absorb countdown errors across the minute boundary, including when an explicit reset replaces an estimate.
        let tolerance: TimeInterval = 2
        let cycle = Int((reset.timeIntervalSince1970 + tolerance) / 60)
        func previousMinutes(_ date: Date) -> Set<Int> {
            Set([-tolerance, tolerance].map { Int((date.timeIntervalSince1970 + $0) / 60) })
        }
        let providerID = provider.rawValue
        let duration = meter.durationSeconds
        var previousBases = Set(previousMinutes(reset).map { "\(providerID)|\(duration)|\($0)|\(scope)" })
        if let key = UsagePaceHistory.key(provider, window), let shownReset = Self.cycleReset(window.resetsAt) {
            previousBases.formUnion(previousMinutes(shownReset).map { "\(key)|\($0)" })
        }
        return AlertCycle(base: "v2|\(providerID)|\(duration)|\(cycle)|\(scope)", previousBases: previousBases)
    }
}

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

    struct ForecastKey: Equatable {
        let observation: QuotaObservation
        let cycle: QuotaCycle
        let generation = UUID()
    }

    struct CachedForecast {
        let result: ForecastResult
        let calculatedAt: Date
    }

    struct Entry {
        private(set) var key: ForecastKey
        var current: QuotaObservation { key.observation }
        private(set) var highWater: Double
        private(set) var cached: CachedForecast?

        init(key: ForecastKey) {
            self.key = key
            highWater = key.observation.used
        }

        mutating func update(_ observation: QuotaObservation) {
            if current != observation {
                key = ForecastKey(observation: observation, cycle: key.cycle)
                cached = nil
            }
            highWater = max(highWater, observation.used)
        }

        mutating func cache(_ forecast: CachedForecast, for completedKey: ForecastKey) {
            if key == completedKey { cached = forecast }
        }
    }

    private enum CapRegime: Equatable {
        case absent, unknown, unresolved, inactive, active(Int, Date)
    }

    private let worker = DispatchQueue(label: "local.cala.usage.forecast", qos: .utility)
    private var entries: [MeterKey: Entry] = [:]
    private var nextAllowed: [MeterKey: TimeInterval] = [:]
    private var legacyHistory: UsageLegacyHistory? // worker only
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
        worker.async {
            if self.legacyHistory == nil {
                let url = AppPaths.supportDirectory.appendingPathComponent("usage-history.json")
                self.legacyHistory = UsageLegacyHistory(url: url, now: Date())
            }
        }
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
        worker.async { self.legacyHistory?.save(now: Date(), force: true) }
        entries.removeAll()
        nextAllowed.removeAll()
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
        let changed = states.filter { state in
            state.available && !self.states.contains {
                $0.provider == state.provider && $0.available && $0.reading?.date == state.reading?.date
            }
        }
        let now = Date()
        if !changed.isEmpty {
            worker.async {
                for state in changed { self.legacyHistory?.ingest(state, now: now) }
                self.legacyHistory?.save(now: now)
            }
        }
        self.states = states
        for state in states where state.available {
            evaluateThreshold(state, now: now)
        }
        refreshForecasts()
    }

    private func accept(_ readings: [QuotaObservation]) {
        guard !sleeping else { return }
        let now = Date()
        for current in readings where current.attribution == .live && current.date >= refreshedAfter && current.reset > now {
            let series = current.series
            entries = entries.filter { $0.key.provider != series.provider ||
                ($0.value.current.series.profile == series.profile && $0.value.current.series.timeZoneID == series.timeZoneID) }
            let meter = MeterKey(provider: series.provider, meter: series.meter)
            let previous = entries[meter]
            if let old = previous?.current, old.date > current.date ||
                (old.date == current.date && old.source.rawValue > current.source.rawValue) { continue }

            if var entry = previous, entry.current.series == series, entry.key.cycle.reset == current.reset,
               current.used >= entry.highWater - 1 {
                entry.update(current)
                entries[meter] = entry
            } else {
                let cycle = QuotaCycle(reset: current.reset, segmentStart: current.date)
                entries[meter] = Entry(key: ForecastKey(observation: current, cycle: cycle))
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

    private func refreshForecasts() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        guard let run, !sleeping, !computing else { return }
        let now = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        nextAllowed = nextAllowed.filter { $0.value > uptime }
        entries = entries.filter { $0.value.current.reset > now }
        let ready = Set(states.filter(\.available).flatMap { state in
            (state.reading?.windows ?? []).compactMap { window -> MeterKey? in
                guard window.used < 100, let meter = state.observation(for: window)?.meter,
                      meter.durationSeconds == 18_000 || meter.durationSeconds == 604_800 else { return nil }
                let meterKey = MeterKey(provider: state.provider, meter: meter)
                guard let entry = entries[meterKey], matches(entry, state, window, now: now) else { return nil }
                return meterKey
            }
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
            let series = key.observation.series
            let meter = MeterKey(provider: series.provider, meter: series.meter)
            nextAllowed[meter] = started + (meter.meter.durationSeconds == 18_000 ? 60 : 300)
            entries[meter]?.cache(forecast, for: key)
        }
        let now = Date()
        for state in states where state.available {
            evaluatePrediction(state, now: now)
        }
    }

    // MARK: Display identity and freshness

    private static func isStale(_ date: Date, meter: QuotaMeter?, now: Date, short: Bool = false) -> Bool {
        let short = meter.map { $0.durationSeconds == 18_000 } ?? short
        return UsageJSON.observationDate(date, now: now) == nil || now.timeIntervalSince(date) > (short ? 600 : 1800)
    }

    private func matches(_ entry: Entry, _ state: UsageState, _ window: UsageWindow, now: Date) -> Bool {
        guard let observation = state.observation(for: window) else { return false }
        let current = entry.current
        let plan = UsageQuotaCapture.plan(state.reading?.quota?.plan) ?? UsageQuotaCapture.plan(state.reading?.plan)
            ?? UsageQuotaCapture.plan(state.plan)
        return !sleeping && !observation.inactive && current.date >= refreshedAfter && current.date == observation.observedAt
            && current.used == window.used && current.reset == observation.reset
            && (plan == nil || current.series.plan == plan)
            && current.reset > now && (window.resetsAt ?? .distantPast) > now
            && current.series.timeZoneID == TimeZone.current.identifier
            && !Self.isStale(current.date, meter: current.series.meter, now: now)
    }

    private func forecast(_ state: UsageState, _ window: UsageWindow, now: Date) -> ForecastResult? {
        guard let meter = state.observation(for: window)?.meter,
              let entry = entries[MeterKey(provider: state.provider, meter: meter)],
              matches(entry, state, window, now: now), let cached = entry.cached else { return nil }
        let current = entry.current
        // Time can change a cap regime without a new provider observation.
        for cap in [current.companion, current.bindingWeekly] {
            if Self.capRegime(cap, at: cached.calculatedAt) != Self.capRegime(cap, at: now) { return nil }
        }
        if let unlock = current.hardBlockUntil, cached.calculatedAt < unlock && unlock <= now { return nil }
        return cached.result
    }

    func staleReadingDate(_ state: UsageState, _ window: UsageWindow, now: Date) -> Date? {
        guard let observation = state.observation(for: window) else { return nil }
        let date = observation.observedAt
        if sleeping || date < refreshedAfter || Self.isStale(date, meter: observation.meter, now: now, short: window.presentationOrder.0 == 0) {
            return date
        }
        return nil
    }

    func line(_ state: UsageState, _ window: UsageWindow, now: Date) -> Line? {
        let observation = state.observation(for: window)
        guard !window.isResetting(now), observation?.inactive != true,
              staleReadingDate(state, window, now: now) == nil else { return nil }
        if window.used == 100 { return Line(text: tx("Quota used up", "Cuota agotada")) }
        let learning = Line(text: tx("Learning your usage pattern…", "Aprendiendo tu patrón de uso…"))
        guard let observation, let result = forecast(state, window, now: now) else { return learning }
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
            if let eta = validETA(result, reset: window.resetsAt, observation: observation, now: now),
               let phrase = etaPhrase(eta, reset: window.resetsAt, observation: observation, now: now) {
                return Line(text: tx("Likely to hit the limit \(phrase)", "Probablemente agotes la cuota \(phrase)"), warn: true)
            }
            return Line(text: tx("You may hit the limit before reset", "Podrías agotar la cuota antes del reinicio"), warn: true)
        }
    }

    private func validETA(_ result: ForecastResult, reset: Date?, observation: UsageWindowObservation, now: Date) -> Date? {
        guard result.readiness == .likely, let eta = result.eta, let reset,
              now < eta, eta < min(reset, observation.reset ?? reset) else { return nil }
        return eta
    }

    private func etaPhrase(_ eta: Date, reset: Date?, observation: UsageWindowObservation, now: Date) -> String? {
        if observation.meter?.durationSeconds == 18_000 {
            let offset = Double(TimeZone.current.secondsFromGMT(for: eta))
            let rounded = ((eta.timeIntervalSince1970 + offset) / 1800).rounded() * 1800 - offset
            let time = Date(timeIntervalSince1970: rounded)
            guard let reset, now < time, time < min(reset, observation.reset ?? reset) else { return nil }
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

    struct AlertContext {
        let cycle: UsageWindowObservation.AlertCycle
        let resetIn: String

        func id(_ kind: String) -> String { cycle.base + "|" + kind }

        func wasFired(_ kind: String, recorded: [String: Any]) -> Bool {
            recorded[id(kind)] != nil || cycle.previousBases.contains { recorded[$0 + "|" + kind] != nil }
        }
    }

    private static func alertContext(_ state: UsageState, _ window: UsageWindow, now: Date) -> AlertContext? {
        guard state.available, (0..<100).contains(window.used),
              let reset = UsageJSON.boundedDate(window.resetsAt), reset > now,
              let observation = state.observation(for: window), !observation.inactive,
              !isStale(observation.observedAt, meter: observation.meter, now: now),
              let cycle = observation.alertCycle(provider: state.provider, window: window) else { return nil }
        return AlertContext(cycle: cycle, resetIn: UsagePaceProjection.formatted(reset.timeIntervalSince(now)))
    }

    static func thresholdAlert(_ state: UsageState, _ window: UsageWindow, threshold: Double, now: Date) -> AlertContext? {
        guard 100 - window.used <= threshold else { return nil }
        return alertContext(state, window, now: now)
    }

    private func evaluateThreshold(_ state: UsageState, now: Date) {
        let threshold = Double(store?.config.usageAlertThreshold ?? 20)
        for window in state.orderedWindows {
            guard let context = Self.thresholdAlert(state, window, threshold: threshold, now: now) else { continue }
            let remaining = Int((100 - window.used).rounded())
            fire(context, kind: "thr",
                 title: tx("\(state.provider.title): \(remaining)% left", "\(state.provider.title): te queda \(remaining)%"),
                 body: tx("\(window.localizedTitle) · resets in \(context.resetIn)", "\(window.localizedTitle) · se reinicia en \(context.resetIn)")) { [weak self] in
                guard let self, let current = self.states.first(where: { $0.provider == state.provider }) else { return false }
                let threshold = Double(self.store?.config.usageAlertThreshold ?? 20)
                return current.orderedWindows.contains { visible in
                    visible.used == window.used
                        && Self.thresholdAlert(current, visible, threshold: threshold, now: Date())?.id("thr") == context.id("thr")
                }
            }
        }
    }

    private func predictiveETA(_ state: UsageState, _ window: UsageWindow, now: Date) -> Date? {
        let threshold = Double(store?.config.usageAlertThreshold ?? 20)
        guard 100 - window.used > threshold, let observation = state.observation(for: window),
              let result = forecast(state, window, now: now),
              let eta = validETA(result, reset: window.resetsAt, observation: observation, now: now), eta.timeIntervalSince(now) <= 3600 else { return nil }
        return eta
    }

    private func evaluatePrediction(_ state: UsageState, now: Date) {
        for window in state.orderedWindows {
            guard let context = Self.alertContext(state, window, now: now),
                  let eta = predictiveETA(state, window, now: now) else { continue }
            let remaining = UsagePaceProjection.formatted(eta.timeIntervalSince(now))
            fire(context, kind: "proj",
                 title: tx("\(state.provider.title): estimated to hit the limit in \(remaining)",
                           "\(state.provider.title): se estima que agote la cuota en \(remaining)"),
                 body: tx("\(window.localizedTitle) · resets in \(context.resetIn)", "\(window.localizedTitle) · se reinicia en \(context.resetIn)")) { [weak self] in
                guard let self, let current = self.states.first(where: { $0.provider == state.provider && $0.available }),
                      let visible = current.orderedWindows.first(where: {
                          Self.alertContext(current, $0, now: Date())?.id("proj") == context.id("proj")
                      }) else { return false }
                return self.predictiveETA(current, visible, now: Date()) == eta
            }
        }
    }

    private func fire(_ context: AlertContext, kind: String, title: String, body: String, stillValid: @escaping () -> Bool) {
        guard canNotify, let run, store?.config.usageAlertsEnabled == true else { return }
        let defaults = UserDefaults.standard
        let id = context.id(kind)
        let fired = defaults.dictionary(forKey: firedKey) ?? [:]
        guard !context.wasFired(kind, recorded: fired), pendingAlerts.insert(id).inserted else { return }
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

/// The rollback file keeps the original two-column format and lives independently of forecast buckets.
struct UsageLegacyHistory {
    private let url: URL
    private var history = UsagePaceHistory()
    private var dirty = false
    private var lastSaved = Date.distantPast

    init(url: URL, now: Date) {
        self.url = url
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size < 2_000_000,
              let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode([String: [[Double]]].self, from: data) else { return }
        history.restore(raw, now: now)
        dirty = raw != history.persistedSamples
    }

    mutating func ingest(_ state: UsageState, now: Date) {
        guard let reading = state.reading else { return }
        let samples = history.persistedSamples
        for window in reading.windows {
            guard let key = UsagePaceHistory.key(state.provider, window),
                  let date = state.observation(for: window)?.observedAt,
                  date <= now.addingTimeInterval(5), now.timeIntervalSince(date) <= 43_200,
                  date.timeIntervalSince1970 > (samples[key]?.last?.first ?? -.infinity) else { continue }
            history.ingest(UsageReading(windows: [window], plan: reading.plan, date: date), for: state.provider, now: now)
            dirty = true
        }
    }

    mutating func save(now: Date, force: Bool = false) {
        guard force || (dirty && now.timeIntervalSince(lastSaved) >= 60) else { return }
        let previous = history.persistedSamples
        history.restore(previous, now: now)
        let recent = history.persistedSamples
        dirty = dirty || previous != recent
        guard dirty else { return }
        do {
            let data = try JSONEncoder().encode(recent)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            lastSaved = now
            dirty = false
        } catch { log("usage: legacy history write failed") }
    }
}

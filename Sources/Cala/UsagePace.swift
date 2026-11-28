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
                observedAt: raw?.date ?? reading.date, meter: canonicalMeter, reset: UsageJSON.boundedDate(raw?.reset),
                inactive: raw?.inactive == true || (duration == 300 && reading.quota?.short == .inactive)
            )
        }
        return observations
    }

    static func cached(_ window: UsageWindow) -> Self {
        // Provider dates cannot establish when an individual quota was observed.
        Self(observedAt: .distantPast, meter: nil, reset: UsageJSON.boundedDate(window.resetsAt))
    }

    static func cycleReset(_ reset: Date?) -> Date? {
        UsageJSON.boundedDate(reset).map(QuotaObservation.resetAnchor)
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
        let reset: Date
        let legacySlot: String
    }

    func alertCycle(provider: UsageProvider, window: UsageWindow) -> AlertCycle? {
        guard let meter, let reset = UsageJSON.boundedDate(reset) else { return nil }
        let scope: String
        switch meter.scope {
        case .shared: scope = "shared"
        case .modelID(let id): scope = "id:" + id
        case .modelName(let name): scope = "name:" + name
        case .legacyClaude(let id): scope = "legacy:" + id
        }
        let slot = provider == .codex ? "any-slot" : window.id
        return AlertCycle(base: "\(provider.rawValue)|\(meter.durationSeconds)|\(scope)", reset: reset,
                          legacySlot: "\(provider.rawValue)|\(slot)")
    }
}

/// Coordinates learned quota forecasts. State and cache access stay on main; snapshots and replay run on a worker.
final class UsagePace: NSObject, UNUserNotificationCenterDelegate {
    static let shared = UsagePace()

    struct Line {
        let text: String
        var warn = false
        /// A smaller secondary line, e.g. the quick estimate's learning progress.
        var detail: String? = nil
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
        /// The result computed for exactly the current observation. Alerts use only this.
        private(set) var cached: CachedForecast?
        /// The latest result for an earlier reading of the same series and cycle, shown while the
        /// current reading is recomputed so the card never blanks between readings. Display only.
        private(set) var carried: CachedForecast?

        /// What the card shows: the current result, else the carried one.
        var displayed: CachedForecast? { cached ?? carried }

        init(key: ForecastKey) {
            self.key = key
            highWater = key.observation.used
        }

        mutating func update(_ observation: QuotaObservation) {
            if current != observation {
                key = ForecastKey(observation: observation, cycle: key.cycle)
                if let cached { carried = cached }
                cached = nil
            }
            highWater = max(highWater, observation.used)
        }

        mutating func cache(_ forecast: CachedForecast, for completedKey: ForecastKey) {
            if key == completedKey {
                cached = forecast
                carried = nil
            } else if completedKey.cycle == key.cycle, completedKey.observation.series == current.series,
                      forecast.calculatedAt >= (carried?.calculatedAt ?? .distantPast) {
                // A result that finished after a newer reading arrived still describes this cycle.
                carried = forecast
            }
        }

        /// The entry after a live reading. A different series, a different reset or a counter that drops
        /// (a reset) starts a fresh entry with nothing carried, so no pre-reset number is shown. A reset that
        /// wobbles by seconds between readings, as the provider's fractional resets do, is the same cycle.
        static func advanced(_ previous: Entry?, with observation: QuotaObservation) -> Entry {
            if var entry = previous, entry.current.series == observation.series,
               QuotaObservation.sameCycle(entry.key.cycle.reset, observation.reset),
               observation.used >= entry.highWater - 1 {
                entry.update(observation)
                return entry
            }
            let cycle = QuotaCycle(reset: observation.reset, segmentStart: observation.date)
            return Entry(key: ForecastKey(observation: observation, cycle: cycle))
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
    private let firedKey = "usageAlertResetDates"
    private var canNotify: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    func start(store: ConfigStore) {
        guard self.store == nil else { return }
        self.store = store
        let defaults = UserDefaults.standard
        if defaults.dictionary(forKey: firedKey) == nil {
            defaults.set(Self.migratedAlerts(defaults.dictionary(forKey: "usageAlertsFired") ?? [:]), forKey: firedKey)
        }
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
            self.apply(event)
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

    /// Applies a quota event to the forecast entries; scheduling stays with the caller.
    func apply(_ event: UsageQuotaEvent) {
        switch event {
        case .observations(let readings): accept(readings)
        case .discontinuity(let provider?):
            // Only the provider whose readings broke loses its entries; the other cards keep theirs.
            entries = entries.filter { $0.key.provider != provider }
            nextAllowed = nextAllowed.filter { $0.key.provider != provider }
        case .discontinuity(nil): entries.removeAll()
        case .importUpdated: break
        }
    }

    /// The entry kept for a provider's meter, for checks and diagnostics.
    func entry(_ provider: UsageProvider, _ meter: QuotaMeter) -> Entry? {
        entries[MeterKey(provider: provider, meter: meter)]
    }

    /// Whether a recompute of the meter waits for its throttle.
    func throttled(_ provider: UsageProvider, _ meter: QuotaMeter) -> Bool {
        nextAllowed[MeterKey(provider: provider, meter: meter)].map { $0 > ProcessInfo.processInfo.systemUptime } ?? false
    }

    /// Records a finished computation and throttles the next one of its meter. A computation that finished after its
    /// entry was replaced (a discontinuity, a new cycle or login) throttles nothing, so the new entry computes now.
    func record(_ forecast: CachedForecast, for key: ForecastKey, started: TimeInterval) {
        let series = key.observation.series
        let meter = MeterKey(provider: series.provider, meter: series.meter)
        guard let entry = entries[meter], entry.key.cycle == key.cycle, entry.current.series == series else { return }
        nextAllowed[meter] = started + (meter.meter.durationSeconds == 18_000 ? 60 : 300)
        entries[meter]?.cache(forecast, for: key)
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

            let next = Entry.advanced(previous, with: current)
            // A new cycle or series has nothing to show, so it computes now instead of waiting for the throttle.
            if previous.map({ $0.key.cycle != next.key.cycle || $0.current.series != next.current.series }) ?? true {
                nextAllowed[meter] = nil
            }
            entries[meter] = next
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
                guard window.used < 100, let meter = state.observation(for: window)?.meter, Self.plans(meter) else { return nil }
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
        for (key, forecast, started) in results { record(forecast, for: key, started: started) }
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
            && current.used == window.used && current.reset == UsageWindowObservation.cycleReset(observation.reset)
            && (plan == nil || current.series.plan == plan)
            && current.reset > now && (window.resetsAt ?? .distantPast) > now
            && current.series.timeZoneID == TimeZone.current.identifier
            && !Self.isStale(current.date, meter: current.series.meter, now: now)
    }

    /// `display` may fall back to the carried result of an earlier reading; alerts never do.
    private func forecast(_ state: UsageState, _ window: UsageWindow, now: Date, display: Bool = false) -> ForecastResult? {
        guard let meter = state.observation(for: window)?.meter,
              let entry = entries[MeterKey(provider: state.provider, meter: meter)],
              matches(entry, state, window, now: now),
              let cached = display ? entry.displayed : entry.cached else { return nil }
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
        let short = observation?.meter?.durationSeconds == 18_000
        let result = observation == nil ? nil : forecast(state, window, now: now, display: true)
        if let line = Self.coldLine(result, window: window, short: short, pending: result == nil && pending(state, window, now: now)) {
            return line
        }
        guard let observation, let result else { return nil }
        let none = Line(text: tx("No estimate yet", "Sin estimación por ahora"))
        switch result.readiness {
        case .learning, .exhausted, .quick: return none
        case .normal, .provisional:
            guard let expected = result.expectedUsed, expected.isFinite else { return none }
            let used = Self.displayedUsed(expected, window: window)
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

    /// Whether forecasts are computed for the meter at all: the 5-hour and weekly windows.
    static func plans(_ meter: QuotaMeter) -> Bool {
        meter.durationSeconds == 18_000 || meter.durationSeconds == 604_800
    }

    /// A current reading whose forecast is still being computed.
    private func pending(_ state: UsageState, _ window: UsageWindow, now: Date) -> Bool {
        guard let meter = state.observation(for: window)?.meter, Self.plans(meter),
              let entry = entries[MeterKey(provider: state.provider, meter: meter)] else { return false }
        return matches(entry, state, window, now: now)
    }

    /// Text for every state before the learned profile: no result yet, a hold, exhaustion or a quick estimate.
    /// Returns nil for the learned readiness levels. `pending` means a current reading is being computed.
    static func coldLine(_ result: ForecastResult?, window: UsageWindow, short: Bool, pending: Bool = false) -> Line? {
        guard let result else {
            return pending ? Line(text: tx("Calculating…", "Calculando…")) : Line(text: tx("No estimate yet", "Sin estimación por ahora"))
        }
        switch result.readiness {
        case .exhausted: return Line(text: tx("Quota used up", "Cuota agotada"))
        case .learning:
            switch result.hold {
            case .warmingUp: return Line(text: tx("Calculating… a few minutes", "Calculando… unos minutos"))
            case .capLimited:
                return short ? Line(text: tx("Limited by the weekly quota", "Limitado por la cuota semanal"))
                    : Line(text: tx("Limited by the 5-hour quota", "Limitado por la cuota de 5 horas"))
            case .none: return Line(text: tx("No estimate yet", "Sin estimación por ahora"))
            }
        case .quick:
            guard let expected = result.expectedUsed, expected.isFinite else {
                return Line(text: tx("No estimate yet", "Sin estimación por ahora"))
            }
            let day = result.learningDays
            let detail = day >= 14 ? tx("Still refining · may change", "Aún afinando la estimación · puede variar")
                : tx("Still learning your pattern (day \(max(1, day)) of 14) · may change",
                     "Aún aprendiendo tu patrón (día \(max(1, day)) de 14) · puede variar")
            if result.quickWarning {
                return Line(text: tx("You may hit the limit before reset", "Podrías agotar la cuota antes del reinicio"),
                            warn: true, detail: detail)
            }
            let used = displayedUsed(expected, window: window)
            // A quick number this high is not trustworthy without the near-certain warning.
            if used >= 90 {
                return Line(text: tx("High use · may run out before reset", "Uso alto · podría agotarse antes del reinicio"),
                            detail: detail)
            }
            return Line(text: tx("Quick estimate · ~\(used)% used at reset", "Estimación rápida · ~\(used)% usado al reinicio"),
                        detail: detail)
        default: return nil
        }
    }

    private static func displayedUsed(_ expected: Double, window: UsageWindow) -> Int {
        let rounded = (min(100, max(0, expected)) / 5).rounded() * 5
        return max(Int(rounded), 100 - Int((100 - window.used).rounded()))
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

    // Positional records contain neither duration nor scope. Preserve each possible cycle until
    // expiry so an upgraded installation recognizes a moved slot even when both slots were fired.
    static func migratedAlerts(_ old: [String: Any]) -> [String: Double] {
        var result: [String: Double] = [:]
        var latestNotification: [String: Double] = [:]
        for (key, timestamp) in old {
            var fields = key.components(separatedBy: "|")
            if fields.first == "v2" { fields.removeFirst() }
            guard fields.count >= 4, let minute = Double(fields[2]), minute.isFinite,
                  let kind = fields.last, ["thr", "proj"].contains(kind) else { continue }
            let reset = minute * 60
            if fields.count == 4 {
                let slot = fields[0] == "codex" ? "any-slot" : fields[1]
                result["legacy|\(fields[0])|\(slot)|\(kind)|\(fields[2])"] = reset
            } else {
                let scope = fields[3..<(fields.count - 1)].joined(separator: "|")
                let id = "\(fields[0])|\(fields[1])|\(scope)|\(kind)"
                if let timestamp = timestamp as? Double, timestamp >= (latestNotification[id] ?? 0) {
                    result[id] = reset
                    latestNotification[id] = timestamp
                }
                // Retain the uncertainty of an old minute-only record at the tolerance boundary.
                result["legacy|\(id)|\(fields[2])"] = reset
            }
        }
        return result
    }

    struct AlertContext {
        let cycle: UsageWindowObservation.AlertCycle
        let resetIn: String

        func id(_ kind: String) -> String { cycle.base + "|" + kind }

        func sameCycle(as other: AlertContext) -> Bool {
            cycle.base == other.cycle.base && QuotaObservation.sameCycle(cycle.reset, other.cycle.reset)
        }

        func wasFired(_ kind: String, recorded: [String: Double]) -> Bool {
            let reset = cycle.reset.timeIntervalSince1970
            if let last = recorded[id(kind)], abs(reset - last) <= QuotaObservation.explicitResetJitter { return true }
            // Old formats kept only a minute, with v2 adding two seconds before truncation.
            let aliases = ["legacy|" + id(kind) + "|", "legacy|" + cycle.legacySlot + "|" + kind + "|"]
            return recorded.contains { key, value in
                aliases.contains { key.hasPrefix($0) } && (value - 602...value + 660).contains(reset)
            }
        }
    }

    private static func alertContext(_ state: UsageState, _ window: UsageWindow, now: Date) -> AlertContext? {
        guard state.available, state.reading?.codexRolloutIdentified != false, (0..<100).contains(window.used),
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
                        && Self.thresholdAlert(current, visible, threshold: threshold, now: Date())?.sameCycle(as: context) == true
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

    /// A quick estimate warns only when exhaustion is nearly certain, and never with a time.
    private func quickWarning(_ state: UsageState, _ window: UsageWindow, now: Date) -> Bool {
        let threshold = Double(store?.config.usageAlertThreshold ?? 20)
        guard 100 - window.used > threshold, let result = forecast(state, window, now: now) else { return false }
        return result.readiness == .quick && result.quickWarning
    }

    private func evaluatePrediction(_ state: UsageState, now: Date) {
        for window in state.orderedWindows {
            guard let context = Self.alertContext(state, window, now: now) else { continue }
            guard let eta = predictiveETA(state, window, now: now) else {
                guard quickWarning(state, window, now: now) else { continue }
                // Shares the predictive kind, so one cycle never gets both a quick and an ETA warning.
                fire(context, kind: "proj",
                     title: tx("\(state.provider.title): you may hit the limit before reset",
                               "\(state.provider.title): podrías agotar la cuota antes del reinicio"),
                     body: tx("\(window.localizedTitle) · resets in \(context.resetIn)", "\(window.localizedTitle) · se reinicia en \(context.resetIn)")) { [weak self] in
                    guard let self, let current = self.states.first(where: { $0.provider == state.provider && $0.available }),
                          let visible = current.orderedWindows.first(where: {
                              Self.alertContext(current, $0, now: Date())?.sameCycle(as: context) == true
                          }) else { return false }
                    return self.quickWarning(current, visible, now: Date())
                }
                continue
            }
            let remaining = UsagePaceProjection.formatted(eta.timeIntervalSince(now))
            fire(context, kind: "proj",
                 title: tx("\(state.provider.title): estimated to hit the limit in \(remaining)",
                           "\(state.provider.title): se estima que agote la cuota en \(remaining)"),
                 body: tx("\(window.localizedTitle) · resets in \(context.resetIn)", "\(window.localizedTitle) · se reinicia en \(context.resetIn)")) { [weak self] in
                guard let self, let current = self.states.first(where: { $0.provider == state.provider && $0.available }),
                      let visible = current.orderedWindows.first(where: {
                          Self.alertContext(current, $0, now: Date())?.sameCycle(as: context) == true
                      }) else { return false }
                return self.predictiveETA(current, visible, now: Date()) == eta
            }
        }
    }

    private func fire(_ context: AlertContext, kind: String, title: String, body: String, stillValid: @escaping () -> Bool) {
        guard canNotify, let run, store?.config.usageAlertsEnabled == true else { return }
        let defaults = UserDefaults.standard
        let id = context.id(kind)
        let fired = defaults.dictionary(forKey: firedKey) as? [String: Double] ?? [:]
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
                        recent[id] = context.cycle.reset.timeIntervalSince1970
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

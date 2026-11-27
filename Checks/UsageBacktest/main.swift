import Foundation

private let hour: TimeInterval = 3_600
private let day = 24 * hour
private let weekly = 604_800
private let short = 18_000
private let fullRange = Date.distantPast..<Date.distantFuture

private struct ArchiveRow {
    let quota: QuotaObservation
    let available: Date
}

private struct Scan {
    let rows: [ArchiveRow]
    let candidates: Int
    let truncated: Bool
    let unsupported: Int
}

private func scan(root: URL, asOf: Date, calendar: Calendar, key: QuotaImportKey) -> Scan {
    var limits = UsageCodexBackfill.Limits()
    // Keep the production tail, line and observation bounds. Offline replay can read more files.
    limits.files = 4_096
    limits.bytes = 512 * 1_024 * 1_024
    limits.elapsed = 120
    let importer = UsageCodexBackfill(sessionsRoot: root, now: asOf, calendar: calendar, account: nil, limits: limits)
    let done = DispatchSemaphore(value: 0)
    var pass: UsageCodexBackfill.Pass?
    func receive(_ result: UsageCodexBackfill.Pass) {
        pass = result
        done.signal()
    }
    importer.scanNextPass(receive)
    done.wait()
    if pass!.moreFiles {
        importer.scanNextPass(receive)
        done.wait()
    }
    let result = pass!
    var unsupported = 0
    let rows = result.replayCandidates.flatMap { candidate -> [ArchiveRow] in
        // There is no live anchor in a replay. Admit only directly parseable, unlabeled rows,
        // with no inferred identity, plan, duration, or future same-cycle anchor.
        guard !candidate.identified else { return [] }
        let reading = candidate.reading
        return UsageQuotaCapture.observations(reading, provider: .codex, profile: key.profile,
                                        timeZoneID: key.timeZoneID, source: .rollout, attribution: .provisional,
                                        now: asOf).compactMap { quota -> ArchiveRow? in
            guard quota.series.meter.durationSeconds == weekly || quota.series.meter.durationSeconds == short else {
                unsupported += 1
                return nil
            }
            let available = max(quota.date, reading.date)
            return available <= asOf ? ArchiveRow(quota: quota, available: available) : nil
        }
    }
    return Scan(rows: rows, candidates: result.replayCandidates.count, truncated: result.truncated, unsupported: unsupported)
}

private enum Horizon: String, CaseIterable {
    case weeklyNear = "weekly <24h", weeklyMid = "weekly 1–3d", weeklyFar = "weekly >3d"
    case shortNear = "short <1h", shortFar = "short 1–5h"

    init(remaining: TimeInterval, duration: Int) {
        if duration == short { self = remaining < hour ? .shortNear : .shortFar }
        else if remaining < day { self = .weeklyNear }
        else { self = remaining <= 3 * day ? .weeklyMid : .weeklyFar }
    }
}

private struct CycleKey: Hashable {
    let series: QuotaSeries
    let reset: Date
}

private struct Outcome {
    let final: Double
    let hit: Bool
    let tight: Bool
    let bracket: ClosedRange<Date>?
}

private enum Label {
    case resolved(Outcome)
    case unresolved(String)
}

private func label(for rows: [QuotaObservation], nextCycleStart: Date?, asOf: Date) -> Label {
    let reset = rows[0].reset
    guard let terminal = rows.last(where: { $0.resetKind == .explicit }) else { return .unresolved("no explicit reset anchor") }
    var high = 0.0
    var lastBelow: Date?
    var firstHit: Date?
    var bracket: ClosedRange<Date>?
    for row in rows {
        if row.used < high - 1 { return .unresolved("counter discontinuity") }
        high = max(high, row.used)
        if firstHit == nil {
            if row.used == 100 && row.date < reset {
                firstHit = row.date
                bracket = lastBelow.map { $0...row.date }
            } else if row.used < 100 { lastBelow = row.date }
        }
    }
    let gap = reset.timeIntervalSince(terminal.date)
    if firstHit != nil {
        return .resolved(Outcome(final: 100, hit: true, tight: gap <= 60, bracket: bracket))
    }
    guard reset <= asOf else { return .unresolved("reset still ahead") }
    guard nextCycleStart.map({ $0 >= reset }) ?? true else { return .unresolved("reset superseded") }
    let tolerance = terminal.series.meter.durationSeconds == short ? 600.0 : 1_800.0
    guard gap <= tolerance else { return .unresolved("no near-reset reading") }
    return .resolved(Outcome(final: terminal.used, hit: false, tight: gap <= 60, bracket: nil))
}

private struct Prediction {
    var point: Double?
    // Point baselines supply binary warnings but issue no calibrated probabilities.
    var probability: Double?
    var warning: Bool?
    var eta: Date?
}

private enum Model: String, CaseIterable {
    case forecast, linear, pooled
}

private func linear(_ quota: QuotaObservation, now: Date, known: ArraySlice<ArchiveRow>) -> Prediction {
    let window = UsageWindow(id: "meter", title: "", used: quota.used, resetsAt: quota.reset,
                             durationMinutes: Double(quota.series.meter.durationSeconds) / 60)
    var history = UsagePaceHistory()
    // Feed the same-cycle readings through the legacy history retention and sample cap.
    let recent = known.filter { $0.quota.reset == quota.reset && now.timeIntervalSince($0.quota.date) <= 43_200 }
    for row in recent.sorted(by: { $0.quota.date < $1.quota.date }) {
        var sample = window
        sample.used = row.quota.used
        history.ingest(UsageReading(windows: [sample], plan: nil, date: row.quota.date), for: .codex, now: now)
    }
    guard let pace = history.pace(.codex, window, now: now) else { return Prediction() }
    if pace.secondsToEmpty.isFinite {
        let remaining = 100 - quota.used
        let point = min(100, quota.used + remaining * pace.secondsToReset / pace.secondsToEmpty)
        return Prediction(point: point, warning: pace.warn,
                          eta: pace.warn ? now.addingTimeInterval(pace.secondsToEmpty) : nil)
    }
    // The legacy helper uses infinity for both zero-rate and insufficient-data states.
    if quota.used == 0 || pace.text == calendarText("No recent use", "Sin uso reciente") {
        return Prediction(point: quota.used, warning: false)
    }
    return Prediction()
}

private struct Exposure {
    var points = 0.0
    var seconds = 0.0
    mutating func add(_ points: Double, _ seconds: Double) {
        self.points += points
        self.seconds += seconds
    }
    var rate: Double { points / seconds }
}

private func observedBucket(_ row: QuotaBucket, at origin: Date) -> Bool {
    row.end <= origin && !row.flags.contains(.censored)
        && row.coveredSeconds + row.quietSeconds >= Double(row.series.meter.bucketSeconds) / 2
}

private func pooled(_ quota: QuotaObservation, now: Date, snapshot: QuotaHistorySnapshot, calendar: Calendar) -> Prediction {
    func slot(_ date: Date) -> Int {
        calendar.component(.hour, from: date) + (calendar.isDateInWeekend(date) ? 24 : 0)
    }
    var byClassAndHour: [Int: Exposure] = [:]
    var byHour: [Int: Exposure] = [:]
    var all = Exposure()
    for row in snapshot.buckets(for: quota.series, in: fullRange) where observedBucket(row, at: now) {
        let seconds = row.coveredSeconds + row.quietSeconds
        let index = slot(row.start)
        byClassAndHour[index, default: Exposure()].add(row.delta, seconds)
        byHour[index % 24, default: Exposure()].add(row.delta, seconds)
        all.add(row.delta, seconds)
    }
    guard all.seconds > 0 else { return Prediction() }
    var position = now
    var used = quota.used
    var eta: Date?
    while position < quota.reset && used < 100 {
        let index = slot(position)
        let rate = (byClassAndHour[index] ?? byHour[index % 24] ?? all).rate
        let interval = QuotaCalendarBuckets.interval(containing: position, timeZoneID: quota.series.timeZoneID, seconds: Int(hour))
        let end = min(interval.end, quota.reset)
        let delta = rate * end.timeIntervalSince(position)
        if rate > 0 && used + delta >= 100 {
            let crossing = position.addingTimeInterval((100 - used) / rate)
            if crossing < quota.reset { eta = crossing }
        }
        used += delta
        position = end
    }
    return Prediction(point: min(100, used), warning: eta != nil, eta: eta)
}

private struct ScoredOrigin {
    let cycle: CycleKey
    let week: Date
    let horizon: Horizon
    let trainedWeeks: Int
    let outcome: Outcome
    let predictions: [Model: Prediction]
}

private struct Abstentions {
    var point = 0
    var warning = 0

    mutating func count(_ prediction: Prediction) {
        if prediction.point == nil { point += 1 }
        if prediction.warning == nil { warning += 1 }
    }
}

private struct Replay {
    var scores: [ScoredOrigin] = []
    var unresolved: [String: Int] = [:]
    var cohorts: [String: Int] = [:]
    var eligible: [Horizon: Int] = [:]
    var abstentions: [Horizon: [Model: Abstentions]] = [:]
    var origins: Int { eligible.values.reduce(0, +) }
    var excludedExhausted = 0
    var cycles = 0
}

private func weekStart(_ date: Date, calendar: Calendar) -> Date {
    calendar.dateInterval(of: .weekOfYear, for: date)!.start
}

private func replay(_ archive: [ArchiveRow], asOf: Date, key: QuotaImportKey, store: URL, calendar: Calendar) -> Replay {
    var result = Replay()
    for (series, raw) in Dictionary(grouping: archive, by: { $0.quota.series }) {
        let timeline = raw.sorted { ($0.available, $0.quota.date, $0.quota.resetKind.rawValue, $0.quota.reset, $0.quota.used) <
            ($1.available, $1.quota.date, $1.quota.resetKind.rawValue, $1.quota.reset, $1.quota.used) }
        var seen = Set<Date>()
        let events = timeline.filter { seen.insert($0.quota.date).inserted }
        let byDate = events.map(\.quota).sorted { $0.date < $1.date }
        let cycles = Dictionary(grouping: byDate, by: \.reset).values.sorted { $0[0].date < $1[0].date }
        result.cycles += cycles.count
        var labels: [Date: Label] = [:]
        for (index, rows) in cycles.enumerated() {
            let next = index + 1 < cycles.count ? cycles[index + 1][0].date : nil
            let outcome: Label
            if let next, next < rows[rows.count - 1].date { outcome = .unresolved("interleaved reset anchors") }
            else { outcome = label(for: rows, nextCycleStart: next, asOf: asOf) }
            labels[rows[0].reset] = outcome
            if case .unresolved(let reason) = outcome { result.unresolved[reason, default: 0] += 1 }
        }

        let duration = series.meter.durationSeconds
        var daysSeen: [Date: Set<Date>] = [:]
        var end = events.startIndex
        for event in events {
            let now = event.available
            var quota = event.quota
            guard now < quota.reset, now.timeIntervalSince(quota.date) <= (duration == short ? 600 : 1_800) else { continue }
            let dateKey = duration == short ? quota.reset : calendar.startOfDay(for: now)
            guard daysSeen[quota.reset, default: []].insert(dateKey).inserted else { continue }
            if quota.used >= 100 { result.excludedExhausted += 1; continue }
            let horizon = Horizon(remaining: quota.reset.timeIntervalSince(now), duration: duration)
            result.eligible[horizon, default: 0] += 1
            while end < events.endIndex && events[end].available <= now { end += 1 }
            let known = events[..<end]
            let history = UsageQuotaHistory(directory: store, clock: { now })
            history.replaceImport(known.map(\.quota), for: key, complete: false, now: now)
            let snapshot = history.snapshot()
            // The engine requires a live current counter. Only this copy is simulated live.
            quota.attribution = .live
            let forecast = UsageForecast().forecast(snapshot: snapshot, current: quota, calendar: calendar, now: now)
            let warning: Bool? = switch forecast.readiness {
            case .risk, .likely: true
            case .normal: false
            default: nil
            }
            let predictions: [Model: Prediction] = [
                .forecast: Prediction(point: forecast.expectedUsed, probability: forecast.exhaustProbability,
                                      warning: warning, eta: forecast.eta),
                .linear: linear(quota, now: now, known: known),
                .pooled: pooled(quota, now: now, snapshot: snapshot, calendar: calendar),
            ]
            for (model, prediction) in predictions {
                result.abstentions[horizon, default: [:]][model, default: Abstentions()].count(prediction)
            }
            guard case .resolved(let outcome) = labels[quota.reset] else { continue }
            let trainedWeeks = Set(snapshot.buckets(for: series, in: fullRange).lazy.filter {
                observedBucket($0, at: now)
            }.map { weekStart($0.start, calendar: calendar) }).count
            let scope = series.meter.scope == .shared ? "shared" : "scoped"
            let cohort = "\(horizon.rawValue), \(scope), provisional, \(trainedWeeks) observed weeks"
            result.cohorts[cohort, default: 0] += 1
            result.scores.append(ScoredOrigin(cycle: CycleKey(series: series, reset: quota.reset),
                                              week: weekStart(quota.reset.addingTimeInterval(-1), calendar: calendar),
                                              horizon: horizon, trainedWeeks: trainedWeeks, outcome: outcome,
                                              predictions: predictions))
        }
    }
    return result
}

private func number(_ value: Double?, digits: Int = 2) -> String {
    guard let value else { return "—" }
    return String(format: "%.*f", locale: Locale(identifier: "en_US_POSIX"), digits, value)
}

private func fraction(_ numerator: Int, _ denominator: Int) -> Double? {
    denominator == 0 ? nil : Double(numerator) / Double(denominator)
}

/// Average within a local reset week first, so a dense week cannot dominate point and probability errors.
private func weeklyMean(_ rows: [ScoredOrigin], value: (ScoredOrigin) -> Double?) -> Double? {
    let weeks = Dictionary(grouping: rows, by: \.week)
    let means = weeks.keys.sorted().compactMap { week -> Double? in
        let values = weeks[week]!.compactMap(value)
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
    return means.isEmpty ? nil : means.reduce(0, +) / Double(means.count)
}

private func pointError(_ rows: [ScoredOrigin], model: Model) -> Double? {
    weeklyMean(rows) { row in row.predictions[model]?.point.map { abs($0 - row.outcome.final) } }
}

private func report(_ rows: [ScoredOrigin], title: String, calibration: Bool = false) {
    print("\n\(title) · \(rows.count) origins, \(Set(rows.map(\.cycle)).count) cycles, \(Set(rows.map(\.week)).count) local reset weeks")
    guard !rows.isEmpty else {
        print("No labeled origins for scoring.")
        return
    }
    print("Horizon | Model | N | Hits | MAE pp | Shared MAE pp (N) | Brier (N) | Precision | Recall | False/cycle | Abstain point/warn | ETA MAE h (issued/bracketed)")
    print("--- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---:")
    for horizon in Horizon.allCases {
        let group = rows.filter { $0.horizon == horizon }
        guard !group.isEmpty else { continue }
        let shared = group.filter { row in Model.allCases.allSatisfy { row.predictions[$0]?.point != nil } }
        let hits = group.filter { $0.outcome.hit }.count
        let cycles = Set(group.map(\.cycle)).count
        let bracketed = group.filter { $0.outcome.bracket != nil }.count
        for model in Model.allCases {
            let issued = group.filter { $0.predictions[model]?.probability != nil }
            let brier = weeklyMean(issued) { row in
                row.predictions[model]?.probability.map { pow($0 - (row.outcome.hit ? 1 : 0), 2) }
            }
            let warnings = group.filter { $0.predictions[model]?.warning == true }
            let trueWarnings = warnings.filter { $0.outcome.hit }.count
            let falseCycles = Set(warnings.filter { !$0.outcome.hit }.map(\.cycle)).count
            let pointAbstentions = group.filter { $0.predictions[model]?.point == nil }.count
            let warningAbstentions = group.filter { $0.predictions[model]?.warning == nil }.count
            let etaScored = group.filter { $0.outcome.bracket != nil && $0.predictions[model]?.eta != nil }.count
            let etaError = weeklyMean(group) { row in
                guard let eta = row.predictions[model]?.eta, let bracket = row.outcome.bracket else { return nil }
                return max(0, bracket.lowerBound.timeIntervalSince(eta), eta.timeIntervalSince(bracket.upperBound)) / hour
            }
            let cells = [horizon.rawValue, model.rawValue, "\(group.count)", "\(hits)", number(pointError(group, model: model)),
                         "\(number(pointError(shared, model: model))) (\(shared.count))", "\(number(brier, digits: 3)) (\(issued.count))",
                         number(fraction(trueWarnings, warnings.count)), number(fraction(trueWarnings, hits)),
                         number(fraction(falseCycles, cycles)),
                         "\(number(fraction(pointAbstentions, group.count)))/\(number(fraction(warningAbstentions, group.count)))",
                         "\(number(etaError)) (\(etaScored)/\(bracketed))"]
            print(cells.joined(separator: " | "))
        }
    }
    if calibration { reportCalibration(rows) }
}

private func reportCalibration(_ rows: [ScoredOrigin]) {
    let probabilities = rows.filter { $0.predictions[.forecast]?.probability != nil }
    guard !probabilities.isEmpty else {
        print("Reliability: no issued probabilities.")
        return
    }
    print("Reliability by horizon | Probability bin | N | Mean probability | Observed hit rate")
    for horizon in Horizon.allCases {
        let binned = Dictionary(grouping: probabilities.filter { $0.horizon == horizon }) { row in
            min(4, Int(row.predictions[.forecast]!.probability! * 5))
        }
        for bin in binned.keys.sorted() {
            let group = binned[bin]!
            let predicted = weeklyMean(group) { $0.predictions[.forecast]?.probability }
            let observed = weeklyMean(group) { $0.outcome.hit ? 1 : 0 }
            let interval = "[\(number(Double(bin) / 5, digits: 1)), \(number(Double(bin + 1) / 5, digits: 1))\(bin == 4 ? "]" : ")")"
            print("\(horizon.rawValue) | \(interval) | \(group.count) | \(number(predicted)) | \(number(observed))")
        }
    }
}

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

let arguments = CommandLine.arguments
let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
var isDirectory: ObjCBool = false
guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue,
      FileManager.default.isReadableFile(atPath: root.path) else { fail("Sessions root must be a readable directory.") }
let asOf: Date
if arguments[3].isEmpty { asOf = Date() }
else if let date = ISO8601DateFormatter().date(from: arguments[3]) { asOf = date }
else { fail("Expected an ISO 8601 as-of timestamp with a timezone.") }

var calendar = Calendar(identifier: .iso8601)
calendar.timeZone = .current
let key = QuotaImportKey(profile: QuotaProfileID(rawValue: "offline-backtest"), timeZoneID: calendar.timeZone.identifier)
private let archive = scan(root: root, asOf: asOf, calendar: calendar, key: key)
private let replayed = replay(archive.rows, asOf: asOf, key: key,
                             store: URL(fileURLWithPath: arguments[2], isDirectory: true), calendar: calendar)
let dateFormat = ISO8601DateFormatter()
dateFormat.timeZone = calendar.timeZone
dateFormat.formatOptions = [.withFullDate]
let dates = archive.rows.map(\.available)
let dateRange = dates.min().flatMap { first in dates.max().map { "\(dateFormat.string(from: first)) to \(dateFormat.string(from: $0))" } } ?? "none"
print("Codex walk-forward · \(calendar.timeZone.identifier) · archive dates \(dateRange)")
print("Scan: \(archive.candidates) candidate events, \(archive.rows.count) quota rows before deduplication, \(archive.unsupported) unsupported duration rows, truncated=\(archive.truncated).")
print("Unlabeled archive only, provisional attribution. Weekly origins use the first fresh local-day reading; short cycles use the first fresh reading. Production thresholds are fixed.")
print("\(replayed.cycles) cycles, \(replayed.origins) eligible origins, \(replayed.origins - replayed.scores.count) omitted for unresolved labels, \(replayed.excludedExhausted) already exhausted at origin.")
for reason in replayed.unresolved.keys.sorted() { print("Unresolved cycles: \(replayed.unresolved[reason]!) · \(reason)") }
print("Horizon | Eligible origins | Labeled origins | Forecast abstain point/warn | Linear abstain point/warn | Pooled abstain point/warn")
print("--- | ---: | ---: | ---: | ---: | ---:")
for horizon in Horizon.allCases {
    let eligible = replayed.eligible[horizon, default: 0]
    let labeled = replayed.scores.filter { $0.horizon == horizon }.count
    let abstentions = Model.allCases.map { model in
        let counts = replayed.abstentions[horizon]?[model] ?? Abstentions()
        return "\(number(fraction(counts.point, eligible)))/\(number(fraction(counts.warning, eligible)))"
    }
    print(([horizon.rawValue, "\(eligible)", "\(labeled)"] + abstentions).joined(separator: " | "))
}
for cohort in replayed.cohorts.keys.sorted() { print("Scored origins: \(replayed.cohorts[cohort]!) · \(cohort)") }
print("MAE/Brier/ETA weight local reset weeks equally. Shared MAE requires points from all three models. Warning recall includes abstentions; false alerts are deduplicated per meter-cycle within each horizon. ETA error is distance outside the observed crossing interval.")
report(replayed.scores, title: "Near-reset approximate labels (weekly ≤30m / short ≤10m) or observed exhaustion", calibration: true)
report(replayed.scores.filter(\.outcome.tight), title: "Sensitivity · same-cycle reading ≤1m before reset")
report(replayed.scores.filter { (4...8).contains($0.trainedWeeks) }, title: "Later-origin cohort · 4–8 observed training weeks")

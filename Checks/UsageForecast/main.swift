import Foundation

let hour = 3_600.0
let day = 24 * hour
let week = 7 * day
let utc = TimeZone(identifier: "UTC")!
var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = utc
let monday = calendar.date(from: DateComponents(year: 2026, month: 11, day: 23))!
let now = monday.addingTimeInterval(18 * hour)
let reset = monday.addingTimeInterval(week)
let shortNow = monday.addingTimeInterval(11 * hour)
let shortReset = monday.addingTimeInterval(14 * hour)
let weekly = series()
let short = series(duration: 18_000)
let engine = UsageForecast()
var assertions = 0

func series(_ id: String = "owner", plan: String = "plus", duration: Int = 604_800,
            scope: QuotaMeterScope = .shared, zone: String = "UTC") -> QuotaSeries {
    QuotaSeries(provider: .codex, profile: QuotaProfileID(rawValue: id), plan: plan,
                meter: QuotaMeter(scope: scope, durationSeconds: duration), timeZoneID: zone)
}

func check(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
    assertions += 1
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL line \(line): \(message)\n".utf8))
        exit(1)
    }
}

func close(_ actual: Double?, _ expected: Double, within tolerance: Double = 0.000_001) -> Bool {
    actual.map { abs($0 - expected) <= tolerance } ?? false
}

func current(_ used: Double = 7, for key: QuotaSeries = weekly, at time: Date = now,
             reset end: Date = reset, companion: QuotaCapState = .absent,
             binding: QuotaCapState = .absent) -> QuotaObservation {
    QuotaObservation(series: key, date: time, used: used, reset: end, source: .api,
                     companion: companion, bindingWeekly: binding)
}

func forecast(_ buckets: [QuotaBucket], _ observation: QuotaObservation = current(),
              at time: Date = now, in cal: Calendar = calendar, gaps: [QuotaGap] = []) -> ForecastResult {
    engine.forecast(snapshot: QuotaHistorySnapshot(buckets: buckets, gaps: gaps),
                    current: observation, calendar: cal, now: time)
}

func sample(_ time: Date, _ used: Double, _ companion: QuotaCapState = .absent, _ binding: QuotaCapState = .absent,
            _ attribution: QuotaAttribution = .live) -> QuotaBucketSample {
    QuotaBucketSample(date: time, used: used, source: attribution == .live ? .api : .rollout,
                      attribution: attribution, companion: companion, bindingWeekly: binding, hardBlockUntil: nil)
}

func routine(_ slot: Int) -> Double {
    slot / 24 < 5 && (9..<17).contains(slot % 24) ? 1 : 0
}

func weeks(_ count: Int, for key: QuotaSeries = weekly, preceding first: Date = monday,
           skipping: Set<Int> = [], vacation: Set<Int> = [],
           attribution: QuotaAttribution = .live,
           cap: (Int, Date) -> QuotaCapState = { _, _ in .absent },
           debit: (Int, Int) -> Double = { _, slot in routine(slot) },
           resolved: (Int, Int) -> Double = { _, _ in 1 }) -> [QuotaBucket] {
    var buckets: [QuotaBucket] = []
    for index in 1...count where !skipping.contains(index) {
        let start = first.addingTimeInterval(-Double(index) * week)
        let cycle = QuotaCycle(reset: start.addingTimeInterval(week), segmentStart: start)
        var used = 0.0
        for slot in 0..<168 {
            let date = start.addingTimeInterval(Double(slot) * hour)
            let coverage = used == 100 ? 0 : resolved(index, slot) * hour
            let amount = vacation.contains(index) ? 0 : max(0, debit(index, slot))
            let delta = min(100 - used, amount)
            let crossing = delta > 0 && delta < amount
            let seconds = crossing ? coverage * delta / amount : coverage
            var flags: QuotaBucketFlags = attribution == .live ? [] : [.rollout]
            if attribution == .provisional { flags.insert(.provisional) }
            if crossing || used == 100 { flags.insert(.censored) }
            let readingDate = crossing ? date.addingTimeInterval(seconds) : date
            let reading = sample(readingDate, crossing ? 100 : used, cap(index, readingDate), .absent, attribution)
            buckets.append(.init(series: key, cycle: cycle, start: date, deltaHundredths: Int((delta * 100).rounded()),
                                 coveredSeconds: delta == 0 ? 0 : seconds, quietSeconds: delta == 0 ? seconds : 0,
                                 flags: flags, latest: reading))
            used += delta
        }
    }
    return buckets
}

let ordinary = weeks(8)
let owner = forecast(ordinary)
check(owner.readiness == .normal, "owner routine is normal")
check(close(owner.expectedUsed, 39, within: 2), "owner routine projects about 39%")
check(owner.exhaustProbability == 0 && owner.eta == nil && owner.etaRange == nil, "owner routine has no hit or ETA")
check(forecast(Array(ordinary.reversed())) == owner, "history order does not affect the forecast")
check(close(forecast(ordinary, current(0)).expectedUsed, 32), "zero is a valid origin")

let heavyRows = weeks(8, debit: { _, slot in slot >= 24 ? 3 * routine(slot) : 0 })
let heavy = forecast(heavyRows, current(20))
let fridayNoon = monday.addingTimeInterval(4 * day + 12 * hour)
check(heavy.readiness == .likely && (heavy.exhaustProbability ?? 0) >= 0.8, "heavy routine issues a likely result")
check(abs(heavy.eta?.timeIntervalSince(fridayNoon) ?? .infinity) <= hour, "heavy routine hits near Friday noon")
check(heavy.etaRange?.contains(heavy.eta!) == true, "range contains the recurring crossing")

let vacation = forecast(weeks(12, vacation: [4]))
let outage = forecast(weeks(12, skipping: [4]))
check((vacation.expectedUsed ?? 0) >= 30 && (vacation.expectedUsed ?? 100) < 39, "vacation is observed zero use")
check(close(outage.expectedUsed, 39) && outage.effectiveWeeks < vacation.effectiveWeeks, "outage adds no zero path")

let burst = forecast(weeks(12, debit: { index, slot in
    if index != 1 { return routine(slot) }
    return slot == 24 ? 250 : 0
}))
check(burst.hitWeeks == 1 && (burst.exhaustProbability ?? 1) <= 0.2, "lone burst kept with at most one fifth mass")
check((burst.expectedUsed ?? 100) <= 52 && burst.readiness == .normal && burst.eta == nil,
      "lone burst does not produce a warning")
let fiveWeeks = forecast(weeks(5, debit: { index, slot in
    if index != 1 { return routine(slot) }
    return slot == 24 ? 250 : 0
}))
check(close(fiveWeeks.exhaustProbability, 0.2) && close(fiveWeeks.effectiveWeeks, 5),
      "five-week normalization caps every week and redistributes the excess")

let exactly = forecast(weeks(8, debit: { _, slot in slot == 167 ? 1 : 0 }), current(99))
check(close(exactly.expectedUsed, 100) && exactly.exhaustProbability == 0 && exactly.eta == nil,
      "crossing exactly at reset is outside the event")
let before = forecast(weeks(8, debit: { _, slot in slot == 167 ? 1 : 0 }), current(99.01))
check(before.readiness == .likely && before.eta.map { $0 < reset } == true, "a crossing just before reset is an event")
let partial = forecast(ordinary, current(7, at: monday.addingTimeInterval(10.5 * hour),
                                        reset: monday.addingTimeInterval(12.25 * hour)),
                       at: monday.addingTimeInterval(10.5 * hour))
check(close(partial.expectedUsed, 8.75), "first and last hours scale to their overlap")

check(forecast([]).readiness == .learning && forecast(weeks(1)).expectedUsed == nil, "cold start")
let imported = weeks(3, attribution: .provisional)
let seed = forecast(imported)
check(seed.readiness == .provisional && close(seed.expectedUsed, 39) && seed.eta == nil, "three unverified weeks seed a point")
check(forecast(weeks(8, attribution: .verifiedArchive)).readiness == .normal, "verified archive can issue a normal forecast")
let contaminated = forecast(ordinary + weeks(8, preceding: monday.addingTimeInterval(-8 * week),
                                            attribution: .provisional, debit: { _, _ in 10 }))
check(contaminated == owner, "provisional history cannot influence verified warnings")
check(forecast(ordinary, current(for: series("different account"))).readiness == .learning, "accounts are independent")
check(forecast(ordinary, current(for: series(plan: "max"))).readiness == .learning, "plans are independent")
check(forecast(ordinary, current(for: series(plan: ""))).readiness == .learning, "no plan")
check(forecast(ordinary, current(reset: now)).readiness == .learning, "no active reset")
check(forecast(ordinary, current(at: now.addingTimeInterval(-1_801))).readiness == .learning, "stale weekly counter")
check(forecast(ordinary, current(100)).readiness == .exhausted, "actual 100% is distinct")
check(forecast(ordinary, at: now.addingTimeInterval(-week)).readiness == .learning, "future origin is rejected")

let uncertain = forecast(weeks(8, cap: { _, _ in .unknown }), current(companion: .unknown))
check(uncertain.readiness == .provisional && uncertain.exhaustProbability == nil, "unknown applicability can use only a point profile")
check(forecast(ordinary, current(companion: .present(.unknown))).readiness == .learning, "unresolved applicable cap")
let inactive = weeks(8, cap: { _, _ in .present(.inactive) })
check(forecast(inactive, current(companion: .present(.inactive))).readiness == .normal, "inactive weekly companion")
let active = weeks(8, cap: { _, date in .present(.active(used: 30, reset: date.addingTimeInterval(2 * hour))) })
check(forecast(active, current(companion: .present(.active(used: 18, reset: now.addingTimeInterval(hour))))).readiness == .normal,
      "low active companion matches without reset alignment")
let near = QuotaCapState.present(.active(used: 85, reset: now.addingTimeInterval(2 * hour)))
let nearRows = weeks(8, cap: { _, date in .present(.active(used: 95, reset: date.addingTimeInterval(2.5 * hour))) })
check(forecast(nearRows, current(companion: near)).readiness == .normal, "near cap requires a comparable reset")
let quarterHourRows = nearRows.map { bucket -> QuotaBucket in
    var row = bucket
    if calendar.component(.weekday, from: row.start) == 2 && calendar.component(.hour, from: row.start) == 18 {
        let capReset = row.start.addingTimeInterval(3 * hour)
        let cap = QuotaCapState.present(.active(used: 95, reset: capReset))
        row.earlierCompanionSamples = [15.0, 30].map { sample(row.start.addingTimeInterval($0 * 60), 7, cap) }
        row.latest = sample(row.start.addingTimeInterval(45 * 60), 7, cap)
    }
    return row
}
let quarterHourForecasts = [30.0, 45].map { minute -> ForecastResult in
    let time = now.addingTimeInterval(minute * 60)
    let cap = QuotaCapState.present(.active(used: 85, reset: now.addingTimeInterval(3 * hour)))
    return forecast(quarterHourRows, current(at: time, companion: cap), at: time)
}
check(quarterHourForecasts.allSatisfy { $0.readiness == .normal && close($0.expectedUsed, 39) },
      "quarter-hour companion matching at :30 and :45")
let flatAtCap = ordinary.map { bucket -> QuotaBucket in
    var row = bucket
    if calendar.component(.weekday, from: row.start) == 2 && calendar.component(.hour, from: row.start) == 18 {
        row.deltaHundredths = 1_000
        row.coveredSeconds = 600
        row.quietSeconds = 0
        row.flags.insert(.censored)
        row.firstHit = row.start.addingTimeInterval(600)
        row.latest = sample(row.start.addingTimeInterval(3_000), 100)
    }
    return row
}
let beforeFirstHit = now.addingTimeInterval(-hour)
let firstHitForecast = forecast(flatAtCap, current(95, at: beforeFirstHit, reset: now.addingTimeInterval(900)), at: beforeFirstHit)
check(firstHitForecast.readiness == .likely && firstHitForecast.eta == now.addingTimeInterval(300),
      "replay places debit before the first 100% reading despite a later flat sample")
let mismatch = current(companion: .present(.active(used: 85, reset: now.addingTimeInterval(4 * hour))))
check(forecast(nearRows, mismatch).readiness == .learning, "near-cap reset outside tolerance cannot fall back to profile")
check(forecast(active, current(companion: near)).readiness == .learning, "low-cap paths cannot stand in for near-cap paths")
let full = QuotaCapState.present(.active(used: 100, reset: now.addingTimeInterval(2 * hour)))
let fullRows = weeks(8, cap: { _, date in .present(.active(used: 100, reset: date.addingTimeInterval(2 * hour))) })
check(close(forecast(fullRows, current(companion: full)).expectedUsed, 39), "100% companion alone does not impose a hard block")
var blocked = current(companion: full)
blocked.hardBlockUntil = monday.addingTimeInterval(day + 12 * hour)
check(close(forecast(fullRows, blocked).expectedUsed, 36), "a hard block removes debit up to the actual unlock")
blocked.hardBlockUntil = reset
let entirelyBlocked = forecast([], blocked)
check(entirelyBlocked.expectedUsed == 7 && entirelyBlocked.exhaustProbability == 0, "hard block through reset needs no history")
let scoped = series(scope: .modelID("opus"))
let scopedRows = weeks(8, for: scoped, cap: { _, _ in .present(.inactive) })
check(forecast(scopedRows + heavyRows, current(for: scoped, companion: .present(.inactive))).readiness == .normal,
      "scoped weekly stream uses its observed shared cap and its own debit")

let ambiguousRows = weeks(8, debit: { _, slot in routine(slot) },
                          resolved: { _, slot in routine(slot) > 0 ? 0.5 : 1 }).map { bucket -> QuotaBucket in
    var row = bucket
    if row.coveredSeconds != 0 { row.deltaHundredths = 50 }
    return row
}
let ambiguous = forecast(ambiguousRows, current(75))
check(ambiguous.readiness == .provisional && (ambiguous.exhaustProbability ?? 0) >= 0.8 && ambiguous.eta == nil,
      "risk threshold disagreement keeps a provisional point")
let thin = weeks(8, resolved: { _, slot in slot == 12 || slot == 36 ? 1 : 0 })
check(forecast(thin).readiness == .learning, "unsupported remaining hours prevent extrapolation")
let future = weeks(8, preceding: reset.addingTimeInterval(8 * week))
check(forecast(future).readiness == .learning, "future rows cannot train the profile")

// These quiet cells were resolved by an endpoint that arrives after the forecast origin.
let earlierNow = monday.addingTimeInterval(hour)
let earlierReading = current(at: earlierNow)
let lastKnown = monday.addingTimeInterval(-6 * hour)
let delayedEndpoint = earlierNow.addingTimeInterval(hour)
let delayed = weeks(8, preceding: monday.addingTimeInterval(4 * hour))
let available = delayed.filter { $0.start <= lastKnown }.map { bucket -> QuotaBucket in
    var row = bucket
    if row.start == lastKnown { row.quietSeconds = 0 }
    return row
}
let retrospectivelyResolved = delayed.filter { lastKnown <= $0.start && $0.start <= delayedEndpoint }.map { bucket -> QuotaBucket in
    var row = bucket
    if lastKnown < row.start && row.start < delayedEndpoint { row.latest = nil }
    return row
}
let historicalPoint = forecast(available, earlierReading, at: earlierNow)
check(historicalPoint.expectedUsed != nil &&
      forecast(available.filter { $0.start != lastKnown } + retrospectivelyResolved, earlierReading, at: earlierNow) == historicalPoint,
      "a later quiet endpoint cannot retroactively resolve a forecast's input")

do {
    let zone = "America/New_York"
    var local = Calendar(identifier: .gregorian)
    local.timeZone = TimeZone(identifier: zone)!
    func date(_ month: Int, _ day: Int, hour: Int = 0) -> Date {
        local.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }
    let key = series("dst", zone: zone)
    let sundayNine = 6 * 24 + 9
    let fall = forecast(weeks(8, for: key, preceding: date(10, 26), debit: { _, slot in slot == sundayNine ? 20 : 0 }),
                        current(90, for: key, at: date(11, 1), reset: date(11, 1, hour: 9)), at: date(11, 1), in: local)
    check(fall.readiness == .normal && fall.exhaustProbability == 0 && close(fall.expectedUsed, 90) && fall.eta == nil,
          "New York fall-back replay excludes Sunday debit at the 09:00 reset")

    let spring = forecast(weeks(8, for: key, preceding: date(3, 2), debit: { _, slot in slot == sundayNine - 1 ? 20 : 0 }),
                          current(90, for: key, at: date(3, 8), reset: date(3, 8, hour: 9)), at: date(3, 8), in: local)
    let crossing = date(3, 8, hour: 8).addingTimeInterval(30 * 60)
    check(spring.readiness == .likely && close(spring.exhaustProbability, 1) && spring.eta == crossing,
          "New York spring-forward replay retains debit at 08:00 and its local ETA")
}

func sessions(_ count: Int = 15, shift: Double = 0, key: QuotaSeries = short,
              bind: (Date) -> QuotaCapState = { _ in .absent },
              debit: (Int, Int) -> Double = { _, cell in cell < 4 ? 20 : 3 }) -> [QuotaBucket] {
    (0..<count).flatMap { index -> [QuotaBucket] in
        let offset = -Double(index / 3 + 1) * week + Double(index % 3) * day
        let start = monday.addingTimeInterval(offset + (9 + shift) * hour)
        let cycle = QuotaCycle(reset: start.addingTimeInterval(5 * hour), segmentStart: start)
        var used = 0.0
        return (0..<10).map { cell in
            let date = start.addingTimeInterval(Double(cell) * hour / 2)
            let delta = min(100 - used, debit(index, cell))
            let row = QuotaBucket(series: key, cycle: cycle, start: date, deltaHundredths: Int((delta * 100).rounded()),
                                  coveredSeconds: used < 100 ? hour / 2 : 0, quietSeconds: 0,
                                  flags: used < 100 ? [] : [.censored], latest: sample(date, used, .unknown, bind(date)))
            used += delta
            return row
        }
    }
}

let shortReading = current(94, for: short, at: shortNow, reset: shortReset)
let shortRows = sessions()
let shortResult = forecast(shortRows, shortReading, at: shortNow)
check(shortResult.readiness == .likely && close(shortResult.exhaustProbability, 1), "same-phase five-hour forecast")
check(shortResult.eta == shortNow.addingTimeInterval(hour) && shortResult.etaRange?.lowerBound == shortResult.eta,
      "stable short crossing has a median and interval")
check(forecast(sessions(11), shortReading, at: shortNow).readiness == .learning, "requires twelve sessions")
check(forecast(sessions(12), shortReading, at: shortNow).readiness == .likely, "twelve eligible sessions qualify")
let wideShort = forecast(sessions(shift: 2.5), shortReading, at: shortNow)
check(wideShort.readiness == .provisional && wideShort.eta == nil, "four-hour time match is provisional")
check(forecast(sessions(shift: 4.5), shortReading, at: shortNow).readiness == .learning, "time match never exceeds four hours")
let wrongPhase = current(94, for: short, at: shortNow, reset: shortReset.addingTimeInterval(hour))
check(forecast(shortRows, wrongPhase, at: shortNow).readiness == .learning, "use the actual cycle phase and band")
let betweenSamples = current(94, for: short, at: shortNow.addingTimeInterval(15 * 60), reset: shortReset)
let clippedShort = forecast(shortRows, betweenSamples, at: betweenSamples.date)
check(clippedShort.eta == betweenSamples.date.addingTimeInterval(hour), "interpolates mapped phase between samples")
let uncertainShort = current(94, for: short, at: shortNow, reset: shortReset, binding: .unknown)
check(forecast(shortRows, uncertainShort, at: shortNow).readiness == .learning, "unknown weekly state blocks a short forecast")
let bindingFull = current(94, for: short, at: shortNow, reset: shortReset, binding: fullAt(shortNow))
func fullAt(_ date: Date) -> QuotaCapState { .present(.active(used: 100, reset: date.addingTimeInterval(day))) }
check(forecast(shortRows, bindingFull, at: shortNow).readiness == .learning, "does not mix incompatible binding states")
check(forecast(sessions(bind: fullAt), bindingFull, at: shortNow).readiness == .likely, "known matching binding state")
let staleShort = current(94, for: short, at: shortNow.addingTimeInterval(-601), reset: shortReset)
check(forecast(shortRows, staleShort, at: shortNow).readiness == .learning, "short freshness gate")
check(forecast(shortRows, current(0, for: short, at: shortNow, reset: shortNow), at: shortNow).readiness == .learning,
      "inactive session produces no estimate")
let broad = forecast(sessions(debit: { index, cell in
    if cell < 4 { return 20 }
    return (index % 3 == 0 ? cell == 4 : cell == 9) ? 12 : 0
}), shortReading, at: shortNow)
check(broad.readiness == .risk && broad.eta == nil && broad.etaRange == nil, "short ETA envelope wider than an hour suppresses ETA")

// Quick estimate: live rows of the current cycle from `begin` to `end`, debiting `perHour(date)` per hour.
func liveCycle(_ key: QuotaSeries = weekly, from begin: Date, to end: Date, reset cycleReset: Date, start used: Double = 0,
               in cal: Calendar = calendar, perHour: (Date) -> Double) -> (rows: [QuotaBucket], used: Double) {
    let cycle = QuotaCycle(reset: cycleReset, segmentStart: begin)
    var rows: [QuotaBucket] = []
    var total = used
    var position = begin
    while position < end {
        let bounds = QuotaCalendarBuckets.interval(containing: position, timeZoneID: key.timeZoneID,
                                                   seconds: key.meter.bucketSeconds)
        let upper = min(bounds.end, end)
        let seconds = upper.timeIntervalSince(position)
        let delta = min(100 - total, perHour(position) * seconds / hour)
        total += delta
        rows.append(.init(series: key, cycle: cycle, start: bounds.start, deltaHundredths: Int((delta * 100).rounded()),
                          coveredSeconds: delta > 0 ? seconds : 0, quietSeconds: delta > 0 ? 0 : seconds, flags: [],
                          latest: sample(upper.addingTimeInterval(-1), total)))
        position = upper
    }
    return (rows, total)
}

func quickForecast(_ key: QuotaSeries = weekly, from begin: Date, hours: Double, reset cycleReset: Date,
                   history: [QuotaBucket] = [], in cal: Calendar = calendar, start used: Double = 0,
                   perHour: @escaping (Date) -> Double) -> ForecastResult {
    let end = begin.addingTimeInterval(hours * hour)
    let live = liveCycle(key, from: begin, to: end, reset: cycleReset, start: used, in: cal, perHour: perHour)
    let reading = current(live.used, for: key, at: end, reset: cycleReset)
    return forecast(history + live.rows, reading, at: end, in: cal)
}

let mondayNine = monday.addingTimeInterval(9 * hour)
let weeklyReset = mondayNine.addingTimeInterval(week)
check(quickForecast(from: mondayNine, hours: 1 / 3, reset: weeklyReset) { _ in 3 }.readiness == .learning,
      "twenty minutes of readings are still calculating")
check(quickForecast(from: mondayNine, hours: 0.9, reset: weeklyReset) { _ in 0 }.readiness == .learning,
      "under an hour without use is still calculating")
check(quickForecast(from: mondayNine, hours: 0.6, reset: weeklyReset) { _ in 2 }.readiness == .quick,
      "three readings over 30 minutes with some use give a quick estimate")
let firstHour = quickForecast(from: mondayNine, hours: 1, reset: weeklyReset) { _ in 1 }
check(firstHour.readiness == .quick && (firstHour.expectedUsed ?? 100) < 40 && (firstHour.expectedUsed ?? 0) > 1
      && firstHour.eta == nil && !firstHour.quickWarning && firstHour.learningDays == 1,
      "1% in the first hour on Monday morning is well below 100%, not a 24/7 extrapolation")
let idle = quickForecast(from: mondayNine, hours: 2, reset: weeklyReset, start: 12) { _ in 0 }
check(idle.readiness == .quick && close(idle.expectedUsed, 12, within: 0.01) && !idle.quickWarning, "zero usage stays at the current value")
let firstDay = quickForecast(from: mondayNine, hours: 24, reset: weeklyReset) { date in
    (9..<18).contains(calendar.component(.hour, from: date)) ? 3.33 : 0
}
let burstHour = quickForecast(from: mondayNine, hours: 1, reset: weeklyReset) { _ in 20 }
check(close(burstHour.expectedUsed, 100) && !burstHour.quickWarning, "heavy first hour caps at 100% without a warning")
let heavyStart = quickForecast(from: mondayNine, hours: 2, reset: weeklyReset) { _ in 30 }
check(close(heavyStart.expectedUsed, 100) && heavyStart.quickWarning && heavyStart.eta == nil,
      "60% in two hours is a near-certain warning, still without an ETA")
let nearlyFull = quickForecast(from: mondayNine, hours: 1, reset: weeklyReset, start: 85) { _ in 1 }
check(nearlyFull.quickWarning, "86% used with most of the window left warns")
let lateFull = quickForecast(from: mondayNine.addingTimeInterval(6 * day), hours: 1, reset: weeklyReset, start: 85) { _ in 1 }
check(lateFull.readiness == .quick && !lateFull.quickWarning, "86% used near reset with a low conservative estimate does not warn")

func dailyHours(_ count: Int, sameCycle: Bool) -> [QuotaBucket] {
    var rows: [QuotaBucket] = []
    for offset in 1...count {
        let begin: Date = mondayNine.addingTimeInterval(-Double(offset) * day)
        let end: Date = sameCycle ? mondayNine : begin.addingTimeInterval(day)
        rows += liveCycle(from: begin, to: begin.addingTimeInterval(hour), reset: end, perHour: { _ in 0.5 }).rows
    }
    return rows
}
let earlierDays = dailyHours(3, sameCycle: true)
let fourDays = quickForecast(from: mondayNine, hours: 1, reset: weeklyReset, history: earlierDays) { _ in 1 }
check(fourDays.readiness == .quick && fourDays.learningDays == 4, "day counter counts distinct live days")
let manyDays = dailyHours(20, sameCycle: false)
check(quickForecast(from: mondayNine, hours: 1, reset: weeklyReset, history: manyDays) { _ in 1 }.learningDays == 14,
      "day counter caps at 14")
let withRoutine = quickForecast(from: monday, hours: 18, reset: reset, history: weeks(3)) { date in routine(Int(date.timeIntervalSince(monday) / hour)) }
check(withRoutine.readiness == .provisional && withRoutine.learningDays == 0, "the provisional gate replaces the quick estimate")
check(quickForecast(from: mondayNine, hours: 1, reset: weeklyReset, history: weeks(8)) { _ in 1 }.readiness == .normal,
      "a learned profile is unchanged by current-cycle rows")

let shortStart = monday.addingTimeInterval(10 * hour)
let shortQuick = quickForecast(short, from: shortStart, hours: 1, reset: shortStart.addingTimeInterval(5 * hour)) { _ in 20 }
check(shortQuick.readiness == .quick && (shortQuick.expectedUsed ?? 100) < 100 && (shortQuick.expectedUsed ?? 0) > 40
      && !shortQuick.quickWarning, "five-hour quick estimate is sane")
let shortHeavy = quickForecast(short, from: shortStart, hours: 1, reset: shortStart.addingTimeInterval(5 * hour)) { _ in 50 }
check(shortHeavy.quickWarning && close(shortHeavy.expectedUsed, 100), "half a session in its first hour warns")

let modelScoped = series(scope: .modelID("opus"))
check(quickForecast(modelScoped, from: mondayNine, hours: 1, reset: weeklyReset) { _ in 1 }.readiness == .quick,
      "per-model meters get a quick estimate")

var dstResults: [Double] = []
do {
    let zone = "America/New_York"
    var local = Calendar(identifier: .gregorian)
    local.timeZone = TimeZone(identifier: zone)!
    let key = series("dst-quick", zone: zone)
    for (month, day) in [(10, 30), (3, 6)] {
        let begin = local.date(from: DateComponents(year: 2026, month: month, day: day, hour: 9))!
        let end = local.date(byAdding: .day, value: 7, to: begin)!
        let result = quickForecast(key, from: begin, hours: 1, reset: end, in: local) { _ in 1 }
        dstResults.append(result.expectedUsed ?? .nan)
        check(result.readiness == .quick && (result.expectedUsed ?? 100) < 40 && (result.expectedUsed ?? 0) > 1,
              "a DST week gives a sane quick estimate")
    }
}

// Review scenarios: one ordinary-to-heavy first hour must not read as "~100%".
let saturdayTen = monday.addingTimeInterval(5 * day + 10 * hour)
let mondayEleven = monday.addingTimeInterval(23 * hour)
let firstHours: [(String, Date, Double)] = [("3% Mon 09:00", mondayNine, 3), ("4% Mon 09:00", mondayNine, 4),
                                            ("3% Sat 10:00", saturdayTen, 3), ("3% Mon 23:00", mondayEleven, 3)]
var scenarioText: [String] = []
for (name, begin, amount) in firstHours {
    let result = quickForecast(from: begin, hours: 1, reset: begin.addingTimeInterval(week)) { _ in amount }
    scenarioText.append(String(format: "%@ → %.1f%%", name, result.expectedUsed ?? .nan))
    check(result.readiness == .quick && (result.expectedUsed ?? 100) < 40 && !result.quickWarning,
          "\(name) in the first hour stays well below 100%")
}
let tenPercent = quickForecast(from: mondayNine, hours: 1, reset: weeklyReset) { _ in 10 }
check((tenPercent.expectedUsed ?? 100) < 90 && !tenPercent.quickWarning, "10% in the first weekly hour is not shown near 100%")
let warmUp = quickForecast(from: mondayNine, hours: 0.25, reset: weeklyReset) { _ in 1 }
check(warmUp.readiness == .learning && warmUp.hold == .warmingUp, "a short warm-up is marked as calculating")
check(forecast([], current()).hold == .warmingUp, "no current-cycle rows are a warm-up")
check(forecast(ordinary, current(companion: .present(.unknown))).hold == .capLimited, "an unresolved companion cap is a cap hold")
let nearLive = liveCycle(from: mondayNine, to: mondayNine.addingTimeInterval(2 * hour), reset: weeklyReset) { _ in 1 }
let nearCap = QuotaCapState.present(.active(used: 90, reset: mondayNine.addingTimeInterval(4 * hour)))
let nearResult = forecast(nearLive.rows, current(nearLive.used, at: mondayNine.addingTimeInterval(2 * hour), reset: weeklyReset,
                                                 companion: nearCap), at: mondayNine.addingTimeInterval(2 * hour))
check(nearResult.readiness == .learning && nearResult.hold == .capLimited, "a near-limit companion holds the quick estimate")
check(forecast([], current(reset: now)).hold == .none, "an invalid reading is neither warm-up nor cap hold")

// Only live readings count as days: archive samples and quiet bridges on other days do not.
let archiveDays = dailyHours(3, sameCycle: true).map { row -> QuotaBucket in
    var copy = row
    copy.latest = copy.latest.map { sample($0.date, $0.used, .absent, .absent, .verifiedArchive) }
    return copy
}
let quietBridge = QuotaBucket(series: weekly, cycle: QuotaCycle(reset: weeklyReset, segmentStart: mondayNine.addingTimeInterval(-30 * hour)),
                              start: mondayNine.addingTimeInterval(-30 * hour), deltaHundredths: 0, coveredSeconds: 0,
                              quietSeconds: hour, flags: [], latest: nil)
let liveOnly = quickForecast(from: mondayNine, hours: 1, reset: weeklyReset, history: archiveDays + [quietBridge]) { _ in 1 }
check(liveOnly.readiness == .quick && liveOnly.learningDays == 1, "day counter ignores archive samples and quiet spans")

// Past rows recorded under a different companion regime do not feed the rate.
let foreignRegime = dailyHours(3, sameCycle: true).map { row -> QuotaBucket in
    var copy = row
    copy.deltaHundredths = 5_000
    copy.latest = copy.latest.map { sample($0.date, $0.used, .present(.inactive)) }
    return copy
}
let filtered = quickForecast(from: mondayNine, hours: 1, reset: weeklyReset, history: foreignRegime) { _ in 1 }
check(filtered.readiness == .quick && close(filtered.expectedUsed, firstHour.expectedUsed ?? .nan, within: 0.001),
      "rows with another cap applicability are excluded from the quick rate")

var quickRows = earlierDays
for stream in 1..<16 { quickRows += weeks(16, for: series("quick-\(stream)")) }
let quickLive = liveCycle(from: monday.addingTimeInterval(-6 * day), to: now, reset: reset.addingTimeInterval(-6 * day)) { _ in 0.2 }
let quickSnapshot = QuotaHistorySnapshot(buckets: quickRows + quickLive.rows)
let quickClock = DispatchTime.now().uptimeNanoseconds
let quickTimed = engine.forecast(snapshot: quickSnapshot, current: current(quickLive.used, at: now, reset: reset.addingTimeInterval(-6 * day)),
                                 calendar: calendar, now: now)
let quickMS = Double(DispatchTime.now().uptimeNanoseconds - quickClock) / 1_000_000
check(quickTimed.readiness == .quick && quickMS < 10, "quick estimate benchmark under 10 ms")
print("Quick first hour (weekly): " + scenarioText.joined(separator: "; ") + String(format: "; 10%% Mon 09:00 → %.1f%%", tenPercent.expectedUsed ?? .nan))
print(String(format: "Quick estimate: 1%% at 1 h Monday 09:00 weekly → %.1f%% (day %d); 30%% after 1 day weekly → %.1f%% (warning %@); 20%% after 1 h on 5-hour → %.1f%%; DST weeks → %.1f%% / %.1f%%; benchmark %.3f ms",
             firstHour.expectedUsed ?? .nan, firstHour.learningDays, firstDay.expectedUsed ?? .nan,
             firstDay.quickWarning ? "yes" : "no", shortQuick.expectedUsed ?? .nan, dstResults[0], dstResults[1], quickMS))

// Build the full row-budget snapshot before the timed call. The selected short meter keeps
// 16 weeks of half-hours; other streams fill the snapshot without entering its calculation.
var benchmarkRows: [QuotaBucket] = []
for stream in 0..<16 {
    let key = series("benchmark-\(stream)", duration: 18_000)
    for cell in 0..<6_000 {
        let date = monday.addingTimeInterval(Double(cell - 6_000) * hour / 2)
        let start = monday.addingTimeInterval(Double((cell / 10) * 10 - 6_000) * hour / 2)
        let cycle = QuotaCycle(reset: start.addingTimeInterval(5 * hour), segmentStart: start)
        benchmarkRows.append(.init(series: key, cycle: cycle, start: date, deltaHundredths: 100,
                                   coveredSeconds: hour / 2, quietSeconds: 0, flags: [],
                                   latest: sample(date, Double(cell % 10))))
    }
}
let maxSnapshot = QuotaHistorySnapshot(buckets: benchmarkRows)
let benchmark = current(4, for: series("benchmark-0", duration: 18_000), at: shortNow, reset: shortReset)
let start = DispatchTime.now().uptimeNanoseconds
let measured = engine.forecast(snapshot: maxSnapshot, current: benchmark, calendar: calendar, now: shortNow)
let elapsedMS = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
check(benchmarkRows.count == 96_000 && measured.expectedUsed != nil, "full-store benchmark computed a forecast")
print(String(format: "Forecast benchmark, 96,000 rows: %.3f ms (target ≤10 ms)", elapsedMS))
print("Usage forecast: \(assertions) checks passed")

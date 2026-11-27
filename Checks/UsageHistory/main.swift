import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let now = UsageJSON.date("2026-11-06T12:00:00Z")!
let profile = QuotaProfileID(rawValue: "fixture")
let utc = "UTC"
let weekly = QuotaMeter(scope: .shared, durationSeconds: 604_800)
let session = QuotaMeter(scope: .shared, durationSeconds: 18_000)
let key = QuotaImportKey(profile: profile, timeZoneID: utc)
let codex = QuotaSeries(provider: .codex, profile: profile, plan: "plus", meter: weekly, timeZoneID: utc)
let t = UsageJSON.date("2026-11-05T09:00:00Z")!
let reset = t.addingTimeInterval(86_400)
var assertions = 0

func check(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
    assertions += 1
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL line \(line): \(message)\n".utf8))
        exit(1)
    }
}

func store(_ name: String, at clock: Date = now, limits: UsageQuotaHistory.Limits = .init()) -> UsageQuotaHistory {
    UsageQuotaHistory(directory: root.appendingPathComponent(name), limits: limits, clock: { clock })
}

func observation(_ time: Date, _ used: Double, _ series: QuotaSeries = codex, reset anchor: Date = reset,
                 source: QuotaSource = .api, attribution: QuotaAttribution = .live,
                 kind: QuotaResetKind = .explicit) -> QuotaObservation {
    QuotaObservation(series: series, date: time, used: used, reset: anchor, source: source,
                     resetKind: kind, attribution: attribution)
}

func date(_ minutes: Double) -> Date { t.addingTimeInterval(minutes * 60) }

func buckets(_ history: UsageQuotaHistory, _ series: QuotaSeries = codex) -> [QuotaBucket] {
    Array(history.snapshot().buckets(for: series, in: now.addingTimeInterval(-120 * 86_400)..<now.addingTimeInterval(86_400)))
}

func gaps(_ history: UsageQuotaHistory, _ series: QuotaSeries = codex) -> [QuotaGap] {
    history.snapshot().gaps(for: series, in: now.addingTimeInterval(-120 * 86_400)..<now.addingTimeInterval(86_400))
}

func parse(_ object: [String: Any], provider: UsageProvider = .codex, timestamp: Date = t,
           source: QuotaSource = .api) -> [QuotaObservation] {
    let reading = provider == .codex ? UsageJSON.codex(object, at: timestamp, format: "local")
        : UsageJSON.claude(object, at: timestamp)
    return UsageQuotaCapture.observations(reading, provider: provider, profile: profile, timeZoneID: utc,
                                          source: source, attribution: .live, now: now, fallbackPlan: "Max")
}

func limit(_ used: Double, duration: Int, at time: Date? = nil, reset anchor: Date = reset) -> [String: Any] {
    var result: [String: Any] = ["used_percent": used, "window_minutes": duration, "resets_at": anchor.timeIntervalSince1970]
    if let time { result["observed_at"] = time.timeIntervalSince1970 }
    return result
}

do {
    let weeklyLimit = limit(17, duration: 10080, at: date(-1))
    let shortLimit = limit(100, duration: 300, at: date(-1), reset: date(120))
    let first = parse(["primary": weeklyLimit, "secondary": shortLimit, "plan_type": " Plus "])
    let swapped = parse(["primary": shortLimit, "secondary": weeklyLimit, "plan_type": "plus"])
    check(Set(first.map(\.series)) == Set(swapped.map(\.series)), "Codex slot moves preserve the meter")
    let week = first.first { $0.series.meter == weekly }!
    check(week.date == date(-1) && week.companion == .present(.active(used: 100, reset: date(120))),
          "per-meter time and simultaneously exhausted companion")
    check(first.first { $0.series.meter == session }?.bindingWeekly == .present(.active(used: 17, reset: reset)),
          "short sample carries weekly state")
    check(week.hardBlockUntil == nil, "100% companion alone implies no hard block")
    let missing = parse(["primary": weeklyLimit, "secondary": NSNull(), "plan_type": "plus"])
    check(missing.count == 1 && missing[0].companion == .unknown, "null slot has unknown applicability")
    check(parse(["primary": weeklyLimit, "secondary": [:], "plan_type": "plus"])[0].companion == .unknown,
          "empty slot has unknown applicability")
    check(parse(["primary": weeklyLimit, "secondary": weeklyLimit, "plan_type": "plus"]).isEmpty,
          "ambiguous duplicate meter dropped")
    check(parse(["primary": limit(102, duration: 10080), "plan_type": "plus"]).isEmpty,
          "display clamping cannot train history")
    check(parse(["primary": weeklyLimit, "five_hour_applicable": false, "hard_blocked": true,
                 "unlock_at": date(25).timeIntervalSince1970, "plan_type": "plus"])[0].hardBlockUntil == date(25),
          "explicit hard block window survives")
    check(parse(["primary": weeklyLimit, "five_hour_applicable": false, "plan_type": "plus"])[0].companion == .absent,
          "explicit absent")
    check(parse(["primary": weeklyLimit, "five_hour_status": "inactive", "plan_type": "plus"])[0].companion == .present(.inactive),
          "explicit inactive")
    check(parse(["primary": weeklyLimit, "secondary": limit(2, duration: 300, at: t, reset: date(120)),
                 "plan_type": "plus"]).first { $0.series.meter == weekly }?.companion == .present(.unknown),
          "stale companion remains unknown")

    func model(_ id: String?, _ name: String?) -> [String: Any] {
        var model: [String: Any] = [:]
        model["id"] = id
        model["display_name"] = name
        return ["kind": "weekly_scoped", "percent": 3, "resets_at": reset.timeIntervalSince1970, "scope": ["model": model]]
    }
    let claudeA = parse(["limits": [model("a", "Old"), model(nil, " SONNET "), model(nil, nil)]], provider: .claude)
    let claudeB = parse(["limits": [model(nil, "sonnet"), model("a", "New")]], provider: .claude)
    check(Set(claudeA.map(\.series)) == Set(claudeB.map(\.series)) && claudeA.count == 2,
          "stable model IDs and normalized names ignore rename/order")
    check(claudeA.contains { $0.series.meter.scope == .modelID("a") }, "Claude model ID is preserved")
    let legacy = parse(["seven_day_sonnet": ["utilization": 3, "resets_at": reset.timeIntervalSince1970]], provider: .claude)
    check(legacy.first?.series.meter.scope == .legacyClaude("seven_day_sonnet"), "legacy scope is separate")
    let cache = try JSONEncoder().encode(UsageJSON.codex(["primary": weeklyLimit], at: t, format: "local"))
    check(try! JSONDecoder().decode(UsageReading.self, from: cache).quota == nil, "display cache cannot replay quota")
}

do {
    let history = store("ordered")
    history.ingest([observation(date(10), 2, source: .statusLine), observation(t, 1),
                    observation(date(20), 3), observation(date(10), 2.5), observation(date(10), 91, source: .rollout),
                    observation(date(20), 3), observation(date(30), -.infinity),
                    observation(date(30), 22, reset: date(29)), observation(now.addingTimeInterval(6), 60, reset: now.addingTimeInterval(600))], now: date(20))
    let rows = buckets(history)
    check(rows.count == 1 && rows[0].deltaHundredths == 200 && rows[0].coveredSeconds == 1200,
          "sort, duplicate filtering, validated readings and per-meter API precedence")
    check(rows[0].latest?.used == 3 && rows[0].latest?.date == date(20), "latest sample keeps actual time")
    check(history.flush(), "write ordered history")
    let reopened = store("ordered")
    check(buckets(reopened) == rows, "manifest endpoints and compact rows restore identically")
    reopened.ingest([observation(date(30), 3.01)], now: date(30))
    check(buckets(reopened)[0].deltaHundredths == 201, "restart resumes the original high water")
}

do {
    let history = store("stored-reset-tolerance")
    let short = QuotaSeries(provider: .codex, profile: profile, plan: "plus", meter: session, timeZoneID: utc)
    let corrupt = QuotaSeries(provider: .codex, profile: profile, plan: "max", meter: weekly, timeZoneID: utc)
    let weeklyReset = t.addingTimeInterval(Double(weekly.durationSeconds + 1))
    let shortReset = t.addingTimeInterval(Double(session.durationSeconds + 2))
    history.ingest([observation(t, 2, reset: weeklyReset, kind: .calculated),
                    observation(date(10), 3, reset: weeklyReset, kind: .calculated),
                    observation(t, 4, short, reset: shortReset, kind: .calculated),
                    observation(date(10), 6, short, reset: shortReset, kind: .calculated),
                    observation(t, 8, corrupt), observation(date(10), 9, corrupt),
                    observation(date(60), 10, corrupt)], now: now)
    check(history.flush(), "write calculated-reset cycles")
    let reopened = store("stored-reset-tolerance")
    check(buckets(reopened).first?.deltaHundredths == 100 && buckets(reopened, short).first?.deltaHundredths == 200,
          "calculated cycle durations +1 s and +2 s survive shard reload")

    let directory = root.appendingPathComponent("stored-reset-tolerance")
    let manifestURL = directory.appendingPathComponent("manifest.json")
    var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String: Any]
    var files = manifest["files"] as! [String: [String: Any]]
    let week = files.keys.first!
    let shardURL = directory.appendingPathComponent(files[week]!["name"] as! String)
    var shard = try JSONSerialization.jsonObject(with: Data(contentsOf: shardURL)) as! [String: Any]
    var rows = shard["rows"] as! [[Any]]
    let corruptRow = rows.firstIndex { ($0[3] as? Int) == 100 && ($0[9] as? Double) == 9 }!
    rows[corruptRow][4] = 3_601
    rows.append(["malformed row"])
    shard["rows"] = rows
    let data = try JSONSerialization.data(withJSONObject: shard)
    try data.write(to: shardURL)
    files[week]!["bytes"] = data.count
    manifest["files"] = files
    try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
    let recovered = store("stored-reset-tolerance")
    check(buckets(recovered).first?.deltaHundredths == 100 && buckets(recovered, short).first?.deltaHundredths == 200
          && buckets(recovered, corrupt).allSatisfy { $0.deltaHundredths == 0 },
          "invalid or malformed shard rows leave other meters intact")
}

do {
    let history = store("alternating-rollout")
    history.ingest([observation(t, 10),
                    observation(date(5), 11, source: .rollout, attribution: .provisional),
                    observation(date(10), 12),
                    observation(date(15), 13, source: .rollout, attribution: .provisional),
                    observation(date(20), 14)], now: date(20))
    let rows = buckets(history)
    check(rows.count == 1 && rows[0].coveredSeconds == 1_200 && rows[0].deltaHundredths == 400,
          "alternating provisional rollout and API preserves 20 minutes of live coverage")
    check(history.flush() && buckets(store("alternating-rollout")) == rows,
          "alternating-rollout live coverage survives restart")
}

do {
    let history = store("first-hit")
    history.ingest([observation(t, 90), observation(date(10), 100), observation(date(50), 100)], now: now)
    let rows = buckets(history)
    check(rows.count == 1 && rows[0].firstHit == date(10) && rows[0].latest?.date == date(50)
          && rows[0].coveredSeconds == 600 && rows[0].deltaHundredths == 1000,
          "flat 100% samples preserve the minute-10 hit and censor through minute 50")
    check(history.flush() && buckets(store("first-hit")) == rows, "first saturation time survives restart")
}

do {
    let history = store("companion-samples")
    let readings = [15.0, 30, 45].map { minute -> QuotaObservation in
        var reading = observation(date(minute), 7)
        reading.companion = .present(.active(used: 80 + minute / 10, reset: date(120)))
        return reading
    }
    history.ingest(readings, now: now)
    let rows = buckets(history)
    check(rows.first?.earlierCompanionSamples.map(\.date) == [date(15), date(30)]
          && rows.first?.latest?.date == date(45), "quarter-hour companion samples share one bucket")
    check(history.flush() && buckets(store("companion-samples")) == rows, "within-bucket companion samples survive restart")
}

do {
    let monday = UsageJSON.date("2026-11-02T00:00:00Z")!
    let week: TimeInterval = 604_800
    let hour: TimeInterval = 3_600
    let origin = monday.addingTimeInterval(18 * hour + 30 * 60 + 30)
    let history = store("companion-crossing", at: origin)
    func companion(_ used: Double, on day: Date) -> QuotaCapState {
        .present(.active(used: used, reset: day.addingTimeInterval(21 * hour)))
    }
    var observations: [QuotaObservation] = []
    for priorWeek in 1...8 {
        let start = monday.addingTimeInterval(-Double(priorWeek) * week)
        let reset = start.addingTimeInterval(week)
        for tick in 0..<672 {
            let date = start.addingTimeInterval(Double(tick) * 900)
            var reading = observation(date, Double(tick) / 10, reset: reset)
            reading.companion = tick == 74 ? companion(79, on: start)
                : .present(.active(used: 85, reset: date.addingTimeInterval(2 * hour)))
            observations.append(reading)
            if tick == 74 {
                for (seconds, used) in [(15.0, 85.0), (45.0, 87.0)] {
                    var followup = observation(date.addingTimeInterval(seconds), reading.used, reset: reset)
                    followup.companion = companion(used, on: start)
                    observations.append(followup)
                }
            }
        }
    }
    history.ingest(observations, now: origin)
    let crossed = buckets(history).filter { row in
        row.earlierCompanionSamples.contains { $0.companion == companion(79, on: row.cycle.segmentStart) }
    }
    check(crossed.count == 8 && crossed.allSatisfy { row in
        row.earlierCompanionSamples.contains {
            $0.date == row.start.addingTimeInterval(30 * 60 + 15)
                && $0.companion == companion(85, on: row.cycle.segmentStart)
        }
    }, "79%, 85%, and 87% in the same minute retain the first 80% crossing after the next sample")
    check(history.flush(), "companion crossing history saves")
    let reopened = store("companion-crossing", at: origin)
    var calendar = Calendar(identifier: .iso8601)
    calendar.timeZone = TimeZone(identifier: utc)!
    var current = observation(origin, 7.4, reset: monday.addingTimeInterval(week))
    current.companion = companion(85, on: monday)
    let forecast = UsageForecast().forecast(snapshot: reopened.snapshot(), current: current, calendar: calendar, now: origin)
    check(forecast.readiness == .normal, "eight persisted weeks stay normal at :30:30 after a same-minute 80% crossing")
}

do {
    let history = store("resets")
    history.ingest([observation(t, 4), observation(date(10), 3.6), observation(date(20), 4),
                    observation(date(30), 4.12, reset: reset.addingTimeInterval(2), kind: .calculated),
                    observation(date(35), 4.50), observation(date(40), 1),
                    observation(date(45), 1.4), observation(date(48), 22, reset: reset.addingTimeInterval(900)),
                    observation(date(50), 22.87, reset: reset.addingTimeInterval(900)),
                    observation(date(54), 100, reset: reset.addingTimeInterval(900)),
                    observation(date(58), 100, reset: reset.addingTimeInterval(900))], now: now)
    let rows = buckets(history)
    check(rows.count == 3 && rows.map(\.deltaHundredths) == [50, 40, 7800], "regression, nearby calculated reset, and manual resets")
    check(rows.map(\.coveredSeconds) == [900, 300, 360], "regressions and capped flats add no coverage")
    check(rows.last?.flags.contains(.censored) == true, "censored sample distinguished from first observed hit")
}

do {
    let history = store("split")
    history.ingest([observation(date(54), 10.002), observation(date(59), 10.006),
                    observation(date(61), 10.019), observation(date(68), 10.029)], now: now)
    let rows = buckets(history)
    check(rows.map(\.deltaHundredths) == [1, 2] && rows.map(\.coveredSeconds) == [360, 480],
          "fractional debits aggregate and a split conserves hundredths")
    check(rows.allSatisfy { $0.flags.contains(.split) }, "split is explicit")

    let sleeps = store("sleeps")
    sleeps.ingest([observation(t, 12)], now: now)
    sleeps.breakCoverage(at: date(8), allowsQuiet: true)
    sleeps.ingest([observation(date(60), 12)], now: now)
    sleeps.breakCoverage(at: date(65), allowsQuiet: true)
    sleeps.ingest([observation(date(75), 14.5)], now: now)
    sleeps.breakCoverage(at: date(85), allowsQuiet: true)
    sleeps.ingest([observation(date(135), 16)], now: now)
    sleeps.breakCoverage(at: date(145), allowsQuiet: false)
    sleeps.ingest([observation(date(180), 16)], now: now)
    let sleepRows = buckets(sleeps)
    check(sleepRows.reduce(0) { $0 + $1.quietSeconds } == 3600, "rounded zero bridges sleep and respects permission breaks")
    check(sleepRows.reduce(0) { $0 + $1.deltaHundredths } == 250 && gaps(sleeps).map(\.localized) == [true, false],
          "localized same-hour positive gap and unresolved cross-hour positive gap")
    check(sleepRows[0].flags.contains(.roundedPlateau), "integer plateau is preserved without synthetic debit")

    let short = QuotaSeries(provider: .codex, profile: profile, plan: "plus", meter: session, timeZoneID: utc)
    let event = store("event")
    event.ingest([observation(date(23), 5, short, reset: date(180), source: .statusLine),
                  observation(date(29), 6, short, reset: date(180), source: .statusLine),
                  observation(date(37), 7, short, reset: date(180), source: .statusLine)], now: now)
    check(buckets(event, short).map(\.deltaHundredths) == [100, 0] && gaps(event, short).count == 1,
          "event threshold is six minutes and short buckets are half an hour")
}

do {
    let zone = "America/Los_Angeles"
    let series = QuotaSeries(provider: .codex, profile: profile, plan: "plus", meter: weekly, timeZoneID: zone)
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: zone)!
    let fall = store("fall")
    let before = UsageJSON.date("2026-11-01T08:55:00Z")!
    let after = UsageJSON.date("2026-11-01T09:05:00Z")!
    fall.ingest([observation(before, 4, series, reset: after.addingTimeInterval(3600)),
                 observation(after, 5, series, reset: after.addingTimeInterval(3600))], now: now)
    let repeated = buckets(fall, series)
    check(repeated.count == 2 && repeated.map { cal.component(.hour, from: $0.start) } == [1, 1]
          && repeated.map(\.deltaHundredths) == [50, 50], "both absolute copies of the fall-back hour")

    let springBefore = UsageJSON.date("2026-03-08T09:55:00Z")!
    let springAfter = UsageJSON.date("2026-03-08T10:05:00Z")!
    let spring = store("spring", at: springAfter)
    spring.ingest([observation(springBefore, 0, series, reset: springAfter.addingTimeInterval(3600)),
                   observation(springAfter, 1, series, reset: springAfter.addingTimeInterval(3600))], now: springAfter)
    let skipped = spring.snapshot().buckets(for: series, in: springBefore.addingTimeInterval(-3600)..<springAfter)
    check(skipped.map { cal.component(.hour, from: $0.start) } == [1, 3], "no nonexistent spring-forward slot")
    check(spring.snapshot().buckets(for: codex, in: springBefore..<springAfter).isEmpty, "zones are separate series")

    let halfZone = "Australia/Lord_Howe"
    let halfSeries = QuotaSeries(provider: .codex, profile: profile, plan: "plus", meter: weekly, timeZoneID: halfZone)
    let halfBefore = UsageJSON.date("2026-04-04T14:55:00Z")!
    let halfAfter = UsageJSON.date("2026-04-04T15:05:00Z")!
    let halfHistory = store("half-hour-dst", at: halfAfter.addingTimeInterval(600))
    halfHistory.ingest([observation(halfBefore, 10, halfSeries, reset: halfAfter.addingTimeInterval(3600)),
                        observation(halfAfter, 11, halfSeries, reset: halfAfter.addingTimeInterval(3600))], now: halfAfter)
    let halfRange = halfBefore.addingTimeInterval(-3600)..<halfAfter
    let partial = Array(halfHistory.snapshot().buckets(for: halfSeries, in: halfRange))
    check(partial.count == 2 && partial[0].end == partial[1].start
          && partial[1].end.timeIntervalSince(partial[1].start) == 1800
          && partial.map(\.deltaHundredths) == [50, 50], "half-hour DST transition yields disjoint clipped buckets")
    check(halfHistory.flush() && Array(store("half-hour-dst", at: halfAfter).snapshot()
        .buckets(for: halfSeries, in: halfRange)) == partial, "clipped buckets round-trip")
}

func rollout(_ time: Date, _ used: Double, account: String? = nil, subject: String? = nil,
             limitID: String = "codex", anchor: Date = reset, labeledPlan: Bool = true,
             payloadAccount: String? = nil) throws -> Data {
    var rate: [String: Any] = ["primary": limit(used, duration: 10080, reset: anchor), "secondary": NSNull(), "limit_id": limitID]
    if labeledPlan { rate["plan_type"] = "plus" }
    rate["account_id"] = account
    rate["user_id"] = subject
    if payloadAccount != nil { rate["account_id"] = NSNull() }
    var payload: [String: Any] = ["type": "token_count", "rate_limits": rate]
    payload["account_id"] = payloadAccount
    return try JSONSerialization.data(withJSONObject: ["type": "event_msg", "timestamp": time.timeIntervalSince1970,
                                                       "payload": payload])
}

func appendLine(_ data: Data, to destination: inout Data) { destination.append(data); destination.append(10) }

func scan(_ reader: UsageCodexBackfill) -> UsageCodexBackfill.Pass {
    let group = DispatchGroup()
    group.enter()
    var result: UsageCodexBackfill.Pass?
    reader.scanNextPass { result = $0; group.leave() }
    check(group.wait(timeout: .now() + 8) == .success, "bounded scan completes")
    return result!
}

do {
    let sessions = root.appendingPathComponent("sessions")
    let recent = sessions.appendingPathComponent("2026/11/06")
    let earlier = sessions.appendingPathComponent("2026/11/05")
    try FileManager.default.createDirectory(at: recent, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: earlier, withIntermediateDirectories: true)
    var one = Data(repeating: 120, count: 5_000)
    one.append(10)
    appendLine(try rollout(date(10), 4), to: &one)
    appendLine(Data("{bad".utf8), to: &one)
    appendLine(try rollout(t, 2), to: &one)
    appendLine(try rollout(date(10), 4), to: &one)
    appendLine(try rollout(date(12), 67, limitID: "other"), to: &one)
    appendLine(Data(repeating: 120, count: 2048), to: &one)
    appendLine(try rollout(date(14), 4.5, labeledPlan: false), to: &one)
    one.append(try rollout(date(13), 80))
    try one.write(to: recent.appendingPathComponent("rollout-new.jsonl"))
    var two = Data()
    appendLine(try rollout(date(-1), 1, account: "account", subject: "person"), to: &two)
    try two.write(to: earlier.appendingPathComponent("rollout-old.jsonl"))

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: utc)!
    let reader = UsageCodexBackfill(sessionsRoot: sessions, now: now, calendar: calendar,
                                    account: .init(account: "account", subject: "person"),
                                    limits: .init(files: 1, fileTailBytes: 4096, maxLineBytes: 1024))
    let first = scan(reader)
    let final = scan(reader)
    check(first.candidates.count == 4 && first.moreFiles && first.truncated, "first-pass tail and per-line bounds")
    check(final.candidates.count == 5 && final.candidates.filter(\.identified).count == 1,
          "round robin continues on older day and matches both account and user")
    let anchor = observation(date(17), 5)
    let current = date(17)
    let attributed = UsageCodexBackfill.attributed(final.candidates, key: key, anchors: [anchor], switchedAt: nil, now: current)
    check(attributed.count == 5 && attributed.filter { $0.attribution == .provisional }.count == 4,
          "same-cycle anchor admits provisional data including a missing plan")
    check(UsageCodexBackfill.attributed(final.candidates, key: key, anchors: [anchor],
                                      switchedAt: date(15), now: current).map(\.attribution) == [.verifiedArchive],
          "account switch limits unlabeled provenance")
    check(UsageCodexBackfill.attributed(final.candidates, key: key, anchors: [], switchedAt: nil, now: current).count == 1,
          "unlabeled archive needs fresh evidence")
    let imported = store("archive-order")
    imported.replaceImport(attributed.filter { $0.attribution == .provisional }, for: key, complete: true, now: current)
    check(buckets(imported).reduce(0) { $0 + $1.deltaHundredths } == 250, "out-of-order events and duplicate debit")
}

do {
    let sessions = root.appendingPathComponent("shared-sessions")
    let day = sessions.appendingPathComponent("2026/11/06")
    try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
    var lines = Data()
    appendLine(try rollout(date(10), 4), to: &lines)
    appendLine(try rollout(date(2), 2, account: "account", subject: "person"), to: &lines)
    appendLine(try rollout(date(12), 5, account: "account", subject: "person"), to: &lines)
    appendLine(try rollout(date(5), 80, account: "another"), to: &lines)
    appendLine(try rollout(date(14), 6), to: &lines)
    appendLine(try rollout(date(11), 81, account: "account", subject: "other"), to: &lines)
    appendLine(try rollout(date(11.5), 4.5), to: &lines)
    appendLine(try rollout(date(4), 3), to: &lines)
    try lines.write(to: day.appendingPathComponent("rollout-shared.jsonl"))
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: utc)!
    let reader = UsageCodexBackfill(sessionsRoot: sessions, now: now, calendar: calendar,
                                    account: .init(account: "account", subject: "person"))
    let attributed = UsageCodexBackfill.attributed(scan(reader).candidates, key: key, anchors: [observation(date(17), 7)],
                                                   switchedAt: nil, now: date(17))
    check(attributed.map(\.date).sorted() == [date(2), date(12), date(14)]
          && attributed.filter { $0.attribution == .provisional }.map(\.date) == [date(14)],
          "shared rollout home rejects unlabeled rows across explicit other-account or user evidence")
}

do {
    let sessions = root.appendingPathComponent("null-identity-sessions")
    let day = sessions.appendingPathComponent("2026/11/06")
    try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
    var lines = Data()
    appendLine(try rollout(date(2), 2, account: "account-a"), to: &lines)
    appendLine(try rollout(date(5), 95, payloadAccount: "account-b"), to: &lines)
    appendLine(try rollout(date(10), 4), to: &lines)
    appendLine(try rollout(date(12), 5, account: "account-a"), to: &lines)
    appendLine(try rollout(date(14), 6), to: &lines)
    try lines.write(to: day.appendingPathComponent("rollout-null-identity.jsonl"))
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: utc)!
    let reader = UsageCodexBackfill(sessionsRoot: sessions, now: now, calendar: calendar,
                                    account: .init(account: "account-a", subject: nil))
    let attributed = UsageCodexBackfill.attributed(scan(reader).candidates, key: key, anchors: [observation(date(17), 7)],
                                                   switchedAt: nil, now: date(17))
    check(attributed.map(\.date).sorted() == [date(2), date(12), date(14)]
          && attributed.filter { $0.attribution == .provisional }.map(\.date) == [date(14)],
          "null rate-limits identity imports neither payload account B at minute 5 nor its unlabeled row at minute 10")
}

do {
    let history = store("seam")
    let live = [observation(date(65), 20), observation(date(75), 22)]
    let archive = [observation(t, 10, source: .rollout, attribution: .verifiedArchive),
                   observation(date(54), 12, source: .rollout, attribution: .verifiedArchive),
                   observation(date(59), 13, source: .rollout, attribution: .verifiedArchive),
                   observation(date(64), 18, source: .rollout, attribution: .verifiedArchive),
                   observation(date(75), 28, source: .rollout, attribution: .verifiedArchive)]
    history.replaceImport(archive, for: key, complete: false, now: now)
    check(history.flush() && !history.importComplete(key), "first-pass shards are durable without a marker")
    let restarted = store("seam")
    check(buckets(restarted).allSatisfy { $0.flags.contains(.provisional) }, "interrupted imports reload as provisional")
    restarted.ingest(live, now: now)
    restarted.replaceImport(archive, for: key, complete: true, now: now)
    check(!restarted.importComplete(key), "completion waits for durable replacement")
    check(restarted.flush() && restarted.importComplete(key), "marker written with shards")
    let baseline = buckets(restarted)
    check(baseline.map(\.start) == [t, date(60)] && baseline.last?.deltaHundredths == 200
          && baseline.last?.latest?.source == .api, "first live bucket owns the seam")
    check(baseline.first?.flags.contains(.provisional) == false, "completed identified history can be promoted")
    let repeated = store("seam")
    repeated.ingest(live, now: now)
    repeated.replaceImport(archive.reversed(), for: key, complete: true, now: now)
    check(repeated.flush() && buckets(repeated) == baseline, "restart and import replacement are idempotent")
    let dir = root.appendingPathComponent("seam")
    let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
    let shard = files.first { $0.lastPathComponent.hasPrefix("week-") }!
    try Data("{truncated".utf8).write(to: shard)
    let damaged = store("seam")
    check(buckets(damaged).allSatisfy { $0.deltaHundredths == 0 } && !damaged.importComplete(key),
          "corrupt shard yields missing history and invalidates the marker")
}

do {
    let one = store("account")
    let account = QuotaAccount(account: "private-account", subject: "private-person")
    let login = one.login(provider: .codex, directory: "/private/home/one", account: account, signedIn: true, now: t)!
    check(one.login(provider: .codex, directory: "/private/home/one", account: nil, signedIn: true, now: date(2))?.profile == login.profile,
          "temporary identity metadata unavailability does not rotate a known login")
    check(one.flush(), "flush login metadata")
    let persisted = try String(contentsOf: root.appendingPathComponent("account/manifest.json"), encoding: .utf8)
    check(!persisted.contains("private-account") && !persisted.contains("private-person") && !persisted.contains("/private/home"),
          "opaque IDs only on disk")
    let two = store("account")
    check(two.login(provider: .codex, directory: "/private/home/one", account: account, signedIn: true, now: date(2))?.profile == login.profile,
          "same salt and profile across restart")
    _ = two.login(provider: .codex, directory: "/private/home/one", account: nil, signedIn: false, now: date(3))
    let relogin = two.login(provider: .codex, directory: "/private/home/one", account: account, signedIn: true, now: date(4))
    check(relogin?.profile != login.profile && relogin?.switchedAt == date(3), "observed sign-out rotates the login generation")
}

do {
    let limits = UsageQuotaHistory.Limits(series: 3, rows: 18, bytes: 5500)
    let cap = store("budget", limits: limits)
    for n in 0..<6 {
        let series = QuotaSeries(provider: .codex, profile: QuotaProfileID(rawValue: "p\(n)"), plan: "plus", meter: weekly, timeZoneID: utc)
        let begin = t.addingTimeInterval(Double(n * 60))
        let samples = (0..<16).map { observation(begin.addingTimeInterval(Double($0 * 3600)), Double($0), series, reset: reset) }
        cap.ingest(samples, now: now)
    }
    check(cap.flush(), "byte budget trims the store")
    let snapshot = cap.snapshot()
    let range = now.addingTimeInterval(-UsageQuotaHistory.retention)..<now
    let cells = snapshot.series.reduce(0) { $0 + snapshot.buckets(for: $1, in: range).count + snapshot.gaps(for: $1, in: range).count }
    let sizes = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("budget"), includingPropertiesForKeys: [.fileSizeKey])
        .reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    check(snapshot.series.count <= 3 && cells <= 18 && sizes <= 5500 && cells > 0, "series, combined row/gap, and byte cap")
    check(!store("budget", limits: limits).snapshot().series.isEmpty, "bounded store remains readable")
    let archive = (0...115).flatMap { day -> [QuotaObservation] in
        let time = now.addingTimeInterval(Double(-day * 86_400 - 60))
        return [observation(time, 10, reset: time.addingTimeInterval(3600), source: .rollout, attribution: .verifiedArchive),
                observation(time.addingTimeInterval(30), 11, reset: time.addingTimeInterval(3600), source: .rollout, attribution: .verifiedArchive)]
    }
    let retained = store("weeks-archive")
    retained.replaceImport(archive, for: key, complete: true, now: now)
    check(retained.flush(), "persist rolling history")
    let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("weeks-archive"), includingPropertiesForKeys: nil)
    check(files.filter { $0.lastPathComponent.hasPrefix("week-") }.count <= 17 && buckets(retained).count == 112,
          "rolling 112 days and at most 17 UTC shards")
}

do {
    let blocked = root.appendingPathComponent("retry")
    try Data("temporarily a file".utf8).write(to: blocked)
    let history = store("retry")
    let archive = [observation(t, 9, source: .rollout, attribution: .verifiedArchive),
                   observation(date(5), 11, source: .rollout, attribution: .verifiedArchive)]
    history.replaceImport(archive, for: key, complete: true, now: now)
    check(!history.flush() && !history.importComplete(key), "write failure cannot advance the import marker")
    try FileManager.default.removeItem(at: blocked)
    check(history.flush() && history.importComplete(key) && buckets(store("retry")).first?.deltaHundredths == 200,
          "failed shard writes remain available for retry")
    let cancelled = store("cancelled")
    cancelled.replaceImport(archive, for: key, complete: true, now: now, cancelled: { true })
    check(cancelled.flush() && cancelled.snapshot().series.isEmpty && !cancelled.importComplete(key),
          "cancelled generation leaves no import data")
}
print("Usage history checks passed (\(assertions) assertions).")

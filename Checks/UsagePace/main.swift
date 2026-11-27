import Foundation

// The fixtures exercise usage state without starting the app or its module registry.
func log(_ message: String) {}
final class ModuleCancellation: @unchecked Sendable {
    var isCancelled: Bool { fatalError("Unexpected service startup") }
    func cancel() { fatalError("Unexpected service startup") }
}

let now = Date(timeIntervalSince1970: 1_750_000_000)
let hour: TimeInterval = 3600
let day = 24 * hour
let week = 7 * day
var passed = 0
var failed = 0

func expect(_ name: String, _ condition: Bool) {
    if condition { passed += 1 } else { failed += 1 }
    print("\(condition ? "PASS" : "FAIL") \(name)")
}

func quota(_ id: String, used: Double, duration: TimeInterval, elapsed: TimeInterval,
           minutes: Double? = nil) -> UsageWindow {
    UsageWindow(id: id, title: id, used: used, resetsAt: now.addingTimeInterval(duration - elapsed), durationMinutes: minutes)
}

func pace(_ window: UsageWindow, _ samples: [(Date, Double)] = []) -> PaceResult? {
    UsagePaceProjection.pace(window, samples: samples, now: now)
}

func near(_ actual: TimeInterval?, _ expected: TimeInterval) -> Bool {
    actual.map { abs($0 - expected) < 0.001 } ?? false
}

let measuring = calendarText("Measuring pace…", "Midiendo el ritmo…")
for used in [1.0, 0.5] {
    let codex = quota("secondary", used: used, duration: week, elapsed: 31 * 60, minutes: 10080)
    let result = pace(codex)
    expect("Codex weekly at 31 min and \(used)% used stays in measuring",
           result?.warn == false && result?.secondsToEmpty == .infinity && result?.text == measuring)
}

for id in ["secondary", "seven_day", "seven_day_opus", "seven_day_sonnet", "weekly_all-1", "weekly_scoped-2"] {
    let result = pace(quota(id, used: 50, duration: week, elapsed: day, minutes: id == "secondary" ? 10080 : nil))
    expect("\(id) at 50% after one day projects exhaustion in one day",
           result?.warn == true && near(result?.secondsToEmpty, day) && result?.secondsToReset == 6 * day)
}

let scopedReset = now.addingTimeInterval(5 * day).timeIntervalSince1970
let opus: [String: Any] = ["kind": "weekly_scoped", "percent": 10, "resets_at": scopedReset,
                           "scope": ["model": ["id": "opus", "display_name": "Opus"]]]
let sonnet: [String: Any] = ["kind": "weekly_scoped", "percent": 20, "resets_at": scopedReset,
                             "scope": ["model": ["id": NSNull(), "display_name": "Sonnet"]]]
let earlier = UsageJSON.claude(["limits": [opus, sonnet]], at: now.addingTimeInterval(-7 * hour))
let reordered = UsageJSON.claude(["limits": [sonnet, opus]], at: now)
var history = UsagePaceHistory()
history.ingest(earlier, for: .claude, now: now)
history.ingest(reordered, for: .claude, now: now)
let reorderedPaces = reordered.windows.compactMap { history.pace(.claude, $0, now: now) }
expect("Reordering Opus and Sonnet keeps both histories flat and does not warn",
       reorderedPaces.count == 2 && reorderedPaces.allSatisfy {
           !$0.warn && $0.text == calendarText("No recent use", "Sin uso reciente")
       })

var renamedOpus = opus
renamedOpus["scope"] = ["model": ["id": "opus", "display_name": "Claude Opus"]]
let renamed = UsageJSON.claude(["limits": [renamedOpus]], at: now)
expect("A model ID keeps the same history key when its display name changes",
       renamed.windows.first.map { UsagePaceHistory.key(.claude, $0) } ==
           earlier.windows.first.map { UsagePaceHistory.key(.claude, $0) })

let positionalKey = "claude|weekly_scoped-0"
var persisted = history.persistedSamples
persisted[positionalKey] = [[earlier.date.timeIntervalSince1970, 10], [now.timeIntervalSince1970, 20]]
var restored = UsagePaceHistory()
restored.restore(persisted, now: now)
let cached = quota("weekly_scoped-0", used: 20, duration: week, elapsed: 2 * day)
restored.ingest(UsageReading(windows: [cached], plan: nil, date: now), for: .claude, now: now)
expect("Positional Claude keys are discarded on restore and ignored in cached readings",
       restored.persistedSamples == history.persistedSamples && restored.pace(.claude, cached, now: now)?.warn == false)

for id in ["primary", "five_hour", "session-0"] {
    let minutes: Double? = id == "primary" ? 300 : nil
    let early = pace(quota(id, used: 50, duration: 5 * hour, elapsed: 1799, minutes: minutes))
    let ready = pace(quota(id, used: 50, duration: 5 * hour, elapsed: 1800, minutes: minutes))
    expect("\(id) waits until 30 minutes of a 5-hour window",
           early?.warn == false && early?.text == measuring && ready?.warn == true && near(ready?.secondsToEmpty, 1800))
}

let unused = pace(quota("five_hour", used: 0, duration: 5 * hour, elapsed: hour))
expect("Zero usage shows the unused status", unused?.warn == false && unused?.secondsToEmpty == .infinity &&
       unused?.text == calendarText("Not used yet", "Sin uso todavía"))

let belowMinimum = pace(quota("five_hour", used: 4.9, duration: 5 * hour, elapsed: hour))
let atMinimum = pace(quota("five_hour", used: 5, duration: 5 * hour, elapsed: hour))
expect("The cumulative usage threshold is inclusive at 5%",
       belowMinimum?.text == measuring && atMinimum?.warn == false && near(atMinimum?.secondsToEmpty, 19 * hour))

let steepSamples = [(now.addingTimeInterval(-900), 0.0), (now, 50.0)]
let unknown = pace(quota("unknown", used: 50, duration: 5 * hour, elapsed: hour), steepSamples)
let beforeStart = pace(quota("primary", used: 50, duration: 5 * hour, elapsed: -1, minutes: 300), steepSamples)
expect("Unknown duration and a not-yet-active window both suppress the recent projection",
       unknown?.warn == false && unknown?.text == measuring && beforeStart?.warn == false && beforeStart?.text == measuring)

let resetBoundary: [(elapsed: TimeInterval, warns: Bool)] = [(8969, true), (8970, false), (9000, false), (9001, false)]
for (elapsed, warns) in resetBoundary {
    let result = pace(quota("session-0", used: 50, duration: 5 * hour, elapsed: elapsed))
    expect("Exhaustion warning respects the reset margin at \(elapsed) elapsed seconds",
           result?.warn == warns && near(result?.secondsToEmpty, elapsed))
}
let fractionalBoundary = pace(quota("five_hour", used: 15, duration: 5 * hour, elapsed: 2691))
expect("At 15% after 2691 seconds, exhaustion exactly 60 seconds before reset does not warn",
       fractionalBoundary?.warn == false && fractionalBoundary?.secondsToReset == 15309 &&
       near(fractionalBoundary?.secondsToEmpty, 15249))

let recentWindow = quota("five_hour", used: 20, duration: 5 * hour, elapsed: 2 * hour)
let recentChanges: [(span: TimeInterval, delta: Double, warns: Bool)] = [(899, 10, false), (900, 4.9, false), (900, 10, true)]
for (span, delta, warns) in recentChanges {
    let result = pace(recentWindow, [(now.addingTimeInterval(-span), 20 - delta), (now, 20), (now.addingTimeInterval(5), 90)])
    expect("A recent rise of \(delta) points over \(span) seconds uses the correct rate and ignores future readings",
           result?.warn == warns && near(result?.secondsToEmpty, warns ? 7200 : 28800))
}

let flat = pace(recentWindow, [(now.addingTimeInterval(-1440), 20), (now, 20)])
expect("Sufficient flat readings show the no-recent-use status",
       flat?.warn == false && flat?.text == calendarText("No recent use", "Sin uso reciente"))

let custom = quota("custom", used: 20, duration: 1800, elapsed: 600, minutes: 30)
let customResult = pace(custom, [(now.addingTimeInterval(-1200), 0), (now, 20)])
expect("A custom window honors its reported duration and ignores samples from before its start",
       customResult?.warn == false && near(customResult?.secondsToEmpty, 2400))

var inactive = quota("five_hour", used: 50, duration: 5 * hour, elapsed: 5 * hour)
expect("A reset at the current time has no pace line", pace(inactive) == nil)
inactive.resetsAt = nil
expect("A missing reset has no pace line", pace(inactive) == nil)

let activeCodex = QuotaAccount(account: "account-a", subject: "subject-a")
let rolloutJSON = """
{"timestamp":1750000000,"type":"event_msg","payload":{"type":"token_count","account_id":"account-b","rate_limits":{
"account_id":null,"primary":{"used_percent":95,"window_minutes":10080,"resets_at":1750100000}}}}
"""
func parseRollout(_ json: String) -> UsageJSON.CodexRollout {
    guard let event = UsageJSON.codexRollout(Data(json.utf8)) else { fatalError("Invalid rollout fixture") }
    return event
}
let foreignRollout = parseRollout(rolloutJSON)
let matchingRollout = parseRollout(rolloutJSON
    .replacingOccurrences(of: "1750000000", with: "1749999990")
    .replacingOccurrences(of: "\"account-b\"", with: "\"account-a\",\"user_id\":\"subject-a\"")
    .replacingOccurrences(of: "\"used_percent\":95", with: "\"used_percent\":20"))
let foreignSpanRollout = parseRollout(rolloutJSON
    .replacingOccurrences(of: "1750000000", with: "1750000001")
    .replacingOccurrences(of: "\"account_id\":\"account-b\",", with: ""))
var rolloutDisplay = UsageState(provider: .codex, signedIn: true)
if let accepted = UsageService.latestCodexRollout([foreignSpanRollout, foreignRollout, matchingRollout],
                                                 activeAccount: activeCodex, since: nil, now: now) {
    rolloutDisplay.acceptReading(accepted.reading, original: nil)
}
expect("Latest unlabeled balance is display-only despite a preceding foreign marker",
       foreignRollout.identity(for: activeCodex) == .foreign
       && rolloutDisplay.remaining(now) == 5
       && rolloutDisplay.orderedWindows.allSatisfy { UsagePace.thresholdAlert(rolloutDisplay, $0, threshold: 20, now: now) == nil })
let outerRollout = parseRollout(rolloutJSON.replacingOccurrences(of: "\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"account_id\":\"account-b\",",
                                                                with: "\"type\":\"event_msg\",\"account_id\":\"account-b\",\"payload\":{\"type\":\"token_count\","))
let nestedRollout = parseRollout(rolloutJSON.replacingOccurrences(of: "\"account_id\":\"account-b\",", with: "\"info\":{\"account_id\":\"account-b\"},"))
let conflictingRollout = parseRollout(rolloutJSON.replacingOccurrences(of: "\"account_id\":null", with: "\"account_id\":\"account-a\",\"user_id\":\"subject-a\""))
expect("Outer, nested and conflicting rollout identities fail closed",
       [outerRollout, nestedRollout, conflictingRollout].allSatisfy {
           UsageService.latestCodexRollout([$0], activeAccount: activeCodex, since: nil, now: now)?.identified == false
       } && matchingRollout.identity(for: activeCodex) == .matching && foreignSpanRollout.identity(for: activeCodex) == .unlabeled)

let accountOnly = parseRollout(rolloutJSON.replacingOccurrences(of: "account-b", with: "account-a"))
for (event, canAlert) in [(accountOnly, true), (foreignSpanRollout, false), (foreignRollout, false)] {
    let selected = UsageService.latestCodexRollout([event], activeAccount: activeCodex, since: nil, now: now)!
    rolloutDisplay.acceptReading(selected.reading, original: nil)
    expect("A tail scan uses only the row identity (\(event.identity(for: activeCodex)))",
           rolloutDisplay.remaining(now) == 5 && (UsagePace.thresholdAlert(rolloutDisplay, selected.reading.windows[0],
                                                                           threshold: 20, now: now) != nil) == canAlert)
}

// A rollout's session_meta names its creator: the ChatGPT user id, not the token subject, is compared.
let creatorCodex = QuotaAccount(account: "account-a", subject: "subject-a", creatorUser: "user-a")
let creator = UsageJSON.CodexRollout.creatorIdentity
expect("A session_meta creator naming the active account and user is trusted",
       creator("account-a", "user-a", creatorCodex) == .matching && creator("account-a", nil, creatorCodex) == .matching
       && creator("account-a", nil, activeCodex) == .matching)
expect("A session_meta creator naming another account or user is foreign; none is unlabeled",
       creator("account-b", "user-a", creatorCodex) == .foreign && creator("account-a", "user-b", creatorCodex) == .foreign
       && creator(nil, nil, creatorCodex) == .unlabeled)
expect("Without a readable active login a creator is never foreign",
       creator("account-a", "user-a", nil) == .unlabeled && creator("account-b", nil, nil) == .unlabeled)
expect("A creator user the active login cannot confirm stays unlabeled",
       creator("account-a", "user-a", activeCodex) == .unlabeled && creator(nil, "user-a", creatorCodex) == .unlabeled)
expect("A row and its file combine fail-closed",
       UsageJSON.CodexRollout.combined(.unlabeled, .matching) == .matching
       && UsageJSON.CodexRollout.combined(.matching, .foreign) == .foreign
       && UsageJSON.CodexRollout.combined(.foreign, .matching) == .foreign
       && UsageJSON.CodexRollout.combined(.unlabeled, .unlabeled) == .unlabeled)
let meta = UsageJSON.object(Data(#"{"timestamp":"2026-11-05T09:00:00Z","type":"session_meta","payload":{"id":"s","creator_account_id":"account-a","creator_user_id":"user-a"}}"#.utf8))!
expect("session_meta exposes its creator ids", UsageJSON.codexSessionCreator(meta).map { $0.account == "account-a" && $0.user == "user-a" } == true
       && UsageJSON.codexSessionCreator(UsageJSON.object(Data(rolloutJSON.utf8))!) == nil)
func jwtPart(_ object: [String: Any]) -> String {
    try! JSONSerialization.data(withJSONObject: object).base64EncodedString()
        .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
}
let idToken = ["e30", jwtPart(["sub": "subject-a", "https://api.openai.com/auth": ["chatgpt_user_id": "user-a"]]), "sig"].joined(separator: ".")
let login = UsageJSON.codexAccount(["tokens": ["account_id": "account-a", "id_token": idToken]])
expect("auth.json yields the account, the token subject and the ChatGPT user id",
       login?.account == "account-a" && login?.subject == "subject-a" && login?.creatorUser == "user-a")
for format in ["http", "rpc"] {
    let data = format == "rpc"
        ? ["primary": ["usedPercent": 20, "windowDurationMins": 10080]]
        : ["primary_window": ["used_percent": 20, "limit_window_seconds": 604800]]
    let api = UsageJSON.codex(data, at: now, format: format)
    rolloutDisplay.acceptReading(api, original: nil)
    func fallback(_ seconds: Double) -> UsageReading? {
        UsageService.latestCodexRollout([foreignSpanRollout], activeAccount: activeCodex, since: nil,
                                       now: now.addingTimeInterval(seconds), current: rolloutDisplay.reading)?.reading
    }
    expect("A \(format) balance takes priority through 15 minutes inclusive",
           fallback(900) == nil && rolloutDisplay.remaining(now) == 80 && fallback(901)?.codexRolloutIdentified == false)
}

func codexReading(_ slot: String, used: Double = 20, reset: Date, at date: Date = now, model: String? = nil,
                  minutes: Int = 10080) -> UsageReading {
    var window: [String: Any] = ["used_percent": used, "window_minutes": minutes, "resets_at": reset.timeIntervalSince1970]
    if let model { window["model_id"] = model }
    return UsageJSON.codex([slot: window, "plan_type": "pro"], at: date, format: "local")
}

let weeklyReset = now.addingTimeInterval(day)
func alertBase(_ reading: UsageReading) -> String? {
    guard let window = reading.windows.first else { return nil }
    return UsageWindowObservation.capture(reading, provider: .codex)[window.id]?.alertCycle(provider: .codex, window: window)?.base
}
let primary = codexReading("primary", reset: weeklyReset)
let secondary = codexReading("secondary", used: 70, reset: weeklyReset)
let sharedWeekly = alertBase(primary)
expect("A Codex weekly meter keeps its alert identity after moving from primary to secondary",
       sharedWeekly != nil && sharedWeekly == alertBase(secondary))
expect("Alert storage distinguishes meter scope and duration across cycles",
       sharedWeekly != alertBase(codexReading("primary", reset: weeklyReset, model: "o3"))
       && sharedWeekly != alertBase(codexReading("primary", reset: weeklyReset, minutes: 300))
       && sharedWeekly == alertBase(codexReading("primary", reset: weeklyReset.addingTimeInterval(60))))
let countdown = UsageJSON.codex(["secondary_window": ["used_percent": 70, "limit_window_seconds": week,
                                                       "reset_after_seconds": day + 1]], at: now, format: "http")
expect("Countdown jitter within the same reset minute preserves the alert identity", sharedWeekly == alertBase(countdown))

func thresholdAlerts(_ reading: UsageReading) -> [UsagePace.AlertContext] {
    var state = UsageState(provider: .codex, signedIn: true)
    state.acceptReading(reading, original: nil)
    return state.orderedWindows.compactMap { UsagePace.thresholdAlert(state, $0, threshold: 20, now: now) }
}

let minute = Int(weeklyReset.timeIntervalSince1970 / 60)
let minuteReset = Date(timeIntervalSince1970: Double(minute) * 60)
func estimatedAlert(_ offset: TimeInterval) -> UsagePace.AlertContext? {
    let reading = UsageJSON.codex(["primary_window": ["used_percent": 95, "limit_window_seconds": week,
                                                        "reset_after_seconds": minuteReset.timeIntervalSince(now) + offset]],
                                  at: now, format: "http")
    return thresholdAlerts(reading).first
}
guard let beforeMinute = estimatedAlert(-1), let afterMinute = estimatedAlert(1) else { fatalError("Missing threshold candidates") }
let firedAt = now.timeIntervalSince1970
let migrated = UsagePace.migratedAlerts(["codex|primary|\(minute - 1)|thr": firedAt,
                                       "codex|604800|\(minute)|shared|proj": firedAt])
let movedAlert = thresholdAlerts(codexReading("secondary", used: 95, reset: minuteReset)).first!
expect("Migrated primary follows weekly to secondary, including old canonical and v2 keys",
       movedAlert.wasFired("thr", recorded: migrated) && beforeMinute.wasFired("proj", recorded: migrated)
       && !afterMinute.wasFired("proj", recorded: UsagePace.migratedAlerts(["codex|primary|\(minute)|thr": firedAt]))
       && movedAlert.wasFired("thr", recorded: UsagePace.migratedAlerts(["v2|codex|604800|\(minute)|shared|thr": firedAt])))
let recorded = [beforeMinute.id("thr"): beforeMinute.cycle.reset.timeIntervalSince1970]
expect("Reset dates deduplicate :57/:59 and both inclusive ten-minute boundaries",
       estimatedAlert(-3)!.wasFired("thr", recorded: recorded) && afterMinute.wasFired("thr", recorded: recorded)
       && [-601.0, 599].allSatisfy { estimatedAlert($0)!.wasFired("thr", recorded: recorded) }
       && [-602.0, 600].allSatisfy { !estimatedAlert($0)!.wasFired("thr", recorded: recorded) })

let models = UsageJSON.codex([
    "primary": ["used_percent": 95, "window_minutes": 10080, "resets_at": scopedReset, "model_id": "o3"],
    "secondary": ["used_percent": 95, "window_minutes": 10080, "resets_at": scopedReset, "model_id": "gpt-5"]
], at: now, format: "local")
let modelAlerts = thresholdAlerts(models)
let modelObservations = UsageWindowObservation.capture(models, provider: .codex)
expect("Equal-duration Codex models with identical 5% balances and resets both qualify for distinct alerts",
       modelObservations["primary"]?.meter?.scope == .modelID("o3")
       && modelObservations["secondary"]?.meter?.scope == .modelID("gpt-5")
       && modelAlerts.count == 2 && !modelAlerts[1].wasFired("thr", recorded: [modelAlerts[0].id("thr"): modelAlerts[0].cycle.reset.timeIntervalSince1970]))

let series = QuotaSeries(provider: .codex, profile: QuotaProfileID(rawValue: "test"), plan: "pro",
                         meter: QuotaMeter(scope: .shared, durationSeconds: Int(week)), timeZoneID: "UTC")
let cycle = QuotaCycle(reset: weeklyReset, segmentStart: now)
let reading20 = QuotaObservation(series: series, date: now, used: 20, reset: weeklyReset, source: .api)
let reading70 = QuotaObservation(series: series, date: now, used: 70, reset: weeklyReset, source: .api)
let oldForecast = UsagePace.CachedForecast(
    result: ForecastResult(expectedUsed: 100, exhaustProbability: 1, eta: now.addingTimeInterval(900),
                           readiness: .likely, hitWeeks: 4, effectiveWeeks: 4), calculatedAt: now
)
var entry = UsagePace.Entry(key: UsagePace.ForecastKey(observation: reading20, cycle: cycle))
let inFlight = entry.key
entry.cache(oldForecast, for: inFlight)
entry.update(reading20)
expect("Replaying the same observation retains its forecast", entry.cached != nil)
entry.update(reading70)
expect("A 20% to 70% reading invalidates the cached forecast immediately", entry.cached == nil && entry.key != inFlight)
entry.cache(oldForecast, for: inFlight)
expect("An in-flight ETA for the 20% reading cannot publish against the 70% reading", entry.cached == nil)
let refreshed70 = QuotaObservation(series: series, date: now.addingTimeInterval(60), used: 70, reset: weeklyReset, source: .api)
let previousKey = entry.key
entry.update(refreshed70)
expect("New observation time invalidates even an unchanged counter", entry.key != previousKey)
let newReset = weeklyReset.addingTimeInterval(60)
let resetReading = QuotaObservation(series: series, date: refreshed70.date, used: 70, reset: newReset, source: .api)
let resetCycle = QuotaCycle(reset: newReset, segmentStart: resetReading.date)
var resetEntry = UsagePace.Entry(key: UsagePace.ForecastKey(observation: resetReading, cycle: resetCycle))
resetEntry.cache(oldForecast, for: entry.key)
expect("A reset change rejects a result from the previous cycle", resetEntry.cached == nil)

// The card keeps the previous result between readings; alerts only ever see the current reading's result.
do {
    let quickResult = ForecastResult(expectedUsed: 25, exhaustProbability: nil, eta: nil, etaRange: nil, readiness: .quick,
                                     hitWeeks: 0, effectiveWeeks: 0, learningDays: 1)
    let first = QuotaObservation(series: series, date: now, used: 20, reset: weeklyReset, source: .api)
    let second = QuotaObservation(series: series, date: now.addingTimeInterval(300), used: 21, reset: weeklyReset, source: .api)
    var carry = UsagePace.Entry.advanced(nil, with: first)
    expect("First launch has nothing to show until a result exists", carry.displayed == nil)
    carry.cache(.init(result: quickResult, calculatedAt: now), for: carry.key)
    carry = UsagePace.Entry.advanced(carry, with: second)
    expect("A new reading keeps showing the previous result instead of blanking",
           carry.displayed?.result == quickResult && carry.cached == nil)
    expect("Alerts are not driven by the carried-over result", carry.cached == nil)
    let fresh = ForecastResult(expectedUsed: 30, exhaustProbability: nil, eta: nil, etaRange: nil, readiness: .quick,
                               hitWeeks: 0, effectiveWeeks: 0, learningDays: 1, quickWarning: true)
    carry.cache(.init(result: fresh, calculatedAt: now.addingTimeInterval(301)), for: carry.key)
    expect("The recompute for the new reading replaces the carried result",
           carry.displayed?.result == fresh && carry.cached?.result == fresh && carry.carried == nil)

    let third = QuotaObservation(series: series, date: now.addingTimeInterval(600), used: 22, reset: weeklyReset, source: .api)
    let stale = UsagePace.Entry.advanced(carry, with: third)
    let late = QuotaObservation(series: series, date: now.addingTimeInterval(900), used: 23, reset: weeklyReset, source: .api)
    var inFlightCarry = UsagePace.Entry.advanced(stale, with: late)
    inFlightCarry.cache(.init(result: quickResult, calculatedAt: now.addingTimeInterval(901)), for: stale.key)
    expect("A result finishing after a newer reading is carried for display, never cached for alerts",
           inFlightCarry.displayed?.result == quickResult && inFlightCarry.cached == nil)

    let otherPlan = QuotaSeries(provider: .codex, profile: QuotaProfileID(rawValue: "test"), plan: "plus",
                                meter: series.meter, timeZoneID: "UTC")
    let otherAccount = QuotaSeries(provider: .codex, profile: QuotaProfileID(rawValue: "other"), plan: "pro",
                                   meter: series.meter, timeZoneID: "UTC")
    for changed in [otherPlan, otherAccount] {
        let moved = QuotaObservation(series: changed, date: now.addingTimeInterval(600), used: 21, reset: weeklyReset, source: .api)
        expect("A series change clears the carried result", UsagePace.Entry.advanced(carry, with: moved).displayed == nil)
    }
    let nextReset = QuotaObservation(series: series, date: now.addingTimeInterval(600), used: 0,
                                     reset: weeklyReset.addingTimeInterval(week), source: .api)
    expect("A new resets_at clears the pre-reset result", UsagePace.Entry.advanced(carry, with: nextReset).displayed == nil)
    let dropped = QuotaObservation(series: series, date: now.addingTimeInterval(600), used: 2, reset: weeklyReset, source: .api)
    expect("A counter that drops at a reset clears the pre-reset result", UsagePace.Entry.advanced(carry, with: dropped).displayed == nil)
}

var exhaustedOpus = opus
let opusObservedAt = now.addingTimeInterval(-4 * hour)
exhaustedOpus["percent"] = 100
exhaustedOpus["observed_at"] = opusObservedAt.timeIntervalSince1970
let api = UsageJSON.claude(["limits": [exhaustedOpus]], at: now.addingTimeInterval(-60))
let local = UsageJSON.claude(["five_hour": ["used_percentage": 10, "resets_at": now.addingTimeInterval(hour).timeIntervalSince1970]],
                            at: now, local: true)
var claude = UsageState(provider: .claude)
claude.acceptReading(api, original: nil)
let merged = UsageService.mergingClaudeLocal(local, previous: api)
claude.acceptReading(merged, original: local)
let cache = UsageService.Cache(directories: [:], readings: ["claude": merged], cooldowns: [:], failures: [:],
                               observations: ["claude": claude.windowObservations])
let cacheURL = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("usage-cache.json")
func reopenClaudeCache(_ data: Data) throws -> UsageState {
    try data.write(to: cacheURL)
    let reopened = try JSONDecoder().decode(UsageService.Cache.self, from: Data(contentsOf: cacheURL))
    var state = UsageState(provider: .claude, signedIn: true)
    reopened.restoreReading(into: &state, now: now)
    return state
}
let cacheData = try JSONEncoder().encode(cache)
let relaunched = try reopenClaudeCache(cacheData)
guard let retainedOpus = relaunched.orderedWindows.last else { fatalError("Missing retained quota") }
expect("Relaunch preserves the retained quota's observation and suppresses the stale exhausted line",
       retainedOpus.used == 100 && UsagePace.shared.staleReadingDate(relaunched, retainedOpus, now: now) == opusObservedAt
       && UsagePace.shared.line(relaunched, retainedOpus, now: now) == nil)
expect("The shared status-line meter stays fresh alongside the retained quota",
       relaunched.orderedWindows.first.map { UsagePace.shared.staleReadingDate(relaunched, $0, now: now) == nil } == true)
var oldCache = cache
oldCache.observations = nil
let oldState = try reopenClaudeCache(JSONEncoder().encode(oldCache))
expect("Old cache with a one-minute-old API date keeps the four-hour-old 100% Opus quota stale",
       oldState.reading?.apiDate == now.addingTimeInterval(-60)
       && UsagePace.shared.staleReadingDate(oldState, retainedOpus, now: now) == .distantPast
       && UsagePace.shared.line(oldState, retainedOpus, now: now) == nil)

func corruptOpusDate(_ value: Any) throws -> Data {
    var json = UsageJSON.object(cacheData)!
    var observations = json["observations"] as! [String: [String: [String: Any]]]
    observations["claude"]?[retainedOpus.id]?["observedAt"] = value
    json["observations"] = observations
    return try JSONSerialization.data(withJSONObject: json)
}
let oldOpus = try reopenClaudeCache(corruptOpusDate(-1e30))
let futureOpus = try reopenClaudeCache(corruptOpusDate(now.addingTimeInterval(4 * hour).timeIntervalSinceReferenceDate))
let absurdFutureOpus = try reopenClaudeCache(corruptOpusDate(1e30))
let nanOpus = try? reopenClaudeCache(corruptOpusDate("NaN"))
expect("Absurd observedAt values are rejected or treated as unknown after reopening the cache",
       nanOpus == nil && [oldOpus, futureOpus, absurdFutureOpus].allSatisfy {
           UsagePace.shared.staleReadingDate($0, retainedOpus, now: now) == .distantPast
           && UsagePace.shared.line($0, retainedOpus, now: now) == nil
       })
expect("Age and countdown conversions reject NaN and overflowing seconds without trapping",
       [Double.nan, 1e30, -1e30, Double(Int.max), .infinity].allSatisfy {
           UsagePaceProjection.wholeSeconds($0) == nil && UsagePaceProjection.formatted($0) == "—"
       } && UsagePaceProjection.wholeSeconds(59.9) == 59)

appLanguageOverride = "es"
let importedInSpanish = codexReading("primary", reset: weeklyReset)
appLanguageOverride = "en"
guard let fallbackWindow = importedInSpanish.windows.first else { fatalError("Missing imported quota") }
expect("Quota parsing stores the same title key in both languages",
       fallbackWindow.title == primary.windows.first?.title && fallbackWindow.localizedTitle == "Weekly")
appLanguageOverride = "es"
expect("Quota presentation applies the current language to an existing reading",
       fallbackWindow.localizedTitle == "Semanal" && retainedOpus.localizedTitle == "Semanal · Opus")
appLanguageOverride = nil

let legacyURL = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("usage-history.json")
let recentDate = now.addingTimeInterval(-hour).timeIntervalSince1970
let oldDate = now.addingTimeInterval(-13 * hour).timeIntervalSince1970
let legacyRows = ["codex|primary": [[oldDate, 5], [recentDate, 10]], "codex|secondary": [[oldDate, 1]]]
try JSONEncoder().encode(legacyRows).write(to: legacyURL)
var legacy = UsageLegacyHistory(url: legacyURL, now: now)
var codex = UsageState(provider: .codex)
codex.acceptReading(primary, original: nil)
legacy.ingest(codex, now: now)
legacy.ingest(codex, now: now)
legacy.save(now: now, force: true)
let rollbackRows = try JSONDecoder().decode([String: [[Double]]].self, from: Data(contentsOf: legacyURL))
expect("Rollback history keeps recent rows and new readings in the original format, with a 12-hour expiry",
       rollbackRows == ["codex|primary": [[recentDate, 10], [now.timeIntervalSince1970, 20]]])

// Cold-start lines: calculating only during the warm-up, neutral text for holds, and the quick estimate's detail.
do {
    let saved = appLanguageOverride
    appLanguageOverride = "en"
    defer { appLanguageOverride = saved }
    let window = quota("weekly", used: 10, duration: 604_800, elapsed: 3_600, minutes: 10_080)
    func result(_ readiness: ForecastReadiness, expected: Double? = nil, days: Int = 0, warning: Bool = false,
                hold: ForecastHold = .none) -> ForecastResult {
        ForecastResult(expectedUsed: expected, exhaustProbability: nil, eta: nil, etaRange: nil, readiness: readiness,
                       hitWeeks: 0, effectiveWeeks: 0, learningDays: days, quickWarning: warning, hold: hold)
    }
    func text(_ value: ForecastResult?, short: Bool = false) -> String? { UsagePace.coldLine(value, window: window, short: short)?.text }
    expect("Only the warm-up says calculating", text(result(.learning, hold: .warmingUp)) == "Calculating… a few minutes")
    expect("A state that never warms up has neutral text",
           text(result(.learning)) == "No estimate yet" && text(nil) == "No estimate yet")
    expect("Cap holds name the limiting quota",
           text(result(.learning, hold: .capLimited)) == "Limited by the 5-hour quota"
           && text(result(.learning, hold: .capLimited), short: true) == "Limited by the weekly quota")
    expect("Exhausted reads as used up", text(result(.exhausted, expected: 100)) == "Quota used up")
    let quick = UsagePace.coldLine(result(.quick, expected: 23.9, days: 3), window: window, short: false)
    expect("Quick estimate shows its number and the learning day",
           quick?.text == "Quick estimate · ~25% used at reset" && quick?.warn == false
           && quick?.detail == "Still learning your pattern (day 3 of 14) · may change")
    expect("From day 14 the detail says it is still refining",
           UsagePace.coldLine(result(.quick, expected: 30, days: 14), window: window, short: false)?.detail == "Still refining · may change")
    let high = UsagePace.coldLine(result(.quick, expected: 96, days: 1), window: window, short: false)
    expect("A quick number of 90% or more without the warning is not shown as a number",
           high?.text == "High use · may run out before reset" && high?.warn == false)
    let warned = UsagePace.coldLine(result(.quick, expected: 100, days: 1, warning: true), window: window, short: false)
    expect("The near-certain quick warning has no time", warned?.text == "You may hit the limit before reset" && warned?.warn == true)
    expect("Learned readiness is not a cold line", UsagePace.coldLine(result(.normal, expected: 40), window: window, short: false) == nil)
}

print("\(passed) PASS, \(failed) FAIL")
exit(failed == 0 ? 0 : 1)

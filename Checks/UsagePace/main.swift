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
{"timestamp":1750000000,"type":"event_msg","payload":{"type":"token_count","rate_limits":{
"account_id":"account-b","user_id":"subject-b","primary":{"used_percent":95,"window_minutes":10080,"resets_at":1750100000}}}}
"""
if let event = UsageJSON.codexRollout(Data(rolloutJSON.utf8)) {
    expect("A 5%-remaining rollout from another account is ineligible for the display balance",
           !UsageService.canAcceptRollout(account: event.account, subject: event.subject, activeAccount: activeCodex))
} else {
    expect("The conflicting rollout fixture parses", false)
}
expect("Only matching explicit identity or a fully unlabeled rollout can reach acceptance",
       UsageService.canAcceptRollout(account: "account-a", subject: "subject-a", activeAccount: activeCodex)
       && UsageService.canAcceptRollout(account: nil, subject: nil, activeAccount: activeCodex)
       && !UsageService.canAcceptRollout(account: "account-a", subject: "subject-b", activeAccount: activeCodex)
       && !UsageService.canAcceptRollout(account: nil, subject: "subject-b", activeAccount: activeCodex))

func codexReading(_ slot: String, used: Double = 20, reset: Date, at date: Date = now, model: String? = nil,
                  minutes: Int = 10080) -> UsageReading {
    var window: [String: Any] = ["used_percent": used, "window_minutes": minutes, "resets_at": reset.timeIntervalSince1970]
    if let model { window["model_id"] = model }
    return UsageJSON.codex([slot: window, "plan_type": "pro"], at: date, format: "local")
}

let weeklyReset = now.addingTimeInterval(day)
func alertBase(_ reading: UsageReading) -> String? {
    UsageWindowObservation.capture(reading, provider: .codex).values.first?.alertBase(provider: .codex)
}
let primary = codexReading("primary", reset: weeklyReset)
let secondary = codexReading("secondary", used: 70, reset: weeklyReset)
let sharedWeekly = alertBase(primary)
expect("A Codex weekly meter keeps its alert identity after moving from primary to secondary",
       sharedWeekly != nil && sharedWeekly == alertBase(secondary))
expect("Alert identity distinguishes meter scope, duration and cycle",
       sharedWeekly != alertBase(codexReading("primary", reset: weeklyReset, model: "o3"))
       && sharedWeekly != alertBase(codexReading("primary", reset: weeklyReset, minutes: 300))
       && sharedWeekly != alertBase(codexReading("primary", reset: weeklyReset.addingTimeInterval(60))))
let countdown = UsageJSON.codex(["secondary_window": ["used_percent": 70, "limit_window_seconds": week,
                                                       "reset_after_seconds": day + 1]], at: now, format: "http")
expect("Countdown jitter within the same reset minute preserves the alert identity", sharedWeekly == alertBase(countdown))

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

var exhaustedOpus = opus
let opusObservedAt = now.addingTimeInterval(-4 * hour)
exhaustedOpus["percent"] = 100
exhaustedOpus["observed_at"] = opusObservedAt.timeIntervalSince1970
let api = UsageJSON.claude(["limits": [exhaustedOpus]], at: now.addingTimeInterval(-hour))
let local = UsageJSON.claude(["five_hour": ["used_percentage": 10, "resets_at": now.addingTimeInterval(hour).timeIntervalSince1970]],
                            at: now, local: true)
var claude = UsageState(provider: .claude)
claude.acceptReading(api, original: nil)
let merged = UsageService.mergingClaudeLocal(local, previous: api)
claude.acceptReading(merged, original: local)
let cache = UsageService.Cache(directories: [:], readings: ["claude": merged], cooldowns: [:], failures: [:],
                               observations: ["claude": claude.windowObservations])
let reopened = try JSONDecoder().decode(UsageService.Cache.self, from: JSONEncoder().encode(cache))
var relaunched = UsageState(provider: .claude, reading: reopened.readings["claude"],
                            windowObservations: reopened.observations?["claude"] ?? [:])
guard let retainedOpus = relaunched.orderedWindows.last else { fatalError("Missing retained quota") }
expect("Relaunch preserves the retained quota's observation and suppresses the stale exhausted line",
       retainedOpus.used == 100 && UsagePace.shared.staleReadingDate(relaunched, retainedOpus, now: now) == opusObservedAt
       && UsagePace.shared.line(relaunched, retainedOpus, now: now) == nil)
expect("The shared status-line meter stays fresh alongside the retained quota",
       relaunched.orderedWindows.first.map { UsagePace.shared.staleReadingDate(relaunched, $0, now: now) == nil } == true)
relaunched.windowObservations = [:]
expect("A pre-upgrade cache uses the last API date for a retained Claude scoped quota",
       UsagePace.shared.staleReadingDate(relaunched, retainedOpus, now: now) == api.apiDate
       && UsagePace.shared.line(relaunched, retainedOpus, now: now) == nil)

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

print("\(passed) PASS, \(failed) FAIL")
exit(failed == 0 ? 0 : 1)

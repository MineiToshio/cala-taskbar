import Foundation

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

print("\(passed) PASS, \(failed) FAIL")
exit(failed == 0 ? 0 : 1)

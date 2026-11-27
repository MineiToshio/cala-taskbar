import Foundation

/// Compressed rollouts, session_meta identity, `resets_at` jitter, and unlabeled archives that mix several accounts.
///
/// A real 10-week, one-account archive once read as several accounts: its weekly window restarted early 18 times
/// (to ~0%, resetting a full window later) and concurrent sessions wrote the old snapshot for seconds after a reset.
/// Rollouts are now identified by their `session_meta` creator, and only cycles that keep interleaving reveal
/// several accounts in unlabeled history.
func checkArchiveAccounts() throws {
    try checkCompressedRollouts()
    try checkSessionMetaIdentity()
    checkBlipsAndRestarts()
    checkResetJitter()
    try checkMixedAccounts()
    try checkPlusGlobalReset()
    try checkImportRetries()
}

/// A zstd frame of raw blocks, enough to drive the backfill's compressed path without an encoder.
func zstdRaw(_ data: Data, blockSize: Int = 100_000) -> Data {
    var frame = Data([0x28, 0xB5, 0x2F, 0xFD, 0x00, 0x38])  // no content size, 128 KiB window, no checksum
    var offset = 0
    repeat {
        let size = min(blockSize, data.count - offset)
        let last = offset + size == data.count
        let header = (last ? 1 : 0) | (size << 3)
        frame.append(contentsOf: [UInt8(header & 0xFF), UInt8((header >> 8) & 0xFF), UInt8(header >> 16)])
        frame.append(data.subdata(in: offset..<offset + size))
        offset += size
    } while offset < data.count
    return frame
}

private func checkCompressedRollouts() throws {
    let sessions = root.appendingPathComponent("zst-sessions")
    let older = sessions.appendingPathComponent("2026/11/05")
    let recent = sessions.appendingPathComponent("2026/11/06")
    try FileManager.default.createDirectory(at: older, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: recent, withIntermediateDirectories: true)
    var plain = Data()
    appendLine(try rollout(date(10), 5), to: &plain)
    try plain.write(to: recent.appendingPathComponent("rollout-plain.jsonl"))
    var lines = Data()
    appendLine(try rollout(date(2), 2), to: &lines)
    lines.append(try filler(400))
    appendLine(try rollout(date(4), 3), to: &lines)
    let compressed = zstdRaw(lines)
    try compressed.write(to: older.appendingPathComponent("rollout-old.jsonl.zst"))
    try zstdRaw(lines).prefix(compressed.count - 50).write(to: recent.appendingPathComponent("rollout-cut.jsonl.zst"))
    try Data("not a rollout".utf8).write(to: recent.appendingPathComponent("notes.zst"))

    let pass = scan(UsageCodexBackfill(sessionsRoot: sessions, now: now, calendar: calendarUTC(), account: nil))
    check(pass.files == 3 && pass.compressedFiles == 2, "compressed rollouts count as rollout files; other .zst files are ignored")
    check(pass.incompleteFiles == 1 && pass.incompleteDays == 1 && pass.truncated,
          "a compressed rollout that ends mid-frame is incomplete")
    check(pass.candidates.map(\.reading.date).sorted() == [date(2), date(4), date(10)],
          "a whole .zst rollout is imported; the cut one withholds its unlabeled rows")
    check(pass.replayCandidates.count == 4 && pass.parsedLines == 4,
          "the byte pre-filter runs on decoded lines (both events of the whole file, the first of the cut one, the plain one)")
    check(pass.bytesRead > lines.count + plain.count && pass.compressedBytesRead > lines.count,
          "decoded bytes count toward the scan budget, compressed bytes are reported apart")

    let capped = scan(UsageCodexBackfill(sessionsRoot: sessions, now: now, calendar: calendarUTC(), account: nil,
                                         limits: .init(maxDecodedBytes: 1_000)))
    check(capped.incompleteFiles == 2 && capped.candidates.map(\.reading.date) == [date(10)],
          "the per-file decoded cap leaves a compressed rollout incomplete instead of reading it whole")
}

/// The `session_meta` record that opens a rollout, as Codex writes it (its events carry no identity).
private func sessionMeta(_ time: Date, account: String?, user: String?) throws -> Data {
    let stamp = ISO8601DateFormatter().string(from: time)
    var payload: [String: Any] = ["id": "session", "timestamp": stamp, "cwd": "/tmp", "originator": "codex_cli_rs",
                                  "base_instructions": ["text": String(repeating: "x", count: 2_000)]]
    payload["creator_account_id"] = account
    payload["creator_user_id"] = user
    return try JSONSerialization.data(withJSONObject: ["timestamp": stamp, "type": "session_meta", "payload": payload])
}

private func checkSessionMetaIdentity() throws {
    let sessions = root.appendingPathComponent("meta-sessions")
    let folder = sessions.appendingPathComponent("2026/11/05")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    func file(_ name: String, meta: (String?, String?)?, rows: [(Double, String?)], compressed: Bool = false) throws {
        var data = Data()
        if let meta, let first = rows.first { appendLine(try sessionMeta(date(first.0 - 1), account: meta.0, user: meta.1), to: &data) }
        for (minute, account) in rows { appendLine(try rollout(date(minute), minute / 10, account: account), to: &data) }
        if compressed { try zstdRaw(data).write(to: folder.appendingPathComponent("rollout-\(name).jsonl.zst")) }
        else { try data.write(to: folder.appendingPathComponent("rollout-\(name).jsonl")) }
    }
    try file("own", meta: ("acct-1", "user-1"), rows: [(10, nil), (20, nil)])
    try file("own-zst", meta: ("acct-1", "user-1"), rows: [(60, nil)], compressed: true)
    try file("other", meta: ("acct-2", "user-2"), rows: [(50, nil)])
    try file("both", meta: ("acct-1", "user-1"), rows: [(30, nil), (40, "acct-2")])
    try file("older", meta: nil, rows: [(200, nil)])
    let active = QuotaAccount(account: "acct-1", subject: "token-subject", creatorUser: "user-1")
    let pass = scan(UsageCodexBackfill(sessionsRoot: sessions, now: now, calendar: calendarUTC(), account: active))
    let identified = pass.candidates.filter(\.identified).map(\.reading.date).sorted()
    check(identified == [date(10), date(20), date(60)],
          "rows of plain and .zst rollouts whose session_meta names the active account are identified")
    check(pass.foreignSeen && !pass.candidates.contains { [date(50)].contains($0.reading.date) },
          "rows of a rollout whose session_meta names another account are foreign and dropped")
    check(!pass.candidates.contains { [date(30), date(40)].contains($0.reading.date) }
          && !pass.replayCandidates.contains { [date(30), date(40)].contains($0.reading.date) },
          "a row that contradicts its session_meta creator fails closed: none of the file's rows is kept")
    check(pass.candidates.filter { !$0.identified }.map(\.reading.date) == [date(200)]
          && pass.candidates.allSatisfy { $0.identified || $0.provenance == .unlabeledStrict },
          "a rollout without session_meta identity stays unlabeled, and strict once a foreign one exists")
    let decision = UsageCodexBackfill.attribute(pass.candidates, key: key, anchors: [], switchedAt: nil, now: now)
    check(decision.observations.filter { $0.attribution == .verifiedArchive }.map(\.date).sorted() == identified
          && !decision.observations.contains { $0.attribution != .verifiedArchive },
          "session_meta identified rows are verified archive history; unlabeled ones need a live match")

    // A login whose ChatGPT user is unknown cannot confirm a user-scoped creator: the rows stay unlabeled.
    let unknownUser = scan(UsageCodexBackfill(sessionsRoot: sessions, now: now, calendar: calendarUTC(),
                                              account: QuotaAccount(account: "acct-1", subject: "token-subject")))
    check(unknownUser.candidates.allSatisfy { !$0.identified }, "an unconfirmed creator user is never trusted")
    // No readable login (auth.json mid-rewrite): creator-stamped files are not taken for another account, nothing is
    // dropped, and the planner does not scan or mark the import scanned, so it retries once the login is readable.
    let noLogin = scan(UsageCodexBackfill(sessionsRoot: sessions, now: now, calendar: calendarUTC(), account: nil))
    check(!noLogin.replayCandidates.contains(where: \.identified)
          && Set(noLogin.replayCandidates.map(\.reading.date)) == Set([10, 20, 30, 50, 60, 200].map { date(Double($0)) }),
          "without a login, creator-stamped rows stay unlabeled and only rows that name another account themselves drop")
    let planner = UsageCodexImportPlanner()
    let waits: Bool
    if case .idle = planner.step(for: key, account: nil) { waits = true } else { waits = false }
    let retries: Bool
    if case .scan = planner.step(for: key, account: active) { retries = true } else { retries = false }
    check(waits && retries, "with no login no scan starts and no import completes; a later reading with the login scans")
    let later = scan(UsageCodexBackfill(sessionsRoot: sessions, now: now, calendar: calendarUTC(), account: active))
    check(later.candidates.filter(\.identified).map(\.reading.date).sorted() == identified,
          "the later pass with the login keeps the identified rows")
    let otherUser = scan(UsageCodexBackfill(sessionsRoot: sessions, now: now, calendar: calendarUTC(),
                                            account: QuotaAccount(account: "acct-1", subject: nil, creatorUser: "user-9")))
    check(otherUser.candidates.allSatisfy { !$0.identified } && !otherUser.candidates.contains { $0.reading.date == date(10) },
          "another user of the same workspace account is foreign")
}

/// Stale snapshots right after a reset and fresh restarts of one account's window are not other accounts.
private func checkBlipsAndRestarts() {
    let base = now.addingTimeInterval(-3 * 86_400)
    func at(_ seconds: Double, _ used: Double, _ anchor: Date) -> QuotaObservation {
        observation(base.addingTimeInterval(seconds), used, reset: anchor, source: .rollout, attribution: .provisional)
    }
    let old = base.addingTimeInterval(5 * 86_400)
    let renewed = base.addingTimeInterval(3_600 + 7 * 86_400)
    // A concurrent session that started before the reset writes the old snapshot for a few seconds.
    let blip = UsageCodexBackfill.AccountTimeline([at(0, 30, old), at(3_600, 0, renewed), at(3_610, 31, old),
                                                   at(3_620, 0, renewed), at(3_630, 31, old), at(3_640, 1, renewed),
                                                   at(7_200, 3, renewed)])
    check(blip.returns == 0 && blip.earlyStarts == 0 && blip.restarts == 1 && !blip.mixed,
          "a stale-snapshot blip pair right after a reset is not a return")
    let resumed = UsageCodexBackfill.AccountTimeline([at(0, 30, old), at(3_600, 0, renewed), at(3_600 + 360, 31, old),
                                                      at(7_200, 3, renewed)])
    check(resumed.returns == 1 && resumed.mixed, "an old cycle still written five minutes after the new one is a return")
    // Early restarts to ~0% whose reset is the reading plus the window are the same account's window restarting.
    let restarts = UsageCodexBackfill.AccountTimeline([at(0, 30, old), at(3_600, 0, renewed), at(4_000, 2, renewed),
                                                       at(90_000, 4, base.addingTimeInterval(90_000 + 7 * 86_400 - 300)),
                                                       at(180_000, 1, base.addingTimeInterval(180_000 + 7 * 86_400 + 500))])
    check(restarts.restarts == 3 && restarts.earlyStarts == 0 && !restarts.mixed,
          "early restarts to ~0% with resets_at about now plus the window are not counted")
    let used = UsageCodexBackfill.AccountTimeline([at(0, 30, old), at(3_600, 20, renewed),
                                                   at(90_000, 0, base.addingTimeInterval(90_000 + 7 * 86_400 - 1_200)),
                                                   at(90_100, 1, base.addingTimeInterval(90_000 + 7 * 86_400 - 1_200))])
    check(used.restarts == 0 && used.earlyStarts == 2 && used.mixed,
          "an early start already used, or whose reset is not now plus the window, still counts")
}

private func checkResetJitter() {
    // Codex's resets_at drifts by seconds between readings of one window; the cycle and its debits stay whole.
    let history = store("reset-jitter")
    var jittered: [QuotaObservation] = []
    for step in 0...10 {
        let drift: TimeInterval = step % 2 == 0 ? 0 : 3 + Double(step)
        let used: Double = 10 + Double(step)
        jittered.append(observation(date(Double(step) * 5), used, reset: reset.addingTimeInterval(drift),
                                    source: .rollout, attribution: .provisional))
    }
    history.replaceImport(jittered, for: key, complete: true, now: now)
    let rows = buckets(history)
    check(rows.reduce(0) { $0 + $1.deltaHundredths } == 1_000 && Set(rows.map(\.cycle)).count == 1,
          "jittered resets of one window form one cycle and keep every debit")
    let distinct = store("reset-distinct")
    distinct.replaceImport([observation(date(0), 40, source: .rollout, attribution: .provisional),
                            observation(date(5), 2, reset: reset.addingTimeInterval(3_600), source: .rollout, attribution: .provisional),
                            observation(date(10), 4, reset: reset.addingTimeInterval(3_600), source: .rollout, attribution: .provisional)],
                           for: key, complete: true, now: now)
    check(Set(buckets(distinct).map(\.cycle.reset)).count == 2, "resets an hour apart stay separate cycles")
}

/// Weekly readings every five minutes for 28 days. `accounts` take turns; each burns 100 pp in `burn` hours and the
/// next one starts at once. With one account, a cycle starts only when the previous one resets.
private func weeklyArchive(accounts: Int, burn: Double, until end: Date) -> (lines: [Date: Data], live: QuotaObservation) {
    let start = end.addingTimeInterval(-28 * 86_400)
    var resets = [Date?](repeating: nil, count: accounts)
    var account = 0
    var cycleStart = start
    var lines: [Date: Data] = [:]
    var jitter = 0
    var time = start
    var last: (Date, Double, Date)?
    let fresh = end.addingTimeInterval(-6 * 3_600)
    while time < end {
        if accounts > 1 && time >= fresh && account < accounts {
            // The live account: a fresh window opened six hours ago, now at 7%.
            account = accounts
            resets.append(time.addingTimeInterval(7 * 86_400))
            cycleStart = time
        }
        if resets[account] == nil || resets[account]! <= time { resets[account] = time.addingTimeInterval(7 * 86_400); cycleStart = time }
        let rate = account == accounts ? 7 / 6.0 : 100 / burn
        let used = min(100, (time.timeIntervalSince(cycleStart) / 3_600 * rate).rounded())
        jitter = (jitter + 7) % 40
        let anchor = resets[account]!.addingTimeInterval(Double(jitter))
        let day = calendarUTC().startOfDay(for: time)
        appendLine(try! rollout(time, used, anchor: anchor), to: &lines[day, default: Data()])
        last = (time, used, resets[account]!)
        if used >= 100 && accounts > 1 && account < accounts {
            account = (account + 1) % accounts
            // Wait for this account's window if it has not reset yet (with enough accounts it always has).
            if let next = resets[account], next > time { time = min(next, fresh) }
        }
        time = time.addingTimeInterval(300)
    }
    let live = observation(end, accounts > 1 ? 7 : last!.1, reset: last!.2, source: .api, attribution: .live)
    return (lines, live)
}

private func write(_ lines: [Date: Data], to sessions: URL) throws {
    let format = DateFormatter()
    format.calendar = calendarUTC()
    format.timeZone = TimeZone(identifier: utc)
    format.dateFormat = "yyyy/MM/dd"
    for (day, data) in lines {
        let folder = sessions.appendingPathComponent(format.string(from: day))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try zstdRaw(data).write(to: folder.appendingPathComponent("rollout-\(Int(day.timeIntervalSince1970)).jsonl.zst"))
    }
}

/// Every unlabeled row as the old single-account rule kept it.
private func captured(_ pass: UsageCodexBackfill.Pass) -> [QuotaObservation] {
    pass.candidates.flatMap {
        UsageQuotaCapture.observations($0.reading, provider: .codex, profile: profile, timeZoneID: utc, source: .rollout,
                                       attribution: .provisional, now: now)
    }
}

/// Two accounts used alternately, three hours each, for 28 days, readings every five minutes, each on its own weekly
/// window (60 active hours to exhaust it). The merged history keeps going back to a cycle the other one replaced.
private func interleavedArchive(until end: Date) -> (lines: [Date: Data], live: QuotaObservation) {
    let start = end.addingTimeInterval(-28 * 86_400)
    var resets: [Date?] = [nil, nil]
    var used = [0.0, 0.0]
    var lines: [Date: Data] = [:]
    var time = start
    var last = (0.0, start)
    var jitter = 0
    while time < end {
        let account = Int(time.timeIntervalSince(start) / 10_800) % 2
        if resets[account] == nil || resets[account]! <= time {
            resets[account] = time.addingTimeInterval(7 * 86_400)
            used[account] = 0
        }
        used[account] = min(100, used[account] + 100 / 720)
        jitter = (jitter + 7) % 40
        last = (used[account].rounded(), resets[account]!)
        appendLine(try! rollout(time, last.0, anchor: last.1.addingTimeInterval(Double(jitter))),
                   to: &lines[calendarUTC().startOfDay(for: time), default: Data()])
        time = time.addingTimeInterval(300)
    }
    return (lines, observation(end, last.0, reset: last.1, source: .api, attribution: .live))
}

private func checkMixedAccounts() throws {
    var limits = UsageCodexBackfill.Limits()
    limits.elapsed = 30
    // Four accounts strictly in turn, each from a fresh window and never back to an open one: without identity this
    // is what one account whose window keeps restarting looks like, so it is not taken for several accounts.
    let rotation = weeklyArchive(accounts: 4, burn: 40, until: now)
    let rotationRoot = root.appendingPathComponent("rotated-accounts")
    try write(rotation.lines, to: rotationRoot)
    let rotated = scan(UsageCodexBackfill(sessionsRoot: rotationRoot, now: now, calendar: calendarUTC(), account: nil, limits: limits))
    let restarts = UsageCodexBackfill.accountTimeline(rotated.candidates, key: key, now: now)
    check(!restarts.mixed && restarts.restarts >= 10 && restarts.earlyStarts == 0 && restarts.returns == 0,
          "cycles that each open a fresh window are restarts, not evidence of another account")

    // Two accounts whose cycles keep interleaving.
    let mixed = interleavedArchive(until: now)
    let mixedRoot = root.appendingPathComponent("mixed-accounts")
    try write(mixed.lines, to: mixedRoot)
    let pass = scan(UsageCodexBackfill(sessionsRoot: mixedRoot, now: now, calendar: calendarUTC(), account: nil, limits: limits))
    check(!pass.foreignSeen && pass.incompleteFiles == 0 && pass.candidates.count > 7_000
          && pass.candidates.allSatisfy { $0.provenance == .unlabeledSingleAccount },
          "rollouts without identity look like a one-account home to the file scan")
    let timeline = UsageCodexBackfill.accountTimeline(pass.candidates, key: key, now: now)
    check(timeline.mixed && timeline.returns >= 100, "two accounts whose weekly cycles keep interleaving are still mixed")

    let all = UsageCodexBackfill.attribute(pass.candidates, key: key, anchors: [], switchedAt: nil, now: now)
    check(all.observations.isEmpty && all.mixed && all.awaitsLiveReading,
          "without a live anchor nothing of a multi-account archive is kept, and the import waits for a live reading")
    check(all.timeline.earlyStarts == timeline.earlyStarts && all.timeline.returns == timeline.returns,
          "the decision reports the same account judgement the replay uses")
    let decision = UsageCodexBackfill.attribute(pass.candidates, key: key, anchors: [mixed.live], switchedAt: nil, now: now)
    check(decision.mixed && !decision.awaitsLiveReading && !decision.observations.isEmpty,
          "a later pass with a live reading keeps the live cycle and lets the import complete")
    let anchored = UsageCodexBackfill.attributed(pass.candidates, key: key, anchors: [mixed.live], switchedAt: nil, now: now)
    check(anchored == decision.observations, "attributed is the observations of the decision")
    check(!anchored.isEmpty && anchored.allSatisfy {
        abs($0.reset.timeIntervalSince(mixed.live.reset)) <= QuotaObservation.explicitResetJitter && $0.attribution == .provisional
    }, "with a live anchor only the live cycle survives, including its jittered resets")

    // One account whose cycles follow each other keeps its whole history.
    let single = weeklyArchive(accounts: 1, burn: 120, until: now)
    let singleRoot = root.appendingPathComponent("single-account")
    try write(single.lines, to: singleRoot)
    let singlePass = scan(UsageCodexBackfill(sessionsRoot: singleRoot, now: now, calendar: calendarUTC(), account: nil, limits: limits))
    let singleTimeline = UsageCodexBackfill.accountTimeline(singlePass.candidates, key: key, now: now)
    check(!singleTimeline.mixed && singleTimeline.earlyStarts == 0 && singleTimeline.returns == 0,
          "consecutive cycles of one account, with jittered resets, are one account")
    let kept = UsageCodexBackfill.attributed(singlePass.candidates, key: key, anchors: [], switchedAt: nil, now: now)
    check(kept.count == captured(singlePass).count && Set(kept.map(\.reset)).count > 3,
          "a one-account archive keeps all its cycles as provisional history")

    // A fresh restart is the same account; one early start seen late is tolerated; returning to an older window is not.
    let base = now.addingTimeInterval(-3 * 86_400)
    func unlabeled(_ time: Date, _ used: Double, _ anchor: Date) -> QuotaObservation {
        observation(time, used, reset: anchor, source: .rollout, attribution: .provisional)
    }
    let first = base.addingTimeInterval(6 * 86_400)
    let early = base.addingTimeInterval(86_400 + 7 * 86_400)
    let globalReset = UsageCodexBackfill.AccountTimeline([unlabeled(base, 10, first), unlabeled(base.addingTimeInterval(3_600), 30, first),
                                                          unlabeled(base.addingTimeInterval(86_400), 0, early),
                                                          unlabeled(base.addingTimeInterval(90_000), 5, early)])
    check(!globalReset.mixed && globalReset.earlyStarts == 0 && globalReset.restarts == 1, "a single early reset is still one account")
    let late = UsageCodexBackfill.AccountTimeline([unlabeled(base, 10, first), unlabeled(base.addingTimeInterval(90_000), 12, early)])
    check(!late.mixed && late.earlyStarts == 1, "one early start first seen hours after it opened is tolerated")
    let back = UsageCodexBackfill.AccountTimeline([unlabeled(base, 10, first), unlabeled(base.addingTimeInterval(3_600), 0, early),
                                                   unlabeled(base.addingTimeInterval(7_200), 11, first)])
    check(back.mixed && back.returns == 1, "going back to a window another one replaced is a second account")
}

/// 5-hour and weekly windows of one Plus account, every 30 minutes from three days before `now`. Each global reset
/// (hours after the start) restarts both windows while both are open; otherwise the 5-hour window rolls every 5 hours.
private func plusArchive(globalResets: [Double]) throws -> [Date: Data] {
    let start = now.addingTimeInterval(-3 * 86_400)
    var lines: [Date: Data] = [:]
    var pending = globalResets.sorted()
    var sessionReset = start.addingTimeInterval(5 * 3_600)
    var weeklyReset = start.addingTimeInterval(6 * 86_400)
    var sessionUsed = 0.0
    var weeklyUsed = 20.0
    var hour = 0.0
    while hour <= 72 {
        let time = start.addingTimeInterval(hour * 3_600)
        if let next = pending.first, hour >= next {
            pending.removeFirst()
            sessionReset = time.addingTimeInterval(5 * 3_600)
            weeklyReset = time.addingTimeInterval(7 * 86_400)
            sessionUsed = 0
            weeklyUsed = 0
        } else if time >= sessionReset {
            sessionReset = time.addingTimeInterval(5 * 3_600)
            sessionUsed = 0
        }
        sessionUsed = min(100, sessionUsed + 3)
        weeklyUsed += 0.5
        let rate: [String: Any] = ["primary": limit(sessionUsed, duration: 300, reset: sessionReset),
                                   "secondary": limit(weeklyUsed, duration: 10080, reset: weeklyReset),
                                   "limit_id": "codex", "plan_type": "plus"]
        let line = try JSONSerialization.data(withJSONObject: [
            "type": "event_msg", "timestamp": time.timeIntervalSince1970,
            "payload": ["type": "token_count", "rate_limits": rate] as [String: Any]])
        appendLine(line, to: &lines[calendarUTC().startOfDay(for: time), default: Data()])
        hour += 0.5
    }
    return lines
}

private func checkPlusGlobalReset() throws {
    var limits = UsageCodexBackfill.Limits()
    limits.elapsed = 30
    let sessionSeries = QuotaSeries(provider: .codex, profile: profile, plan: "plus", meter: session, timeZoneID: utc)
    let base = now.addingTimeInterval(-3 * 86_400)
    func unlabeled(_ series: QuotaSeries, _ hours: Double, _ used: Double, _ anchor: Date) -> QuotaObservation {
        observation(base.addingTimeInterval(hours * 3_600), used, series, reset: anchor, source: .rollout, attribution: .provisional)
    }

    // The same provider-wide reset on both meters is one event, even when the readings are minutes apart. These new
    // cycles were first seen with some use, so they are early starts rather than fresh restarts.
    let weeklyBefore = base.addingTimeInterval(6 * 86_400)
    let sessionBefore = base.addingTimeInterval(25 * 3_600)
    let both = UsageCodexBackfill.AccountTimeline([
        unlabeled(codex, 20, 30, weeklyBefore), unlabeled(codex, 22, 8, base.addingTimeInterval(7 * 86_400 + 21 * 3_600)),
        unlabeled(sessionSeries, 20, 50, sessionBefore), unlabeled(sessionSeries, 22.1, 20, base.addingTimeInterval(26 * 3_600)),
    ])
    check(both.earlyStarts == 1 && !both.mixed, "a reset that restarts the 5-hour and the weekly window at once is one early start")
    // Two such events a day apart, or one on each meter hours apart, are still several accounts.
    let twice = UsageCodexBackfill.AccountTimeline([
        unlabeled(codex, 20, 30, weeklyBefore), unlabeled(codex, 22, 8, base.addingTimeInterval(7 * 86_400 + 21 * 3_600)),
        unlabeled(codex, 46, 40, base.addingTimeInterval(7 * 86_400 + 21 * 3_600)),
        unlabeled(codex, 47, 9, base.addingTimeInterval(7 * 86_400 + 46 * 3_600)),
    ])
    check(twice.earlyStarts == 2 && twice.mixed, "two early starts a day apart that are not fresh windows are two accounts")
    let apart = UsageCodexBackfill.AccountTimeline([
        unlabeled(codex, 20, 30, weeklyBefore), unlabeled(codex, 22, 8, base.addingTimeInterval(7 * 86_400 + 21 * 3_600)),
        unlabeled(sessionSeries, 20, 50, sessionBefore), unlabeled(sessionSeries, 23.5, 20, base.addingTimeInterval(27.5 * 3_600)),
    ])
    check(apart.earlyStarts == 2 && apart.mixed, "early starts on different meters more than an hour apart stay separate events")
    // The same two resets as fresh windows are the one account's windows restarting.
    let fresh = UsageCodexBackfill.AccountTimeline([
        unlabeled(codex, 20, 30, weeklyBefore), unlabeled(codex, 22, 0, base.addingTimeInterval(7 * 86_400 + 22 * 3_600)),
        unlabeled(codex, 46, 40, base.addingTimeInterval(7 * 86_400 + 22 * 3_600)),
        unlabeled(codex, 47, 0, base.addingTimeInterval(7 * 86_400 + 47 * 3_600)),
    ])
    check(fresh.earlyStarts == 0 && fresh.restarts == 2 && !fresh.mixed, "two fresh restarts a day apart are one account")

    // The whole path: one account, 5-hour and weekly windows, one global reset while both are open.
    let single = root.appendingPathComponent("plus-global-reset")
    try write(try plusArchive(globalResets: [22.5]), to: single)
    let pass = scan(UsageCodexBackfill(sessionsRoot: single, now: now, calendar: calendarUTC(), account: nil, limits: limits))
    check(pass.incompleteFiles == 0 && pass.candidates.allSatisfy { $0.provenance == .unlabeledSingleAccount },
          "the Plus archive reads as one unlabeled account")
    let decision = UsageCodexBackfill.attribute(pass.candidates, key: key, anchors: [], switchedAt: nil, now: now)
    check(decision.timeline.earlyStarts == 0 && decision.timeline.restarts == 2 && !decision.mixed && !decision.awaitsLiveReading,
          "one global reset over a 5-hour and a weekly window is not several accounts")
    let provisional = captured(pass)
    check(!provisional.isEmpty && decision.observations.count == provisional.count
          && Set(decision.observations.map(\.series.meter)).count == 2 && Set(decision.observations.map(\.reset)).count >= 4,
          "the history of both meters, before and after the reset, is kept")

    // Two global resets a day apart that each open fresh windows are still one account (as a real archive whose one
    // account had 18 early weekly resets in ten weeks showed).
    let other = root.appendingPathComponent("plus-two-resets")
    try write(try plusArchive(globalResets: [22.5, 46.5]), to: other)
    let again = scan(UsageCodexBackfill(sessionsRoot: other, now: now, calendar: calendarUTC(), account: nil, limits: limits))
    let kept = UsageCodexBackfill.attribute(again.candidates, key: key, anchors: [], switchedAt: nil, now: now)
    check(kept.timeline.earlyStarts == 0 && kept.timeline.restarts == 4 && !kept.mixed && !kept.awaitsLiveReading
          && kept.observations.count == captured(again).count,
          "two fresh global resets keep the whole one-account history")
}

/// How an import goes on after its scan, as `UsageService` drives it: one reading per step, as live readings arrive.
private func checkImportRetries() throws {
    var limits = UsageCodexBackfill.Limits()
    limits.elapsed = 30
    let mixed = interleavedArchive(until: now)
    let sessions = root.appendingPathComponent("retry-accounts")
    try write(mixed.lines, to: sessions)

    struct Run {
        var scans = 0
        var reattributions = 0
        var imports: [UsageCodexBackfill.Attribution] = []
    }
    let login = QuotaAccount(account: "acct-1", subject: nil)
    /// One live reading: the planner picks the work; `anchors` are the fresh live readings the history has.
    func reading(_ planner: UsageCodexImportPlanner, _ run: inout Run, anchors: [QuotaObservation]) {
        switch planner.step(for: key, account: login) {
        case .scan:
            run.scans += 1
            let pass = scan(UsageCodexBackfill(sessionsRoot: sessions, now: now, calendar: calendarUTC(), account: nil, limits: limits))
            let decision = UsageCodexBackfill.attribute(pass.candidates, key: key, anchors: anchors, switchedAt: nil, now: now)
            planner.scanFinished(key: key, candidates: pass.candidates, decision: decision)
            if !decision.awaitsLiveReading { run.imports.append(decision) }
        case .reattribute(let candidates):
            run.reattributions += 1
            let decision = UsageCodexBackfill.attribute(candidates, key: key, anchors: anchors, switchedAt: nil, now: now)
            planner.reattributed(key: key, decision: decision)
            if !decision.awaitsLiveReading { run.imports.append(decision) }
        case .idle:
            break
        }
    }

    // (a) A fresh live reading whose series never appears in the archive is a final answer: complete, no retry.
    let stranger = QuotaSeries(provider: .codex, profile: profile, plan: "pro", meter: weekly, timeZoneID: utc)
    let foreign = observation(now, 5, stranger, reset: now.addingTimeInterval(6 * 86_400), source: .api, attribution: .live)
    let probe = scan(UsageCodexBackfill(sessionsRoot: sessions, now: now, calendar: calendarUTC(), account: nil, limits: limits))
    let direct = UsageCodexBackfill.attribute(probe.candidates, key: key, anchors: [foreign], switchedAt: nil, now: now)
    check(direct.mixed && !direct.awaitsLiveReading && direct.observations.isEmpty,
          "a fresh live reading of another series is an answer: the import completes with nothing kept")
    let planner = UsageCodexImportPlanner()
    var first = Run()
    reading(planner, &first, anchors: [foreign])
    for _ in 0..<20 { reading(planner, &first, anchors: [foreign]) }
    check(first.scans == 1 && first.reattributions == 0 && first.imports.count == 1,
          "a fresh live reading of another series completes the import and later readings never scan again")

    // (b) No live reading at the final pass: wait, then attribute the same candidates once one arrives.
    let waiting = UsageCodexImportPlanner()
    var second = Run()
    reading(waiting, &second, anchors: [])
    check(second.scans == 1 && second.imports.isEmpty, "with no live reading the scan finishes without completing the import")
    reading(waiting, &second, anchors: [])
    check(second.scans == 1 && second.reattributions == 1 && second.imports.isEmpty,
          "a reading that is not a fresh live one re-attributes in memory and still waits")
    reading(waiting, &second, anchors: [mixed.live])
    check(second.scans == 1 && second.reattributions == 2 && second.imports.count == 1
          && !second.imports[0].observations.isEmpty && second.imports[0].mixed,
          "the next live reading keeps the live cycle from the candidates in memory, without a second scan")

    // (c) Once complete, any number of readings do nothing.
    for _ in 0..<50 { reading(waiting, &second, anchors: [mixed.live]) }
    check(second.scans == 1 && second.reattributions == 2 && second.imports.count == 1,
          "many later live readings never trigger another scan or attribution")
    // Another profile or time zone is another import.
    check({ if case .scan = waiting.step(for: QuotaImportKey(profile: profile, timeZoneID: "Europe/Madrid"), account: login) { return true } else { return false } }(),
          "an import of another key still scans")
}

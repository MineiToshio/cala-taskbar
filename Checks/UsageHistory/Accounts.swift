import Foundation

/// Compressed rollouts, `resets_at` jitter, and unlabeled archives that mix several accounts.
///
/// The multi-account case reproduces the provisional "~100% used at reset" seen on a real 13-week archive while the
/// live weekly reading was 7%: four accounts used in turn, each exhausted in two days, made one series that debits
/// about 350 pp per week, which no single account can do.
func checkArchiveAccounts() throws {
    try checkCompressedRollouts()
    checkResetJitter()
    try checkMixedAccounts()
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

private func forecast(_ rows: [QuotaObservation], live: QuotaObservation, name: String) -> ForecastResult {
    let history = store(name, at: live.date)
    history.replaceImport(rows, for: key, complete: true, now: live.date)
    history.ingest([live], now: live.date)
    return UsageForecast().forecast(snapshot: history.snapshot(), current: live, calendar: calendarUTC(), now: live.date)
}

/// Every unlabeled row as the old single-account rule kept it.
private func captured(_ pass: UsageCodexBackfill.Pass) -> [QuotaObservation] {
    pass.candidates.flatMap {
        UsageQuotaCapture.observations($0.reading, provider: .codex, profile: profile, timeZoneID: utc, source: .rollout,
                                       attribution: .provisional, now: now)
    }
}

private func checkMixedAccounts() throws {
    var limits = UsageCodexBackfill.Limits()
    limits.elapsed = 30
    // Four accounts in turn: the merged series debits ~350 pp a week.
    let mixed = weeklyArchive(accounts: 4, burn: 40, until: now)
    let mixedRoot = root.appendingPathComponent("mixed-accounts")
    try write(mixed.lines, to: mixedRoot)
    let pass = scan(UsageCodexBackfill(sessionsRoot: mixedRoot, now: now, calendar: calendarUTC(), account: nil, limits: limits))
    check(!pass.foreignSeen && pass.incompleteFiles == 0 && pass.candidates.count > 7_000
          && pass.candidates.allSatisfy { $0.provenance == .unlabeledSingleAccount },
          "rollouts without identity look like a one-account home to the file scan")
    let timeline = UsageCodexBackfill.accountTimeline(pass.candidates, key: key, now: now)
    check(timeline.mixed && timeline.earlyStarts >= 10, "weekly cycles that start before the previous one resets reveal several accounts")

    let all = UsageCodexBackfill.attributed(pass.candidates, key: key, anchors: [], switchedAt: nil, now: now)
    check(all.isEmpty, "without a live anchor nothing of a multi-account archive is kept")
    let anchored = UsageCodexBackfill.attributed(pass.candidates, key: key, anchors: [mixed.live], switchedAt: nil, now: now)
    check(!anchored.isEmpty && anchored.allSatisfy {
        abs($0.reset.timeIntervalSince(mixed.live.reset)) <= QuotaObservation.explicitResetJitter && $0.attribution == .provisional
    }, "with a live anchor only the live cycle survives, including its jittered resets")

    // The engine itself is right about the merged series: replaying it says the window will run out.
    let merged = captured(pass)
    let inflated = forecast(merged, live: mixed.live, name: "mixed-merged")
    check((inflated.expectedUsed ?? 0) >= 99 && inflated.readiness == .provisional,
          "merging the accounts reproduces the provisional ~100% at reset")
    let fixed = forecast(anchored, live: mixed.live, name: "mixed-attributed")
    check(fixed.readiness == .learning && fixed.expectedUsed == nil,
          "kept history is the live cycle only, so the forecast keeps learning instead of claiming 100%")

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

    // One early start is tolerated (a provider-wide reset); returning to an older window is not.
    let base = now.addingTimeInterval(-3 * 86_400)
    func unlabeled(_ time: Date, _ used: Double, _ anchor: Date) -> QuotaObservation {
        observation(time, used, reset: anchor, source: .rollout, attribution: .provisional)
    }
    let first = base.addingTimeInterval(6 * 86_400)
    let early = base.addingTimeInterval(86_400 + 7 * 86_400)
    let globalReset = UsageCodexBackfill.AccountTimeline([unlabeled(base, 10, first), unlabeled(base.addingTimeInterval(3_600), 30, first),
                                                          unlabeled(base.addingTimeInterval(86_400), 0, early),
                                                          unlabeled(base.addingTimeInterval(90_000), 5, early)])
    check(!globalReset.mixed && globalReset.earlyStarts == 1, "a single early reset is still one account")
    let back = UsageCodexBackfill.AccountTimeline([unlabeled(base, 10, first), unlabeled(base.addingTimeInterval(3_600), 0, early),
                                                   unlabeled(base.addingTimeInterval(7_200), 11, first)])
    check(back.mixed && back.returns == 1, "going back to a window another one replaced is a second account")
}

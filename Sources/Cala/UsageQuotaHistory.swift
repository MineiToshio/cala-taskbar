import Foundation
import CryptoKit
import Darwin

extension QuotaObservation {
    fileprivate static let calculatedResetTolerance: TimeInterval = 2

    /// The whole second a cycle is keyed by. Providers send fractional resets (02:59:59.819) that land on either side
    /// of a second between readings, so the nearest second is steadier than truncation.
    static func resetAnchor(_ reset: Date) -> Date {
        Date(timeIntervalSince1970: reset.timeIntervalSince1970.rounded())
    }

    func normalized(now: Date) -> Self? {
        let seconds = series.meter.durationSeconds
        guard (1...31_536_000).contains(seconds), (0...100).contains(used),
              TimeZone(identifier: series.timeZoneID) != nil,
              UsageJSON.boundedDate(date) != nil, UsageJSON.boundedDate(reset) != nil,
              date <= now.addingTimeInterval(5), date < reset,
              reset.timeIntervalSince(date) <= Double(seconds) + (resetKind == .calculated ? Self.calculatedResetTolerance : 0) else { return nil }
        let anchor = Self.resetAnchor(reset)
        guard date < anchor else { return nil }
        return Self(series: series, date: date, used: used, reset: anchor, source: source, resetKind: resetKind,
                    attribution: attribution, companion: companion, bindingWeekly: bindingWeekly, hardBlockUntil: hardBlockUntil)
    }

    /// Absolute bucket edges from the recorded calendar, including both occurrences of a repeated hour.
    static func bucketStart(_ date: Date, series: QuotaSeries) -> Date {
        QuotaCalendarBuckets.interval(containing: date, timeZoneID: series.timeZoneID, seconds: series.meter.bucketSeconds).start
    }
}

/// Local identity input. Only its salted digest enters the store.
struct QuotaAccount {
    let account: String
    let subject: String?
    /// ChatGPT user id of a Codex login, as a rollout's `session_meta` names its creator. Not part of the digest.
    var creatorUser: String? = nil

    var components: [String] { [account, subject ?? ""] }
}

struct QuotaLogin: Equatable {
    let directory: String  // Salted directory key.
    let profile: QuotaProfileID
    let identified: Bool
    let switchedAt: Date?
    /// The login kept the profile it had before its account became known, so its readings are still checked for
    /// signs of another account, as for an unidentified login.
    var adopted = false
}

struct QuotaImportKey: Hashable, Codable {
    let profile: QuotaProfileID
    let timeZoneID: String
}

private struct QuotaRowKey: Hashable {
    let series: QuotaSeries
    let cycle: QuotaCycle
    let start: Date
}

private struct QuotaHistoryChange {
    struct Cell {
        let key: QuotaRowKey
        var debit = 0
        var direct = 0.0
        var quiet = 0.0
        var flags: QuotaBucketFlags = []
        var sample: QuotaBucketSample?
    }
    var cells: [Cell] = []
    var gap: QuotaGap?
}

private struct QuotaBoundary: Codable {
    let date: Date
    let breaksQuiet: Bool
}

// Both live and archived counters go through this reducer. Its cursor is sufficient to resume
// after a restart without charging the first reading or forgetting a rounded regression.
private struct QuotaCursor: Codable {
    var previous: QuotaObservation?
    var cycle: QuotaCycle?
    var highWater = 0.0
    var explicitAnchor = false
    var regressed = false
    var carry = 0.0

    mutating func ingest(_ observation: QuotaObservation, across boundaries: [QuotaBoundary]) -> QuotaHistoryChange {
        let prior = previous
        var result = QuotaHistoryChange()
        let meter = observation.series.meter
        let start = QuotaObservation.bucketStart(observation.date, series: observation.series)
        let boundary = boundaries.last { $0.date <= observation.date && (prior?.date ?? .distantPast) <= $0.date }
        let breaksQuiet = boundaries.contains {
            $0.breaksQuiet && $0.date <= observation.date && (prior?.date ?? .distantPast) <= $0.date
        }
        let sameAttribution = prior?.attribution == observation.attribution
        let equivalentReset = cycle.map { anchor in
            if anchor.reset == observation.reset { return true }
            if observation.resetKind == .explicit, explicitAnchor, observation.date < anchor.reset,
               abs(anchor.reset.timeIntervalSince(observation.reset)) <= QuotaObservation.explicitResetJitter { return true }
            return explicitAnchor && observation.resetKind == .calculated
                && abs(anchor.reset.timeIntervalSince(observation.reset)) <= QuotaObservation.calculatedResetTolerance
                && observation.date < anchor.reset
                && anchor.reset.timeIntervalSince(observation.date) <= Double(meter.durationSeconds)
                && observation.used >= highWater
        } ?? false
        let continuous = equivalentReset && sameAttribution && !breaksQuiet && observation.used >= highWater - 1
        if !continuous {
            cycle = QuotaCycle(reset: observation.reset, segmentStart: observation.date)
            highWater = observation.used
            explicitAnchor = observation.resetKind == .explicit
            carry = 0
            regressed = false
        } else if observation.resetKind == .explicit {
            explicitAnchor = true
        }
        guard let cycle else { return result }
        if let prior, continuous {
            let elapsed = observation.date.timeIntervalSince(prior.date)
            let delta = max(0, observation.used - highWater)
            let api = prior.source == .api && observation.source == .api
            let source: QuotaSource = api ? .api : (prior.source == .rollout || observation.source == .rollout ? .rollout : .statusLine)
            var flags: QuotaBucketFlags = []
            if source == .rollout { flags.insert(.rollout) }
            if observation.attribution == .provisional { flags.insert(.provisional) }
            let previousStart = QuotaObservation.bucketStart(prior.date, series: observation.series)
            if elapsed > 0 && highWater < 100 && !regressed && observation.used >= highWater {
                let dense = boundary == nil && elapsed <= (api ? 1_200 : 360)
                let quiet = !dense && delta == 0 && elapsed <= 36 * 3_600
                // The hour localization rule also applies to five-hour meters, but an unresolved
                // half-hour split stays a summary because it has no observed distribution.
                let localized = !dense && delta > 0 && previousStart == start && boundary?.breaksQuiet != true
                if dense || quiet || localized {
                    if delta == 0 && observation.used.rounded() == observation.used { flags.insert(.roundedPlateau) }
                    if localized { flags.insert(.localizedGap) }
                    var remaining = delta * 100 + carry
                    var position = prior.date
                    var bucket = QuotaCalendarBuckets.interval(containing: prior.date, timeZoneID: observation.series.timeZoneID,
                                                               seconds: meter.bucketSeconds)
                    let split = observation.date > bucket.end
                    while position < observation.date {
                        let end = min(observation.date, bucket.end)
                        let seconds = end.timeIntervalSince(position)
                        guard seconds > 0 else { break }
                        var cellFlags = flags
                        if split { cellFlags.insert(.split) }
                        let amount = end == observation.date ? remaining : delta * 100 * seconds / elapsed + carry
                        let debit = max(0, Int(amount.rounded()))
                        remaining -= Double(debit)
                        carry = 0
                        result.cells.append(.init(key: .init(series: observation.series, cycle: cycle, start: bucket.start),
                                                  debit: debit, direct: quiet ? 0 : seconds, quiet: quiet ? seconds : 0,
                                                  flags: cellFlags))
                        position = end
                        if position < observation.date {
                            bucket = QuotaCalendarBuckets.interval(containing: position, timeZoneID: observation.series.timeZoneID,
                                                                   seconds: meter.bucketSeconds)
                        }
                    }
                    carry = remaining
                }
                if !dense && delta > 0 {
                    let debit = localized ? result.cells.reduce(0) { $0 + $1.debit } : Int((delta * 100).rounded())
                    result.gap = QuotaGap(series: observation.series, cycle: cycle, start: prior.date, end: observation.date,
                                          deltaHundredths: debit, source: source, attribution: observation.attribution,
                                          localized: localized)
                }
            } else if elapsed > 0 && delta > 0 && regressed {
                result.gap = QuotaGap(series: observation.series, cycle: cycle, start: prior.date, end: observation.date,
                                      deltaHundredths: Int((delta * 100).rounded()), source: source,
                                      attribution: observation.attribution, localized: false, canLocalizeToHour: false)
            }
            regressed = observation.used < highWater
            highWater = max(highWater, observation.used)
        }
        previous = observation
        var sampleFlags: QuotaBucketFlags = []
        if observation.source == .rollout { sampleFlags.insert(.rollout) }
        if observation.attribution == .provisional { sampleFlags.insert(.provisional) }
        if observation.used == 100 { sampleFlags.insert(.censored) }
        result.cells.append(.init(key: .init(series: observation.series, cycle: cycle, start: start),
                                  flags: sampleFlags, sample: QuotaBucketSample(observation)))
        return result
    }
}

private struct QuotaLiveTrack: Codable {
    let series: QuotaSeries
    let cutoff: Date
    var cursor = QuotaCursor()
    // A short reorder buffer allows API samples to replace same-time events, including after restart.
    var tail: [QuotaObservation] = []
    var boundaries: [QuotaBoundary] = []
    var apiAnchor: QuotaObservation?

    mutating func insert(_ observation: QuotaObservation) -> Bool {
        guard observation.date > (cursor.previous?.date ?? .distantPast),
              QuotaObservation.bucketStart(observation.date, series: series) >= cutoff else { return false }
        if let index = tail.firstIndex(where: { $0.date == observation.date }) {
            let old = tail[index]
            guard (observation.source.rawValue, observation.attribution.rawValue) > (old.source.rawValue, old.attribution.rawValue) else { return false }
            tail[index] = observation
        } else {
            let index = tail.firstIndex { $0.date > observation.date } ?? tail.endIndex
            tail.insert(observation, at: index)
        }
        if observation.source == .api, observation.attribution == .live, observation.date >= (apiAnchor?.date ?? .distantPast) {
            apiAnchor = observation
        }
        return true
    }

    mutating func commitFirst() -> QuotaHistoryChange {
        let first = tail.removeFirst()
        let change = cursor.ingest(first, across: boundaries)
        boundaries.removeAll { $0.date < first.date }
        return change
    }

    var latest: QuotaObservation? { tail.last ?? cursor.previous }
}

private struct QuotaStoredRow {
    var bucket: QuotaBucket
    let imported: Bool

    init(_ key: QuotaRowKey, imported: Bool) {
        self.imported = imported
        bucket = QuotaBucket(series: key.series, cycle: key.cycle, start: key.start,
                             deltaHundredths: 0, coveredSeconds: 0, quietSeconds: 0, flags: [], latest: nil)
    }

    private static func continuous(_ first: QuotaBucketSample, _ second: QuotaBucketSample) -> Bool {
        guard QuotaCapBand(first.companion, at: first.date) == QuotaCapBand(second.companion, at: second.date),
              first.attribution == second.attribution else { return false }
        if case .present(.active(let a, let resetA)) = first.companion,
           case .present(.active(let b, let resetB)) = second.companion { return resetA == resetB && a <= b }
        return first.companion == second.companion
    }

    mutating func apply(_ cell: QuotaHistoryChange.Cell) {
        bucket.deltaHundredths += cell.debit
        bucket.coveredSeconds += cell.direct
        bucket.quietSeconds += cell.quiet
        bucket.flags.formUnion(cell.flags)
        guard let sample = cell.sample else { return }
        if sample.used == 100 && bucket.firstHit == nil { bucket.firstHit = sample.date }
        if let prior = bucket.latest, prior.companion != .unknown, bucket.series.meter.durationSeconds == 604_800 {
            // Compact only interior samples of an uninterrupted band in the same short cycle.
            // Both sides of a reset or band crossing stay available to replay.
            let earlier = bucket.earlierCompanionSamples
            if earlier.count >= 2 {
                let last = earlier[earlier.count - 1]
                let before = earlier[earlier.count - 2]
                let minute = floor(prior.date.timeIntervalSince1970 / 60)
                if floor(before.date.timeIntervalSince1970 / 60) == minute,
                   Self.continuous(before, last), Self.continuous(last, prior) {
                    bucket.earlierCompanionSamples.removeLast()
                }
            }
            bucket.earlierCompanionSamples.append(prior)
        }
        bucket.latest = sample
    }
}

private struct QuotaStoredGap {
    var gap: QuotaGap
    let imported: Bool
}

private struct QuotaShard {
    var rows: [QuotaRowKey: QuotaStoredRow] = [:]
    var gaps: [QuotaStoredGap] = []
    var count: Int { rows.count + gaps.count }
}

/// Queue-owned rolling history. The service can emit observations independently of the display cache.
final class UsageQuotaHistory {
    struct Limits {
        var series = 16
        var rows = 96_000
        var bytes = 12 * 1_024 * 1_024
    }

    static let retention: TimeInterval = 112 * 86_400
    private static let week: TimeInterval = 7 * 86_400
    private static let version = 1
    /// Bumped when the archive importer changes what it accepts; older imports are then rebuilt from the archive.
    /// 2: compressed rollouts, jitter-tolerant cycles, and no unlabeled history across several accounts.
    /// 3: rollouts are identified by their session_meta creator; fresh restarts and stale-snapshot blips are one account.
    private static let importRevision = 3

    private struct LoginRecord: Codable {
        var identity: String?
        var generation = UUID().uuidString
        var signedIn: Bool
        var switchedAt: Date?
        var lastSeen: Date
        /// The unidentified profile this login kept when its account became known (older versions could miss the
        /// account metadata). Cleared by any later switch.
        var adoptedProfile: String?
    }

    private struct ShardFile: Codable {
        let name: String
        let bytes: Int
    }

    private struct Manifest: Codable {
        var version = UsageQuotaHistory.version
        var salt = UUID().uuidString
        var logins: [String: LoginRecord] = [:]
        var series: [Int: QuotaSeries] = [:]
        var files: [Int: ShardFile] = [:]
        var tracks: [QuotaLiveTrack] = []
        var imports: Set<QuotaImportKey> = []
        var fileScopedImports: Bool? = true
        var importRevision: Int? = UsageQuotaHistory.importRevision
    }

    private let queue = DispatchQueue(label: "local.cala.usage.history", qos: .utility)
    private let directory: URL
    private let limits: Limits
    private let clock: () -> Date
    private let report: (String) -> Void
    private var loaded = false
    private var manifest = Manifest()
    private var tracks: [QuotaSeries: QuotaLiveTrack] = [:]
    private var shards: [Int: QuotaShard] = [:]
    private var dirty = Set<Int>()
    private struct PendingImport {
        let cancelled: () -> Bool
        let updated: () -> Void
    }
    private var pendingImports: [QuotaImportKey: PendingImport] = [:]
    private var changed = false
    private var scheduled = false
    /// Bumped by `cancelScheduledFlush`: a delayed flush (or its retry after a failed write) from before is dropped.
    private var flushGeneration = 0
    private var activeProfiles: [String: QuotaProfileID] = [:]
    private var totalCount = 0

    init(directory: URL, limits: Limits = Limits(), clock: @escaping () -> Date = Date.init,
         report: @escaping (String) -> Void = { _ in }) {
        self.directory = directory
        self.limits = limits
        self.clock = clock
        self.report = report
    }

    func login(provider: UsageProvider, directory: String, account: QuotaAccount?, signedIn: Bool,
               now: Date, rotate: Bool = false) -> QuotaLogin? {
        queue.sync {
            load()
            let key = digest([provider.rawValue, directory])
            let identity = account.map { digest($0.components) }
            var record = manifest.logins[key] ?? LoginRecord(identity: identity, signedIn: signedIn, lastSeen: now)
            let previousProfile = profileID(key, record)
            let knownSwitch = identity != nil && record.identity != nil && identity != record.identity
            if rotate || knownSwitch || (record.signedIn && !signedIn) {
                record.switchedAt = now
                record.generation = UUID().uuidString
                record.adoptedProfile = nil
                addBoundary(at: now, profile: previousProfile, breaksQuiet: true)
            } else if identity != nil, record.identity == nil, record.signedIn, signedIn {
                // An account read for the first time on a signed-in login is the same login: keep its history.
                record.adoptedProfile = previousProfile.rawValue
            }
            // A transient metadata read failure must not assign a second profile to token renewal.
            if let identity { record.identity = identity }
            else if !signedIn { record.identity = nil }
            record.signedIn = signedIn
            let previous = manifest.logins[key]
            if previous?.generation != record.generation || previous?.identity != record.identity
                || previous?.adoptedProfile != record.adoptedProfile
                || previous?.signedIn != signedIn || now.timeIntervalSince(record.lastSeen) >= 86_400 {
                record.lastSeen = now
                manifest.logins[key] = record
                pruneLogins()
                scheduleFlush()
            }
            guard signedIn else {
                activeProfiles[key] = nil
                return nil
            }
            let id = profileID(key, record)
            activeProfiles[key] = id
            return QuotaLogin(directory: key, profile: id, identified: record.identity != nil, switchedAt: record.switchedAt,
                              adopted: record.adoptedProfile != nil)
        }
    }

    func deactivate(_ login: QuotaLogin, at date: Date) {
        queue.async {
            self.activeProfiles[login.directory] = nil
            self.addBoundary(at: date, profile: login.profile, breaksQuiet: true)
        }
    }

    func ingest(_ observations: [QuotaObservation], now: Date, accepted: @escaping ([QuotaObservation]) -> Void = { _ in }) {
        guard !observations.isEmpty else { return }
        queue.async {
            self.load()
            let sorted = observations.sorted {
                ($0.date, -$0.source.rawValue, -$0.attribution.rawValue) < ($1.date, -$1.source.rawValue, -$1.attribution.rawValue)
            }
            let actual = sorted.compactMap { self.ingestOne($0, now: now) }
            if !actual.isEmpty { accepted(actual) }
        }
    }

    func liveAnchors(for key: QuotaImportKey) -> [QuotaObservation] {
        queue.sync {
            load()
            return tracks.values.compactMap { track in
                guard track.series.profile == key.profile, track.series.timeZoneID == key.timeZoneID else { return nil }
                return track.apiAnchor
            }
        }
    }

    func breakCoverage(at date: Date, allowsQuiet: Bool, flush: Bool = false) {
        queue.sync {
            load()
            addBoundary(at: date, profile: nil, breaksQuiet: !allowsQuiet)
            if flush { _ = write() }
        }
    }

    func breakCoverage(for profile: QuotaProfileID, at date: Date) {
        queue.async { self.addBoundary(at: date, profile: profile, breaksQuiet: true) }
    }

    func importComplete(_ key: QuotaImportKey) -> Bool {
        queue.sync {
            load()
            return manifest.imports.contains(key)
        }
    }

    func replaceImport(_ observations: [QuotaObservation], for key: QuotaImportKey, complete: Bool,
                       now: Date, cancelled: @escaping () -> Bool = { false }, updated: @escaping () -> Void = {}) {
        queue.async {
            guard !cancelled() else { return }
            self.load()
            self.mergeImport(observations, for: key, now: now, cancelled: cancelled)
            guard !cancelled() else { return }
            if complete { self.pendingImports[key] = PendingImport(cancelled: cancelled, updated: updated) }
            self.scheduleFlush()
            // Publish outside this queue so synchronous snapshot reads from consumers are safe.
            DispatchQueue.global(qos: .utility).async { if !cancelled() { updated() } }
        }
    }

    /// Waits for queued observations and takes a value snapshot off the main thread.
    func snapshot() -> QuotaHistorySnapshot {
        queue.sync {
            load()
            prune(now: clock())
            let cutoff = clock().addingTimeInterval(-Self.retention)
            var overlay = [Int: QuotaShard]()
            for track in tracks.values {
                var cursor = track.cursor
                for reading in track.tail {
                    let change = cursor.ingest(reading, across: track.boundaries)
                    apply(change, imported: false, to: &overlay, over: shards, earliest: cutoff)
                }
            }
            var buckets: [QuotaBucket] = []
            var gaps: [QuotaGap] = []
            for week in Set(shards.keys).union(overlay.keys) {
                let newer = overlay[week]
                for (key, row) in shards[week]?.rows ?? [:] where newer?.rows[key] == nil {
                    var bucket = row.bucket
                    if row.imported && !importIsDurable(bucket.series) { bucket.flags.insert(.provisional) }
                    buckets.append(bucket)
                }
                buckets.append(contentsOf: (newer?.rows.values.map(\.bucket) ?? []))
                for record in (shards[week]?.gaps ?? []) + (newer?.gaps ?? []) {
                    let gap = record.gap
                    if record.imported && !importIsDurable(gap.series) {
                        gaps.append(QuotaGap(series: gap.series, cycle: gap.cycle, start: gap.start, end: gap.end,
                                             deltaHundredths: gap.deltaHundredths, source: gap.source,
                                             attribution: .provisional, localized: gap.localized,
                                             canLocalizeToHour: gap.canLocalizeToHour))
                    } else { gaps.append(gap) }
                }
            }
            // The reorder buffer can contribute additional rows before they enter the durable budget.
            if buckets.count + gaps.count > limits.rows {
                let dates = (buckets.map(\.start) + gaps.map(\.start)).sorted()
                let removeBefore = dates[dates.count - limits.rows - 1]
                buckets.removeAll { $0.start <= removeBefore }
                gaps.removeAll { $0.start <= removeBefore }
            }
            return QuotaHistorySnapshot(buckets: buckets, gaps: gaps)
        }
    }

    @discardableResult
    func flush() -> Bool { queue.sync { load(); return write() } }

    /// The usage service stopped: no delayed flush or write retry keeps running. Unsaved rows stay in memory and are
    /// written by the next flush (stop's final flush, or the next run).
    func cancelScheduledFlush() {
        queue.sync {
            flushGeneration += 1
            scheduled = false
        }
    }

    /// A delayed flush (or a retry of a failed write) is pending.
    var hasScheduledFlush: Bool { queue.sync { scheduled } }

    private func digest(_ fields: [String]) -> String {
        let framed = fields.map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data((manifest.salt + framed).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func profileID(_ key: String, _ record: LoginRecord) -> QuotaProfileID {
        if let adopted = record.adoptedProfile { return QuotaProfileID(rawValue: adopted) }
        return QuotaProfileID(rawValue: digest([key, record.identity ?? "", record.generation]))
    }

    private func ingestOne(_ raw: QuotaObservation, now: Date) -> QuotaObservation? {
        // Unlabeled rollouts train through the provisional import partition. They cannot interrupt live pairs.
        guard raw.attribution != .provisional,
              let observation = raw.normalized(now: now), validSeries(observation.series),
              valid(observation, for: observation.series, now: now),
              observation.date >= now.addingTimeInterval(-Self.retention) else { return nil }
        let series = observation.series
        if tracks[series] == nil {
            let cutoff = QuotaObservation.bucketStart(observation.date, series: series)
            tracks[series] = QuotaLiveTrack(series: series, cutoff: cutoff)
            removeImported(series: series, from: cutoff)
        }
        guard tracks[series]?.insert(observation) == true else { return nil }
        drainTail(series, through: now.addingTimeInterval(-120))
        if tracks.count > limits.series || totalCount > limits.rows { prune(now: now) }
        scheduleFlush()
        return observation
    }

    private func drainTail(_ series: QuotaSeries, through date: Date) {
        guard var track = tracks[series] else { return }
        while let first = track.tail.first, track.tail.count > 16 || (track.tail.count > 1 && first.date < date) {
            let day = clock().addingTimeInterval(-Self.retention)
            let change = track.commitFirst()
            let weeks = Set(change.cells.map { Self.weekID($0.key.start) } + (change.gap.map { [Self.weekID($0.start)] } ?? []))
            let before = weeks.reduce(0) { $0 + (shards[$1]?.count ?? 0) }
            apply(change, imported: false, to: &shards, earliest: day)
            totalCount += weeks.reduce(0) { $0 + (shards[$1]?.count ?? 0) } - before
            dirty.formUnion(weeks)
        }
        tracks[series] = track
    }

    private func addBoundary(at date: Date, profile: QuotaProfileID?, breaksQuiet: Bool) {
        for key in Array(tracks.keys) where profile == nil || key.profile == profile {
            guard var track = tracks[key] else { continue }
            if track.boundaries.count >= 32 {
                // Compress an unattended run of lifecycle events while retaining a quiet break.
                let protectsQuiet = track.boundaries.contains(where: \.breaksQuiet)
                track.boundaries = [.init(date: track.boundaries[0].date, breaksQuiet: protectsQuiet)]
            }
            track.boundaries.append(.init(date: date, breaksQuiet: breaksQuiet))
            tracks[key] = track
        }
        if !tracks.isEmpty { scheduleFlush() }
    }

    private func removeImported(series: QuotaSeries, from cutoff: Date) {
        for week in Array(shards.keys) {
            guard var shard = shards[week] else { continue }
            let before = shard.count
            shard.rows = shard.rows.filter { !$0.value.imported || $0.key.series != series || $0.key.start < cutoff }
            shard.gaps.removeAll { $0.imported && $0.gap.series == series && $0.gap.end >= cutoff }
            if shard.count != before {
                dirty.insert(week)
                totalCount += shard.count - before
                shards[week] = shard
            }
        }
    }

    private func mergeImport(_ observations: [QuotaObservation], for key: QuotaImportKey, now: Date,
                             cancelled: () -> Bool) {
        let earliest = now.addingTimeInterval(-Self.retention)
        var partition: [Int: QuotaShard] = [:]
        let valid = observations.prefix(100_000).compactMap { $0.normalized(now: now) }.filter {
            $0.series.provider == .codex && $0.series.profile == key.profile && $0.series.timeZoneID == key.timeZoneID
                && $0.source == .rollout && $0.date >= earliest && validSeries($0.series)
                && self.valid($0, for: $0.series, now: now)
        }
        for (series, values) in Dictionary(grouping: valid, by: \.series) {
            var cursor = QuotaCursor()
            let cutoff = tracks[series]?.cutoff ?? .distantFuture
            // Include the first reading beyond the seam when it bounds earlier buckets.
            var previousDate: Date?
            for reading in values.sorted(by: {
                ($0.date, -$0.attribution.rawValue, $0.reset, $0.used) < ($1.date, -$1.attribution.rawValue, $1.reset, $1.used)
            }) {
                if cancelled() { return }
                guard reading.date != previousDate else { continue }
                previousDate = reading.date
                let change = cursor.ingest(reading, across: [])
                apply(change, imported: true, to: &partition, earliest: earliest, before: cutoff)
                if reading.date >= cutoff { break }
            }
        }
        guard !cancelled() else { return }
        for week in Set(shards.keys).union(partition.keys) {
            var shard = shards[week] ?? QuotaShard()
            let before = shard.count
            shard.rows = shard.rows.filter { !$0.value.imported || !matches($0.key.series, key) }
            shard.gaps.removeAll { $0.imported && matches($0.gap.series, key) }
            if let imported = partition[week] {
                shard.rows.merge(imported.rows) { live, _ in live }
                shard.gaps.append(contentsOf: imported.gaps)
            }
            if before != shard.count || partition[week] != nil {
                dirty.insert(week)
                totalCount += shard.count - before
                shards[week] = shard
            }
        }
        prune(now: now)
    }

    private func matches(_ series: QuotaSeries, _ key: QuotaImportKey) -> Bool {
        series.provider == .codex && series.profile == key.profile && series.timeZoneID == key.timeZoneID
    }

    private func importIsDurable(_ series: QuotaSeries) -> Bool {
        manifest.imports.contains(QuotaImportKey(profile: series.profile, timeZoneID: series.timeZoneID))
    }

    private static func weekID(_ date: Date) -> Int {
        // Monday 00:00 UTC shards are independent of the recorded profile time zone.
        Int(floor((date.timeIntervalSince1970 + 3 * 86_400) / week))
    }

    private func apply(_ change: QuotaHistoryChange, imported: Bool, to target: inout [Int: QuotaShard],
                       over base: [Int: QuotaShard] = [:], earliest: Date, before cutoff: Date = .distantFuture) {
        for cell in change.cells where cell.key.start >= earliest && cell.key.start < cutoff {
            let week = Self.weekID(cell.key.start)
            if target[week]?.rows[cell.key] == nil, let existing = base[week]?.rows[cell.key] {
                target[week, default: QuotaShard()].rows[cell.key] = existing
            }
            target[week, default: QuotaShard()].rows[cell.key, default: QuotaStoredRow(cell.key, imported: imported)].apply(cell)
        }
        if let gap = change.gap, gap.start >= earliest, gap.end < cutoff {
            target[Self.weekID(gap.start), default: QuotaShard()].gaps.append(QuotaStoredGap(gap: gap, imported: imported))
        }
    }

    private func pruneLogins() {
        let keys = manifest.logins.keys.sorted {
            (manifest.logins[$0]?.lastSeen ?? .distantPast) > (manifest.logins[$1]?.lastSeen ?? .distantPast)
        }
        for key in keys.dropFirst(32) where activeProfiles[key] == nil { manifest.logins[key] = nil }
    }

    private func prune(now: Date) {
        let earliest = now.addingTimeInterval(-Self.retention)
        for series in Array(tracks.keys) where (tracks[series]?.latest?.date ?? .distantPast) < earliest {
            tracks[series] = nil
            changed = true
        }
        var recent = tracks.compactMapValues { $0.latest?.date }
        filterShards(rows: { key, _ in
            guard key.start >= earliest else { return false }
            recent[key.series] = max(recent[key.series] ?? .distantPast, key.start)
            return true
        }, gaps: { record in
            let gap = record.gap
            guard gap.start >= earliest else { return false }
            recent[gap.series] = max(recent[gap.series] ?? .distantPast, gap.end)
            return true
        })
        let active = Set(activeProfiles.values)
        let ranked = recent.keys.sorted {
            let left = active.contains($0.profile), right = active.contains($1.profile)
            return left == right ? recent[$0]! > recent[$1]! : left
        }
        let evicted = Set(ranked.dropFirst(limits.series))
        if !evicted.isEmpty {
            for series in evicted { tracks[series] = nil }
            filterShards(rows: { key, _ in !evicted.contains(key.series) }, gaps: { !evicted.contains($0.gap.series) })
            changed = true
        }
        if totalCount > limits.rows { dropOldest(totalCount - limits.rows) }
        let weeks = shards.keys.sorted()
        for week in weeks.prefix(max(0, weeks.count - 17)) {
            totalCount -= shards.removeValue(forKey: week)?.count ?? 0
            dirty.insert(week)
        }
    }

    private func filterShards(rows keepRow: (QuotaRowKey, QuotaStoredRow) -> Bool,
                              gaps keepGap: (QuotaStoredGap) -> Bool) {
        for week in Array(shards.keys) {
            guard var shard = shards[week] else { continue }
            let before = shard.count
            shard.rows = shard.rows.filter(keepRow)
            shard.gaps = shard.gaps.filter(keepGap)
            if shard.count != before {
                dirty.insert(week)
                totalCount += shard.count - before
                shards[week] = shard.count == 0 ? nil : shard
            }
        }
    }

    private func dropOldest(_ count: Int) {
        guard count > 0 else { return }
        var remaining = count
        for week in shards.keys.sorted() {
            guard let shard = shards[week] else { continue }
            if shard.count <= remaining {
                dirty.insert(week)
                shards[week] = nil
                totalCount -= shard.count
                remaining -= shard.count
            } else {
                let dates = (shard.rows.keys.map(\.start) + shard.gaps.map { $0.gap.start }).sorted()
                let cutoff = dates[remaining - 1]
                filterShards(rows: { key, _ in key.start > cutoff }, gaps: { $0.gap.start > cutoff })
                return
            }
            if remaining == 0 { return }
        }
    }

    private func scheduleFlush() {
        changed = true
        guard !scheduled else { return }
        scheduled = true
        let generation = flushGeneration
        queue.asyncAfter(deadline: .now() + 60) { [weak self] in
            guard let self, self.flushGeneration == generation else { return }
            self.scheduled = false
            if !self.write() { self.scheduleFlush() }
        }
    }
}

private extension UsageQuotaHistory {
    struct DiskRecord<Value: Codable>: Codable {
        let value: Value?

        init(_ value: Value) { self.value = value }
        init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
        func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
    }

    struct DiskShard: Codable {
        let version: Int
        let cycles: [DiskRecord<QuotaCycle>]
        let rows: [DiskRecord<DiskRow>]
        let gaps: [DiskRecord<DiskGap>]
    }

    struct DiskRow: Codable {
        let series: Int
        let cycle: Int
        let start: Double
        let debit: Int
        let direct: Double
        let quiet: Double
        let flags: QuotaBucketFlags
        let imported: Bool
        let sample: QuotaBucketSample?
        let details: Details?

        struct Details: Codable {
            let firstHit: Date?
            let companionSamples: [QuotaBucketSample]?
        }

        init(_ row: QuotaStoredRow, series: Int, cycle: Int) {
            let bucket = row.bucket
            self.series = series
            self.cycle = cycle
            start = bucket.start.timeIntervalSince1970
            debit = bucket.deltaHundredths
            direct = bucket.coveredSeconds
            quiet = bucket.quietSeconds
            flags = bucket.flags
            imported = row.imported
            sample = bucket.latest
            let earlier = bucket.earlierCompanionSamples
            details = bucket.firstHit == nil && earlier.isEmpty ? nil
                : Details(firstHit: bucket.firstHit, companionSamples: earlier.isEmpty ? nil : earlier)
        }

        init(from decoder: Decoder) throws {
            var values = try decoder.unkeyedContainer()
            series = try values.decode(Int.self)
            cycle = try values.decode(Int.self)
            start = try values.decode(Double.self)
            debit = try values.decode(Int.self)
            direct = try values.decode(Double.self)
            quiet = try values.decode(Double.self)
            flags = try values.decode(QuotaBucketFlags.self)
            imported = try values.decode(Bool.self)
            if values.isAtEnd { sample = nil; details = nil; return }
            let date = Date(timeIntervalSince1970: start + (try values.decode(Double.self)))
            let used = try values.decode(Double.self)
            let source = try values.decode(QuotaSource.self)
            let attribution = try values.decode(QuotaAttribution.self)
            let companion = try values.decodeIfPresent(QuotaCapState.self) ?? .unknown
            let bindingWeekly = try values.decodeIfPresent(QuotaCapState.self) ?? .unknown
            let block = try values.decodeIfPresent(Date.self)
            sample = QuotaBucketSample(date: date, used: used, source: source, attribution: attribution,
                                       companion: companion, bindingWeekly: bindingWeekly, hardBlockUntil: block)
            details = try values.decodeIfPresent(Details.self)
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.unkeyedContainer()
            try values.encode(series)
            try values.encode(cycle)
            try values.encode(start)
            try values.encode(debit)
            try values.encode(direct)
            try values.encode(quiet)
            try values.encode(flags)
            try values.encode(imported)
            guard let sample else { return }
            try values.encode(sample.date.timeIntervalSince1970 - start)
            try values.encode(sample.used)
            try values.encode(sample.source)
            try values.encode(sample.attribution)
            let block = sample.hardBlockUntil
            if sample.companion != .unknown || sample.bindingWeekly != .unknown || block != nil || details != nil {
                try values.encode(sample.companion == .unknown ? nil : sample.companion)
            }
            if sample.bindingWeekly != .unknown || block != nil || details != nil {
                try values.encode(sample.bindingWeekly == .unknown ? nil : sample.bindingWeekly)
            }
            if block != nil || details != nil { try values.encode(block) }
            if let details { try values.encode(details) }
        }
    }

    struct DiskGap: Codable {
        let series: Int
        let cycle: Int
        let start: Date
        let end: Date
        let debit: Int
        let source: QuotaSource
        let attribution: QuotaAttribution
        let localized: Bool
        let canLocalizeToHour: Bool
        let imported: Bool
    }

    var manifestURL: URL { directory.appendingPathComponent("manifest.json") }

    func encode(_ shard: QuotaShard, ids: [QuotaSeries: Int]) throws -> Data {
        var cycles: [QuotaCycle] = []
        var index: [QuotaCycle: Int] = [:]
        func cycleID(_ cycle: QuotaCycle) -> Int {
            if let position = index[cycle] { return position }
            let id = cycles.count
            cycles.append(cycle)
            index[cycle] = id
            return id
        }
        let rows = shard.rows.values.map { row in
            DiskRow(row, series: ids[row.bucket.series]!, cycle: cycleID(row.bucket.cycle))
        }
        let gaps = shard.gaps.map { record in
            let gap = record.gap
            return DiskGap(series: ids[gap.series]!, cycle: cycleID(gap.cycle), start: gap.start, end: gap.end,
                           debit: gap.deltaHundredths, source: gap.source, attribution: gap.attribution,
                           localized: gap.localized, canLocalizeToHour: gap.canLocalizeToHour, imported: record.imported)
        }
        return try JSONEncoder().encode(DiskShard(version: Self.version, cycles: cycles.map(DiskRecord.init),
                                                  rows: rows.map(DiskRecord.init), gaps: gaps.map(DiskRecord.init)))
    }

    func boundedRead(_ url: URL, maximum: Int) -> Data? {
        guard maximum >= 0,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size <= maximum,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: size + 1), data.count == size else { return nil }
        return data
    }

    func safeName(_ file: String) -> Bool {
        file.hasPrefix("week-") && file.hasSuffix(".json") && file.utf8.count <= 80
            && file.utf8.allSatisfy { (45...57).contains($0) && $0 != 47 || (97...122).contains($0) }
    }

    func validSeries(_ series: QuotaSeries) -> Bool {
        (1...31_536_000).contains(series.meter.durationSeconds) && !series.plan.isEmpty && series.plan.utf8.count <= 80
            && !series.profile.rawValue.isEmpty && series.profile.rawValue.utf8.count <= 80
            && TimeZone(identifier: series.timeZoneID) != nil
    }

    func validCap(_ cap: QuotaCapState) -> Bool {
        if case .present(.active(let used, let reset)) = cap {
            return (0...100).contains(used) && UsageJSON.boundedDate(reset) != nil
        }
        return true
    }

    func valid(_ observation: QuotaObservation, for series: QuotaSeries, now: Date) -> Bool {
        observation.series == series && observation.normalized(now: now) == observation
            && validCap(observation.companion) && validCap(observation.bindingWeekly)
            && (observation.hardBlockUntil == nil || UsageJSON.boundedDate(observation.hardBlockUntil) != nil)
    }

    func validCycle(_ cycle: QuotaCycle, for series: QuotaSeries) -> Bool {
        UsageJSON.boundedDate(cycle.reset) != nil && UsageJSON.boundedDate(cycle.segmentStart) != nil
            && cycle.segmentStart < cycle.reset
            && cycle.reset.timeIntervalSince(cycle.segmentStart) <= Double(series.meter.durationSeconds) + QuotaObservation.calculatedResetTolerance
    }

    func decode(_ data: Data, week: Int, series: [Int: QuotaSeries]) -> (shard: QuotaShard, skippedRows: Bool)? {
        guard let disk = try? JSONDecoder().decode(DiskShard.self, from: data), disk.version == Self.version,
              disk.rows.count + disk.gaps.count <= limits.rows, disk.cycles.count <= disk.rows.count + disk.gaps.count else { return nil }
        var shard = QuotaShard()
        for record in disk.rows {
            guard let row = record.value else { continue }
            let start = Date(timeIntervalSince1970: row.start)
            guard let identity = series[row.series], disk.cycles.indices.contains(row.cycle),
                  let cycle = disk.cycles[row.cycle].value,
                  UsageJSON.boundedDate(start) != nil, Self.weekID(start) == week,
                  (0...10_000).contains(row.debit), row.direct >= 0, row.quiet >= 0,
                  row.direct + row.quiet <= Double(identity.meter.bucketSeconds) + 0.000_001,
                  (0..<64).contains(row.flags.rawValue) else { continue }
            let bucket = QuotaCalendarBuckets.interval(containing: start, timeZoneID: identity.timeZoneID,
                                                       seconds: identity.meter.bucketSeconds)
            let end = bucket.end
            guard start == bucket.start, row.direct + row.quiet <= bucket.duration + 0.000_001,
                  validCycle(cycle, for: identity), start < cycle.reset, end > cycle.segmentStart else { continue }
            func validSample(_ sample: QuotaBucketSample) -> Bool {
                (0...100).contains(sample.used) && start <= sample.date && sample.date < end
                    && sample.date >= cycle.segmentStart && sample.date < cycle.reset && validCap(sample.companion)
                    && validCap(sample.bindingWeekly)
                    && (sample.hardBlockUntil == nil || UsageJSON.boundedDate(sample.hardBlockUntil) != nil)
            }
            if let sample = row.sample {
                guard validSample(sample) else { continue }
            }
            let earlier = row.details?.companionSamples ?? []
            guard earlier.allSatisfy({ validSample($0) && $0.companion != .unknown }),
                  zip(earlier, earlier.dropFirst()).allSatisfy({ $0.date < $1.date }),
                  earlier.last.map({ $0.date < (row.sample?.date ?? .distantPast) }) ?? true else { continue }
            if let hit = row.details?.firstHit {
                guard row.flags.contains(.censored), hit >= max(start, cycle.segmentStart), hit < min(end, cycle.reset),
                      hit <= (row.sample?.date ?? .distantPast) else { continue }
            }
            let key = QuotaRowKey(series: identity, cycle: cycle, start: start)
            guard shard.rows[key] == nil else { continue }
            var stored = QuotaStoredRow(key, imported: row.imported)
            stored.apply(.init(key: key, debit: row.debit, direct: row.direct, quiet: row.quiet,
                               flags: row.flags, sample: row.sample))
            if let hit = row.details?.firstHit { stored.bucket.firstHit = hit }
            stored.bucket.earlierCompanionSamples = earlier
            shard.rows[key] = stored
        }
        for record in disk.gaps {
            guard let gap = record.value, let identity = series[gap.series], disk.cycles.indices.contains(gap.cycle),
                  let cycle = disk.cycles[gap.cycle].value,
                  UsageJSON.boundedDate(gap.start) != nil, UsageJSON.boundedDate(gap.end) != nil,
                  Self.weekID(gap.start) == week, gap.start < gap.end, (0...10_000).contains(gap.debit),
                  validCycle(cycle, for: identity), gap.start >= cycle.segmentStart, gap.end < cycle.reset else { continue }
            shard.gaps.append(.init(gap: QuotaGap(series: identity, cycle: cycle, start: gap.start, end: gap.end,
                                                deltaHundredths: gap.debit, source: gap.source,
                                                attribution: gap.attribution, localized: gap.localized,
                                                canLocalizeToHour: gap.canLocalizeToHour), imported: gap.imported))
        }
        return (shard, shard.count < disk.rows.count + disk.gaps.count)
    }

    func load() {
        guard !loaded else { return }
        loaded = true
        let now = clock()
        guard let data = boundedRead(manifestURL, maximum: manifestByteLimit),
              let saved = try? JSONDecoder().decode(Manifest.self, from: data),
              saved.version == Self.version, UUID(uuidString: saved.salt) != nil,
              saved.series.count <= limits.series, saved.files.count <= 17, saved.tracks.count <= limits.series,
              saved.logins.count <= 32, saved.imports.count <= limits.series,
              saved.series.values.allSatisfy(validSeries), Set(saved.series.values).count == saved.series.count else { return }
        manifest = saved
        for var track in saved.tracks {
            guard saved.series.values.contains(track.series), track.tail.count <= 16,
                  track.boundaries.count <= 32, UsageJSON.boundedDate(track.cutoff) != nil,
                  track.tail.allSatisfy({ valid($0, for: track.series, now: now) }),
                  zip(track.tail, track.tail.dropFirst()).allSatisfy({ $0.date < $1.date }),
                  track.boundaries.allSatisfy({ UsageJSON.boundedDate($0.date) != nil }),
                  (-1...1).contains(track.cursor.carry), (0...100).contains(track.cursor.highWater) else { continue }
            if let previous = track.cursor.previous {
                guard valid(previous, for: track.series, now: now), let cycle = track.cursor.cycle,
                      validCycle(cycle, for: track.series), cycle.segmentStart <= previous.date, previous.date < cycle.reset,
                      track.tail.first.map({ previous.date < $0.date }) ?? true else { continue }
            }
            if let anchor = track.apiAnchor, !valid(anchor, for: track.series, now: now) || anchor.source != .api {
                track.apiAnchor = nil
            }
            if track.cursor.previous?.attribution == .provisional { track.cursor = QuotaCursor() }
            track.tail.removeAll { $0.attribution == .provisional }
            tracks[track.series] = track
        }
        var bytesLeft = limits.bytes - data.count
        for (week, file) in saved.files.sorted(by: { $0.key > $1.key }) {
            if file.bytes > 0, file.bytes <= bytesLeft, safeName(file.name),
               let bytes = boundedRead(directory.appendingPathComponent(file.name), maximum: file.bytes),
               bytes.count == file.bytes, let decoded = decode(bytes, week: week, series: saved.series),
               decoded.shard.count <= limits.rows - totalCount {
                shards[week] = decoded.shard
                totalCount += decoded.shard.count
                bytesLeft -= bytes.count
                if decoded.skippedRows {
                    dirty.insert(week)
                    scheduleFlush()
                    report("usage forecast: skipped damaged history rows")
                }
            } else {
                dirty.insert(week)
                manifest.imports.removeAll()
                // Replaying the trusted tail after a damaged shard must never recreate intervals
                // from a baseline whose persisted coverage is now missing.
                for series in Array(tracks.keys) where tracks[series]?.cursor.previous.map({ Self.weekID($0.date) == week }) == true {
                    tracks[series]?.cursor = QuotaCursor()
                }
                scheduleFlush()
                report("usage forecast: skipped a damaged history shard")
            }
        }
        if saved.fileScopedImports != true || saved.importRevision != Self.importRevision {
            // Prior imports cannot prove file-level identity, or predate the current importer. Rebuild them.
            for week in Array(shards.keys) {
                guard var shard = shards[week] else { continue }
                let oldCount = shard.count
                shard.rows = shard.rows.filter { !$0.value.imported }
                shard.gaps.removeAll { $0.imported }
                if shard.count != oldCount {
                    totalCount += shard.count - oldCount
                    shards[week] = shard
                    dirty.insert(week)
                }
            }
            manifest.imports.removeAll()
            manifest.fileScopedImports = true
            manifest.importRevision = Self.importRevision
            scheduleFlush()
        }
        prune(now: now)
        if changed { scheduleFlush() }
        removeUnusedFiles(keeping: Set(saved.files.values.map(\.name)))
    }

    var manifestByteLimit: Int { min(limits.bytes, 512 * 1_024) }

    func writeAtomically(_ data: Data, to destination: URL) throws {
        let staging = directory.appendingPathComponent(".pending-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: staging) }
        try data.write(to: staging, options: .withoutOverwriting)
        let handle = try FileHandle(forWritingTo: staging)
        defer { try? handle.close() }
        try handle.synchronize()
        guard rename(staging.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    func write() -> Bool {
        let now = clock()
        for series in Array(tracks.keys) { drainTail(series, through: now.addingTimeInterval(-120)) }
        prune(now: now)
        guard changed || !dirty.isEmpty else { return true }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var encoded: [Int: Data] = [:]
            var next = manifest
            var header = Data()
            while true {
                let keys = Set(shards.values.flatMap { $0.rows.keys.map(\.series) + $0.gaps.map { $0.gap.series } })
                    .union(tracks.keys)
                next = manifest
                next.series = manifest.series.filter { keys.contains($0.value) }
                var ids = Dictionary(uniqueKeysWithValues: next.series.map { ($0.value, $0.key) })
                for key in keys where ids[key] == nil {
                    let id = (0...).first { next.series[$0] == nil }!
                    next.series[id] = key
                    ids[key] = id
                }
                next.tracks = Array(tracks.values)
                let retained = Set(keys.map { QuotaImportKey(profile: $0.profile, timeZoneID: $0.timeZoneID) })
                // Profiles without quota observations do not need a lasting import completion marker.
                let ready = pendingImports.compactMap { $0.value.cancelled() ? nil : $0.key }
                next.imports = manifest.imports.union(ready).intersection(retained)
                encoded.removeAll(keepingCapacity: true)
                for week in dirty {
                    guard let shard = shards[week], shard.count > 0 else { next.files[week] = nil; continue }
                    let bytes = try encode(shard, ids: ids)
                    encoded[week] = bytes
                    let name = "week-\(week)-\(UUID().uuidString.lowercased()).json"
                    next.files[week] = ShardFile(name: name, bytes: bytes.count)
                }
                header = try JSONEncoder().encode(next)
                let size = next.files.values.reduce(header.count) { $0 + $1.bytes }
                if size <= limits.bytes && header.count <= manifestByteLimit { break }
                if totalCount > 0 {
                    dropOldest(max(1, totalCount / 8))
                } else if let oldest = tracks.min(by: { ($0.value.latest?.date ?? .distantPast) < ($1.value.latest?.date ?? .distantPast) }) {
                    tracks[oldest.key] = nil
                } else if let oldest = manifest.logins.min(by: { $0.value.lastSeen < $1.value.lastSeen })?.key {
                    manifest.logins[oldest] = nil
                } else { return false }
            }
            // Keep the old generation readable until every new shard and its index are installed.
            for (week, data) in encoded {
                try writeAtomically(data, to: directory.appendingPathComponent(next.files[week]!.name))
            }
            try writeAtomically(header, to: manifestURL)
            manifest = next
            dirty.removeAll()
            let completed = pendingImports.filter { next.imports.contains($0.key) }.map(\.value)
            pendingImports.removeAll()
            changed = false
            removeUnusedFiles(keeping: Set(next.files.values.map(\.name)))
            for pending in completed {
                DispatchQueue.global(qos: .utility).async { if !pending.cancelled() { pending.updated() } }
            }
            return true
        } catch {
            removeUnusedFiles(keeping: Set(manifest.files.values.map(\.name)))
            report("usage forecast: history write failed")
            return false
        }
    }

    func removeUnusedFiles(keeping names: Set<String>) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files {
            let name = file.lastPathComponent
            let staged = name.hasPrefix(".pending-") && name.hasSuffix(".tmp")
                && UUID(uuidString: String(name.dropFirst(9).dropLast(4))) != nil
            if staged || (safeName(name) && !names.contains(name)) { try? FileManager.default.removeItem(at: file) }
        }
    }
}

import Foundation

/// Translates capture-only parser metadata into canonical quota identities shared by live and archive reads.
enum UsageQuotaCapture {
    struct AnchorKey: Hashable {
        let scope: QuotaMeterScope
        let reset: Date
    }

    private struct Candidate {
        var meter: QuotaMeter
        var used: Double?
        var reset: Date?
        var date: Date
        var calculated: Bool
        var inactive: Bool
        var plan: String?
    }

    static func plan(_ value: String?) -> String? {
        guard let plan = value?.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "_" }).joined(separator: "_"),
              !plan.isEmpty, plan.utf8.count <= 80,
              plan.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }) else { return nil }
        return plan
    }

    private static func scope(_ id: String, provider: UsageProvider) -> QuotaMeterScope? {
        guard id.utf8.count <= 180 else { return nil }
        if provider == .codex {
            if id == "shared" { return .shared }
            if id.hasPrefix("model:") { return .modelID(String(id.dropFirst(6))) }
            return nil
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

    static func observations(_ reading: UsageReading, provider: UsageProvider, profile: QuotaProfileID, timeZoneID: String,
                             source: QuotaSource, attribution: QuotaAttribution, now: Date,
                             fallbackPlan: String? = nil, anchors: [AnchorKey: [QuotaObservation]] = [:]) -> [QuotaObservation] {
        guard let payload = reading.quota else { return [] }
        let plan = plan(payload.plan) ?? plan(reading.plan) ?? plan(fallbackPlan)
        let candidates: [Candidate] = payload.windows.compactMap { window in
            guard let scope = scope(window.id, provider: provider) else { return nil }
            let duration = window.durationMinutes.map { $0 * 60 }
            if let duration, !(1...31_536_000).contains(duration) { return nil }
            var seconds = duration.map { Int($0.rounded()) }
            var attributedPlan = plan
            if (seconds == nil || attributedPlan == nil), let reset = window.reset, let used = window.used,
               (0...100).contains(used), !window.calculated {
                let epoch = Date(timeIntervalSince1970: reset.timeIntervalSince1970.rounded(.down))
                let matching = Set((anchors[AnchorKey(scope: scope, reset: epoch)] ?? []).filter { anchor in
                    anchor.series.profile == profile && anchor.series.provider == provider && anchor.series.timeZoneID == timeZoneID
                        && anchor.series.meter.scope == scope && (seconds == nil || seconds == anchor.series.meter.durationSeconds)
                        && (attributedPlan == nil || attributedPlan == anchor.series.plan) && anchor.resetKind == .explicit
                        && window.date <= anchor.date && used <= anchor.used + 1
                }.map(\.series))
                if matching.count == 1, let anchor = matching.first {
                    seconds = anchor.meter.durationSeconds
                    attributedPlan = anchor.plan
                }
            }
            guard let seconds else { return nil }
            return Candidate(meter: QuotaMeter(scope: scope, durationSeconds: seconds), used: window.used,
                             reset: window.reset, date: window.date, calculated: window.calculated,
                             inactive: window.inactive, plan: attributedPlan)
        }
        let meters = Dictionary(grouping: candidates, by: \.meter)
        func cap(duration: Int, for candidate: Candidate, applicability: UsageReading.Applicability) -> QuotaCapState {
            let scoped = QuotaMeter(scope: candidate.meter.scope, durationSeconds: duration)
            let shared = QuotaMeter(scope: .shared, durationSeconds: duration)
            let matching = meters[scoped] ?? meters[shared] ?? []
            if matching.count == 1, let meter = matching.first {
                guard meter.date == candidate.date else { return .present(.unknown) }
                if meter.inactive { return .present(.inactive) }
                if let used = meter.used, let reset = meter.reset, (0...100).contains(used),
                   meter.date < reset, reset.timeIntervalSince(meter.date) <= Double(duration) {
                    return .present(.active(used: used, reset: reset))
                }
                return .present(.unknown)
            }
            if matching.count > 1 { return .present(.unknown) }
            switch applicability {
            case .absent: return .absent
            case .present: return .present(.unknown)
            case .inactive: return .present(.inactive)
            case .unknown: return .unknown
            }
        }
        return candidates.compactMap { candidate in
            guard meters[candidate.meter]?.count == 1, !candidate.inactive, let plan = candidate.plan,
                  let used = candidate.used, let reset = candidate.reset else { return nil }
            let series = QuotaSeries(provider: provider, profile: profile, plan: plan, meter: candidate.meter, timeZoneID: timeZoneID)
            let short = candidate.meter.durationSeconds == 18_000
            return QuotaObservation(series: series, date: candidate.date, used: used, reset: reset, source: source,
                                    resetKind: candidate.calculated ? .calculated : .explicit, attribution: attribution,
                                    companion: short ? .unknown : cap(duration: 18_000, for: candidate, applicability: payload.short),
                                    bindingWeekly: short ? cap(duration: 604_800, for: candidate, applicability: payload.weekly) : .unknown,
                                    hardBlockUntil: payload.hardBlockUntil.flatMap { $0 > candidate.date ? $0 : nil }).normalized(now: now)
        }
    }

    static func anchorIndex(_ observations: [QuotaObservation]) -> [AnchorKey: [QuotaObservation]] {
        var newest: [AnchorKey: [QuotaSeries: QuotaObservation]] = [:]
        for observation in observations where observation.resetKind == .explicit && observation.attribution != .provisional {
            let key = AnchorKey(scope: observation.series.meter.scope, reset: observation.reset)
            let prior = newest[key]?[observation.series]
            if prior == nil || observation.date > prior!.date {
                newest[key, default: [:]][observation.series] = observation
            }
        }
        return newest.mapValues { Array($0.values) }
    }
}

/// Bounded two-pass reader for the resolved active Codex sessions directory.
///
/// Every rollout is streamed whole, plain (`.jsonl`) or compressed by Codex (`.jsonl.zst`, decoded by `ZstdReader`
/// one block at a time), and a cheap byte pre-filter parses only lines that can be quota events.
/// Completeness is tracked per file, so an unreadable, oversized-event or budget-cut file only withholds its own
/// unlabeled rows and never the rest of the archive.
final class UsageCodexBackfill {
    struct Limits {
        var files = 4_096
        var bytes = 16 * 1_024 * 1_024 * 1_024
        var maxLineBytes = 256 * 1_024
        var observations = 200_000
        /// Wall-clock budget of the first (publish early) pass.
        var elapsed: TimeInterval = 5
        /// Wall-clock budget of the second, idle-time pass that finishes the archive. Decoding compressed rollouts
        /// makes a heavy 16-week archive about 10 GB of lines (~2 min of one utility core); it runs once per import.
        var finalElapsed: TimeInterval = 240
        var slice: TimeInterval = 0.05
        /// Idle time between slices, so a long archive never monopolizes a core.
        var pause: TimeInterval = 0.01
        var chunkBytes = 512 * 1_024
        /// Decoded bytes read from one compressed rollout before it is left incomplete.
        var maxDecodedBytes = 4 * 1_024 * 1_024 * 1_024
        /// Largest zstd window accepted (memory per open compressed rollout is about twice this).
        var maxWindowBytes = 16 * 1_024 * 1_024
    }

    struct Candidate {
        enum Provenance {
            /// The event names the active account.
            case identified
            /// Unlabeled, and no foreign identity exists anywhere in the scanned archive (a one-account home).
            case unlabeledSingleAccount
            /// Unlabeled in an archive that does contain foreign identities: needs a clean scan and a live match.
            case unlabeledStrict
        }

        let reading: UsageReading
        let provenance: Provenance
        var identified: Bool { provenance == .identified }
        fileprivate let file: Int
    }

    private struct FileScan {
        var day: Int
        var first = Date.distantFuture
        var last = Date.distantPast
        var foreign = false
        /// What the opening `session_meta` record says about the whole file.
        var creator = UsageJSON.CodexRollout.Identity.unlabeled
        /// A row contradicts the creator (one names the active account, the other another one): no row is kept.
        var conflict = false
        /// Read to the end without a read error.
        var finished = false
        /// An event may be hidden: a budget cut it, or an oversized line looks like a quota event.
        var hidden = false
        var complete: Bool { finished && !hidden }

        mutating func observe(_ date: Date) {
            first = min(first, date)
            last = max(last, date)
        }
    }

    struct Pass {
        let candidates: [Candidate]
        // Offline replay never writes to production history. Rows of files that contradict their creator are left out.
        let replayCandidates: [Candidate]
        /// Some file was read incompletely, or the archive was not exhausted by the final pass.
        let truncated: Bool
        let moreFiles: Bool
        let files: Int
        let incompleteFiles: Int
        let incompleteDays: Int
        /// Compressed rollouts (`.jsonl.zst`) opened; they count in `files` like plain ones.
        let compressedFiles: Int
        let foreignSeen: Bool
        /// Bytes scanned for lines: file bytes for plain rollouts, decoded bytes for compressed ones.
        let bytesRead: Int
        /// Bytes read from disk for compressed rollouts.
        let compressedBytesRead: Int
        /// Lines that passed the byte pre-filter and were JSON-parsed.
        let parsedLines: Int
    }

    private struct FileCursor {
        let handle: FileHandle
        /// Plain rollouts: bytes left of the size seen at open. Compressed ones: decoded bytes still allowed.
        var remaining: Int
        var zstd: ZstdReader?
        var skipping = false
        var line = Data()
        /// The next complete line is the file's first one, where Codex writes `session_meta`.
        var atStart = true
    }

    private static let eventMarker: StaticString = "\"token_count\""
    private static let metaMarker: StaticString = "\"session_meta\""
    private static let limitsMarker: StaticString = "rate_limits"

    private let queue = DispatchQueue(label: "local.cala.usage.backfill", qos: .utility)
    private let root: URL
    private let now: Date
    private let calendar: Calendar
    private let account: QuotaAccount?
    private let limits: Limits
    private let cancelled: () -> Bool
    private var days: [Int: FileManager.DirectoryEnumerator] = [:]
    private var paths: [URL] = []
    private var exhaustedDays = Set<Int>()
    private var nextDay = 0
    private var cursor: FileCursor?
    private var files: [FileScan] = []
    private var compressed = 0
    private var compressedBytes = 0
    private var readings: [Candidate] = []
    private var meterCount = 0
    private var completedPasses = 0
    private var active = false
    private var passStart = 0.0
    private var passFiles = 0
    private var passBytes = 0
    private var totalBytes = 0
    private var parsedLines = 0

    init(sessionsRoot: URL, now: Date, calendar: Calendar, account: QuotaAccount?, limits: Limits = Limits(),
         cancelled: @escaping () -> Bool = { false }) {
        root = sessionsRoot.resolvingSymlinksInPath().standardizedFileURL
        self.now = now
        self.calendar = calendar
        self.account = account
        self.limits = limits
        self.cancelled = cancelled
    }

    func scanNextPass(_ finish: @escaping (Pass) -> Void) {
        queue.async {
            guard !self.active, self.completedPasses < 2, !self.cancelled() else { return }
            self.active = true
            self.passStart = ProcessInfo.processInfo.systemUptime
            self.passFiles = 0
            self.passBytes = 0
            if self.completedPasses == 0 {
                self.paths = (0..<112).compactMap { offset in
                    guard let date = self.calendar.date(byAdding: .day, value: -offset, to: self.now) else { return nil }
                    let parts = self.calendar.dateComponents([.year, .month, .day], from: date)
                    guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
                    return self.root.appendingPathComponent(String(format: "%04d/%02d/%02d", year, month, day))
                }
            }
            self.scanSlice(finish)
        }
    }

    private func scanSlice(_ finish: @escaping (Pass) -> Void) {
        let end = ProcessInfo.processInfo.systemUptime + limits.slice
        let budget = completedPasses == 0 ? limits.elapsed : limits.finalElapsed
        while ProcessInfo.processInfo.systemUptime < end {
            if cancelled() { close(); days.removeAll(); readings.removeAll(); active = false; return }
            let overBudget = passBytes >= limits.bytes || meterCount >= limits.observations
                || ProcessInfo.processInfo.systemUptime - passStart >= budget
            let more = exhaustedDays.count < paths.count || cursor != nil
            if overBudget || (cursor == nil && (passFiles >= limits.files || !more)) {
                active = false
                completedPasses += 1
                let incomplete = files.filter { !$0.complete }
                let pass = Pass(candidates: eligibleReadings(more: more), replayCandidates: trusted,
                                truncated: !incomplete.isEmpty || (more && completedPasses == 2),
                                moreFiles: more, files: files.count, incompleteFiles: incomplete.count,
                                incompleteDays: Set(incomplete.map(\.day)).count, compressedFiles: compressed,
                                foreignSeen: files.contains(where: \.foreign), bytesRead: totalBytes,
                                compressedBytesRead: compressedBytes, parsedLines: parsedLines)
                if completedPasses == 2 || !more { close(); days.removeAll(); readings.removeAll() }
                finish(pass)
                return
            }
            if cursor != nil { readChunk() }
            else { searchDay() }
        }
        queue.asyncAfter(deadline: .now() + limits.pause) { self.scanSlice(finish) }
    }

    private func searchDay() {
        while exhaustedDays.contains(nextDay) { nextDay = (nextDay + 1) % paths.count }
        // A bounded turn per day before advancing the round-robin, including for non-rollout files.
        let path = paths[nextDay]
        if days[nextDay] == nil {
            let resolved = path.resolvingSymlinksInPath().standardizedFileURL
            if resolved.path == path.path {
                days[nextDay] = FileManager.default.enumerator(at: path, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                                                               options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles])
            }
        }
        let day = nextDay
        nextDay = (nextDay + 1) % paths.count
        if let enumerator = days[day], let file = enumerator.nextObject() as? URL {
            let name = file.lastPathComponent
            guard name.hasPrefix("rollout-") else { return }
            let zstd = file.pathExtension == "zst"
            guard file.pathExtension == "jsonl" || (zstd && file.deletingPathExtension().pathExtension == "jsonl") else { return }
            passFiles += 1
            if zstd { compressed += 1 }
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else {
                files.append(FileScan(day: day))
                return
            }
            open(file, day: day, compressed: zstd)
        } else {
            days[day] = nil
            exhaustedDays.insert(day)
        }
    }

    private func open(_ url: URL, day: Int, compressed: Bool) {
        files.append(FileScan(day: day))
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        if compressed {
            var zstdLimits = ZstdReader.Limits()
            zstdLimits.maxWindow = limits.maxWindowBytes
            zstdLimits.inputChunk = limits.chunkBytes
            cursor = FileCursor(handle: handle, remaining: limits.maxDecodedBytes, zstd: ZstdReader(handle: handle, limits: zstdLimits))
            return
        }
        do {
            let size = try handle.seekToEnd()
            try handle.seek(toOffset: 0)
            cursor = FileCursor(handle: handle, remaining: Int(min(size, UInt64(Int.max))))
            if size == 0 { finishFile() }
        } catch { try? handle.close() }
    }

    private func finishFile() {
        // A non-newline-terminated tail is an unfinished record, not a hidden one.
        files[files.count - 1].finished = true
        close()
    }

    private func readChunk() {
        guard var file = cursor else { return }
        let count = min(limits.chunkBytes, file.remaining, limits.bytes - passBytes)
        if let zstd = file.zstd {
            guard count > 0 else {
                // The decoded-size cap or the pass budget stops before the end, so events may be hidden.
                files[files.count - 1].hidden = true
                close()
                return
            }
            let before = zstd.compressedBytes
            let decoded = try? zstd.read(upTo: count)
            compressedBytes += zstd.compressedBytes - before
            // A corrupt, truncated or unsupported frame leaves the file incomplete; an empty read is a clean end only
            // once the reader says so (otherwise it only skipped empty blocks and the slice loop calls again).
            guard let data = decoded else { close(); return }
            if data.isEmpty {
                if zstd.finished { finishFile() } else { cursor = file }
                return
            }
            file.remaining = max(0, file.remaining - data.count)
            passBytes += data.count
            totalBytes += data.count
            consume(data, file: &file)
            cursor = file
            if meterCount >= limits.observations {
                files[files.count - 1].hidden = true
                close()
            }
            return
        }
        guard count > 0, let data = try? file.handle.read(upToCount: count), !data.isEmpty else {
            // A read error or an externally truncated file leaves the file incomplete.
            close()
            return
        }
        file.remaining -= data.count
        passBytes += data.count
        totalBytes += data.count
        consume(data, file: &file)
        cursor = file
        if meterCount >= limits.observations && file.remaining > 0 {
            files[files.count - 1].hidden = true
            close()
        } else if file.remaining == 0 { finishFile() }
    }

    /// Splits a chunk into lines with `memchr`, parsing only candidates that pass the substring pre-filter.
    private func consume(_ data: Data, file: inout FileCursor) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count && meterCount < limits.observations && !cancelled() {
                let start = base + offset
                let newline = memchr(start, 10, raw.count - offset)
                let length = newline.map { start.distance(to: UnsafeRawPointer($0)) } ?? raw.count - offset
                let segment = UnsafeRawBufferPointer(start: start, count: length)
                if file.skipping {
                    // Remainder of an oversized line.
                } else if file.line.isEmpty && newline != nil && length <= limits.maxLineBytes {
                    line(segment, file: &file)
                } else if file.line.count + length > limits.maxLineBytes {
                    file.line.append(contentsOf: segment.prefix(max(0, limits.maxLineBytes - file.line.count)))
                    // A genuine quota event is small. An oversized line is skipped, but one that opens like an
                    // event could hide an identity or reading, so its file stops counting as complete. An oversized
                    // first line leaves the file without a creator, so its rows stay unlabeled.
                    file.line.withUnsafeBytes(oversized)
                    file.line.removeAll(keepingCapacity: true)
                    file.skipping = newline == nil
                    file.atStart = false
                } else {
                    file.line.append(contentsOf: segment)
                    if newline != nil {
                        let complete = file.line
                        complete.withUnsafeBytes { line($0, file: &file) }
                        file.line.removeAll(keepingCapacity: true)
                    }
                }
                if newline != nil { file.skipping = false }
                offset += length + 1
            }
            // A budget, cap or cancellation stop leaves unread lines behind.
            if offset < raw.count { files[files.count - 1].hidden = true }
        }
    }

    private static func contains(_ bytes: UnsafeRawBufferPointer, _ marker: StaticString) -> Bool {
        guard let base = bytes.baseAddress, bytes.count >= marker.utf8CodeUnitCount else { return false }
        return memmem(base, bytes.count, marker.utf8Start, marker.utf8CodeUnitCount) != nil
    }

    private func isCandidate(_ bytes: UnsafeRawBufferPointer) -> Bool {
        Self.contains(bytes, Self.eventMarker) && Self.contains(bytes, Self.limitsMarker)
    }

    private func oversized(_ bytes: UnsafeRawBufferPointer) {
        if isCandidate(bytes) { files[files.count - 1].hidden = true }
    }

    private func line(_ bytes: UnsafeRawBufferPointer, file: inout FileCursor) {
        if file.atStart {
            file.atStart = false
            creator(bytes)
        }
        consider(bytes)
    }

    /// Reads the creator that Codex's opening `session_meta` record names; it applies to every row of the file.
    private func creator(_ bytes: UnsafeRawBufferPointer) {
        guard Self.contains(bytes, Self.metaMarker), let base = bytes.baseAddress,
              let object = UsageJSON.object(Data(bytes: base, count: bytes.count)),
              let ids = UsageJSON.codexSessionCreator(object) else { return }
        let file = files.count - 1
        let identity = UsageJSON.CodexRollout.creatorIdentity(account: ids.account, user: ids.user, active: account)
        files[file].creator = identity
        if identity == .foreign {
            files[file].foreign = true
            // The session's start bounds the span another account was in use.
            if let date = UsageJSON.date(object["timestamp"]) { files[file].observe(date) }
        }
    }

    private func consider(_ bytes: UnsafeRawBufferPointer) {
        guard isCandidate(bytes), let base = bytes.baseAddress else { return }
        parsedLines += 1
        guard let object = UsageJSON.object(Data(bytes: base, count: bytes.count)) else { return }
        append(object)
    }

    private func append(_ object: [String: Any]) {
        let file = files.count - 1
        if let date = UsageJSON.date(object["timestamp"]) { files[file].observe(date) }
        let ids = UsageJSON.rolloutIDs(object)
        let row = UsageJSON.CodexRollout.identity(accounts: ids.accounts, subjects: ids.subjects, active: account)
        let creator = files[file].creator
        let identity = UsageJSON.CodexRollout.combined(row, creator)
        // A row that contradicts its file's creator fails closed: none of the file's rows is kept. (Rows that name
        // the active account themselves stay trusted beside foreign-labeled rows, as before.)
        if identity == .foreign {
            if (creator == .matching && row == .foreign) || (creator == .foreign && row == .matching) { files[file].conflict = true }
            files[file].foreign = true
            return
        }
        guard let event = UsageJSON.codexRollout(object, ids: ids),
              event.reading.date >= now.addingTimeInterval(-UsageQuotaHistory.retention),
              event.reading.date <= now.addingTimeInterval(5) else { return }
        guard let payload = event.reading.quota, !payload.windows.isEmpty else { return }
        guard meterCount + payload.windows.count <= limits.observations else { files[file].hidden = true; meterCount = limits.observations; return }
        meterCount += payload.windows.count
        var reading = event.reading
        reading.windows.removeAll()
        readings.append(Candidate(reading: reading, provenance: identity == .matching ? .identified : .unlabeledStrict, file: file))
    }

    /// Rows of files that do not contradict their `session_meta` creator. A row is labeled by its own ids or its file's creator.
    private var trusted: [Candidate] { readings.filter { !files[$0.file].conflict } }

    /// Decides which rows may leave the importer.
    ///
    /// - Labeled rows always pass, unless their file contradicts its `session_meta` creator.
    /// - With no foreign identity in the scanned archive, every unlabeled row of a completely read file passes as
    ///   `unlabeledSingleAccount`. Other files, complete or not, cannot be poisoned by an incomplete one.
    /// - Once any foreign identity exists, only a fully exhausted, fully read scan can keep unlabeled rows, and only
    ///   from files and times that no foreign session overlaps.
    private func eligibleReadings(more: Bool) -> [Candidate] {
        let foreign = files.filter(\.foreign)
        if foreign.isEmpty {
            return trusted.compactMap { candidate in
                guard candidate.identified || files[candidate.file].complete else { return nil }
                return Candidate(reading: candidate.reading,
                                 provenance: candidate.identified ? .identified : .unlabeledSingleAccount, file: candidate.file)
            }
        }
        // A skipped file, oversized event or unfinished scan can hide both an identity and its span.
        guard !more, files.allSatisfy(\.complete), !foreign.contains(where: { $0.first > $0.last }) else {
            return trusted.filter(\.identified)
        }
        // Sweep the foreign spans once, including endpoints shared by concurrent sessions.
        let spans = foreign.sorted { $0.first < $1.first }
        var next = 0
        var foreignUntil = Date.distantPast
        return trusted.sorted { $0.reading.date < $1.reading.date }.filter { candidate in
            let date = candidate.reading.date
            while next < spans.count && spans[next].first <= date {
                foreignUntil = max(foreignUntil, spans[next].last)
                next += 1
            }
            return candidate.identified || (!files[candidate.file].foreign && date > foreignUntil)
        }
    }

    private func close() {
        try? cursor?.handle.close()
        cursor = nil
    }

    /// Unlabeled history always stays provisional (it can feed the early estimate but never an alert).
    ///
    /// In an archive that contains no foreign identity, unlabeled rows of the same cycle as a fresh API sample must
    /// continue it (non-decreasing within rounding); every other cycle is accepted as the one account's history.
    /// Once any foreign identity exists, unlabeled rows need a same-meter, same-cycle match with a fresh API sample.
    static func attributed(_ candidates: [Candidate], key: QuotaImportKey, anchors: [QuotaObservation],
                           switchedAt: Date?, now: Date) -> [QuotaObservation] {
        attribute(candidates, key: key, anchors: anchors, switchedAt: switchedAt, now: now).observations
    }

    /// What `attribute` decided about the unlabeled history.
    struct Attribution {
        let observations: [QuotaObservation]
        /// The account judgement applied to the unlabeled rows.
        let timeline: AccountTimeline
        /// The history shows several accounts and no fresh live API reading exists at all (of any series), so nothing
        /// of it was kept. The import must not be marked complete: re-attributing the same candidates once a live
        /// reading arrives can still keep the live cycle. A fresh reading whose series never appears in the
        /// archive is a final answer, not a reason to wait.
        let awaitsLiveReading: Bool
        var mixed: Bool { timeline.mixed }
    }

    static func attribute(_ candidates: [Candidate], key: QuotaImportKey, anchors: [QuotaObservation],
                          switchedAt: Date?, now: Date) -> Attribution {
        let fresh = anchors.filter { now.timeIntervalSince($0.date) <= ($0.series.meter.durationSeconds == 18_000 ? 600 : 1_800)
            && $0.date <= now.addingTimeInterval(5) && $0.reset > now }
        func capture(_ candidate: Candidate, anchors: [UsageQuotaCapture.AnchorKey: [QuotaObservation]]) -> [QuotaObservation] {
            let reading = candidate.reading
            let identified = candidate.identified
            guard identified || reading.date >= (switchedAt ?? .distantPast) else { return [] }
            return UsageQuotaCapture.observations(reading, provider: .codex, profile: key.profile, timeZoneID: key.timeZoneID,
                                                  source: .rollout, attribution: identified ? .verifiedArchive : .provisional,
                                                  now: now, anchors: anchors)
        }
        let labeled = candidates.filter(\.identified)
        let verifiedAnchors = UsageQuotaCapture.anchorIndex(fresh + labeled.flatMap { capture($0, anchors: [:]) })
        let observations = candidates.filter { $0.provenance != .unlabeledSingleAccount }.flatMap { candidate in
            capture(candidate, anchors: verifiedAnchors)
        }
        let grouped = Dictionary(grouping: observations, by: \.series)
        var result = grouped.flatMap { series, rows -> [QuotaObservation] in
            let lived = fresh.first { $0.series == series && $0.date >= (switchedAt ?? .distantPast) }
            let archivalAnchor = lived.flatMap { live in
                rows.filter { $0.date <= live.date && $0.date >= (switchedAt ?? .distantPast)
                    && abs($0.reset.timeIntervalSince(live.reset)) <= QuotaObservation.explicitResetJitter
                    && $0.resetKind == .explicit }
                    .max { $0.date == $1.date ? $0.used < $1.used : $0.date < $1.date }
            }
            let compatible: Bool
            if let lived, let archivalAnchor, lived.resetKind == .explicit {
                compatible = archivalAnchor.used <= lived.used + 1
            } else { compatible = false }
            return rows.filter { row in
                row.attribution == .verifiedArchive || compatible
            }
        }

        let single = candidates.filter { $0.provenance == .unlabeledSingleAccount }.flatMap { candidate in
            capture(candidate, anchors: verifiedAnchors)
        }
        // Unlabeled rows only stand for one account while their cycles could belong to one account.
        let timeline = AccountTimeline(single)
        let mixed = timeline.mixed
        let verified = Dictionary(grouping: observations.filter { $0.attribution == .verifiedArchive }, by: \.series)
        func sameCycle(_ row: QuotaObservation, _ reset: Date) -> Bool {
            abs(row.reset.timeIntervalSince(reset)) <= QuotaObservation.explicitResetJitter
        }
        for (series, rows) in Dictionary(grouping: single, by: \.series) {
            let lived = fresh.first { $0.series == series && $0.date >= (switchedAt ?? .distantPast) && $0.resetKind == .explicit }
            let cycle = lived.map { live in rows.filter { sameCycle($0, live.reset) } } ?? []
            // Other cycles cannot be tied to the live account once the archive shows more than one account.
            if !mixed { result.append(contentsOf: rows.filter { row in lived.map { !sameCycle(row, $0.reset) } ?? true }) }
            guard let lived, !cycle.isEmpty else { continue }
            // The live reading and the labeled rows of the cycle join the unlabeled ones in one time-ordered series.
            let points = (cycle + (verified[series] ?? []).filter { sameCycle($0, lived.reset) } + [lived])
                .filter { $0.resetKind == .explicit }
                .sorted { $0.date == $1.date ? $0.used < $1.used : $0.date < $1.date }
            var high = 0.0
            var continuous = true
            for point in points {
                if point.used < high - 1 { continuous = false; break }
                high = max(high, point.used)
            }
            if continuous { result.append(contentsOf: cycle) }
        }
        return Attribution(observations: result, timeline: timeline, awaitsLiveReading: mixed && fresh.isEmpty)
    }

    /// Unlabeled history describes more than one account when its cycles keep interleaving.
    ///
    /// One account has one window per meter: a new cycle normally starts once the previous one reset, and it never
    /// goes back to an older reset. Resets within `explicitResetJitter` are one cycle.
    ///
    /// - A return to a cycle that a later one replaced counts only when the old cycle is still written
    ///   `returnGrace` after the new one first appeared. Concurrent sessions that started earlier write their cached,
    ///   older snapshot for seconds after a reset; such blips are one account.
    /// - An early start whose new cycle is a fresh window (at most `restartUsed` used, `resets_at` within
    ///   `restartTolerance` of the reading plus the window length) is a restart of the same account's window, such as
    ///   a provider reset, and is only counted in `restarts`.
    /// - Other early starts are tolerated once (a provider-wide reset seen late); two are several accounts. Early
    ///   starts within `earlyStartWindow` of each other, even on different meters, are one event: a provider-wide
    ///   reset that finds a 5-hour and a weekly window open starts both early at once.
    static func accountTimeline(_ candidates: [Candidate], key: QuotaImportKey, now: Date) -> AccountTimeline {
        AccountTimeline(candidates.filter { !$0.identified }.flatMap { candidate in
            UsageQuotaCapture.observations(candidate.reading, provider: .codex, profile: key.profile, timeZoneID: key.timeZoneID,
                                           source: .rollout, attribution: .provisional, now: now)
        })
    }

    struct AccountTimeline {
        /// Early starts of a new cycle while the previous one had not reset yet, counted per event. Fresh restarts
        /// are not included.
        private(set) var earlyStarts = 0
        /// Early starts that opened a fresh window: the same account's window restarted.
        private(set) var restarts = 0
        static let earlyStartWindow: TimeInterval = 3_600
        /// A reading went back to a cycle that a later one had already replaced, and kept to it past `returnGrace`.
        private(set) var returns = 0
        static let returnGrace: TimeInterval = 300
        static let restartUsed = 5.0
        static let restartTolerance: TimeInterval = 600
        var mixed: Bool { returns > 0 || earlyStarts >= 2 }

        init(_ observations: [QuotaObservation]) {
            let jitter = QuotaObservation.explicitResetJitter
            var earlyDates: [Date] = []
            for (_, rows) in Dictionary(grouping: observations.filter { $0.resetKind == .explicit }, by: \.series) {
                // Cycles in the order they first appeared.
                var resets: [Date] = []
                var firstSeen: [Date] = []
                var current: Int?
                for row in rows.sorted(by: { $0.date < $1.date }) {
                    if let index = resets.firstIndex(where: { abs($0.timeIntervalSince(row.reset)) <= jitter }) {
                        if let active = current, active != index, row.date < resets[index], index + 1 < firstSeen.count,
                           row.date >= firstSeen[index + 1].addingTimeInterval(Self.returnGrace) { returns += 1 }
                        current = index
                        continue
                    }
                    if let active = current, row.date < resets[active].addingTimeInterval(-jitter) {
                        let window = TimeInterval(row.series.meter.durationSeconds)
                        let fresh = row.used <= Self.restartUsed
                            && abs(row.reset.timeIntervalSince(row.date.addingTimeInterval(window))) <= Self.restartTolerance
                        if fresh { restarts += 1 } else { earlyDates.append(row.date) }
                    }
                    resets.append(row.reset)
                    firstSeen.append(row.date)
                    current = resets.count - 1
                }
            }
            var eventStart: Date?
            for date in earlyDates.sorted() {
                if let start = eventStart, date.timeIntervalSince(start) <= Self.earlyStartWindow { continue }
                eventStart = date
                earlyStarts += 1
            }
        }
    }
}

/// Decides, per process, how a Codex import goes on: scan the archive, re-attribute the candidates of the scan that
/// already finished, or nothing. The archive is scanned at most once per key per process, however many live
/// readings arrive; a scan that had to wait for a live reading keeps its candidates in memory and only the
/// attribution is repeated (no file I/O). Used from the usage service queue only.
final class UsageCodexImportPlanner {
    enum Step {
        case scan
        case reattribute([UsageCodexBackfill.Candidate])
        case idle
    }

    private var scanned = Set<QuotaImportKey>()
    private var deferred: (key: QuotaImportKey, candidates: [UsageCodexBackfill.Candidate])?

    func step(for key: QuotaImportKey) -> Step {
        if let deferred {
            if deferred.key == key { return .reattribute(deferred.candidates) }
            self.deferred = nil
        }
        return scanned.contains(key) ? .idle : .scan
    }

    /// A scan reached its final pass.
    func scanFinished(key: QuotaImportKey, candidates: [UsageCodexBackfill.Candidate],
                      decision: UsageCodexBackfill.Attribution) {
        scanned.insert(key)
        deferred = decision.awaitsLiveReading ? (key, candidates) : nil
    }

    /// The deferred candidates were attributed again.
    func reattributed(key: QuotaImportKey, decision: UsageCodexBackfill.Attribution) {
        if !decision.awaitsLiveReading, deferred?.key == key { deferred = nil }
    }
}

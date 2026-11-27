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
final class UsageCodexBackfill {
    struct Limits {
        var files = 512
        var bytes = 128 * 1_024 * 1_024
        var fileTailBytes = 2 * 1_024 * 1_024
        var maxLineBytes = 256 * 1_024
        var observations = 100_000
        var elapsed: TimeInterval = 5
        var slice: TimeInterval = 0.05
    }

    enum Candidate {
        // Matching is decided before batching so raw identity metadata is not retained.
        case reading(UsageReading, identified: Bool)
        case foreignAccount(Date)

        init(reading: UsageReading, identified: Bool) { self = .reading(reading, identified: identified) }

        var identified: Bool {
            if case .reading(_, true) = self { return true }
            return false
        }
    }

    struct Pass {
        let candidates: [Candidate]
        let truncated: Bool
        let moreFiles: Bool
    }

    private struct FileCursor {
        let handle: FileHandle
        var remaining: Int
        var skipping: Bool
        var line = Data()
    }

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
    private var readings: [Candidate] = []
    private var meterCount = 0
    private var completedPasses = 0
    private var active = false
    private var passStart = 0.0
    private var passFiles = 0
    private var passBytes = 0
    private var truncated = false

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
        while ProcessInfo.processInfo.systemUptime < end {
            if cancelled() { close(); days.removeAll(); readings.removeAll(); active = false; return }
            let overBudget = passBytes >= limits.bytes || meterCount >= limits.observations
                || ProcessInfo.processInfo.systemUptime - passStart >= limits.elapsed
            let more = exhaustedDays.count < paths.count || cursor != nil
            if overBudget || (cursor == nil && (passFiles >= limits.files || !more)) {
                truncated = truncated || (more && (completedPasses == 1 || meterCount >= limits.observations))
                active = false
                completedPasses += 1
                let pass = Pass(candidates: readings, truncated: truncated, moreFiles: more)
                if completedPasses == 2 || !more { close(); days.removeAll(); readings.removeAll() }
                finish(pass)
                return
            }
            if cursor != nil { readChunk() }
            else { searchDay() }
        }
        queue.async { self.scanSlice(finish) }
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
            guard file.lastPathComponent.hasPrefix("rollout-"), file.pathExtension == "jsonl",
                  let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { return }
            passFiles += 1
            open(file)
        } else {
            days[day] = nil
            exhaustedDays.insert(day)
        }
    }

    private func open(_ url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        do {
            let size = try handle.seekToEnd()
            let tail = UInt64(max(1, limits.fileTailBytes))
            // Reserve one byte of the tail budget to determine whether the first line is complete.
            let start = size > tail ? size - tail + 1 : 0
            try handle.seek(toOffset: start > 0 ? start - 1 : start)
            var skipping = false
            if start > 0 {
                let previous = try handle.read(upToCount: 1)
                passBytes += previous?.count ?? 0
                skipping = previous?.first != 10
                truncated = true
            }
            cursor = FileCursor(handle: handle, remaining: Int(size - start), skipping: skipping)
        } catch { try? handle.close() }
    }

    private func readChunk() {
        guard var file = cursor else { return }
        let count = min(16_384, file.remaining, limits.bytes - passBytes)
        guard count > 0, let data = try? file.handle.read(upToCount: count), !data.isEmpty else { close(); return }
        file.remaining -= data.count
        passBytes += data.count
        var start = data.startIndex
        while start < data.endIndex && meterCount < limits.observations && !cancelled() {
            let newline = data[start...].firstIndex(of: 10)
            let end = newline ?? data.endIndex
            if !file.skipping {
                if file.line.count + end - start > limits.maxLineBytes {
                    file.skipping = true
                    truncated = true
                    file.line.removeAll(keepingCapacity: true)
                } else { file.line.append(contentsOf: data[start..<end]) }
            }
            guard newline != nil else { break }
            if !file.skipping { append(file.line) }
            file.line.removeAll(keepingCapacity: true)
            file.skipping = false
            start = end + 1
        }
        cursor = file
        if file.remaining == 0 { close() } // A non-newline-terminated tail is an incomplete record.
    }

    private func append(_ line: Data) {
        guard let event = UsageJSON.codexRollout(line),
              event.reading.date >= now.addingTimeInterval(-UsageQuotaHistory.retention),
              event.reading.date <= now.addingTimeInterval(5) else { return }
        let identity = event.identity(for: account)
        if identity == .foreign {
            guard meterCount < limits.observations else { truncated = true; return }
            readings.append(.foreignAccount(event.reading.date))
            meterCount += 1
            return
        }
        guard let payload = event.reading.quota, !payload.windows.isEmpty else { return }
        guard meterCount + payload.windows.count <= limits.observations else { truncated = true; return }
        meterCount += payload.windows.count
        var reading = event.reading
        reading.windows.removeAll()
        readings.append(.reading(reading, identified: identity == .matching))
    }

    private func close() {
        try? cursor?.handle.close()
        cursor = nil
    }

    /// Unlabeled history stays provisional and needs a same-meter, same-cycle match with a fresh API sample.
    static func attributed(_ candidates: [Candidate], key: QuotaImportKey, anchors: [QuotaObservation],
                           switchedAt: Date?, now: Date, realtime: Bool = false) -> [QuotaObservation] {
        let fresh = anchors.filter { now.timeIntervalSince($0.date) <= ($0.series.meter.durationSeconds == 18_000 ? 600 : 1_800)
            && $0.date <= now.addingTimeInterval(5) && $0.reset > now }
        let latestForeign = candidates.compactMap { candidate -> Date? in
            if case .foreignAccount(let date) = candidate, date <= now.addingTimeInterval(5) { return date }
            return nil
        }.max()
        func isAfterSwitches(_ date: Date) -> Bool {
            date >= (switchedAt ?? .distantPast) && date > (latestForeign ?? .distantPast)
        }
        // The active login can only own unlabeled rows after its first confirmed return.
        let archiveReturn = latestForeign.flatMap { _ in
            candidates.compactMap { candidate -> Date? in
                if case .reading(let reading, true) = candidate, isAfterSwitches(reading.date) { return reading.date }
                return nil
            }.min()
        }
        func capture(_ candidate: Candidate, anchors: [UsageQuotaCapture.AnchorKey: [QuotaObservation]]) -> [QuotaObservation] {
            guard case .reading(let reading, let identified) = candidate,
                  identified || isAfterSwitches(reading.date) else { return [] }
            return UsageQuotaCapture.observations(reading, provider: .codex, profile: key.profile, timeZoneID: key.timeZoneID,
                                                  source: .rollout, attribution: identified ? .verifiedArchive : .provisional,
                                                  now: now, anchors: anchors)
        }
        let labeled = candidates.filter(\.identified)
        let verifiedAnchors = UsageQuotaCapture.anchorIndex(fresh + labeled.flatMap { capture($0, anchors: [:]) })
        let observations = candidates.flatMap { candidate in
            capture(candidate, anchors: verifiedAnchors)
        }
        let grouped = Dictionary(grouping: observations, by: \.series)
        return grouped.flatMap { series, rows -> [QuotaObservation] in
            let lived = fresh.first { $0.series == series && isAfterSwitches($0.date) }
            let unlabeledSince = latestForeign == nil ? .distantPast : ([archiveReturn, lived?.date].compactMap { $0 }.min() ?? .distantFuture)
            let archivalAnchor = lived.flatMap { live in
                rows.filter { (realtime || $0.date <= live.date) && isAfterSwitches($0.date) && $0.date >= unlabeledSince
                    && $0.reset == live.reset && $0.resetKind == .explicit }
                    .max { $0.date == $1.date ? $0.used < $1.used : $0.date < $1.date }
            }
            let compatible: Bool
            if let lived, let archivalAnchor, lived.resetKind == .explicit {
                if realtime && archivalAnchor.date > lived.date { compatible = archivalAnchor.used >= lived.used - 1 }
                else { compatible = archivalAnchor.used <= lived.used + 1 }
            } else { compatible = false }
            return rows.filter { row in
                row.attribution == .verifiedArchive || (compatible && isAfterSwitches(row.date) && row.date >= unlabeledSince)
            }
        }
    }
}

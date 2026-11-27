import Foundation

/// Salted local identifier for a provider login in a resolved configuration directory.
struct QuotaProfileID: Hashable, Codable, Sendable {
    let rawValue: String
}

/// The quota scope supplied by the provider. Legacy Claude names remain independent.
enum QuotaMeterScope: Hashable, Codable, Sendable {
    case shared, modelID(String), modelName(String), legacyClaude(String)
}

/// A transport-independent quota meter and its advertised window length.
struct QuotaMeter: Hashable, Codable, Sendable {
    let scope: QuotaMeterScope
    let durationSeconds: Int
    var bucketSeconds: Int { durationSeconds == 18_000 ? 1_800 : 3_600 }
}

/// The complete partition key. Calendar profiles only combine evidence in the same recorded zone.
struct QuotaSeries: Hashable, Codable, Sendable {
    let provider: UsageProvider
    let profile: QuotaProfileID
    let plan: String
    let meter: QuotaMeter
    let timeZoneID: String
}

/// Absolute bounds of a local hour or half-hour, clipped where a time-zone offset changes.
enum QuotaCalendarBuckets {
    static func interval(containing date: Date, timeZoneID: String, seconds: Int) -> DateInterval {
        let zone = TimeZone(identifier: timeZoneID) ?? TimeZone(secondsFromGMT: 0)!
        let offset = zone.secondsFromGMT(for: date)
        let width = Double(seconds)
        let wallTime = date.timeIntervalSince1970 + Double(offset)
        var start = Date(timeIntervalSince1970: floor(wallTime / width) * width - Double(offset))
        var end = start.addingTimeInterval(width)
        // Some zones change by half an hour. Their repeated/skipped local hour has shorter bounds.
        if (zone.secondsFromGMT(for: start) != offset || zone.secondsFromGMT(for: end.addingTimeInterval(-0.001)) != offset),
           let transition = zone.nextDaylightSavingTimeTransition(after: start.addingTimeInterval(-0.001)),
           transition < end {
            if transition <= date { start = max(start, transition) }
            else { end = transition }
        }
        return DateInterval(start: start, end: end)
    }
}

/// Origin of the counter, ordered by precedence when readings share a timestamp.
enum QuotaSource: Int, Codable, Sendable {
    case rollout = 0, statusLine, api
}

/// How positively the evidence is attributed to the active profile.
enum QuotaAttribution: Int, Codable, Sendable {
    case provisional = 0, verifiedArchive, live
}

/// Whether the applicable companion meter exists and its state in the same payload.
enum QuotaCapState: Equatable, Codable, Sendable {
    case absent, present(QuotaCapActivity), unknown
}

/// The activity of an applicable companion meter.
enum QuotaCapActivity: Equatable, Codable, Sendable {
    case inactive, active(used: Double, reset: Date), unknown
}

enum QuotaCapBand: CaseIterable {
    case absent, inactive, low, near, full, unknown, unresolved

    init(_ cap: QuotaCapState, at date: Date) {
        switch cap {
        case .absent: self = .absent
        case .unknown: self = .unknown
        case .present(.inactive): self = .inactive
        case .present(.unknown): self = .unresolved
        case .present(.active(let used, let reset)):
            if reset <= date || !(0...100).contains(used) { self = .unresolved }
            else if used == 100 { self = .full }
            else { self = used >= 80 ? .near : .low }
        }
    }

    var nearLimit: Bool { self == .near || self == .full }
}

/// Whether the reset was advertised directly or calculated from a countdown.
enum QuotaResetKind: Int, Codable, Sendable {
    case explicit, calculated
}

/// One original, unmerged quota counter with any simultaneously observed cap context.
/// A hard block requires positive evidence independent of the included allowance percentage.
struct QuotaObservation: Equatable, Codable, Sendable {
    let series: QuotaSeries
    let date: Date
    let used: Double
    let reset: Date
    let source: QuotaSource
    var resetKind: QuotaResetKind = .explicit
    var attribution: QuotaAttribution = .live
    var companion: QuotaCapState = .unknown
    var bindingWeekly: QuotaCapState = .unknown
    var hardBlockUntil: Date? = nil
}

/// One continuous segment within an advertised reset. Manual resets can change either component.
struct QuotaCycle: Hashable, Codable, Sendable {
    let reset: Date
    let segmentStart: Date
}

/// Evidence qualifiers. Coverage counts only resolved seconds, including in censored buckets.
struct QuotaBucketFlags: OptionSet, Codable, Sendable {
    let rawValue: Int
    static let split = Self(rawValue: 1 << 0)
    static let rollout = Self(rawValue: 1 << 1)
    static let provisional = Self(rawValue: 1 << 2)
    // The sample hit 100%. Resolved seconds before the hit remain usable.
    static let censored = Self(rawValue: 1 << 3)
    static let localizedGap = Self(rawValue: 1 << 4)
    static let roundedPlateau = Self(rawValue: 1 << 5)
}

/// Latest counter and companion context observed within an individual cycle/bucket row.
struct QuotaBucketSample: Equatable, Codable, Sendable {
    let date: Date
    let used: Double
    let source: QuotaSource
    let attribution: QuotaAttribution
    let companion: QuotaCapState
    let bindingWeekly: QuotaCapState
    let hardBlockUntil: Date?

    init(_ observation: QuotaObservation) {
        self.init(date: observation.date, used: observation.used, source: observation.source,
                  attribution: observation.attribution, companion: observation.companion,
                  bindingWeekly: observation.bindingWeekly, hardBlockUntil: observation.hardBlockUntil)
    }

    init(date: Date, used: Double, source: QuotaSource, attribution: QuotaAttribution, companion: QuotaCapState,
         bindingWeekly: QuotaCapState, hardBlockUntil: Date?) {
        self.date = date
        self.used = used
        self.source = source
        self.attribution = attribution
        self.companion = companion
        self.bindingWeekly = bindingWeekly
        self.hardBlockUntil = hardBlockUntil
    }
}

/// Localized debit and evidence exposure in one absolute bucket, possibly shared by several segments.
/// Covered seconds count direct intervals. Quiet seconds count lower-weight bridges and are disjoint.
struct QuotaBucket: Equatable, Sendable {
    let series: QuotaSeries
    let cycle: QuotaCycle
    let start: Date
    var deltaHundredths: Int
    var coveredSeconds: Double
    var quietSeconds: Double
    var flags: QuotaBucketFlags
    var latest: QuotaBucketSample?
    var firstHit: Date? = nil
    var earlierCompanionSamples: [QuotaBucketSample] = []
    var end: Date {
        QuotaCalendarBuckets.interval(containing: start, timeZoneID: series.timeZoneID, seconds: series.meter.bucketSeconds).end
    }
    var delta: Double { Double(deltaHundredths) / 100 }
}

/// A positive debit across a sparse interval. Localized gaps are already included in their bucket.
struct QuotaGap: Equatable, Sendable {
    let series: QuotaSeries
    let cycle: QuotaCycle
    let start: Date
    let end: Date
    let deltaHundredths: Int
    let source: QuotaSource
    let attribution: QuotaAttribution
    let localized: Bool
    var canLocalizeToHour = true

    /// Hour containing both endpoints. A short-window gap can have an hourly total without a known
    /// distribution across its two half-hour cells. Only `localized` totals are already in bucket rows.
    var localizedHourStart: Date? {
        guard canLocalizeToHour else { return nil }
        let hour = QuotaCalendarBuckets.interval(containing: start, timeZoneID: series.timeZoneID, seconds: 3600)
        return end < hour.end ? hour.start : nil
    }
}

/// Value snapshot indexed by series and absolute time. Queries return whole overlapping cells;
/// callers can clip the boundary cells and map them using a calendar in the recorded time zone.
struct QuotaHistorySnapshot: Sendable {
    private let rows: [QuotaSeries: [QuotaBucket]]
    private let gapsBySeries: [QuotaSeries: [QuotaGap]]
    private let samples: [QuotaSeries: [(QuotaCycle, QuotaBucketSample)]]
    let series: Set<QuotaSeries>

    init(buckets: [QuotaBucket] = [], gaps: [QuotaGap] = []) {
        rows = Dictionary(grouping: buckets, by: \.series).mapValues {
            $0.sorted { ($0.start, $0.cycle.segmentStart) < ($1.start, $1.cycle.segmentStart) }
        }
        gapsBySeries = Dictionary(grouping: gaps, by: \.series).mapValues { $0.sorted { $0.end < $1.end } }
        samples = rows.mapValues { $0.compactMap { row in row.latest.map { (row.cycle, $0) } }.sorted { $0.1.date < $1.1.date } }
        series = Set(rows.keys).union(gapsBySeries.keys)
    }

    func buckets(for series: QuotaSeries, in range: Range<Date>) -> ArraySlice<QuotaBucket> {
        guard let values = rows[series], !range.isEmpty else { return [] }
        let first = Self.bound(in: values) { $0.end > range.lowerBound }
        let last = Self.bound(in: values) { $0.start >= range.upperBound }
        return values[first..<last]
    }

    func gaps(for series: QuotaSeries, in range: Range<Date>) -> [QuotaGap] {
        guard let values = gapsBySeries[series], !range.isEmpty else { return [] }
        let first = Self.bound(in: values) { $0.end > range.lowerBound }
        return values[first...].filter { $0.start < range.upperBound }
    }

    func latestQuota(for series: QuotaSeries, atOrBefore date: Date) -> (cycle: QuotaCycle, sample: QuotaBucketSample)? {
        guard let values = samples[series] else { return nil }
        let end = Self.bound(in: values) { $0.1.date > date }
        return end > 0 ? values[end - 1] : nil
    }

    private static func bound<T>(in values: [T], where predicate: (T) -> Bool) -> Int {
        var lo = 0, hi = values.count
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            if predicate(values[mid]) { hi = mid } else { lo = mid + 1 }
        }
        return lo
    }
}

/// Display readiness after coverage, calibration and ETA gates.
enum ForecastReadiness: Equatable, Sendable {
    case learning, provisional, normal, risk, likely, exhausted
}

/// Forecast values in percentage points, probability (0...1), and absolute crossing times.
struct ForecastResult: Equatable, Sendable {
    var expectedUsed: Double?
    var exhaustProbability: Double?
    var eta: Date?
    var etaRange: ClosedRange<Date>?
    var readiness: ForecastReadiness
    var hitWeeks: Int
    var effectiveWeeks: Double
}

/// Pure forecast interface for the next wave. The caller supplies the current live counter and calendar.
protocol UsageForecasting {
    func forecast(snapshot: QuotaHistorySnapshot, current: QuotaObservation, calendar: Calendar, now: Date) -> ForecastResult
}

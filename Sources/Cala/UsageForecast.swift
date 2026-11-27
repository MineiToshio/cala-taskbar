import Foundation

struct UsageForecast: UsageForecasting {
    func forecast(snapshot: QuotaHistorySnapshot, current: QuotaObservation, calendar: Calendar, now: Date) -> ForecastResult {
        let meter = current.series.meter
        let short = meter.durationSeconds == 18_000
        let age = now.timeIntervalSince(current.date)
        guard short || meter.durationSeconds == 604_800,
              !current.series.plan.isEmpty, !current.series.profile.rawValue.isEmpty,
              let zone = TimeZone(identifier: current.series.timeZoneID),
              current.attribution == .live, (0...100).contains(current.used),
              (-5...(short ? 600.0 : 1_800.0)).contains(age),
              current.reset > max(now, current.date),
              current.reset.timeIntervalSince(current.date) <= Double(meter.durationSeconds) + 2 else { return Self.learning }
        if current.used == 100 {
            return .init(expectedUsed: 100, exhaustProbability: nil, eta: nil, etaRange: nil,
                         readiness: .exhausted, hitWeeks: 0, effectiveWeeks: 0)
        }

        let start = max(now, min(current.hardBlockUntil ?? now, current.reset))
        if start == current.reset {
            return .init(expectedUsed: current.used, exhaustProbability: 0, eta: nil, etaRange: nil,
                         readiness: .normal, hitWeeks: 0, effectiveWeeks: 0)
        }

        let cap = short ? current.bindingWeekly : current.companion
        let band = QuotaCapBand(cap, at: now)
        guard band != .unresolved, !short || band != .unknown else { return Self.capLimited }

        var local = calendar
        local.timeZone = zone
        let grid = Grid(calendar: local, zone: zone, zoneID: current.series.timeZoneID)
        guard let earliest = local.date(byAdding: .day, value: -112, to: now) else { return Self.learning }
        var availableThrough = now
        if let newest = snapshot.latestQuota(for: current.series, atOrBefore: .distantFuture), newest.sample.date > now {
            // A later snapshot can contain quiet cells confirmed by a future endpoint. No cell
            // past the last as-of counter can be considered resolved in a historical replay.
            guard let anchor = snapshot.latestQuota(for: current.series, atOrBefore: now) else { return Self.learning }
            availableThrough = anchor.sample.date
        }
        let rows = snapshot.buckets(for: current.series, in: earliest..<now)
        let gaps = short ? snapshot.gaps(for: current.series, in: earliest..<now) : []
        let run = Run(current: current, now: now, start: start, grid: grid, short: short, band: band)
        if band == .unknown {
            let recent = snapshot.buckets(for: current.series, in: now.addingTimeInterval(-1_800)..<now.addingTimeInterval(1))
            let latest = recent.flatMap { row in
                row.latest.map { row.earlierCompanionSamples + [$0] } ?? row.earlierCompanionSamples
            }.filter {
                $0.date <= now && now.timeIntervalSince($0.date) <= 1_800 && Applicability($0.companion) != .unknown
            }.max { $0.date < $1.date }
            if let latest, QuotaCapBand(latest.companion, at: now).nearLimit { return Self.capLimited }
        }

        if band != .unknown {
            let trusted = History(rows: rows, gaps: gaps, since: earliest, through: availableThrough, run: run, trusted: true)
            let result = run.evaluate(trusted, trusted: true)
            if result.readiness != .learning { return result }
        }
        let combined = History(rows: rows, gaps: gaps, since: earliest, through: availableThrough, run: run, trusted: false)
        let result = run.evaluate(combined, trusted: false)
        guard result.readiness == .learning else { return result }
        return run.quick(rows, through: availableThrough)
    }

    static let learning = ForecastResult(expectedUsed: nil, exhaustProbability: nil, eta: nil, etaRange: nil,
                                                readiness: .learning, hitWeeks: 0, effectiveWeeks: 0)
    static let warmingUp = ForecastResult(expectedUsed: nil, exhaustProbability: nil, eta: nil, etaRange: nil,
                                          readiness: .learning, hitWeeks: 0, effectiveWeeks: 0, hold: .warmingUp)
    static let capLimited = ForecastResult(expectedUsed: nil, exhaustProbability: nil, eta: nil, etaRange: nil,
                                           readiness: .learning, hitWeeks: 0, effectiveWeeks: 0, hold: .capLimited)
}

private extension QuotaCapBand {
    func matches(_ historical: QuotaCapState, origin: Date, current: QuotaCapState, now: Date,
                 matchReset: Bool) -> Bool {
        guard Self(historical, at: origin) == self else { return false }
        guard nearLimit, matchReset,
              case .present(.active(_, let oldReset)) = historical,
              case .present(.active(_, let reset)) = current else { return true }
        return abs(oldReset.timeIntervalSince(origin) - reset.timeIntervalSince(now)) <= 3_600
    }
}

private extension UsageForecast {
    static let hour = 3_600.0
    static let day = 86_400.0
    static let epsilon = 0.000_001

    static func decay(_ seconds: Double) -> Double { exp2(-max(0, seconds) / (28 * day)) }

    enum Applicability {
        case absent, present, unknown

        init(_ cap: QuotaCapState) {
            switch cap {
            case .absent: self = .absent
            case .present: self = .present
            case .unknown: self = .unknown
            }
        }
    }

    struct Grid {
        let calendar: Calendar
        let zone: TimeZone
        let zoneID: String

        struct Position {
            let date: Int
            let second: Double

            // The Unix epoch starts on a Thursday.
            var weekday: Int { ((date + 3) % 7 + 7) % 7 }
            var week: Int { date - weekday }
            var weekend: Bool { weekday >= 5 }
            var slot: Int { weekday * 24 + Int(second / hour) }
        }

        func position(_ date: Date) -> Position {
            let wall = date.timeIntervalSince1970 + Double(zone.secondsFromGMT(for: date))
            let ordinal = floor(wall / day)
            return Position(date: Int(ordinal), second: wall - ordinal * day)
        }

        func bounds(_ date: Date, seconds: Int) -> DateInterval {
            QuotaCalendarBuckets.interval(containing: date, timeZoneID: zoneID, seconds: seconds)
        }

        struct WallSpan {
            let start: Date
            let end: Date
            let offset: TimeInterval

            func absolute(_ wall: Date) -> Date { wall.addingTimeInterval(-offset) }
        }

        /// Local clock coordinates for runs with a constant UTC offset.
        func wallSpans(from start: Date, to end: Date) -> [WallSpan] {
            var spans: [WallSpan] = []
            var date = start
            while date < end {
                let offset = Double(zone.secondsFromGMT(for: date))
                let next = min(end, zone.nextDaylightSavingTimeTransition(after: date) ?? end)
                spans.append(.init(start: date.addingTimeInterval(offset), end: next.addingTimeInterval(offset), offset: offset))
                date = next
            }
            return spans
        }
    }

    struct Cell {
        let start: Date
        let end: Date
        let cycle: QuotaCycle
        let debit: Double
        let covered: Double
        let exposure: Double

        var duration: Double { end.timeIntervalSince(start) }
        var fraction: Double { covered / duration }
        var debitPerSecond: Double { debit / duration }
    }

    struct HourEvidence {
        var covered = 0.0
        var exposure = 0.0
        var debit = 0.0
    }

    struct History {
        var cells: [Date: [Cell]] = [:]
        var hours: [Date: HourEvidence] = [:]
        var caps: [QuotaBucketSample] = []
        var sessions: [QuotaCycle: [QuotaBucketSample]] = [:]

        init(rows: ArraySlice<QuotaBucket>, gaps: [QuotaGap], since earliest: Date, through availableThrough: Date,
             run: Run, trusted: Bool) {
            var cycle: QuotaCycle?
            var applicability: Applicability = .unknown
            cells.reserveCapacity(rows.count)
            hours.reserveCapacity(run.short ? rows.count / 2 : rows.count)
            for index in rows.indices {
                let row = rows[index]
                if cycle != row.cycle {
                    cycle = row.cycle
                    applicability = .unknown
                }
                let sample = row.latest.flatMap { $0.date <= run.now ? $0 : nil }
                let verified = !row.flags.contains(.provisional) && sample?.attribution != .provisional
                let earlier = row.earlierCompanionSamples.filter { $0.date <= run.now && (!trusted || $0.attribution != .provisional) }
                let cap = sample.map { run.short ? $0.bindingWeekly : $0.companion } ?? .unknown
                let observed = Applicability(cap)
                if observed != .unknown, !trusted || verified { applicability = observed }
                else if !run.short, let prior = earlier.last { applicability = Applicability(prior.companion) }

                guard !trusted || verified else { continue }
                if !run.short { caps.append(contentsOf: earlier) }
                if let sample {
                    if run.short { sessions[row.cycle, default: []].append(sample) }
                    else if observed != .unknown { caps.append(sample) }
                }
                guard run.accepts(applicability), row.deltaHundredths >= 0,
                      row.coveredSeconds >= 0, row.quietSeconds >= 0 else { continue }
                let seconds = row.coveredSeconds + row.quietSeconds
                guard seconds > 0 else { continue }

                let start = max(row.start, row.cycle.segmentStart)
                var end = min(row.end, row.cycle.reset)
                // A subsequent segment can occupy the rest of the same bucket after a reset or regression.
                let next = index + 1
                if next < rows.endIndex, rows[next].start == row.start {
                    end = min(end, rows[next].cycle.segmentStart)
                }
                if row.flags.contains(.censored), let hit = row.firstHit ?? (sample?.used == 100 ? sample?.date : nil) {
                    end = min(end, hit)
                }
                let duration = end.timeIntervalSince(start)
                // A partially published bucket can contain debits confirmed by a later observation.
                guard start >= earliest, end <= availableThrough, duration > 0, seconds <= duration + epsilon else { continue }

                let exposure = row.flags.contains(.rollout) ? seconds * 0.5 : row.coveredSeconds + row.quietSeconds * 0.5
                let cell = Cell(start: start, end: end, cycle: row.cycle, debit: row.delta,
                                covered: min(seconds, duration), exposure: exposure)
                cells[row.start, default: []].append(cell)
                let hourStart = run.short ? run.grid.bounds(row.start, seconds: 3_600).start : row.start
                hours[hourStart, default: HourEvidence()].covered += cell.covered
                hours[hourStart, default: HourEvidence()].exposure += cell.exposure
                hours[hourStart, default: HourEvidence()].debit += cell.debit
            }

            // A known hourly total across two half-hour cells is useful for fitting, but cannot
            // resolve either half of a short-session path.
            if run.short {
                for gap in gaps where !gap.localized && (!trusted || gap.attribution != .provisional) {
                    guard gap.start >= earliest, gap.end <= availableThrough, gap.deltaHundredths >= 0,
                          let hourStart = gap.localizedHourStart,
                          let sample = prior(sessions[gap.cycle] ?? [], at: gap.end),
                          run.accepts(Applicability(sample.bindingWeekly)) else { continue }
                    let seconds = gap.end.timeIntervalSince(gap.start)
                    hours[hourStart, default: HourEvidence()].covered += seconds
                    hours[hourStart, default: HourEvidence()].exposure += seconds * (gap.source == .rollout ? 0.5 : 1)
                    hours[hourStart, default: HourEvidence()].debit += Double(gap.deltaHundredths) / 100
                }
            }
            // Rows sharing a bucket can carry samples from different segments.
            caps.sort { $0.date < $1.date }
        }

        func cap(at date: Date) -> QuotaBucketSample? {
            guard let sample = prior(caps, at: date), date.timeIntervalSince(sample.date) <= 1_800 else { return nil }
            return sample
        }

        func sessionUsed(_ cycle: QuotaCycle, samples: [QuotaBucketSample], at date: Date, grid: Grid)
            -> (used: Double, binding: QuotaCapState)? {
            guard let sample = prior(samples, at: date), date.timeIntervalSince(sample.date) <= 1_800 else { return nil }
            var used = sample.used
            var position = sample.date
            while position < date {
                let bounds = grid.bounds(position, seconds: 1_800)
                let end = min(bounds.end, date)
                let seconds = end.timeIntervalSince(position)
                var covered = 0.0
                for cell in cells[bounds.start] ?? [] where cell.cycle == cycle && cell.fraction >= 1 - epsilon {
                    let overlap = min(end, cell.end).timeIntervalSince(max(position, cell.start))
                    if overlap > 0 {
                        covered += overlap
                        used += overlap * cell.debitPerSecond
                    }
                }
                guard covered + epsilon >= seconds else { return nil }
                position = end
            }
            return (min(100, used), sample.bindingWeekly)
        }

        private func prior(_ values: [QuotaBucketSample], at date: Date) -> QuotaBucketSample? {
            var lo = 0
            var hi = values.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if values[mid].date <= date { lo = mid + 1 }
                else { hi = mid }
            }
            return lo == 0 ? nil : values[lo - 1]
        }
    }

    struct Observation {
        let date: Int
        let week: Int
        let rate: Double
        let weight: Double
    }

    struct Pool {
        var observations: [Observation] = []
        var weight = 0.0

        mutating func add(_ observation: Observation) {
            weight += observation.weight
            observations.append(observation)
        }

        func sum(cappedAt cap: Double?) -> Double {
            observations.reduce(0) { $0 + min($1.rate, cap ?? .infinity) * $1.weight }
        }

        func percentile() -> Double? {
            let positive = observations.filter { $0.rate > 0 }
            guard positive.count >= 20, Set(positive.map(\.date)).count >= 5 else { return nil }
            return UsageForecast.quantile(observations.map { ($0.rate, $0.weight) }, at: 0.9)
        }
    }

    struct Prior {
        let rate: Double
        let upper: Double
        let sameHour: Bool
        let weeks: Int
    }

    struct Profile {
        let slots: [Prior?]
        let hasSpan: Bool

        init(history: History, grid: Grid, now: Date) {
            struct WeekSlot: Hashable { let week: Int; let slot: Int }
            // Both occurrences of a repeated wall hour contribute, sharing one hour of exposure.
            var hoursByWeek: [WeekSlot: Double] = [:]
            var candidates: [(Date, Grid.Position, HourEvidence)] = []
            for (date, hour) in history.hours.sorted(by: { $0.key < $1.key }) where hour.covered >= 1_800 - epsilon {
                let position = grid.position(date)
                hoursByWeek[WeekSlot(week: position.week, slot: position.slot), default: 0] += hour.covered
                candidates.append((date, position, hour))
            }

            var exact = Array(repeating: Pool(), count: 168)
            var sameClass = Array(repeating: Pool(), count: 48)
            var sameHour = Array(repeating: Pool(), count: 24)
            var band = Array(repeating: Pool(), count: 12)
            var weeks: Set<Int> = []
            for (date, position, evidence) in candidates {
                let key = WeekSlot(week: position.week, slot: position.slot)
                let normalization = min(1, hour / (hoursByWeek[key] ?? hour))
                let observation = Observation(date: position.date, week: position.week,
                                              rate: evidence.debit * hour / evidence.covered,
                                              weight: decay(now.timeIntervalSince(date)) * evidence.exposure / hour * normalization)
                let localHour = position.slot % 24
                let dayClass = position.weekend ? 1 : 0
                exact[position.slot].add(observation)
                sameClass[dayClass * 24 + localHour].add(observation)
                sameHour[localHour].add(observation)
                band[dayClass * 6 + localHour / 4].add(observation)
                weeks.insert(position.week)
            }

            hasSpan = weeks.count >= 3
                && (candidates.last?.1.date ?? 0) - (candidates.first?.1.date ?? 0) >= 14
            slots = (0..<168).map { slot in
                let localHour = slot % 24
                let dayClass = slot >= 120 ? 1 : 0
                let sameDay = sameClass[dayClass * 24 + localHour]
                let allDays = sameHour[localHour]
                let coarse = band[dayClass * 6 + localHour / 4]
                let parent: Pool?
                if sameDay.weight >= 4 { parent = sameDay }
                else if allDays.weight >= 4 { parent = allDays }
                else if coarse.weight >= 8 && Set(coarse.observations.map(\.date)).count >= 3 { parent = coarse }
                else { parent = nil }

                let local = exact[slot]
                let upper = parent?.percentile()
                let total = local.sum(cappedAt: upper)
                let rate: Double
                if let parent { rate = (total + 4 * parent.sum(cappedAt: upper) / parent.weight) / (local.weight + 4) }
                else if local.weight > 0 { rate = total / local.weight }
                else { return nil }
                return Prior(rate: rate, upper: max(rate, upper ?? rate),
                             sameHour: local.weight > 0 || sameDay.weight >= 4 || allDays.weight >= 4,
                             weeks: Set(local.observations.map(\.week)).count)
            }
        }
    }
}

private extension UsageForecast {
    struct Trial {
        var used: Double
        var crossing: Double?

        mutating func add(_ debit: Double, from offset: Double, for seconds: Double) {
            guard crossing == nil else { return }
            let remaining = 100 - used
            if debit > 0, debit + epsilon >= remaining {
                crossing = offset + seconds * min(1, remaining / debit)
                used = 100
            } else {
                used += debit
            }
        }
    }

    struct Replay {
        var observed: Trial
        var nominal: Trial
        var upper: Trial
        var covered = 0.0
        var unsupported = false

        init(used: Double) {
            observed = Trial(used: used)
            nominal = observed
            upper = observed
        }

        mutating func add(at offset: Double, seconds: Double, fraction: Double,
                          debit: Double, prior: Prior?) {
            observed.add(debit, from: offset, for: seconds)
            let missing = seconds * (1 - fraction)
            if missing > epsilon, prior == nil { unsupported = true }
            nominal.add(debit + missing * (prior?.rate ?? 0) / hour, from: offset, for: seconds)
            upper.add(debit + missing * (prior?.upper ?? 0) / hour, from: offset, for: seconds)
            let timeToHit = max(0, (observed.crossing ?? offset + seconds) - offset)
            covered += min(seconds, timeToHit) * fraction
        }
    }

    struct Path {
        let week: Int
        let age: Double
        let coverage: Double
        let replay: Replay
    }

    struct ReplaySpan {
        let target: Date
        let source: Date?
        let duration: TimeInterval
    }

    struct Outcome {
        let expected: Double
        let probability: Double
        let hitWeeks: Int
        let median: Double?
        let range: ClosedRange<Double>?

        var risk: Bool { probability + epsilon >= 0.2 && hitWeeks >= 2 }
        var likely: Bool { probability + epsilon >= 0.8 && hitWeeks >= 3 }

        init(paths: [Path], weights: [Double], duration: Double, trial: KeyPath<Replay, Trial>) {
            var expected = 0.0
            var probability = 0.0
            var weeks: Set<Int> = []
            var times: [(Double, Double)] = []
            for (path, weight) in zip(paths, weights) {
                let result = path.replay[keyPath: trial]
                expected += weight * result.used
                if let crossing = result.crossing, crossing < duration - epsilon {
                    probability += weight
                    weeks.insert(path.week)
                    times.append((crossing, weight))
                }
            }
            self.expected = min(100, expected)
            self.probability = min(1, probability)
            hitWeeks = weeks.count
            times.sort { $0.0 < $1.0 }
            median = UsageForecast.sortedQuantile(times, total: probability, at: 0.5)
            if let low = UsageForecast.sortedQuantile(times, total: probability, at: 0.1),
               let high = UsageForecast.sortedQuantile(times, total: probability, at: 0.9) {
                range = low...high
            } else {
                range = nil
            }
        }
    }

    static func quantile(_ samples: [(Double, Double)], at fraction: Double) -> Double? {
        sortedQuantile(samples.sorted { $0.0 < $1.0 }, total: samples.reduce(0) { $0 + $1.1 }, at: fraction)
    }

    static func sortedQuantile(_ samples: [(Double, Double)], total: Double, at fraction: Double) -> Double? {
        let target = fraction * total
        var cumulative = 0.0
        for (value, weight) in samples {
            cumulative += weight
            if cumulative >= target { return value }
        }
        return samples.last?.0
    }

    struct Weights {
        let paths: [Double]
        let effectiveWeeks: Double
        let weeks: Int

        init(_ paths: [Path], short: Bool) {
            let groups = Dictionary(grouping: paths.indices, by: { paths[$0].week })
            let memberships = groups.keys.sorted().compactMap { groups[$0] }
            let totals = memberships.map { indices in
                indices.reduce(0) { $0 + paths[$1].coverage }
            }
            let raw = zip(memberships, totals).map { indices, coverage in
                let count = Double(indices.count)
                let age = indices.reduce(0) { $0 + paths[$1].age } / count
                return decay(age) * coverage / count
            }

            // Water-fill the per-week cap, redistributing excess in proportion to uncapped weight.
            let cap = raw.count >= 5 ? 0.2 : 1
            var remaining = 1.0
            var rawRemaining = raw.reduce(0, +)
            var masses = Array(repeating: 0.0, count: raw.count)
            for index in raw.indices.sorted(by: { raw[$0] > raw[$1] }) {
                let weight = min(cap, rawRemaining > 0 ? remaining * raw[index] / rawRemaining : remaining)
                masses[index] = weight
                remaining -= weight
                rawRemaining -= raw[index]
            }

            var result = Array(repeating: 0.0, count: paths.count)
            for (week, indices) in memberships.enumerated() {
                for index in indices {
                    result[index] = short ? masses[week] * paths[index].coverage / totals[week] : masses[week]
                }
            }
            self.paths = result
            let squared = masses.reduce(0) { $0 + $1 * $1 }
            effectiveWeeks = squared > 0 ? pow(masses.reduce(0, +), 2) / squared : 0
            weeks = raw.count
        }
    }

    struct Run {
        let current: QuotaObservation
        let now: Date
        let start: Date
        let grid: Grid
        let short: Bool
        let band: QuotaCapBand

        var duration: Double { current.reset.timeIntervalSince(start) }
        var bucketSeconds: Int { current.series.meter.bucketSeconds }

        func accepts(_ cap: Applicability) -> Bool {
            switch band {
            case .absent: return cap == .absent
            case .unknown: return cap != .present
            default: return cap == .present
            }
        }

        func evaluate(_ history: History, trusted: Bool) -> ForecastResult {
            let profile = Profile(history: history, grid: grid, now: now)
            guard profile.hasSpan else { return UsageForecast.learning }
            let support = remainingSupport(profile)
            guard support.sameHour + epsilon >= 0.7 * duration else { return UsageForecast.learning }

            let paths: [Path]
            let wide: Bool
            if short {
                let matches = sessionPaths(history, profile: profile)
                paths = matches.paths
                wide = matches.wide
                guard paths.count >= 12 else { return UsageForecast.learning }
            } else {
                paths = band == .unknown ? [] : weeklyPaths(history, profile: profile)
                wide = false
            }

            let weights = Weights(paths, short: short)
            if !short, weights.effectiveWeeks + epsilon < 2 {
                guard !band.nearLimit, let point = support.point else { return UsageForecast.learning }
                return .init(expectedUsed: point, exhaustProbability: nil, eta: nil, etaRange: nil,
                             readiness: .provisional, hitWeeks: 0, effectiveWeeks: weights.effectiveWeeks)
            }

            let nominal = Outcome(paths: paths, weights: weights.paths, duration: duration, trial: \.nominal)
            var result = ForecastResult(expectedUsed: max(current.used, nominal.expected),
                                        exhaustProbability: nominal.probability, eta: nil, etaRange: nil,
                                        readiness: .provisional, hitWeeks: nominal.hitWeeks, effectiveWeeks: weights.effectiveWeeks)
            guard trusted, !wide, weights.weeks >= 4, weights.effectiveWeeks + epsilon >= 3.5,
                  support.repeated + epsilon >= 0.8 * duration else { return result }

            let low = Outcome(paths: paths, weights: weights.paths, duration: duration, trial: \.observed)
            let high = Outcome(paths: paths, weights: weights.paths, duration: duration, trial: \.upper)
            guard low.risk == high.risk else { return result }
            guard nominal.risk, low.risk, high.risk else {
                result.readiness = .normal
                return result
            }
            result.readiness = .risk

            if nominal.likely, low.likely, high.likely,
               let median = nominal.median, let lowRange = low.range, let highRange = high.range {
                let left = min(lowRange.lowerBound, highRange.lowerBound)
                let right = max(lowRange.upperBound, highRange.upperBound)
                if right - left <= (short ? hour : 24 * hour) + epsilon {
                    result.readiness = .likely
                    result.eta = start.addingTimeInterval(median)
                    result.etaRange = start.addingTimeInterval(left)...start.addingTimeInterval(right)
                }
            }
            return result
        }

        /// Cold-start estimate used while the learned profile is not ready. The default activity profile
        /// spreads the remaining window by typical local hours instead of extrapolating the rate 24/7:
        ///
        ///     rate      = debit / (Σ observed seconds · prior(slot) / 1 h + shrink)
        ///     slotRate  = (1 − w) · rate · prior(slot) + w · ownRate(slot)      w = min(1, liveDays / 14)
        ///     expected  = clamp(used + Σ remaining seconds · slotRate / 1 h, used...100)
        ///
        /// `shrink` is a zero-debit pseudo-exposure, max(2 h weekly / ½ h 5-hour, 0.2 · remaining prior hours · (1 − w)),
        /// that discounts a first burst against what is left of the window and fades as own days accumulate. `ownRate` is the user's own hour-of-week
        /// rate over the last 28 days where a slot has at least 30 minutes of evidence. The low estimate uses a
        /// pseudo-exposure of at least half the remaining prior hours and half the own rates; it alone, or 85%
        /// used with a quarter of the window left, raises the warning.
        func quick(_ rows: ArraySlice<QuotaBucket>, through availableThrough: Date) -> ForecastResult {
            guard !band.nearLimit else { return UsageForecast.capLimited }
            guard let horizon = grid.calendar.date(byAdding: .day, value: -28, to: now) else { return UsageForecast.learning }
            var debit = 0.0
            var exposure = 0.0
            var ownDebit = Array(repeating: 0.0, count: 168)
            var ownSeconds = Array(repeating: 0.0, count: 168)
            var days: Set<Int> = []
            var cycleStart: Date?
            var cycleSeconds = 0.0
            var cycleDirect = 0.0
            var cycleDebit = 0.0
            // Same applicability rule as History: a cycle keeps its last known companion/binding state.
            var applicability: [QuotaCycle: Applicability] = [:]
            for row in rows where row.start >= horizon && row.start < availableThrough {
                guard !row.flags.contains(.provisional), row.latest?.attribution != .provisional else { continue }
                let sample = row.latest.flatMap { $0.date <= now ? $0 : nil }
                let observed = Applicability(sample.map { short ? $0.bindingWeekly : $0.companion } ?? .unknown)
                if observed != .unknown { applicability[row.cycle] = observed }
                else if !short, let prior = row.earlierCompanionSamples.last(where: { $0.date <= now }) {
                    applicability[row.cycle] = Applicability(prior.companion)
                }
                guard accepts(applicability[row.cycle] ?? .unknown),
                      row.deltaHundredths >= 0, row.coveredSeconds >= 0, row.quietSeconds >= 0 else { continue }
                // Only days with an actual live reading count, not backfill or quiet bridges.
                if let sample, sample.attribution == .live { days.insert(grid.position(sample.date).date) }
                let start = max(row.start, row.cycle.segmentStart)
                let end = min(row.end, row.cycle.reset, availableThrough)
                let seconds = min(row.coveredSeconds + row.quietSeconds, max(0, end.timeIntervalSince(start)))
                guard seconds > 0 else { continue }
                let slot = grid.position(row.start).slot
                debit += row.delta
                exposure += seconds * Self.prior(slot, short: short) / hour
                ownDebit[slot] += row.delta
                ownSeconds[slot] += seconds
                if abs(row.cycle.reset.timeIntervalSince(current.reset)) <= 600 {
                    cycleStart = min(cycleStart ?? row.cycle.segmentStart, row.cycle.segmentStart)
                    cycleSeconds += seconds
                    cycleDirect += min(row.coveredSeconds, seconds)
                    cycleDebit += row.delta
                }
            }
            // One hour of live readings in this cycle, or at least three (dense intervals are at most
            // 20 minutes, so 30 resolved minutes need three readings) over 30 minutes with some use.
            guard let cycleStart else { return UsageForecast.warmingUp }
            let span = current.date.timeIntervalSince(cycleStart)
            guard (span + epsilon >= hour && cycleSeconds + epsilon >= 0.75 * hour)
                    || (span + epsilon >= 1_800 && cycleDirect + epsilon >= 1_800 && cycleDebit > 0) else {
                return UsageForecast.warmingUp
            }

            var remainingPrior = 0.0
            var spans: [(slot: Int, seconds: Double)] = []
            var position = start
            while position < current.reset {
                let bounds = grid.bounds(position, seconds: 3_600)
                let end = min(bounds.end, current.reset)
                let slot = grid.position(bounds.start).slot
                let seconds = end.timeIntervalSince(position)
                spans.append((slot, seconds))
                remainingPrior += seconds * Self.prior(slot, short: short) / hour
                position = end
            }
            let own = min(1, Double(days.count) / 14)
            // The zero-use allowance scales with what is left of the window and fades as own days accumulate,
            // so one heavy first hour cannot project to ~100% (that takes ≥ ~17% in the first weekly hour).
            let base = short ? 0.5 : 2.0
            let shrink = max(base, 0.2 * remainingPrior * (1 - own))
            let rate = debit / (exposure + shrink)
            let lowRate = debit / (exposure + max(4 * base, shrink, 0.5 * remainingPrior))
            var expected = current.used
            var low = current.used
            for (slot, seconds) in spans {
                let prior = Self.prior(slot, short: short)
                let ownRate = ownSeconds[slot] + epsilon >= 1_800 ? ownDebit[slot] * hour / ownSeconds[slot] : nil
                let nominal = ownRate.map { (1 - own) * rate * prior + own * $0 } ?? rate * prior
                let conservative = ownRate.map { (1 - own) * lowRate * prior + own * 0.5 * $0 } ?? lowRate * prior
                expected += nominal * seconds / hour
                low += conservative * seconds / hour
            }
            let remaining = current.reset.timeIntervalSince(now) / Double(current.series.meter.durationSeconds)
            let warning = low + epsilon >= 100 || (current.used >= 85 && remaining + epsilon >= 0.25)
            return ForecastResult(expectedUsed: min(100, max(current.used, expected)), exhaustProbability: nil, eta: nil,
                                  etaRange: nil, readiness: .quick, hitWeeks: 0, effectiveWeeks: 0,
                                  learningDays: min(14, days.count), quickWarning: warning)
        }

        /// Default hour-of-week activity in local time (relative, peak 1). Weekdays: nights 00–07 near zero,
        /// 07–09 waking up, 09–12 and 14–18 working peak, 12–14 lunch, 18–20 and 20–23 lighter evenings.
        /// Weekends stay light. A 0.05 floor keeps night owls from dividing by ~0; inside a 5-hour session the
        /// user is already active, so the shape only modulates a 0.5 floor.
        static let weekdayActivity: [Double] = [0.02, 0.02, 0.02, 0.02, 0.02, 0.02, 0.02, 0.4, 0.4, 1, 1, 1,
                                                0.7, 0.7, 1, 1, 1, 1, 0.5, 0.5, 0.35, 0.35, 0.35, 0.1]
        static let weekendActivity: [Double] = [0.02, 0.02, 0.02, 0.02, 0.02, 0.02, 0.02, 0.02, 0.15, 0.15, 0.25, 0.25,
                                                0.25, 0.25, 0.25, 0.25, 0.25, 0.25, 0.25, 0.25, 0.2, 0.2, 0.2, 0.05]

        static func prior(_ slot: Int, short: Bool) -> Double {
            let shape = slot >= 120 ? weekendActivity[slot % 24] : weekdayActivity[slot % 24]
            let floor = short ? 0.5 : 0.05
            return floor + (1 - floor) * shape
        }

        private func remainingSupport(_ profile: Profile) -> (sameHour: Double, repeated: Double, point: Double?) {
            var position = start
            var sameHour = 0.0
            var repeated = 0.0
            var total = current.used
            var supported = true
            while position < current.reset {
                let bounds = grid.bounds(position, seconds: 3_600)
                let end = min(bounds.end, current.reset)
                let seconds = end.timeIntervalSince(position)
                if let prior = profile.slots[grid.position(bounds.start).slot] {
                    if prior.sameHour { sameHour += seconds }
                    if prior.weeks >= 2 { repeated += seconds }
                    total += prior.rate * seconds / hour
                } else {
                    supported = false
                }
                position = end
            }
            return (sameHour, repeated, supported ? min(100, total) : nil)
        }

        private func weeklyPaths(_ history: History, profile: Profile) -> [Path] {
            let live = grid.wallSpans(from: now, to: current.reset)
            return (1...16).compactMap { week in
                let lag = Double(week * 7) * day
                let spans = weeklySpans(live, lag: lag)
                let mappedOrigin = spans.first?.source
                guard let origin = mappedOrigin ?? grid.calendar.date(byAdding: .day, value: -7 * week, to: now) else { return nil }
                if band != .absent {
                    guard mappedOrigin != nil, let sample = history.cap(at: origin),
                          band.matches(sample.companion, origin: origin, current: current.companion, now: now,
                                       matchReset: true) else { return nil }
                } else if let mappedOrigin, let sample = history.cap(at: mappedOrigin), Applicability(sample.companion) == .present {
                    return nil
                }
                return replay(origin, spans: spans, cycle: nil, history: history, profile: profile)
            }
        }

        private func weeklySpans(_ live: [Grid.WallSpan], lag: TimeInterval) -> [ReplaySpan] {
            // The padding keeps both occurrences of repeated clock times in the historical range.
            let history = grid.wallSpans(from: now.addingTimeInterval(-lag - 2 * day),
                                         to: current.reset.addingTimeInterval(-lag + 2 * day))
            let boundaries = Set(history.flatMap { [$0.start, $0.end] }).sorted()
            return live.flatMap { span in
                let start = span.start.addingTimeInterval(-lag)
                let end = span.end.addingTimeInterval(-lag)
                let cuts = [start] + boundaries.filter { start < $0 && $0 < end } + [end]
                return zip(cuts, cuts.dropFirst()).map { lower, upper in
                    let matches = history.filter { $0.start <= lower && lower < $0.end }
                    // An ordinary hour can supply either repeat. When both weeks repeat, match the offset.
                    let source = (matches.first { $0.offset == span.offset } ?? matches.first)?.absolute(lower)
                    return ReplaySpan(target: span.absolute(lower.addingTimeInterval(lag)), source: source,
                                      duration: upper.timeIntervalSince(lower))
                }
            }
        }

        private func sessionPaths(_ history: History, profile: Profile) -> (paths: [Path], wide: Bool) {
            let target = grid.position(now)
            let remaining = current.reset.timeIntervalSince(now)
            let usedBand = sessionBand(current.used)
            var narrow: [Path] = []
            var wide: [Path] = []
            var resets: Set<Date> = []
            let cycles = history.sessions.keys.sorted { ($0.reset, $0.segmentStart) > ($1.reset, $1.segmentStart) }
            for cycle in cycles where cycle.reset <= now {
                let origin = cycle.reset.addingTimeInterval(-remaining)
                let local = grid.position(origin)
                let difference = abs(local.second - target.second)
                let distance = min(difference, day - difference)
                let span = ReplaySpan(target: now, source: origin, duration: remaining)
                guard origin >= cycle.segmentStart, local.weekend == target.weekend, distance <= 4 * hour,
                      !resets.contains(cycle.reset), let samples = history.sessions[cycle],
                      let reading = history.sessionUsed(cycle, samples: samples, at: origin, grid: grid),
                      reading.used < 100, sessionBand(reading.used) == usedBand,
                      band.matches(reading.binding, origin: origin, current: current.bindingWeekly, now: now, matchReset: false),
                      let path = replay(origin, spans: [span], cycle: cycle, history: history, profile: profile) else { continue }
                resets.insert(cycle.reset)
                if distance <= 2 * hour { narrow.append(path) }
                if wide.count < 40 { wide.append(path) }
                if narrow.count == 40 { break }
            }
            if narrow.count >= 12 { return (narrow, false) }
            return (wide, true)
        }

        private func sessionBand(_ used: Double) -> Int {
            if used >= 80 { return 2 }
            return used >= 50 ? 1 : 0
        }

        private func replay(_ origin: Date, spans: [ReplaySpan], cycle: QuotaCycle?, history: History, profile: Profile) -> Path? {
            var replay = Replay(used: current.used)
            for span in spans {
                replaySpan(span, cycle: cycle, history: history, profile: profile, replay: &replay)
                if replay.observed.crossing != nil { break }
            }
            let considered = replay.observed.crossing ?? duration
            let coverage = considered > 0 ? min(1, replay.covered / considered) : 0
            guard coverage + epsilon >= 0.7, !replay.unsupported || replay.observed.crossing != nil else { return nil }
            return Path(week: grid.position(origin).week, age: now.timeIntervalSince(origin), coverage: coverage, replay: replay)
        }

        private func replaySpan(_ span: ReplaySpan, cycle: QuotaCycle?, history: History, profile: Profile, replay: inout Replay) {
            let offset = span.target.timeIntervalSince(start)
            let skip = max(0, -offset)
            guard skip < span.duration else { return }
            let first = span.source ?? span.target
            let last = first.addingTimeInterval(span.duration)
            var position = first.addingTimeInterval(skip)
            while position < last {
                let bounds = grid.bounds(position, seconds: bucketSeconds)
                let end = min(bounds.end, last)
                let prior = profile.slots[grid.position(bounds.start).slot]
                var cursor = position
                for cell in (span.source != nil ? history.cells[bounds.start] : nil) ?? [] where cycle == nil || cell.cycle == cycle {
                    let lower = max(cursor, cell.start)
                    let upper = min(end, cell.end)
                    guard upper > lower else { continue }
                    if lower > cursor {
                        replay.add(at: offset + cursor.timeIntervalSince(first), seconds: lower.timeIntervalSince(cursor),
                                   fraction: 0, debit: 0, prior: prior)
                    }
                    let seconds = upper.timeIntervalSince(lower)
                    replay.add(at: offset + lower.timeIntervalSince(first), seconds: seconds, fraction: cell.fraction,
                               debit: seconds * cell.debitPerSecond, prior: prior)
                    cursor = upper
                    if replay.observed.crossing != nil { break }
                }
                if replay.observed.crossing != nil { break }
                if cursor < end {
                    replay.add(at: offset + cursor.timeIntervalSince(first), seconds: end.timeIntervalSince(cursor),
                               fraction: 0, debit: 0, prior: prior)
                }
                position = end
            }
        }
    }
}

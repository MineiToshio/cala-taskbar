import Foundation

struct UsagePaceHistory {
    private var samples: [String: [(date: Date, used: Double)]] = [:]

    private static func hasStableScope(_ key: String) -> Bool {
        // Older Claude model keys used array positions, so their samples may already mix models.
        !key.hasPrefix("claude|weekly_scoped-") && key != "claude|\(UsageWindow.unidentifiedClaudeScope)"
    }

    static func key(_ provider: UsageProvider, _ window: UsageWindow) -> String? {
        let key = provider.rawValue + "|" + window.id
        return hasStableScope(key) ? key : nil
    }

    func pace(_ provider: UsageProvider, _ window: UsageWindow, now: Date) -> PaceResult? {
        let recent = Self.key(provider, window).flatMap { samples[$0] } ?? []
        return UsagePaceProjection.pace(window, samples: recent, now: now)
    }

    mutating func ingest(_ reading: UsageReading, for provider: UsageProvider, now: Date) {
        for window in reading.windows where window.used.isFinite {
            guard let key = Self.key(provider, window) else { continue }
            var list = samples[key] ?? []
            if let last = list.last {
                if last.date == reading.date { continue }
                if window.used < last.used - 5 { list.removeAll() }  // The window reset.
            }
            list.append((reading.date, window.used))
            list = list.filter { now.timeIntervalSince($0.date) <= 43_200 }
            if list.count > 600 { list.removeFirst(list.count - 600) }
            samples[key] = list
        }
    }

    mutating func restore(_ raw: [String: [[Double]]], now: Date) {
        for (key, rows) in raw where Self.hasStableScope(key) {
            let list = rows.compactMap { row -> (date: Date, used: Double)? in
                guard row.count == 2, row[0].isFinite, row[1].isFinite else { return nil }
                let date = Date(timeIntervalSince1970: row[0])
                return date <= now.addingTimeInterval(5) && now.timeIntervalSince(date) <= 43_200
                    ? (date, min(100, max(0, row[1]))) : nil
            }.sorted { $0.date < $1.date }
            if !list.isEmpty { samples[key] = list }
        }
    }

    var persistedSamples: [String: [[Double]]] {
        samples.mapValues { $0.map { [$0.date.timeIntervalSince1970, $0.used] } }
    }
}

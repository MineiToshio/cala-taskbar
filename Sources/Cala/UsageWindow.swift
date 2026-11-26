import Foundation

// Usage values are safe to cache. Credentials never enter a published or persisted object.
enum UsageProvider: String, Codable, CaseIterable {
    case claude, codex
    var title: String { self == .claude ? "Claude" : "Codex" }
    var glyph: String { self == .claude ? "✳" : "⬡" }
    var trayID: String { "__t_usage_" + rawValue }
    var interval: TimeInterval { self == .claude ? 120 : 60 }
}

struct UsageReading: Codable {
    var windows: [UsageWindow]
    var plan: String?
    var date: Date
    var apiDate: Date? = nil
}

struct UsageWindow: Codable, Identifiable {
    static let unidentifiedClaudeScope = "weekly_scoped:unidentified"

    var id: String
    var title: String
    var used: Double
    var resetsAt: Date?
    var durationMinutes: Double? = nil
    // Provider categories take precedence; old caches can recover duration from their title.
    var presentationOrder: (Int, Double) {
        let label = title.lowercased()
        let hours = label.hasSuffix(" h") ? Double(label.dropLast(2)) : nil
        let duration = [durationMinutes, hours.map { $0 * 60 }].compactMap { $0 }
            .first { $0.isFinite && $0 > 0 } ?? .infinity
        if id == "five_hour" || id == "session" || id.hasPrefix("session-") || label == "5-hour session" || label == "sesión de 5 horas" || duration == 300 {
            return (0, 300)
        }
        let scoped = id.hasPrefix("weekly_scoped") || id.hasPrefix("seven_day_") ||
            (label.hasPrefix("weekly ·") && label != "weekly · all models") ||
            (label.hasPrefix("semanal ·") && label != "semanal · todos los modelos")
        if scoped { return (2, 10080) }
        if id == "seven_day" || id.hasPrefix("weekly_all") || label == "weekly" || label == "weekly · all models" || label == "semanal" || label == "semanal · todos los modelos" || duration == 10080 {
            return (1, 10080)
        }
        return (3, duration)
    }
    func isResetting(_ now: Date) -> Bool { resetsAt.map { $0 <= now } ?? false }
    func effectiveUsed(_ now: Date) -> Double { isResetting(now) ? 0 : used }
}

struct PaceResult {
    var text: String
    /// The quota is projected to run out before it resets.
    var warn: Bool
    var secondsToEmpty: TimeInterval
    var secondsToReset: TimeInterval
}

enum UsagePaceProjection {
    private static func duration(_ w: UsageWindow) -> TimeInterval? {
        let seconds = (w.durationMinutes ?? w.presentationOrder.1) * 60
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }

    /// Exact remaining time, never rounded up: "2 d 3 h 12 min", "4 h 47 min", "16 min", "42 s".
    static func formatted(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))      // truncated: a countdown never claims more time than there is
        let d = total / 86400, h = (total % 86400) / 3600, m = (total % 3600) / 60
        var parts: [String] = []
        if d > 0 { parts.append("\(d) d") }
        if h > 0 { parts.append("\(h) h") }
        if m > 0 { parts.append("\(m) min") }
        return parts.isEmpty ? "\(total) s" : parts.joined(separator: " ")
    }

    /// Keeps the status line visible while an active window collects enough data to project a rate.
    static func pace(_ window: UsageWindow, samples: [(date: Date, used: Double)], now: Date) -> PaceResult? {
        guard let reset = window.resetsAt, (0..<100).contains(window.used) else { return nil }
        let untilReset = reset.timeIntervalSince(now)
        guard untilReset.isFinite, untilReset > 0 else { return nil }
        let remaining = 100 - window.used
        func result(_ text: String, warn: Bool = false, toEmpty: TimeInterval = .infinity) -> PaceResult {
            PaceResult(text: text, warn: warn, secondsToEmpty: toEmpty, secondsToReset: untilReset)
        }

        if window.used == 0 { return result(calendarText("Not used yet", "Sin uso todavía")) }
        let measuring = calendarText("Measuring pace…", "Midiendo el ritmo…")
        guard let total = duration(window) else { return result(measuring) }
        let elapsed = total - untilReset
        // An early burst can dominate the window average. A few percentage points can also be rounding noise.
        // Wait for 10% of the window (at least 10 min) and 5 percentage points of cumulative use.
        guard elapsed >= max(600, total * 0.10), window.used >= 5 else { return result(measuring) }

        let lookback = max(1800, total * 0.05)
        let earliest = max(reset.addingTimeInterval(-total), now.addingTimeInterval(-lookback))
        let recent = samples.filter { $0.date >= earliest && $0.date <= now }
        var rate = window.used / elapsed   // percentage points per second
        if let first = recent.first, let last = recent.last {
            let span = last.date.timeIntervalSince(first.date), delta = last.used - first.used
            // Require at least half the lookback and enough change to dampen quantized provider readings.
            if span >= lookback * 0.5, delta >= 5 {
                rate = delta / span
            } else if span >= lookback * 0.8, delta <= 0 {
                return result(calendarText("No recent use", "Sin uso reciente"))
            }
        }

        let toEmpty = remaining / rate
        // Allow one microsecond for arithmetic noise at the strict 60-second boundary.
        if untilReset - toEmpty > 60.000_001 {
            let text = calendarText("At this pace it runs out in \(Self.formatted(toEmpty)), before the reset",
                                    "A este ritmo se agota en \(Self.formatted(toEmpty)), antes del reinicio")
            return result(text, warn: true, toEmpty: toEmpty)
        }
        let left = max(0, Int((remaining - rate * untilReset).rounded()))
        let text = calendarText("At this pace you reach the reset with ~\(left)% left",
                                "A este ritmo llegas al reinicio con ~\(left)% disponible")
        return result(text, toEmpty: toEmpty)
    }
}

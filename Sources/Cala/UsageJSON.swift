import Foundation
import CoreFoundation

enum UsageJSON {
    static func object(_ data: Data) -> [String: Any]? { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] }
    static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }
    static func boundedDate(_ value: Date?) -> Date? {
        guard let value, value.timeIntervalSince1970.isFinite, value.timeIntervalSince1970 >= 0, value.timeIntervalSince1970 < 253_402_300_800 else { return nil }
        return value
    }
    static func date(_ value: Any?) -> Date? {
        if let n = number(value), n > 0 { return boundedDate(Date(timeIntervalSince1970: n)) }
        guard let s = value as? String else { return nil }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = boundedDate(f.date(from: s)) { return d }
        f.formatOptions = [.withInternetDateTime]; return boundedDate(f.date(from: s))
    }
    static func window(_ id: String, _ title: String, _ used: Any?, _ reset: Any?, durationMinutes: Double? = nil) -> UsageWindow? {
        guard let n = number(used) else { return nil }
        return UsageWindow(id: id, title: title, used: max(0, min(100, n)), resetsAt: date(reset), durationMinutes: durationMinutes)
    }
    private static func scopeValue(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    static func claude(_ obj: [String: Any], at date: Date, local: Bool = false) -> UsageReading {
        var windows: [UsageWindow] = []
        if let limits = obj["limits"] as? [[String: Any]], !limits.isEmpty {
            var seen = Set<String>()
            for limit in limits {
                let kind = limit["kind"] as? String ?? ""
                let id: String
                let title: String
                switch kind {
                case "session":
                    id = kind
                    title = tx("5-hour session", "Sesión de 5 horas")
                case "weekly_all":
                    id = kind
                    title = tx("Weekly · all models", "Semanal · todos los modelos")
                case "weekly_scoped":
                    let model = (limit["scope"] as? [String: Any])?["model"] as? [String: Any]
                    let name = scopeValue(model?["display_name"])
                    if let modelID = scopeValue(model?["id"]) {
                        id = "\(kind):id:\(modelID)"
                    } else if let name {
                        id = "\(kind):name:\(name.lowercased())"
                    } else {
                        id = UsageWindow.unidentifiedClaudeScope
                    }
                    title = tx("Weekly · ", "Semanal · ") + (name ?? tx("model", "modelo"))
                default: continue
                }
                if let w = window(id, title, limit["percent"], limit["resets_at"]), seen.insert(id).inserted { windows.append(w) }
            }
        } else {
            for (key, title) in [("five_hour", tx("5-hour session", "Sesión de 5 horas")), ("seven_day", tx("Weekly · all models", "Semanal · todos los modelos")), ("seven_day_opus", tx("Weekly · ", "Semanal · ") + "Opus"), ("seven_day_sonnet", tx("Weekly · ", "Semanal · ") + "Sonnet")] {
                if let d = obj[key] as? [String: Any], let w = window(key, title, d[local ? "used_percentage" : "utilization"], d["resets_at"]) { windows.append(w) }
            }
        }
        return UsageReading(windows: windows, plan: nil, date: date, apiDate: local ? nil : date)
    }
    static func codex(_ obj: [String: Any], at date: Date, format: String) -> UsageReading {
        var windows: [UsageWindow] = []
        for key in ["primary", "secondary"] {
            guard let d = obj[key + (format == "http" ? "_window" : "")] as? [String: Any],
                  let duration = number(d[format == "rpc" ? "windowDurationMins" : (format == "http" ? "limit_window_seconds" : "window_minutes")]), duration > 0 else { continue }
            let minutes = format == "http" ? duration / 60 : duration
            let title = minutes == 300 ? tx("5-hour session", "Sesión de 5 horas") : (minutes == 10080 ? tx("Weekly", "Semanal") : String(format: "%g h", minutes / 60))
            var reset = d[format == "rpc" ? "resetsAt" : (format == "http" ? "reset_at" : "resets_at")]
            if reset == nil, let after = number(d["reset_after_seconds"]) { reset = date.timeIntervalSince1970 + after }
            if let w = window(key, title, d[format == "rpc" ? "usedPercent" : "used_percent"], reset, durationMinutes: minutes) { windows.append(w) }
        }
        return UsageReading(windows: windows, plan: obj[format == "rpc" ? "planType" : "plan_type"] as? String, date: date)
    }
}

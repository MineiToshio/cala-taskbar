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
    private static let fractionalDates: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let wholeDates = ISO8601DateFormatter()
    static func date(_ value: Any?) -> Date? {
        if let n = number(value), n > 0 { return boundedDate(Date(timeIntervalSince1970: n)) }
        guard let s = value as? String else { return nil }
        return boundedDate(fractionalDates.date(from: s) ?? wholeDates.date(from: s))
    }
    static func window(_ id: String, _ title: String, _ used: Any?, _ reset: Any?, durationMinutes: Double? = nil) -> UsageWindow? {
        guard let n = number(used) else { return nil }
        return UsageWindow(id: id, title: title, used: max(0, min(100, n)), resetsAt: date(reset), durationMinutes: durationMinutes)
    }
    private static func scopeValue(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }

    private static func applicability(_ object: [String: Any], meter: String) -> UsageReading.Applicability {
        if boolean(object[meter + "_applicable"]) == false { return .absent }
        if object[meter + "_status"] as? String == "inactive" { return .inactive }
        return boolean(object[meter + "_applicable"]) == true ? .present : .unknown
    }

    private static func capture(_ object: [String: Any], id: String, duration: Double?, used: Any?, reset: Any?,
                                received: Date, calculated: Bool = false) -> UsageReading.Meter {
        let timestamp = object["timestamp"] ?? object["observed_at"] ?? object["observedAt"]
        return UsageReading.Meter(id: id, durationMinutes: duration, used: number(used), reset: date(reset),
                                  date: timestamp == nil ? received : (date(timestamp) ?? .distantPast),
                                  calculated: calculated, inactive: object["status"] as? String == "inactive")
    }

    static func claude(_ obj: [String: Any], at date: Date, local: Bool = false) -> UsageReading {
        var windows: [UsageWindow] = []
        var quota = UsageReading.Payload(plan: obj["plan_type"] as? String,
                                         short: applicability(obj, meter: "five_hour"),
                                         weekly: applicability(obj, meter: "seven_day"),
                                         hardBlockUntil: boolean(obj["hard_blocked"]) == true ? Self.date(obj["unlock_at"]) : nil)
        if let limits = obj["limits"] as? [[String: Any]], !limits.isEmpty {
            var seen = Set<String>()
            for limit in limits {
                let kind = limit["kind"] as? String ?? ""
                let id: String
                let title: String
                switch kind {
                case "session":
                    id = kind
                    title = "5-hour session"
                case "weekly_all":
                    id = kind
                    title = "Weekly · all models"
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
                    title = "Weekly · " + (name ?? "model")
                default: continue
                }
                quota.windows.append(capture(limit, id: id, duration: kind == "session" ? 300 : 10080,
                                             used: limit["percent"], reset: limit["resets_at"], received: date))
                if let w = window(id, title, limit["percent"], limit["resets_at"]), seen.insert(id).inserted { windows.append(w) }
            }
        } else {
            for (key, title) in [("five_hour", "5-hour session"), ("seven_day", "Weekly · all models"),
                                 ("seven_day_opus", "Weekly · Opus"), ("seven_day_sonnet", "Weekly · Sonnet")] {
                guard let d = obj[key] as? [String: Any] else { continue }
                let used = d[local ? "used_percentage" : "utilization"]
                if !d.isEmpty {
                    quota.windows.append(capture(d, id: key, duration: key == "five_hour" ? 300 : 10080,
                                                 used: used, reset: d["resets_at"], received: date))
                }
                if let w = window(key, title, used, d["resets_at"]) { windows.append(w) }
            }
        }
        return UsageReading(windows: windows, plan: nil, date: date,
                            apiDate: local ? nil : date, quota: quota)
    }
    static func codex(_ obj: [String: Any], at date: Date, format: String) -> UsageReading {
        var windows: [UsageWindow] = []
        var quota = UsageReading.Payload(short: applicability(obj, meter: "five_hour"),
                                         weekly: applicability(obj, meter: "seven_day"),
                                         hardBlockUntil: boolean(obj["hard_blocked"]) == true ? Self.date(obj["unlock_at"]) : nil)
        for key in ["primary", "secondary"] {
            guard let d = obj[key + (format == "http" ? "_window" : "")] as? [String: Any], !d.isEmpty else { continue }
            let duration = number(d[format == "rpc" ? "windowDurationMins" : (format == "http" ? "limit_window_seconds" : "window_minutes")])
            let used = d[format == "rpc" ? "usedPercent" : "used_percent"]
            var reset = d[format == "rpc" ? "resetsAt" : (format == "http" ? "reset_at" : "resets_at")]
            let calculated = reset == nil && number(d["reset_after_seconds"]) != nil
            var capturedReset = reset
            if calculated, let after = number(d["reset_after_seconds"]) {
                reset = date.timeIntervalSince1970 + after
                let meterDate = Self.date(d["timestamp"] ?? d["observed_at"] ?? d["observedAt"]) ?? date
                capturedReset = meterDate.timeIntervalSince1970 + after
            }
            let scope = d["scope"] ?? obj["scope"]
            let scoped = scope as? [String: Any]
            let model = scoped?["model"] as? [String: Any]
            let modelID = scopeValue(d["model_id"] ?? d["modelId"] ?? obj["model_id"] ?? model?["id"])
            let id: String
            if let modelID { id = "model:" + modelID }
            else if scope == nil || scope as? String == "all" || scope as? String == "shared" { id = "shared" }
            else { id = "unidentified" }
            quota.windows.append(capture(d, id: id, duration: duration.map { format == "http" ? $0 / 60 : $0 },
                                         used: used, reset: capturedReset, received: date, calculated: calculated))
            guard let duration, duration > 0 else { continue }
            let minutes = format == "http" ? duration / 60 : duration
            let title = minutes == 300 ? "5-hour session" : (minutes == 10080 ? "Weekly" : String(format: "%g h", minutes / 60))
            if let w = window(key, title, used, reset, durationMinutes: minutes) { windows.append(w) }
        }
        return UsageReading(windows: windows, plan: obj[format == "rpc" ? "planType" : "plan_type"] as? String,
                            date: date, quota: quota)
    }

    /// Shared filter for realtime rollout reads and bounded history import.
    static func codexRollout(_ line: Data) -> (reading: UsageReading, account: String?, subject: String?)? {
        guard line.range(of: Data("token_count".utf8)) != nil,
              let object = object(line), object["type"] as? String == "event_msg",
              let payload = object["payload"] as? [String: Any], payload["type"] as? String == "token_count",
              let limits = payload["rate_limits"] as? [String: Any],
              limits["limit_id"] == nil || limits["limit_id"] is NSNull || limits["limit_id"] as? String == "codex",
              let time = date(object["timestamp"]) else { return nil }
        return (codex(limits, at: time, format: "local"),
                scopeValue(limits["account_id"] ?? payload["account_id"]),
                scopeValue(limits["user_id"] ?? limits["subject"] ?? payload["user_id"]))
    }
}

extension UsageWindow {
    // Older display caches contain titles in the language active when they were written.
    var titleKey: String {
        switch title {
        case "Sesión de 5 horas": return "5-hour session"
        case "Semanal": return "Weekly"
        case "Semanal · todos los modelos": return "Weekly · all models"
        case "Semanal · modelo": return "Weekly · model"
        default:
            let prefix = "Semanal · "
            if title.hasPrefix(prefix) { return "Weekly · " + title.dropFirst(prefix.count) }
            return title
        }
    }

    var localizedTitle: String {
        let key = titleKey
        switch key {
        case "5-hour session": return tx(key, "Sesión de 5 horas")
        case "Weekly": return tx(key, "Semanal")
        case "Weekly · all models": return tx(key, "Semanal · todos los modelos")
        case "Weekly · model": return tx(key, "Semanal · modelo")
        default:
            let prefix = "Weekly · "
            return key.hasPrefix(prefix) ? tx(prefix, "Semanal · ") + key.dropFirst(prefix.count) : key
        }
    }
}

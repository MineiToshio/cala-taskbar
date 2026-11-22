import Foundation

/// Turns a macOS crash report (`.ips`: a JSON header line followed by a JSON body) into the pieces Sentry needs to
/// show a readable stack and to group crashes by cause instead of lumping them together.
enum CrashSummary {
    struct Summary {
        let type: String          // e.g. "EXC_BREAKPOINT (SIGTRAP)"
        let value: String         // codes / termination reason
        let frames: [[String: Any]]   // Sentry order: oldest call first, crashing frame last
        let fingerprint: [String]
    }

    private static func dict(_ any: Any?) -> [String: Any] { any as? [String: Any] ?? [:] }

    static func parse(_ text: String) -> Summary? {
        // A report is a one-line JSON header, a newline, then the JSON body. Older .crash text files are not handled.
        guard let newline = text.firstIndex(of: "\n"),
              let data = String(text[text.index(after: newline)...]).data(using: .utf8),
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let exception = dict(body["exception"])
        let kind = exception["type"] as? String ?? "crash"
        let signal = exception["signal"] as? String
        let type = signal.map { "\(kind) (\($0))" } ?? kind
        let termination = dict(body["termination"])
        var value = (exception["codes"] as? String) ?? ""
        if let indicator = termination["indicator"] as? String { value += (value.isEmpty ? "" : " · ") + indicator }
        if let reasons = termination["reasons"] as? [String], let first = reasons.first { value += (value.isEmpty ? "" : " · ") + first }

        let threads = body["threads"] as? [[String: Any]] ?? []
        let faulting = (body["faultingThread"] as? Int) ?? threads.firstIndex { ($0["triggered"] as? Bool) == true } ?? 0
        guard threads.indices.contains(faulting) else { return nil }
        let images = body["usedImages"] as? [[String: Any]] ?? []
        let raw = threads[faulting]["frames"] as? [[String: Any]] ?? []
        let frames: [[String: Any]] = raw.prefix(40).map { f in
            var out: [String: Any] = [:]
            if let i = f["imageIndex"] as? Int, images.indices.contains(i) {
                out["module"] = images[i]["name"] as? String ?? images[i]["path"] as? String
            }
            if let symbol = f["symbol"] as? String { out["function"] = symbol }
            if let offset = f["imageOffset"] as? Int { out["instruction_addr"] = String(format: "0x%llx", offset); out["package"] = out["module"] }
            out["in_app"] = (out["module"] as? String) == "Cala"
            return out
        }.reversed()
        guard !frames.isEmpty else { return nil }

        // Group by cause: crash type plus the innermost frames that belong to Cala (falling back to the top frame).
        let ours = frames.reversed().filter { ($0["in_app"] as? Bool) == true }.prefix(3)
        let key = (ours.isEmpty ? Array(frames.reversed().prefix(2)) : Array(ours)).map { f -> String in
            (f["function"] as? String) ?? "\(f["module"] as? String ?? "?")+\(f["instruction_addr"] as? String ?? "?")"
        }
        return Summary(type: type, value: value, frames: frames, fingerprint: ["cala-crash", type] + key)
    }

    /// Extra event fields (exception, fingerprint) merged into the Sentry crash event; empty if the report is unreadable.
    static func payload(_ text: String) -> [String: Any] {
        guard let s = parse(text) else { return [:] }
        return [
            "exception": ["values": [["type": s.type, "value": s.value,
                                       "mechanism": ["type": "generic", "handled": false],
                                       "stacktrace": ["frames": s.frames]] as [String: Any]]],
            "fingerprint": s.fingerprint,
        ]
    }
}

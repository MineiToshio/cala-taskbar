import Foundation

/// Sends reports to a Sentry project over its public HTTP envelope API, with no SDK and no background activity:
/// nothing is sent unless the user presses Send (or chose "send crash reports automatically").
/// The DSN is not stored in the repository: `build.sh` writes it into the app's Info.plist from `CALA_SENTRY_DSN`.
enum Telemetry {
    struct Attachment {
        let filename: String
        let text: String
    }
    enum Kind: String { case problem, suggestion, other, crash }
    struct Outcome {
        let ok: Bool
        let detail: String
    }

    /// Only for tests: points the transport at a local server.
    static var dsnOverride: String?
    static var dsn: String? {
        if let dsnOverride { return dsnOverride }
        let value = Bundle.main.object(forInfoDictionaryKey: "CalaSentryDSN") as? String
        return value?.isEmpty == false ? value : nil
    }
    static var isConfigured: Bool { dsn.flatMap(endpoint) != nil }

    /// `https://<key>@<host>/<project>` -> `https://<host>/api/<project>/envelope/`
    static func endpoint(for dsn: String) -> URL? {
        guard let u = URL(string: dsn), let host = u.host, let key = u.user, !key.isEmpty, !u.lastPathComponent.isEmpty, u.lastPathComponent != "/" else { return nil }
        var c = URLComponents()
        c.scheme = u.scheme; c.host = host; c.port = u.port
        c.path = "/api/\(u.lastPathComponent)/envelope/"
        return c.url
    }
    private static func key(of dsn: String) -> String { URL(string: dsn)?.user ?? "" }

    static func appVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
    static func appBuild() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    private static func json(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
    }

    /// Builds the envelope: a header line, then each item as a header line plus its payload.
    static func envelope(dsn: String, kind: Kind, message: String, email: String?, tags: [String: String],
                         contexts: [String: Any], attachments: [Attachment], now: Date = Date(), eventID: String = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()) -> Data {
        var body = Data()
        func line(_ d: Data) { body.append(d); body.append(10) }
        let stamp = ISO8601DateFormatter().string(from: now)
        line(json(["event_id": eventID, "sent_at": stamp, "dsn": dsn]))

        var ctx = contexts
        var payload: [String: Any] = ["event_id": eventID, "timestamp": now.timeIntervalSince1970, "platform": "cocoa",
                                      "release": "cala@" + appVersion(), "tags": tags.merging(["kind": kind.rawValue]) { a, _ in a }]
        if kind == .crash {
            payload["level"] = "fatal"
            payload["message"] = message
            payload["contexts"] = ctx
            let item = json(payload)
            line(json(["type": "event", "length": item.count])); line(item)
        } else {
            var feedback: [String: Any] = ["message": message, "source": "cala-app"]
            if let email, !email.isEmpty { feedback["contact_email"] = email }
            ctx["feedback"] = feedback
            payload["type"] = "feedback"
            payload["level"] = "info"
            payload["contexts"] = ctx
            let item = json(payload)
            line(json(["type": "feedback", "length": item.count])); line(item)
        }
        for a in attachments {
            let data = Data(a.text.utf8)
            line(json(["type": "attachment", "length": data.count, "filename": a.filename, "content_type": "text/plain"]))
            line(data)
        }
        return body
    }

    /// Calls back on the main thread.
    static func send(kind: Kind, message: String, email: String?, tags: [String: String], contexts: [String: Any],
                     attachments: [Attachment], done: @escaping (Outcome) -> Void) {
        guard let dsn, let url = endpoint(for: dsn) else {
            DispatchQueue.main.async { done(Outcome(ok: false, detail: "not configured")) }
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/x-sentry-envelope", forHTTPHeaderField: "Content-Type")
        request.setValue("Sentry sentry_version=7, sentry_client=cala/\(appVersion()), sentry_key=\(key(of: dsn))", forHTTPHeaderField: "X-Sentry-Auth")
        request.setValue("Cala/\(appVersion())", forHTTPHeaderField: "User-Agent")
        request.httpBody = envelope(dsn: dsn, kind: kind, message: message, email: email, tags: tags, contexts: contexts, attachments: attachments)
        URLSession.shared.dataTask(with: request) { _, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            DispatchQueue.main.async {
                done(Outcome(ok: error == nil && (200..<300).contains(status), detail: error?.localizedDescription ?? "HTTP \(status)"))
            }
        }.resume()
    }
}

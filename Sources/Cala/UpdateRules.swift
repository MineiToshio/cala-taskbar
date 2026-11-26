import Foundation

enum AppLocationKind { case applications, translocated, diskImage, other }
enum InstallPath { case ready, needsAdmin, unsupported }

enum UpdateRules {
    static let assetLimit: Int64 = 200 * 1024 * 1024
    static let reserve: Int64 = 100 * 1024 * 1024

    static func requiredSpace(_ m: UpdateManifest) -> Int64? {
        guard (1...assetLimit).contains(m.dmg.size), m.app.unpackedSize > 0,
              m.app.unpackedSize <= (Int64.max - m.dmg.size - reserve) / 2 else { return nil }
        return m.dmg.size + 2 * m.app.unpackedSize + reserve
    }

    static func validPayload(_ m: UpdateManifest, testURLs: Bool) -> Bool {
        func hash(_ text: String) -> Bool {
            text.utf8.count == 64 && text.utf8.allSatisfy {
                (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
            }
        }
        guard m.schema == 1, requiredSpace(m) != nil, hash(m.dmg.sha256), hash(m.app.keychainHelperSHA256),
              m.notes.values.allSatisfy({ $0.utf8.count <= 8192 }),
              UpdateFeed.permitsRedirect(m.dmg.url, testURLs: testURLs) else { return false }
        if m.dmg.url.scheme == "http" { return true } // Already gated by permitsRedirect.
        return m.dmg.url.absoluteString.hasPrefix("https://github.com/MineiToshio/cala-taskbar/releases/download/")
    }

    static func evaluate(_ m: UpdateManifest, running: AppVersion, bundleId: String, os: OperatingSystemVersion,
                         highestSeen: AppVersion?, skipped: String?, blocked: Set<String>, testURLs: Bool) -> UpdateEvaluation {
        guard m.bundleId == bundleId, validPayload(m, testURLs: testURLs),
              let candidate = AppVersion(version: m.version, build: String(m.build)) else { return .manualInstall }
        guard candidate > running, highestSeen.map({ candidate >= $0 }) ?? true,
              !isBlocked(candidate, by: blocked) else { return .upToDate }
        guard AppVersion.supports(minimum: m.minimumSystemVersion, os: os) else {
            return .needsNewerMacOS(m.minimumSystemVersion)
        }
        if let skipped, AppVersion(version: skipped, build: String(m.build)) == candidate { return .skipped(m) }
        return .available(m)
    }

    static func isBlocked(_ candidate: AppVersion, by blocked: Set<String>) -> Bool {
        blocked.contains { value in
            let parts = value.split(separator: "+", omittingEmptySubsequences: false)
            return parts.count == 2 && AppVersion(version: String(parts[0]), build: String(parts[1])) == candidate
        }
    }

    static func classify(status: Int, headers: [String: String], error: URLError?) -> FeedFailure? {
        if error != nil { return .offline }
        func header(_ name: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let retry = header("Retry-After")
        if status == 429 || (status == 403 && (retry != nil || header("X-RateLimit-Remaining") == "0")) {
            var delay: TimeInterval?
            if let retry {
                if let seconds = UInt64(retry) { delay = Double(seconds) }
                else {
                    let date = DateFormatter()
                    date.locale = Locale(identifier: "en_US_POSIX")
                    date.timeZone = TimeZone(secondsFromGMT: 0)
                    date.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
                    delay = date.date(from: retry).map { max(0, $0.timeIntervalSinceNow) }
                }
            }
            return .rateLimited(retryAfter: delay)
        }
        return (200..<300).contains(status) ? nil : .feedUnavailable
    }

    static func mayCheckAutomatically(enabled: Bool, path: InstallPath) -> Bool {
        enabled && path != .unsupported
    }

    static func mayCheckManually(now: Date, lastManualAttempt: Date?) -> Bool {
        lastManualAttempt.map { now.timeIntervalSince($0) >= 60 } ?? true
    }

    // jitter is a uniform sample in 0...1, supplied by the caller.
    static func nextCheck(now: Date, lastAttempt: Date?, failures: Int, retryAfter: TimeInterval?, jitter: Double) -> Date {
        let sample = min(1, max(0, jitter))
        let delay: Double
        if failures > 0 { delay = min(24, pow(2, Double(min(6, failures - 1)))) * 3600 }
        else if lastAttempt == nil { delay = (2 + 8 * sample) * 60 }
        else { delay = (22 + 4 * sample) * 3600 }
        return max(now, (lastAttempt ?? now).addingTimeInterval(max(delay, retryAfter ?? 0)))
    }

    static func autoInstall(enabled: Bool, path: InstallPath, idleSeconds: Double, blockers: Int, presenting: Bool,
                            skipped: Bool, blocked: Bool, idleThreshold: Double) -> Bool {
        enabled && path == .ready && idleSeconds >= idleThreshold && blockers == 0 && !presenting && !skipped && !blocked
    }

    static func installPath(location: AppLocationKind, bundleWritable: Bool, parentWritable: Bool) -> InstallPath {
        guard location == .applications else { return .unsupported }
        return bundleWritable && parentWritable ? .ready : .needsAdmin
    }
}

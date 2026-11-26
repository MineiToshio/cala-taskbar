import Foundation

struct UpdateManifest: Codable, Equatable {
    struct Asset: Codable, Equatable {
        var url: URL
        var size: Int64
        var sha256: String
    }
    struct AppInfo: Codable, Equatable {
        var unpackedSize: Int64
        var keychainHelperSHA256: String
    }
    var schema: Int
    // In-memory fixtures can omit this argument. Codable still requires the key on the wire.
    var commit = ""
    var bundleId: String
    var version: String
    var build: Int
    var minimumSystemVersion: String
    var publishedAt: Date
    var dmg: Asset
    var app: AppInfo
    var notes: [String: String]
    var notesURL: URL?

    static func decodeSigned(_ data: Data) throws -> Self {
        struct Header: Decodable { let schema: Int }
        let decoder = JSONDecoder()
        let header = try decoder.decode(Header.self, from: data)
        // A future schema need not contain any v1 fields. Only its schema is actionable.
        guard header.schema == 1 else {
            return Self(schema: header.schema, bundleId: "", version: "", build: 0, minimumSystemVersion: "",
                        publishedAt: Date(timeIntervalSince1970: 0),
                        dmg: Asset(url: URL(fileURLWithPath: "/"), size: 0, sha256: ""),
                        app: AppInfo(unpackedSize: 0, keychainHelperSHA256: ""), notes: [:], notesURL: nil)
        }
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(Self.self, from: data)
        guard manifest.commit.utf8.count == 40, manifest.commit.utf8.allSatisfy({
            (48...57).contains($0) || (97...102).contains($0)
        }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [CodingKeys.commit], debugDescription: "Invalid commit SHA"))
        }
        return manifest
    }
}

enum UpdateEvaluation: Equatable {
    case upToDate, available(UpdateManifest), skipped(UpdateManifest), manualInstall, needsNewerMacOS(String)
}

enum FeedFailure: Error, Equatable {
    case offline, feedUnavailable, rateLimited(retryAfter: TimeInterval?), tooLarge
}

enum UpdateFeed {
    static let limit = 64 * 1024
    static let url = URL(string: "https://github.com/MineiToshio/cala-taskbar/releases/latest/download/latest.json")!

    static func configuration(version: String, background: Bool) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.httpAdditionalHeaders = ["User-Agent": "Cala/\(version)"]
        config.allowsConstrainedNetworkAccess = !background
        return config
    }

    static func permitsRedirect(_ url: URL, testURLs: Bool) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else { return false }
        if components.scheme?.lowercased() == "https" { return true }
        #if CALA_UPDATE_TEST
        if testURLs && components.scheme == "http" && host == "127.0.0.1",
           let port = components.port, (1...65535).contains(port) { return true }
        #endif
        return false
    }
}

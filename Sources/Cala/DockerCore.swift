import Foundation

enum DockerCommand: Equatable {
    case executable(String, [String])
    case openApp(String)
    case terminateApp(String)
}

enum DockerRuntime: Equatable {
    case desktop, colima(String), orbstack, rancher, podman(String?), unknown

    static let appRuntimes: [Self] = [.desktop, .orbstack, .rancher]

    static func detect(context: String, path: String, resolvedPath: String? = nil) -> Self {
        let resolved = resolvedPath ?? path
        let name = context.lowercased()
        let parts = resolved.split(separator: "/")
        if name == "desktop-linux" || [path, resolved].contains(where: { $0.hasSuffix("/.docker/run/docker.sock") }) { return .desktop }
        if let i = parts.firstIndex(of: ".colima"), i + 2 < parts.count, parts.last == "docker.sock" {
            return .colima(String(parts[i + 1]))
        }
        if name.hasPrefix("colima-"), context.count > 7 { return .colima(String(context.dropFirst(7))) }
        if name.hasPrefix("colima") { return .colima("default") }
        if name == "orbstack" || [path, resolved].contains(where: { $0.hasSuffix("/.orbstack/run/docker.sock") }) { return .orbstack }
        if name == "rancher-desktop" || [path, resolved].contains(where: { $0.hasSuffix("/.rd/docker.sock") }) { return .rancher }
        let socketNames = Set([path, resolved].compactMap(podmanSocketName))
        let genericContexts = ["podman-machine", "podman-rootful", "podman-rootless"]
        let contextName = name.hasPrefix("podman-") && !genericContexts.contains(name) && validMachineName(context) ? context : nil
        if name.hasPrefix("podman") || [path, resolved].contains(where: { $0.lowercased().contains("podman") }) {
            // A context can be an arbitrary alias. Explicit machine names must agree with the socket.
            let names = socketNames.union([contextName].compactMap { $0 })
            return .podman(names.count == 1 ? names.first : nil)
        }
        return .unknown
    }

    private static func podmanSocketName(_ path: String) -> String? {
        let parts = path.split(separator: "/")
        guard parts.count >= 2 else { return nil }
        let filename = parts[parts.count - 1]
        let parent = parts[parts.count - 2]
        let name: String
        if parent == "podman", filename.hasSuffix("-api.sock") {
            name = String(filename.dropLast("-api.sock".count))
        } else if filename == "podman.sock", parts.dropLast(2).contains("podman") {
            name = String(parent)
            guard !["podman", "machine", "applehv", "libkrun", "qemu"].contains(name) else { return nil }
        } else {
            return nil
        }
        return validMachineName(name) ? name : nil
    }

    private static func validMachineName(_ name: String) -> Bool {
        let allowed = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-".utf8
        guard let first = name.utf8.first, first != 45, first != 46 else { return false }
        return name.utf8.allSatisfy(allowed.contains)
    }

    // These are product names. The pane localizes the fallback for an unidentified engine.
    var displayName: String? {
        switch self {
        case .desktop: return "Docker Desktop"
        case .colima(let profile): return profile == "default" ? "Colima" : "Colima (\(profile))"
        case .orbstack: return "OrbStack"
        case .rancher: return "Rancher Desktop"
        case .podman: return "Podman"
        case .unknown: return nil
        }
    }

    var appID: String? {
        switch self {
        case .desktop: return "com.docker.docker"
        case .orbstack: return "dev.kdrag0n.MacVirt"
        case .rancher: return "io.rancherdesktop.app"
        default: return nil
        }
    }

    func command(start: Bool, dockerCLI: Bool) -> DockerCommand? {
        switch self {
        case .desktop:
            if start { return appID.map(DockerCommand.openApp) }
            return dockerCLI ? .executable("docker", ["desktop", "stop"]) : appID.map(DockerCommand.terminateApp)
        case .colima(let profile):
            let args = profile == "default" ? [] : ["--profile", profile]
            return .executable("colima", [start ? "start" : "stop"] + args)
        case .orbstack:
            return start ? appID.map(DockerCommand.openApp) : .executable("orb", ["stop"])
        case .rancher:
            return start ? appID.map(DockerCommand.openApp) : .executable("rdctl", ["shutdown"])
        case .podman(let machine):
            return machine.map { .executable("podman", ["machine", start ? "start" : "stop", $0]) }
        case .unknown:
            return nil
        }
    }
}

struct DockerEndpoint: Equatable, Identifiable {
    let context: String
    let path: String
    let resolvedPath: String
    let runtime: DockerRuntime
    let isContext: Bool

    var id: String { resolvedPath }
}

struct DockerResolution {
    let active: DockerEndpoint?
    let engines: [DockerEndpoint]
    let hasSocket: Bool
    let signedIn: Bool
}

enum DockerDiscovery {
    static let defaultPath = "/var/run/docker.sock"

    struct Config: Equatable {
        let currentContext: String?
        let registryNames: Set<String>

        static func read(_ data: Data?) -> Self {
            guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return Self(currentContext: nil, registryNames: [])
            }
            let names = (json["auths"] as? [String: Any]).map { Set($0.keys) } ?? []
            return Self(currentContext: json["currentContext"] as? String, registryNames: names)
        }
    }

    private struct Context: Decodable {
        struct Endpoint: Decodable { let Host: String? }
        let Name: String
        let Endpoints: [String: Endpoint]?
    }

    static func knownPaths(home: String, colimaProfiles: [String]) -> [(name: String, path: String)] {
        var paths: [(name: String, path: String)] = [
            ("desktop-linux", home + "/.docker/run/docker.sock"),
            ("orbstack", home + "/.orbstack/run/docker.sock"),
            ("rancher-desktop", home + "/.rd/docker.sock")
        ]
        for profile in Set(colimaProfiles + ["default"]).sorted() {
            let name = profile == "default" ? "colima" : "colima-" + profile
            paths.append((name, home + "/.colima/" + profile + "/docker.sock"))
        }
        return paths
    }

    static func socketPath(_ host: String, home: String) -> String? {
        guard host.hasPrefix("unix://") else { return nil }
        let path = String(host.dropFirst(7))
        let expanded = path.hasPrefix("~/") ? home + path.dropFirst() : path
        guard expanded.hasPrefix("/"), !expanded.utf8.contains(0) else { return nil }
        return expanded
    }

    static func contextPaths(_ metadata: [Data], home: String) -> [String] {
        contexts(metadata).values.compactMap { $0.Endpoints?["docker"]?.Host.flatMap { socketPath($0, home: home) } }
    }

    private static func contexts(_ metadata: [Data]) -> [String: Context] {
        let decoder = JSONDecoder()
        let entries = metadata.compactMap { try? decoder.decode(Context.self, from: $0) }
        return Dictionary(entries.map { ($0.Name, $0) }, uniquingKeysWith: { first, _ in first })
    }

    static func ownsSocket(_ canonicalPath: String, home: String, otherHomes: [String] = []) -> Bool {
        func comparable(_ value: String) -> String {
            let volume = "/System/Volumes/Data/"
            return value.lowercased().hasPrefix(volume.lowercased()) ? "/" + String(value.dropFirst(volume.count)) : value
        }
        func includes(_ home: String, _ path: String) -> Bool {
            path == home || path.hasPrefix(home + "/")
        }
        let path = comparable(canonicalPath)
        guard path.hasPrefix("/") else { return false }
        if includes(comparable(home), path) { return true }
        if otherHomes.contains(where: { includes(comparable($0), path) }) { return false }
        return !path.lowercased().hasPrefix("/users/") || includes("/Users/Shared", path)
    }

    static func resolve(home: String, config: Config, metadata: [Data], existing: Set<String>,
                        resolved: [String: String], known: [(name: String, path: String)] = [],
                        preferredApp: DockerRuntime? = nil, canonicalHome: String? = nil, otherHomes: [String] = []) -> DockerResolution {
        let current = config.currentContext.flatMap { $0.isEmpty ? nil : $0 } ?? "default"
        let contexts = contexts(metadata)
        func endpoint(_ name: String, _ path: String, isContext: Bool = true) -> DockerEndpoint? {
            guard let real = resolved[path], ownsSocket(real, home: canonicalHome ?? home, otherHomes: otherHomes) else { return nil }
            return DockerEndpoint(context: name, path: path, resolvedPath: real,
                                  runtime: DockerRuntime.detect(context: name, path: path, resolvedPath: real),
                                  isContext: isContext)
        }
        let named = contexts.keys.sorted().compactMap { name -> DockerEndpoint? in
            guard name != "default", let host = contexts[name]?.Endpoints?["docker"]?.Host,
                  let path = socketPath(host, home: home) else { return nil }
            return endpoint(name, path)
        }
        let discovered = known.compactMap { endpoint($0.name, $0.path, isContext: false) }
        let defaultEngine = endpoint("default", defaultPath)
        let liveNamed = (named + discovered).filter { existing.contains($0.resolvedPath) }
        let liveDefault = defaultEngine.flatMap { existing.contains($0.resolvedPath) ? $0 : nil }

        let active: DockerEndpoint?
        if current != "default", contexts[current] != nil {
            active = named.first { $0.context == current }
        } else {
            let direct = liveNamed.first { $0.isContext && $0.path == $0.resolvedPath }
            active = liveDefault ?? direct ?? liveNamed.first ?? (named + discovered).first { $0.runtime == preferredApp } ?? defaultEngine
        }

        var seen = Set<String>()
        let candidates = [active].compactMap { $0 } + named + [liveDefault].compactMap { $0 } + liveNamed.filter { !$0.isContext }
        let engines = candidates.filter { seen.insert($0.resolvedPath).inserted }
        let signedIn = config.registryNames.contains { $0.contains("docker.io") }
        return DockerResolution(active: active, engines: engines, hasSocket: !liveNamed.isEmpty || liveDefault != nil, signedIn: signedIn)
    }

}

struct DockerPort: Decodable {
    let PrivatePort: Int?
    let PublicPort: Int?
    let `Type`: String?
    let IP: String?
}

struct DockerMount: Decodable {
    let `Type`: String?
    let Name: String?
}

struct DockerContainer: Decodable, Identifiable {
    let Id: String?
    let Names: [String]?
    let Image: String?
    let ImageID: String?
    let State: String?
    let Status: String?
    let Created: TimeInterval?
    let Ports: [DockerPort]?
    let Labels: [String: String]?
    let Mounts: [DockerMount]?
    let SizeRw: Int64?

    var id: String { Id ?? "" }
    var name: String { Names?.first.map { String($0.drop(while: { $0 == "/" })) } ?? String(id.prefix(12)) }
    var project: String? { Labels?["com.docker.compose.project"].flatMap { $0.isEmpty ? nil : $0 } }
    var displayName: String {
        Labels?["com.docker.compose.service"].flatMap { $0.isEmpty ? nil : $0 } ?? name
    }
    var isRunning: Bool { State == "running" }
    var isActive: Bool { isRunning || State == "restarting" || State == "paused" }
    var exitCode: Int? {
        guard let Status, Status.hasPrefix("Exited ("),
              let end = Status.firstIndex(of: ")") else { return nil }
        return Int(Status[Status.index(Status.startIndex, offsetBy: 8)..<end])
    }
    var uptimeSeconds: TimeInterval? {
        guard isRunning, let Status, Status.hasPrefix("Up ") else { return nil }
        let words = Status.dropFirst(3).lowercased().split(separator: " ").filter { $0 != "about" }
        if words.first == "less" { return 0 }
        guard words.count >= 2 else { return nil }
        let amount = words[0] == "a" || words[0] == "an" ? 1 : Double(words[0])
        guard let amount, amount.isFinite, amount >= 0 else { return nil }
        switch words[1].hasSuffix("s") ? words[1].dropLast() : words[1] {
        case "second": return amount
        case "minute": return amount * 60
        case "hour": return amount * 3600
        case "day": return amount * 86_400
        case "week": return amount * 604_800
        case "month": return amount * 2_592_000
        case "year": return amount * 31_536_000
        default: return nil
        }
    }
    var publishedPort: DockerPublishedPort? { DockerPublishedPort.first(in: Ports ?? []) }

}

struct DockerPublishedPort: Equatable {
    let number: Int
    let ip: String

    var url: URL? {
        guard !ip.isEmpty else { return nil }
        let host: String
        if ip == "0.0.0.0" || ip == "::" {
            host = "localhost"
        } else if ip.contains(":") {
            let digits = Set("0123456789abcdefABCDEF:.".utf8)
            guard ip.utf8.allSatisfy(digits.contains) else { return nil }
            host = "[\(ip)]"
        } else {
            let octets = ip.split(separator: ".", omittingEmptySubsequences: false)
            guard octets.count == 4, octets.allSatisfy({ UInt8($0) != nil }) else { return nil }
            host = ip
        }
        return URL(string: "http://\(host):\(number)")
    }

    static func first(in ports: [DockerPort]) -> Self? {
        // min() preserves the first binding on ties. A second IPv4/IPv6 record
        // for the same public port must not replace the selected binding's IP.
        ports.lazy.compactMap { port -> Self? in
            guard port.Type?.lowercased() == "tcp", let number = port.PublicPort, (1...65535).contains(number),
                  let ip = port.IP else { return nil }
            let publication = Self(number: number, ip: ip)
            return publication.url == nil ? nil : publication
        }.min { $0.number < $1.number }
    }
}

struct DockerGroup: Identifiable {
    let project: String?
    let containers: [DockerContainer]

    var id: String? { project }
    var running: Int { containers.filter(\.isRunning).count }
    var countLabel: String { "\(running)/\(containers.count)" }

    static func build(_ containers: [DockerContainer]) -> [Self] {
        let groups = Dictionary(grouping: containers, by: \.project)
        func group(_ name: String?) -> Self {
            let sorted = groups[name, default: []].sorted {
                let order = $0.displayName.localizedStandardCompare($1.displayName)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            }
            return Self(project: name, containers: sorted)
        }
        let projects = groups.keys.compactMap { $0 }.sorted {
            let order = $0.localizedStandardCompare($1)
            return order == .orderedSame ? $0 < $1 : order == .orderedAscending
        }
        return projects.map { group($0) } + (groups[nil] == nil ? [] : [group(nil)])
    }
}

struct DockerImage: Decodable, Identifiable {
    let Id: String?
    let RepoTags: [String]?
    let Size: Int64?
    let Created: TimeInterval?
    let Containers: Int?

    var id: String { Id ?? "" }
    var reference: (repo: String, tag: String?)? {
        guard let ref = RepoTags?.first(where: { !$0.isEmpty && $0 != "<none>:<none>" && $0 != "<none>" }) else { return nil }
        if let colon = ref.lastIndex(of: ":"), ref.lastIndex(of: "/").map({ $0 < colon }) ?? true {
            return (String(ref[..<colon]), String(ref[ref.index(after: colon)...]))
        }
        return (ref, nil)
    }

    func inUse(by containers: [DockerContainer]) -> Bool { containers.contains { $0.ImageID == id } }
}

struct DockerVolume: Decodable, Identifiable {
    struct Usage: Decodable {
        let Size: Int64?
        let RefCount: Int?
    }

    let Name: String?
    let Driver: String?
    let CreatedAt: String?
    let Labels: [String: String]?
    let UsageData: Usage?

    var id: String { Name ?? "" }
    var size: Int64? { UsageData?.Size.flatMap { $0 >= 0 ? $0 : nil } }

    func usedBy(_ containers: [DockerContainer]) -> [String] {
        containers.filter { $0.Mounts?.contains { $0.Type == "volume" && $0.Name == id } == true }
            .map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

struct DockerVolumes: Decodable {
    let Volumes: [DockerVolume]?
}

struct DockerDiskUsage: Decodable {
    struct Cache: Decodable {
        let Size: Int64?
        let InUse: Bool?
        let Shared: Bool?
    }

    struct Summary<Item: Decodable>: Decodable {
        let TotalSize: Int64?
        let Reclaimable: Int64?
        let Items: [Item]?
    }

    let LayersSize: Int64?
    let Images: [DockerImage]?
    let Containers: [DockerContainer]?
    let Volumes: [DockerVolume]?
    let BuildCache: [Cache]?

    let ImageUsage: Summary<DockerImage>?
    let ContainerUsage: Summary<DockerContainer>?
    let VolumeUsage: Summary<DockerVolume>?
    let BuildCacheUsage: Summary<Cache>?

    var volumeSizes: [String: Int64] {
        Dictionary((VolumeUsage?.Items ?? Volumes ?? []).compactMap { volume in
            volume.size.map { (volume.id, $0) }
        }, uniquingKeysWith: { first, _ in first })
    }

    var totals: (used: Int64, reclaimable: Int64)? {
        if ImageUsage != nil || ContainerUsage != nil || VolumeUsage != nil || BuildCacheUsage != nil {
            return (dockerTotal([ImageUsage?.TotalSize, ContainerUsage?.TotalSize, VolumeUsage?.TotalSize, BuildCacheUsage?.TotalSize]),
                    dockerTotal([ImageUsage?.Reclaimable, ContainerUsage?.Reclaimable, VolumeUsage?.Reclaimable, BuildCacheUsage?.Reclaimable]))
        }
        guard LayersSize != nil || Images != nil || Containers != nil || Volumes != nil || BuildCache != nil else { return nil }
        let containers = Containers ?? [], volumes = Volumes ?? [], images = Images ?? []
        let cache = (BuildCache ?? []).filter { $0.Shared != true }
        let layers = max(0, LayersSize ?? dockerTotal(images.map(\.Size)))
        let unusedLayers = min(layers, dockerTotal(images.filter { image in
            image.Containers.map { $0 == 0 } ?? !image.inUse(by: containers)
        }.map(\.Size)))
        return (dockerTotal([layers, dockerTotal(containers.map(\.SizeRw)), dockerTotal(volumes.map(\.size)), dockerTotal(cache.map(\.Size))]),
                dockerTotal([unusedLayers, dockerTotal(containers.filter { !$0.isActive }.map(\.SizeRw)),
                             dockerTotal(volumes.filter { $0.UsageData?.RefCount == 0 }.map(\.size)),
                             dockerTotal(cache.filter { $0.InUse == false }.map(\.Size))]))
    }
}

func dockerTotal(_ sizes: [Int64?]) -> Int64 {
    sizes.reduce(0) { total, size in total + min(Int64.max - total, max(0, size ?? 0)) }
}

struct DockerStats: Decodable {
    struct Memory: Decodable {
        let usage: Int64?
        let stats: [String: Int64]?
    }

    let memory_stats: Memory?

    var ram: Int64? {
        guard let memory_stats, let usage = memory_stats.usage, usage >= 0 else { return nil }
        let cache = memory_stats.stats?["total_inactive_file"] ?? memory_stats.stats?["inactive_file"] ??
            memory_stats.stats?["cache"] ?? 0
        return usage - min(usage, max(0, cache))
    }
}

struct DockerEvent: Decodable {
    struct ActorData: Decodable {
        let ID: String?
        let Attributes: [String: String]?
    }

    let `Type`: String?
    let Action: String?
    let Actor: ActorData?
    let time: TimeInterval?
}

struct DockerCrashes {
    private(set) var ids = Set<String>()
    private var stopEvents: [String: TimeInterval] = [:]
    private var calaStops: [String: TimeInterval] = [:]

    mutating func clear() { ids.removeAll() }
    mutating func suppressStop(_ id: String, until expiry: TimeInterval) { calaStops[id] = expiry }
    mutating func cancelStop(_ id: String) { calaStops[id] = nil }

    mutating func receive(_ event: DockerEvent, now: TimeInterval) {
        guard event.Type == "container", let id = event.Actor?.ID, !id.isEmpty else { return }
        let time = event.time
        if let time { stopEvents = stopEvents.filter { $0.value >= time - 15 } }
        calaStops = calaStops.filter { $0.value >= now }
        switch event.Action {
        case "kill", "stop": stopEvents[id] = time
        case "start", "destroy":
            ids.remove(id)
            cancelStop(id)
            stopEvents[id] = nil
        case "die":
            let suppressed = calaStops.removeValue(forKey: id) != nil
            guard let raw = event.Actor?.Attributes?["exitCode"], let code = Int(raw), code != 0,
                  !suppressed else { return }
            if let time, let stop = stopEvents[id], (0...15).contains(time - stop) { return }
            ids.insert(id)
        default: break
        }
    }
}

struct DockerEventDebounce {
    private var firstEvent: TimeInterval?

    mutating func delay(afterEventAt now: TimeInterval) -> TimeInterval {
        let first = firstEvent ?? now
        firstEvent = first
        return max(0, min(0.3, first + 1 - now))
    }

    mutating func reset() { firstEvent = nil }
}

struct DockerListing: Equatable {
    let socket: String
    private let generation = UUID()

    func matches(current: Self?, endpoint: DockerEndpoint?) -> Bool {
        self == current && socket == endpoint?.resolvedPath
    }
}

struct DockerConfirmation {
    let key: String
    let listing: DockerListing

    func matches(_ key: String, shown: DockerListing?) -> Bool {
        self.key == key && listing == shown
    }
}

struct DockerUsageLoad {
    private var request: UUID?

    mutating func begin() -> UUID? {
        guard request == nil else { return nil }
        let token = UUID()
        request = token
        return token
    }

    mutating func invalidate() { request = nil }
    func accepts(_ token: UUID) -> Bool { request == token }
}

enum DockerEngineState: Equatable {
    enum Reason { case connection, context, command, timedOut }

    case notInstalled, stopped, starting, running, stopping, unreachable(Reason)

    var observesRuntimeApps: Bool {
        switch self {
        case .stopped, .starting, .unreachable: return true
        default: return false
        }
    }
}

enum DockerGlyphState: Equatable {
    case off, starting, running(Int), crashed(Int)

    static func resolve(_ state: DockerEngineState, running: Int, crashed: Bool) -> Self {
        switch state {
        case .running: return crashed ? .crashed(running) : .running(running)
        case .starting, .stopping: return .starting
        default: return .off
        }
    }
}

func dockerShellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

func dockerURLComponent(_ value: String) -> String {
    let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
    return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
}

enum DockerHTTPError: Error {
    case malformed, incomplete, status(Int)
}

struct DockerHTTPHead {
    static let separator = Data([13, 10, 13, 10])
    let status: Int
    let headers: [String: String]

    subscript(_ name: String) -> String? { headers[name.lowercased()] }
    var isChunked: Bool {
        self["transfer-encoding"]?.split(separator: ",").contains {
            $0.trimmingCharacters(in: .whitespaces).lowercased() == "chunked"
        } ?? false
    }

    static func parse(_ bytes: Data) throws -> (head: Self, remainder: Data) {
        guard let split = bytes.range(of: separator) else {
            throw bytes.count < 64 * 1024 ? DockerHTTPError.incomplete : DockerHTTPError.malformed
        }
        let lines = String(decoding: bytes[..<split.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        guard split.lowerBound - bytes.startIndex < 64 * 1024,
              let line = lines.first, line.hasPrefix("HTTP/1."),
              let field = line.split(separator: " ").dropFirst().first, let status = Int(field),
              (100...599).contains(status) else { throw DockerHTTPError.malformed }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { throw DockerHTTPError.malformed }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = headers[name].map { $0 + "," + value } ?? value
        }
        return (Self(status: status, headers: headers), bytes[split.upperBound...])
    }
}

struct DockerHTTPResponse {
    let head: DockerHTTPHead
    let body: Data

    static func parse(_ bytes: Data) throws -> Self {
        let (head, remainder) = try DockerHTTPHead.parse(bytes)
        if head.isChunked {
            var decoder = DockerChunks()
            let body = try decoder.append(remainder)
            guard decoder.finished else { throw DockerHTTPError.incomplete }
            return Self(head: head, body: body)
        }
        if let raw = head["content-length"] {
            guard let count = Int(raw), count >= 0 else { throw DockerHTTPError.malformed }
            guard remainder.count >= count else { throw DockerHTTPError.incomplete }
            return Self(head: head, body: remainder.prefix(count))
        }
        return Self(head: head, body: remainder)
    }
}

/// Exposes data as soon as it arrives, even in the middle of a chunk.
struct DockerChunks {
    private enum State { case size, body(Int), terminator, trailer, done }
    private var state = State.size
    private var line = Data()
    static let lineLimit = 64 * 1024
    var finished: Bool { if case .done = state { return true }; return false }

    mutating func append(_ bytes: Data) throws -> Data {
        var output = Data()
        var index = bytes.startIndex
        while index < bytes.endIndex {
            switch state {
            case .done:
                return output
            case .body(let left):
                let count = min(left, bytes.endIndex - index)
                output.append(bytes[index..<(index + count)])
                index += count
                state = left == count ? .terminator : .body(left - count)
            case .size, .terminator, .trailer:
                let byte = bytes[index]
                index += 1
                guard line.count < Self.lineLimit else { throw DockerHTTPError.malformed }
                line.append(byte)
                guard byte == 10 else { continue }
                guard line.count >= 2, line[line.count - 2] == 13 else { throw DockerHTTPError.malformed }
                let text = String(decoding: line.dropLast(2), as: UTF8.self)
                line.removeAll(keepingCapacity: true)
                switch state {
                case .size:
                    let hex = text.prefix(while: { $0 != ";" })
                    guard !hex.isEmpty, hex.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
                          let size = Int(hex, radix: 16) else { throw DockerHTTPError.malformed }
                    state = size == 0 ? .trailer : .body(size)
                case .terminator:
                    guard text.isEmpty else { throw DockerHTTPError.malformed }
                    state = .size
                case .trailer:
                    if text.isEmpty { state = .done }
                default: break
                }
            }
        }
        return output
    }
}

struct DockerEventStream {
    private let chunked: Bool
    private var chunks = DockerChunks()
    private var pending = Data()

    init(chunked: Bool = true) { self.chunked = chunked }

    var finished: Bool { chunked && chunks.finished }

    mutating func append(_ bytes: Data) throws -> [DockerEvent] {
        let data = chunked ? try chunks.append(bytes) : bytes
        var events: [DockerEvent] = []
        var cursor = data.startIndex
        for end in data.indices where data[end] == 10 {
            pending.append(data[cursor..<end])
            if let event = try? JSONDecoder().decode(DockerEvent.self, from: pending) { events.append(event) }
            pending.removeAll(keepingCapacity: true)
            cursor = end + 1
        }
        pending.append(data[cursor...])
        guard pending.count <= 1024 * 1024 else { throw DockerHTTPError.malformed }
        return events
    }
}

import Foundation

var checks = 0
func expect(_ label: String, _ condition: @autoclosure () throws -> Bool) throws {
    guard try condition() else {
        FileHandle.standardError.write(Data("FAIL docker: \(label)\n".utf8))
        exit(1)
    }
    checks += 1
}

func bytes(_ value: String) -> Data { Data(value.utf8) }

func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(type, from: bytes(json))
}

func context(_ name: String, _ host: String) -> Data {
    bytes(#"{"Name":"\#(name)","Endpoints":{"docker":{"Host":"\#(host)","SkipTLSVerify":false}}}"#)
}

func event(_ action: String, _ time: Int, code: String = "1", id: String = "a") throws -> DockerEvent {
    try decode(DockerEvent.self, #"{"Type":"container","Action":"\#(action)","Actor":{"ID":"\#(id)","Attributes":{"name":"web","exitCode":"\#(code)"}},"time":\#(time)}"#)
}

func chunk(_ text: String) -> String { String(text.utf8.count, radix: 16) + "\r\n" + text + "\r\n" }

func runChecks() throws {
    let home = "/Users/Sergio"
    let defaultPath = DockerDiscovery.defaultPath
    let desktop = home + "/.docker/run/docker.sock"
    let colima = home + "/.colima/food/docker.sock"
    let foreign = "/Users/Trabajo/.docker/run/docker.sock"
    let selected = bytes(#"{"currentContext":"desktop-linux","auths":{"https://index.docker.io/v1/":{}},"credsStore":"desktop"}"#)
    let contexts = [
        context("desktop-linux", "unix://" + desktop),
        context("desktop-alias", "unix:///tmp/docker-desktop-alias.sock"),
        context("colima-food", "unix://" + colima),
        context("remote", "ssh://engine"),
        context("tcp", "tcp://localhost:2375"),
        bytes("malformed")
    ]

    func resolve(_ config: Data?, _ existing: Set<String>,
                 _ paths: [String: String] = [:], _ metadata: [Data] = []) -> DockerResolution {
        DockerDiscovery.resolve(home: home, config: config, metadata: metadata, existing: existing, resolved: paths)
    }

    let local = resolve(selected, [defaultPath, desktop, colima],
                        [defaultPath: foreign, "/tmp/docker-desktop-alias.sock": desktop], contexts)
    try expect("current context wins over foreign default", local.active?.path == desktop && local.active?.context == "desktop-linux")
    try expect("deduplicated aliases, no remote engines", local.engines.map(\.context) == ["desktop-linux", "colima-food"])
    try expect("Docker Hub auth key", local.signedIn)
    let missing = resolve(nil, [defaultPath], [defaultPath: foreign])
    try expect("foreign symlink is rejected even if it is live", missing.active == nil && !missing.hasSocket && missing.engines.isEmpty)
    try expect("foreign user's name cannot share our prefix",
               !DockerDiscovery.ownsDefault("/Users/SergioOther/socket", home: home))
    let defaultEngine = resolve(nil, [defaultPath], [defaultPath: desktop], contexts)
    try expect("current omitted means default", defaultEngine.active?.context == "default" && defaultEngine.active?.resolvedPath == desktop)
    try expect("default alias acquires the correct runtime", defaultEngine.active?.runtime == .desktop)
    let fallback = resolve(nil, [desktop], [defaultPath: foreign, "/tmp/docker-desktop-alias.sock": desktop], contexts)
    try expect("socket fallback with default rejected", fallback.active?.context == "desktop-linux")
    let stopped = resolve(selected, [colima], [:], contexts)
    try expect("explicit current context stays selected while stopped", stopped.active?.context == "desktop-linux")
    let remote = resolve(bytes(#"{"currentContext":"remote"}"#), [defaultPath], [:], contexts)
    try expect("remote current context ignored", remote.active == nil && !remote.engines.contains { $0.context == "remote" })
    try expect("credential helpers are not login evidence", !resolve(bytes(#"{"credsStore":"desktop"}"#), []).signedIn)
    try expect("tilde expands for the supplied home", DockerDiscovery.socketPath("unix://~/.docker/run/docker.sock", home: home) == desktop)
    let known = DockerDiscovery.knownPaths(home: home, colimaProfiles: ["food"])
    let app = DockerDiscovery.resolve(home: home, config: nil, metadata: [], existing: [],
                                      resolved: [defaultPath: foreign], known: known, preferredApp: .desktop)
    try expect("an installed app can be reached after its socket appears", app.active?.path == desktop && !app.hasSocket)

    try expect("Docker Desktop by name", DockerRuntime.detect(context: "desktop-linux", path: "/tmp/d.sock") == .desktop)
    try expect("Docker Desktop by path", DockerRuntime.detect(context: "other", path: desktop) == .desktop)
    try expect("Colima profile by name", DockerRuntime.detect(context: "colima-food", path: "/tmp/local.sock") == .colima("food"))
    try expect("Colima profile by path", DockerRuntime.detect(context: "other", path: colima) == .colima("food"))
    try expect("Colima default", DockerRuntime.detect(context: "colima", path: "") == .colima("default"))
    try expect("OrbStack by name", DockerRuntime.detect(context: "orbstack", path: "") == .orbstack)
    try expect("OrbStack by path", DockerRuntime.detect(context: "other", path: home + "/.orbstack/run/docker.sock") == .orbstack)
    try expect("Rancher Desktop by path", DockerRuntime.detect(context: "other", path: home + "/.rd/docker.sock") == .rancher)
    try expect("Rancher Desktop by name", DockerRuntime.detect(context: "rancher-desktop", path: "") == .rancher)
    try expect("Podman by name and path", DockerRuntime.detect(context: "podman-machine-default", path: "") == .podman &&
               DockerRuntime.detect(context: "other", path: "/var/folders/podman/socket") == .podman)
    try expect("unknown runtime has no command", DockerRuntime.detect(context: "default", path: defaultPath).command(start: true, dockerCLI: true) == nil)
    try expect("Desktop starts without CLI", DockerRuntime.desktop.command(start: true, dockerCLI: false) == .openApp("com.docker.docker"))
    try expect("Desktop stop CLI or app", DockerRuntime.desktop.command(start: false, dockerCLI: true) == .executable("docker", ["desktop", "stop"]) &&
               DockerRuntime.desktop.command(start: false, dockerCLI: false) == .terminateApp("com.docker.docker"))
    try expect("Colima command for named profile", DockerRuntime.colima("food").command(start: false, dockerCLI: true) ==
               .executable("colima", ["stop", "--profile", "food"]))
    try expect("Colima command for default profile", DockerRuntime.colima("default").command(start: true, dockerCLI: false) ==
               .executable("colima", ["start"]))
    try expect("OrbStack commands", DockerRuntime.orbstack.command(start: true, dockerCLI: true) == .openApp("dev.kdrag0n.MacVirt") &&
               DockerRuntime.orbstack.command(start: false, dockerCLI: true) == .executable("orb", ["stop"]))
    try expect("Podman commands", DockerRuntime.podman.command(start: true, dockerCLI: false) == .executable("podman", ["machine", "start"]) &&
               DockerRuntime.podman.command(start: false, dockerCLI: false) == .executable("podman", ["machine", "stop"]))
    try expect("Rancher Desktop commands", DockerRuntime.rancher.command(start: true, dockerCLI: false) == .openApp("io.rancherdesktop.app") &&
               DockerRuntime.rancher.command(start: false, dockerCLI: false) == .executable("rdctl", ["shutdown"]))

    let containers = try decode([DockerContainer].self, #"""
    [
      {"Id":"web-id","Names":["/garden-web-1"],"Image":"nginx:alpine","ImageID":"sha256:web","State":"running",
       "Status":"Up 2 hours (healthy)","Created":1750000000,
       "Ports":[{"IP":"0.0.0.0","PrivatePort":80,"PublicPort":8080,"Type":"tcp"},
                {"IP":"::","PrivatePort":80,"PublicPort":8080,"Type":"tcp"},
                {"IP":"127.0.0.1","PrivatePort":80,"PublicPort":3000,"Type":"tcp"},
                {"IP":"::","PrivatePort":53,"PublicPort":53,"Type":"udp"},
                {"PrivatePort":443,"Type":"tcp"}],
       "Labels":{"com.docker.compose.project":"garden","com.docker.compose.service":"web"},
       "Mounts":[{"Type":"volume","Name":"shared"},{"Type":"bind","Source":"/tmp/site"}]},
      {"Id":"db-id","Names":["/garden-db-1"],"Image":"postgres:17","ImageID":"sha256:pg","State":"exited",
       "Status":"Exited (17) 2 minutes ago","Labels":{"com.docker.compose.project":"garden","com.docker.compose.service":"db"},
       "Mounts":[{"Type":"volume","Name":"shared"},{"Type":"bind","Name":"bind-only"}]},
      {"Id":"a-id","Names":["/aardvark"],"State":"running","Labels":{"com.docker.compose.project":"alpha"}},
      {"Id":"z-id","Names":["/standalone"],"State":"created"},
      {"Id":"x-id","Names":["/alternate"],"State":"exited"}
    ]
    """#)
    let web = containers[0], db = containers[1]
    try expect("decode list fields", web.Image == "nginx:alpine" && web.Created == 1_750_000_000 &&
               web.Ports?.first?.PrivatePort == 80 && web.Ports?.first?.IP == "0.0.0.0")
    try expect("container name and compose service", web.name == "garden-web-1" && web.displayName == "web")
    try expect("running status time", web.isRunning && web.uptimeSeconds == 7200)
    try expect("exit status", !db.isRunning && db.exitCode == 17)
    try expect("port picks lowest published TCP and ignores IPv4/IPv6 duplicates", web.publishedPort == 3000 &&
               web.publishedURL?.absoluteString == "http://localhost:3000" && db.publishedURL == nil)
    let groups = DockerGroup.build(containers)
    try expect("sort projects and standalone", groups.map(\.project) == ["alpha", "garden", nil])
    try expect("stable alphabetical, even when stopped precedes running", groups[1].containers.map(\.displayName) == ["db", "web"])
    try expect("standalone names use slashless name", groups[2].containers.map(\.displayName) == ["alternate", "standalone"])
    try expect("project counts", groups.map(\.countLabel) == ["1/1", "1/2", "0/2"])

    let images = try decode([DockerImage].self, #"""
    [
      {"Id":"sha256:web","RepoTags":["registry:5000/team/nginx:alpine"],"Size":18754201,"Created":1750000000,"Containers":1},
      {"Id":"sha256:pg","RepoTags":["<none>:<none>"],"Size":150000},
      {"Id":"sha256:cached","RepoTags":null,"Size":12345}
    ]
    """#)
    try expect("image JSON fields", images[0].id == "sha256:web" && images[0].Size == 18_754_201 && images[0].Created == 1_750_000_000)
    try expect("image tag split after registry port", images[0].reference?.repo == "registry:5000/team/nginx" && images[0].reference?.tag == "alpine")
    try expect("untagged and null RepoTags", images[1].reference == nil && images[2].reference == nil)
    try expect("images are in use by running or stopped containers", images.map { $0.inUse(by: containers) } == [true, true, false])

    let volumes = try decode(DockerVolumes.self, #"""
    {"Volumes":[{"Name":"shared","Driver":"local","CreatedAt":"2025-06-15T14:00:00Z","Labels":{"com.docker.compose.volume":"data"}},
                {"Name":"bind-only","Driver":"local"}],"Warnings":null}
    """#)
    let shared = volumes.Volumes![0]
    try expect("volume metadata", shared.Driver == "local" && shared.CreatedAt != nil && shared.Labels?["com.docker.compose.volume"] == "data")
    try expect("volume use includes any container and filters mount type",
               shared.usedBy(containers) == ["garden-db-1", "garden-web-1"] && volumes.Volumes![1].usedBy(containers).isEmpty)
    try expect("volume size absent until df", shared.size == nil)
    let df = try decode(DockerDiskUsage.self, #"""
    {"LayersSize":1000,"Images":[{"Id":"sha256:unused","Size":250,"Containers":0},{"Id":"sha256:used","Size":900,"Containers":1}],
     "Containers":[{"Id":"a","State":"running","SizeRw":7},{"Id":"b","State":"exited","SizeRw":3}],
     "Volumes":[{"Name":"free","UsageData":{"Size":100,"RefCount":0}},
                {"Name":"shared","UsageData":{"Size":300,"RefCount":2}},{"Name":"unknown","UsageData":{"Size":-1,"RefCount":-1}}],
     "BuildCache":[{"Size":4,"InUse":false,"Shared":false},{"Size":200,"InUse":true,"Shared":true}]}
    """#)
    try expect("df decodes all legacy sections", df.LayersSize == 1000 && df.Images?.count == 2 &&
               df.Containers?.count == 2 && df.BuildCache?.count == 2)
    try expect("df volume sizes and refcount", df.volumeSizes == ["free": 100, "shared": 300] && df.Volumes?[1].UsageData?.RefCount == 2)
    try expect("df old disk totals", df.totals?.used == 1414 && df.totals?.reclaimable == 357)
    let modern = try decode(DockerDiskUsage.self, #"""
    {"ImageUsage":{"TotalSize":100,"Reclaimable":20},"VolumeUsage":{"TotalSize":80,"Reclaimable":15,
      "Items":[{"Name":"free","UsageData":{"Size":15,"RefCount":0}}]},
      "ContainerUsage":{"TotalSize":20,"Reclaimable":1},"BuildCacheUsage":{"TotalSize":50,"Reclaimable":10}}
    """#)
    try expect("modern df summaries and volume sizes", modern.totals?.used == 250 &&
               modern.totals?.reclaimable == 46 && modern.volumeSizes["free"] == 15)
    let stats = try decode(DockerStats.self, #"{"memory_stats":{"usage":1000,"stats":{"cache":400,"inactive_file":150}}}"#)
    try expect("RAM excludes page cache", stats.ram == 850)
    let minimal = try decode(DockerContainer.self, "{}")
    try expect("missing fields are tolerated", minimal.id.isEmpty && minimal.project == nil && minimal.Ports == nil)

    let length = try DockerHTTPResponse.parse(bytes("HTTP/1.1 200 OK\r\nCoNtEnT-LeNgTh: 2\r\nX-Engine: Docker\r\n\r\nOKjunk"))
    try expect("HTTP status, case-insensitive headers and content length",
               length.head.status == 200 && length.head["x-ENGINE"] == "Docker" && length.body == bytes("OK"))
    let eof = try DockerHTTPResponse.parse(bytes("HTTP/1.1 201 Created\r\nConnection: close\r\n\r\n {} "))
    try expect("HTTP body to EOF", eof.head.status == 201 && eof.body == bytes(" {} "))
    let framed = try DockerHTTPResponse.parse(bytes("HTTP/1.1 200 OK\r\nTransfer-Encoding: Chunked\r\n\r\n" +
                                                   "4;foo=bar\r\nDock\r\n" + chunk("er") + "0\r\nTrailer: value\r\n\r\n"))
    try expect("HTTP chunk extension and trailer", framed.body == bytes("Docker"))
    do {
        _ = try DockerHTTPResponse.parse(bytes("HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nAB"))
        try expect("HTTP truncated content length rejected", false)
    } catch DockerHTTPError.incomplete { try expect("HTTP truncated content length rejected", true) }
    do {
        _ = try DockerHTTPResponse.parse(bytes("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" + chunk("OK")))
        try expect("HTTP missing final chunk rejected", false)
    } catch DockerHTTPError.incomplete { try expect("HTTP missing final chunk rejected", true) }

    let first = #"{"Type":"container","Action":"die","Actor":{"ID":"a","Attributes":{"exitCode":"1","name":"wéb"}},"time":100}"# + "\n"
    let second = #"{"Type":"container","Action":"start","Actor":{"ID":"a","Attributes":{"name":"wéb"}},"time":110}"# + "\n"
    let halfway = first.index(first.startIndex, offsetBy: 17)
    let sample = bytes(chunk(String(first[..<halfway])) + chunk(String(first[halfway...]) + String(second.prefix(5))) +
                       chunk(String(second.dropFirst(5))) + "0\r\n\r\n")
    for split in 0...sample.count {
        var stream = DockerEventStream()
        let events = try stream.append(sample.prefix(split)) + stream.append(sample.dropFirst(split))
        try expect("stream split at byte \(split)", stream.finished && events.map(\.Action) == ["die", "start"] &&
                   events[0].Actor?.ID == "a" && events[0].Actor?.Attributes?["name"] == "wéb" && events[0].time == 100)
    }
    var byteStream = DockerEventStream()
    var eventLines: [DockerEvent] = []
    for byte in sample { eventLines += try byteStream.append(Data([byte])) }
    try expect("stream supports one byte reads", byteStream.finished && eventLines.count == 2)
    var plain = DockerEventStream(chunked: false)
    try expect("stream accepts unchunked lines", try plain.append(bytes(first + second)).count == 2)

    var crashes = DockerCrashes()
    crashes.receive(try event("die", 100), calaStopped: [])
    try expect("exited nonzero without stop is a crash", crashes.ids == ["a"])
    crashes.receive(try event("start", 101), calaStopped: [])
    try expect("start clears the crash mark", crashes.ids.isEmpty)
    crashes.receive(try event("kill", 110), calaStopped: [])
    crashes.receive(try event("die", 125), calaStopped: [])
    try expect("kill within 15 seconds suppresses a crash", crashes.ids.isEmpty)
    crashes.receive(try event("die", 126), calaStopped: [])
    try expect("older kill does not suppress a crash", crashes.ids == ["a"])
    crashes.clear()
    try expect("opening clears crash marks", crashes.ids.isEmpty)
    crashes.receive(try event("stop", 128, id: "another"), calaStopped: [])
    crashes.receive(try event("die", 130), calaStopped: [])
    try expect("stop for another id does not suppress a crash", crashes.ids == ["a"])
    crashes.clear()
    crashes.receive(try event("stop", 140), calaStopped: [])
    crashes.receive(try event("die", 150), calaStopped: [])
    try expect("recent stop suppresses a crash", crashes.ids.isEmpty)
    crashes.receive(try event("die", 180), calaStopped: ["a"])
    try expect("Cala stop suppresses a crash", crashes.ids.isEmpty)
    crashes.receive(try event("die", 200, code: "0"), calaStopped: [])
    try expect("zero exit is not a crash", crashes.ids.isEmpty)
    try expect("glyph transitions", DockerGlyphState.resolve(.stopped, running: 3, crashed: true) == .off &&
               DockerGlyphState.resolve(.starting, running: 0, crashed: false) == .starting &&
               DockerGlyphState.resolve(.stopping, running: 3, crashed: false) == .starting &&
               DockerGlyphState.resolve(.running, running: 3, crashed: false) == .running(3) &&
               DockerGlyphState.resolve(.running, running: 3, crashed: true) == .crashed(3))

    try expect("shell quotes spaces", dockerShellQuote("my container") == "'my container'")
    try expect("shell quotes single and double quotes", dockerShellQuote("my 'quoted' \"name\"") == "'my '\\''quoted'\\'' \"name\"'")
    try expect("shell quotes empty argument", dockerShellQuote("") == "''")
    try expect("URL argument cannot change the request target", dockerURLComponent(":/?\r\n") == "%3A%2F%3F%0D%0A")
    print("PASS docker: \(checks) checks")
}

do {
    #if DOCKER_CHECK
    if CommandLine.arguments.contains("--live") {
        guard let endpoint = DockerLocal.discover().active else { throw DockerSocketError.path }
        print("Docker context \(endpoint.context) · \(endpoint.resolvedPath)")
        let ping = try DockerSocket.request(endpoint, "/_ping")
        let list = try DockerSocket.request(endpoint, "/containers/json?all=1")
        let containers = try JSONDecoder().decode([DockerContainer].self, from: list.body)
        print("GET /_ping → HTTP \(ping.head.status) \(String(decoding: ping.body, as: UTF8.self))")
        print("GET /containers/json?all=1 → HTTP \(list.head.status) · \(containers.count) containers · \(containers.filter(\.isRunning).count) running")
    } else {
        try runChecks()
    }
    #else
    try runChecks()
    #endif
} catch {
    FileHandle.standardError.write(Data("FAIL docker: \(error)\n".utf8))
    exit(1)
}

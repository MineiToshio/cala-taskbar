import Foundation
#if DOCKER_CHECK
import Darwin
#endif

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
        let allPaths = Set(DockerDiscovery.contextPaths(metadata, home: home) + [defaultPath]).union(existing)
        let resolved = Dictionary(uniqueKeysWithValues: allPaths.map { ($0, paths[$0] ?? $0) })
        return DockerDiscovery.resolve(home: home, config: .read(config), metadata: metadata,
                                       existing: Set(existing.map { resolved[$0] ?? $0 }), resolved: resolved)
    }

    let local = resolve(selected, [defaultPath, desktop, colima],
                        [defaultPath: foreign, "/tmp/docker-desktop-alias.sock": desktop], contexts)
    try expect("current context wins over foreign default", local.active?.path == desktop && local.active?.context == "desktop-linux")
    try expect("deduplicated aliases, no remote engines", local.engines.map(\.context) == ["desktop-linux", "colima-food"])
    try expect("Docker Hub auth key", local.signedIn)
    let configFields = DockerDiscovery.Config.read(bytes(#"{"currentContext":"desktop-linux","auths":{"docker.io":{"auth":"secret","identitytoken":"token"},"example.org":null},"credsStore":"secret-helper","extra":"secret"}"#))
    try expect("config retains context and registry names only",
               configFields == DockerDiscovery.Config(currentContext: "desktop-linux", registryNames: ["docker.io", "example.org"]))
    try expect("invalid config returns empty fields", DockerDiscovery.Config.read(bytes("[123]")) == .read(nil))
    try expect("invalid auths don't discard context",
               DockerDiscovery.Config.read(bytes(#"{"currentContext":"colima","auths":"wrong"}"#)) ==
               DockerDiscovery.Config(currentContext: "colima", registryNames: []))
    let missing = resolve(nil, [defaultPath], [defaultPath: foreign])
    try expect("foreign symlink is rejected even if it is live", missing.active == nil && !missing.hasSocket && missing.engines.isEmpty)
    try expect("foreign user's name cannot share our prefix",
               !DockerDiscovery.ownsSocket("/Users/SergioOther/socket", home: home))
    let alias = "/tmp/foreign-engine.sock"
    let foreignContext = bytes(#"{"currentContext":"shared-alias"}"#)
    let rejected = resolve(foreignContext, [alias], [alias: foreign], [context("shared-alias", "unix://" + alias)])
    try expect("foreign named endpoint is neither active, listed nor installed", rejected.active == nil &&
               rejected.engines.isEmpty && !rejected.hasSocket)
    let direct = resolve(foreignContext, [foreign], [:], [context("shared-alias", "unix://" + foreign)])
    try expect("direct path in another user's home is rejected", direct.active == nil && !direct.hasSocket)
    let sharedEngine = DockerDiscovery.resolve(home: home, config: .read(nil), metadata: [], existing: [foreign],
                                        resolved: [desktop: foreign], known: [("desktop-linux", desktop)], preferredApp: .desktop)
    try expect("foreign known socket path is not an app fallback", sharedEngine.active == nil && !sharedEngine.hasSocket)
    try expect("APFS data-volume alias into a foreign home is rejected",
               !DockerDiscovery.ownsSocket("/System/Volumes/Data/Users/Trabajo/engine.sock", home: home))
    try expect("own home via APFS data-volume alias is allowed",
               DockerDiscovery.ownsSocket("/System/Volumes/Data/Users/Sergio/engine.sock", home: home))
    try expect("distinct homes can differ only by case on a case-sensitive disk",
               !DockerDiscovery.ownsSocket("/Users/sergio/engine.sock", home: home))
    try expect("socket in a locally registered custom home is rejected",
               !DockerDiscovery.ownsSocket("/Volumes/Work/Trabajo/engine.sock", home: home, otherHomes: ["/Volumes/Work/Trabajo"]))
    try expect("similarly named directory outside a custom home is allowed",
               DockerDiscovery.ownsSocket("/Volumes/Work/Trabajo-VM/engine.sock", home: home, otherHomes: ["/Volumes/Work/Trabajo"]))
    try expect("shared non-home directory and system run directory are allowed",
               DockerDiscovery.ownsSocket("/Users/Shared/engine.sock", home: home) &&
               DockerDiscovery.ownsSocket("/private/var/run/engine.sock", home: home))
    let unresolved = DockerDiscovery.resolve(home: home, config: .read(foreignContext),
                                            metadata: [context("shared-alias", "unix://" + alias)],
                                            existing: [alias], resolved: [:])
    try expect("unresolved socket can't be used", unresolved.active == nil && !unresolved.hasSocket)
    let defaultEngine = resolve(nil, [defaultPath], [defaultPath: desktop], contexts)
    try expect("current omitted means default", defaultEngine.active?.context == "default" && defaultEngine.active?.resolvedPath == desktop)
    try expect("default alias acquires the correct runtime", defaultEngine.active?.runtime == .desktop)
    let fallback = resolve(nil, [desktop], [defaultPath: foreign, "/tmp/docker-desktop-alias.sock": desktop], contexts)
    try expect("socket fallback with default rejected", fallback.active?.context == "desktop-linux")
    let stopped = resolve(selected, [colima], [:], contexts)
    try expect("explicit current context stays selected while stopped", stopped.active?.context == "desktop-linux")
    let remote = resolve(bytes(#"{"currentContext":"remote"}"#), [defaultPath], [:], contexts)
    try expect("remote current context ignored", remote.active == nil && !remote.engines.contains { $0.context == "remote" })
    let remoteConfig = bytes(#"{"currentContext":"remote"}"#)
    let oneLocal = resolve(remoteConfig, [colima], [:], [context("remote", "ssh://engine"),
                                                        context("colima-food", "unix://" + colima)])
    try expect("a remote active context still offers the single local context", oneLocal.engines.count == 1 &&
               DockerDiscovery.selectableContexts(oneLocal.engines, active: oneLocal.active, hasCLI: true).map(\.context) == ["colima-food"])
    let socketOnly = home + "/.orbstack/run/docker.sock"
    let withSocketOnly = DockerDiscovery.resolve(home: home, config: .read(remoteConfig),
                                                  metadata: [context("remote", "ssh://engine"), context("colima-food", "unix://" + colima)],
                                                  existing: [colima, socketOnly], resolved: [colima: colima, socketOnly: socketOnly],
                                                  known: [("orbstack", socketOnly)])
    try expect("socket-only engines do not appear in the switch menu", withSocketOnly.engines.count == 2 &&
               DockerDiscovery.selectableContexts(withSocketOnly.engines, active: withSocketOnly.active, hasCLI: true).map(\.context) == ["colima-food"])
    try expect("the active socket is not a switch option even under another context name",
               DockerDiscovery.selectableContexts(local.engines, active: defaultEngine.active, hasCLI: true).map(\.context) == ["colima-food"])
    try expect("the only active local context needs no switch menu",
               DockerDiscovery.selectableContexts(oneLocal.engines, active: oneLocal.engines.first, hasCLI: true).isEmpty)
    try expect("switching contexts requires the Docker CLI",
               DockerDiscovery.selectableContexts(oneLocal.engines, active: oneLocal.active, hasCLI: false).isEmpty)
    let beforeExternalStart = resolve(nil, [])
    let afterExternalStart = resolve(bytes(#"{"currentContext":"colima-food"}"#), [colima], [:],
                                     [context("colima-food", "unix://" + colima)])
    try expect("rediscovery moves from a missing default socket to the externally started context",
               beforeExternalStart.active?.path == defaultPath && !beforeExternalStart.hasSocket &&
               afterExternalStart.active?.resolvedPath == colima && afterExternalStart.hasSocket)
    try expect("credential helpers are not login evidence", !resolve(bytes(#"{"credsStore":"desktop"}"#), []).signedIn)
    try expect("tilde expands for the supplied home", DockerDiscovery.socketPath("unix://~/.docker/run/docker.sock", home: home) == desktop)
    let known = DockerDiscovery.knownPaths(home: home, colimaProfiles: ["food"])
    let app = DockerDiscovery.resolve(home: home, config: .read(nil), metadata: [], existing: [],
                                      resolved: [defaultPath: foreign, desktop: desktop], known: known, preferredApp: .desktop)
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
    try expect("Podman by explicit context name", DockerRuntime.detect(context: "podman-machine-default", path: "") ==
               .podman("podman-machine-default"))
    try expect("Podman custom name from context name", DockerRuntime.detect(context: "podman-build", path: "") ==
               .podman("podman-build"))
    try expect("Podman named machine from resolved socket",
               DockerRuntime.detect(context: "default", path: defaultPath,
                                    resolvedPath: "/private/var/folders/x/T/podman/work-api.sock") == .podman("work"))
    try expect("Podman machine name from a named socket directory",
               DockerRuntime.detect(context: "podman", path: "/Users/Sergio/.local/share/containers/podman/machine/work/podman.sock") ==
               .podman("work"))
    try expect("named context and socket agree",
               DockerRuntime.detect(context: "podman-machine-build", path: "/tmp/podman/podman-machine-build-api.sock") ==
               .podman("podman-machine-build"))
    try expect("Podman context and socket disagreement disables the toggle",
               DockerRuntime.detect(context: "podman-machine-default", path: "/tmp/podman/work-api.sock") == .podman(nil))
    try expect("different Podman machines in configured and resolved paths are ambiguous",
               DockerRuntime.detect(context: "podman", path: "/tmp/podman/work-api.sock",
                                    resolvedPath: "/tmp/podman/build-api.sock") == .podman(nil))
    try expect("generic Podman socket and context are ambiguous",
               DockerRuntime.detect(context: "podman", path: "/var/folders/podman/podman.sock") == .podman(nil))
    try expect("unsafe Podman machine argument is ignored",
               DockerRuntime.detect(context: "podman", path: "/tmp/podman/--help-api.sock") == .podman(nil))
    try expect("unknown runtime has no command", DockerRuntime.detect(context: "default", path: defaultPath).command(start: true, dockerCLI: true) == nil)
    try expect("Desktop starts in the background through its CLI, with the app as fallback",
               DockerRuntime.desktop.command(start: true, dockerCLI: false) ==
               .startApp(bundle: "com.docker.docker", executable: "docker", args: ["desktop", "start", "--detach"]) &&
               DockerRuntime.desktop.command(start: true, dockerCLI: true) == DockerRuntime.desktop.command(start: true, dockerCLI: false))
    try expect("app engines hide the window they open, command-line engines have none to hide",
               DockerRuntime.desktop.quietBundles == ["com.electron.dockerdesktop", "com.docker.docker"] &&
               DockerRuntime.orbstack.quietBundles == ["dev.kdrag0n.MacVirt"] &&
               DockerRuntime.rancher.quietBundles == ["io.rancherdesktop.app"] &&
               DockerRuntime.colima("default").quietBundles.isEmpty && DockerRuntime.podman("work").quietBundles.isEmpty &&
               DockerRuntime.unknown.quietBundles.isEmpty)
    try expect("quiet start only covers a fresh start and checks stay few and ordered",
               DockerQuietStart.isFresh(startedAt: 100, now: 100) && DockerQuietStart.isFresh(startedAt: 100, now: 145) &&
               !DockerQuietStart.isFresh(startedAt: 100, now: 145.1) && !DockerQuietStart.isFresh(startedAt: 100, now: 99) &&
               DockerQuietStart.checkDelays == DockerQuietStart.checkDelays.sorted() &&
               DockerQuietStart.checkDelays.count <= 80 && DockerQuietStart.checkDelays.filter { $0 > 8 }.count <= 8 && DockerQuietStart.checkDelays.allSatisfy { $0 > 0 && $0 <= DockerQuietStart.window } &&
               DockerQuietStart.launchDelays.count <= 4 && DockerQuietStart.launchDelays.allSatisfy { $0 < 5 })
    try expect("Desktop stop CLI or app", DockerRuntime.desktop.command(start: false, dockerCLI: true) == .executable("docker", ["desktop", "stop"]) &&
               DockerRuntime.desktop.command(start: false, dockerCLI: false) == .terminateApp("com.docker.docker"))
    try expect("Colima command for named profile", DockerRuntime.colima("food").command(start: false, dockerCLI: true) ==
               .executable("colima", ["stop", "--profile", "food"]))
    try expect("Colima command for default profile", DockerRuntime.colima("default").command(start: true, dockerCLI: false) ==
               .executable("colima", ["start"]))
    try expect("OrbStack commands", DockerRuntime.orbstack.command(start: true, dockerCLI: true) ==
               .startApp(bundle: "dev.kdrag0n.MacVirt", executable: "orb", args: ["start"]) &&
               DockerRuntime.orbstack.command(start: false, dockerCLI: true) == .executable("orb", ["stop"]))
    try expect("Podman commands target the named machine",
               DockerRuntime.podman("work").command(start: true, dockerCLI: false) == .executable("podman", ["machine", "start", "work"]) &&
               DockerRuntime.podman("work").command(start: false, dockerCLI: false) == .executable("podman", ["machine", "stop", "work"]))
    try expect("ambiguous Podman has no commands",
               DockerRuntime.podman(nil).command(start: true, dockerCLI: true) == nil &&
               DockerRuntime.podman(nil).command(start: false, dockerCLI: true) == nil)
    try expect("Rancher Desktop commands", DockerRuntime.rancher.command(start: true, dockerCLI: false) ==
               .startApp(bundle: "io.rancherdesktop.app", executable: "rdctl", args: ["start"]) &&
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
    try expect("port picks lowest published TCP and keeps its IP", web.publishedPort == .init(number: 3000, ip: "127.0.0.1") &&
               web.publishedPort?.url?.absoluteString == "http://127.0.0.1:3000" && db.publishedPort == nil)
    try expect("wildcard IPv4 and IPv6 use localhost",
               DockerPublishedPort(number: 8080, ip: "0.0.0.0").url?.absoluteString == "http://localhost:8080" &&
               DockerPublishedPort(number: 8080, ip: "::").url?.absoluteString == "http://localhost:8080")
    try expect("specific IPv6 is bracketed", DockerPublishedPort(number: 8080, ip: "2001:db8::1").url?.absoluteString ==
               "http://[2001:db8::1]:8080")
    try expect("a specific IPv4 link keeps its binding", DockerPublishedPort(number: 8080, ip: "192.168.1.9").url?.absoluteString ==
               "http://192.168.1.9:8080")
    let duplicatePorts = try decode([DockerPort].self, #"[{"PublicPort":3000,"Type":"tcp","IP":"::1"},{"PublicPort":3000,"Type":"tcp","IP":"0.0.0.0"}]"#)
    try expect("first duplicate keeps the selected publication's IP", DockerPublishedPort.first(in: duplicatePorts)?.url?.absoluteString ==
               "http://[::1]:3000")
    let missingIP = try decode([DockerPort].self, #"[{"PublicPort":80,"Type":"tcp"},{"PublicPort":81,"Type":"tcp","IP":""},{"PublicPort":82,"Type":"tcp","IP":"127.0.0.1/path"}]"#)
    try expect("unrecorded or invalid IPs aren't mapped to localhost", DockerPublishedPort.first(in: missingIP) == nil)
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
    crashes.receive(try event("die", 100), now: 0)
    try expect("exited nonzero without stop is a crash", crashes.ids == ["a"])
    crashes.receive(try event("start", 101), now: 0)
    try expect("start clears the crash mark", crashes.ids.isEmpty)
    crashes.receive(try event("kill", 110), now: 0)
    crashes.receive(try event("die", 125), now: 0)
    try expect("kill within 15 seconds suppresses a crash", crashes.ids.isEmpty)
    crashes.receive(try event("die", 126), now: 0)
    try expect("older kill does not suppress a crash", crashes.ids == ["a"])
    crashes.clear()
    try expect("opening clears crash marks", crashes.ids.isEmpty)
    crashes.receive(try event("stop", 128, id: "another"), now: 0)
    crashes.receive(try event("die", 130), now: 0)
    try expect("stop for another id does not suppress a crash", crashes.ids == ["a"])
    crashes.clear()
    crashes.receive(try event("stop", 140), now: 0)
    crashes.receive(try event("die", 150), now: 0)
    try expect("recent stop suppresses a crash", crashes.ids.isEmpty)
    crashes.suppressStop("a", until: 100)
    crashes.receive(try event("die", 180), now: 1)
    try expect("Cala stop suppresses its first die", crashes.ids.isEmpty)
    crashes.receive(try event("die", 181), now: 2)
    try expect("matching die consumes Cala suppression", crashes.ids == ["a"])
    crashes.clear()
    crashes.suppressStop("a", until: 100)
    crashes.receive(try event("die", 200, code: "0"), now: 3)
    try expect("zero exit is not a crash", crashes.ids.isEmpty)
    crashes.receive(try event("die", 201), now: 4)
    try expect("even a clean die consumes Cala suppression", crashes.ids == ["a"])
    crashes.clear()
    crashes.suppressStop("a", until: 100)
    crashes.receive(try event("kill", 210), now: 5)
    crashes.receive(try event("start", 211), now: 6)
    crashes.receive(try event("die", 212), now: 7)
    try expect("start clears Cala suppression and old kill history for a fresh crash", crashes.ids == ["a"])
    crashes.clear()
    crashes.suppressStop("a", until: 10)
    crashes.receive(try event("die", 213), now: 11)
    try expect("expired Cala suppression does not hide a crash", crashes.ids == ["a"])
    crashes.clear()
    crashes.suppressStop("a", until: 20)
    crashes.cancelStop("a")
    crashes.receive(try event("die", 214), now: 12)
    try expect("rejected stop leaves no suppression", crashes.ids == ["a"])
    try expect("glyph transitions", DockerGlyphState.resolve(.stopped, running: 3, crashed: true) == .off &&
               DockerGlyphState.resolve(.starting, running: 0, crashed: false) == .starting &&
               DockerGlyphState.resolve(.stopping, running: 3, crashed: false) == .starting &&
               DockerGlyphState.resolve(.running, running: 3, crashed: false) == .running(3) &&
               DockerGlyphState.resolve(.running, running: 3, crashed: true) == .crashed(3))

    var debounce = DockerEventDebounce()
    let closely = { (left: Double, right: Double) in abs(left - right) < 0.0001 }
    try expect("first event delays refresh 300 ms", closely(debounce.delay(afterEventAt: 10), 0.3))
    try expect("each event pushes out trailing refresh", closely(debounce.delay(afterEventAt: 10.2), 0.3))
    try expect("continuous events cap the deadline at first plus 1 s", closely(debounce.delay(afterEventAt: 10.8), 0.2))
    try expect("event at deadline forces immediate refresh", debounce.delay(afterEventAt: 11) == 0)
    debounce.reset()
    try expect("new burst starts after a refresh", closely(debounce.delay(afterEventAt: 11.1), 0.3))

    let listing = DockerListing(socket: local.active!.resolvedPath)
    let nextListing = DockerListing(socket: stopped.active!.resolvedPath)
    let otherEngine = local.engines.last!
    try expect("shown listing matches only its current engine", listing.matches(current: listing, endpoint: local.active))
    try expect("changed canonical socket invalidates actions", !listing.matches(current: listing, endpoint: otherEngine))
    try expect("reconnection at same socket invalidates stale actions", !listing.matches(current: nextListing, endpoint: stopped.active))
    try expect("listing cannot authorize an action while the engine is being reloaded",
               !listing.matches(current: nil, endpoint: local.active))
    let removal = DockerConfirmation(key: "volume:data", listing: listing)
    try expect("confirmation requires the shown listing and item", removal.matches("volume:data", shown: listing) &&
               !removal.matches("volume:data", shown: nextListing) && !removal.matches("volume:other", shown: listing))

    var loads = DockerUsageLoad()
    let firstLoad = loads.begin()!
    try expect("disk totals load once per opening", loads.accepts(firstLoad) && loads.begin() == nil)
    loads.invalidate()
    let refreshedLoad = loads.begin()!
    try expect("disk invalidation permits reload and rejects stale completion",
               !loads.accepts(firstLoad) && loads.accepts(refreshedLoad))

    try expect("only down or starting states observe runtime launches",
               [DockerEngineState.stopped, .starting, .unreachable(.connection)].allSatisfy(\.observesRuntimeApps) &&
               ![DockerEngineState.running, .notInstalled, .stopping].contains(where: \.observesRuntimeApps))
    try expect("shell quotes spaces", dockerShellQuote("my container") == "'my container'")
    try expect("shell quotes single and double quotes", dockerShellQuote("my 'quoted' \"name\"") == "'my '\\''quoted'\\'' \"name\"'")
    try expect("shell quotes empty argument", dockerShellQuote("") == "''")
    try expect("URL argument cannot change the request target", dockerURLComponent(":/?\r\n") == "%3A%2F%3F%0D%0A")
    print("PASS docker: \(checks) checks")
}

#if DOCKER_CHECK
func testStream(on endpoint: DockerEndpoint, response: String, beforeRead: (String) -> Void) throws -> [String] {
    var address = sockaddr_un()
    let path = Array(endpoint.resolvedPath.utf8)
    let length = MemoryLayout<sockaddr_un>.offset(of: \.sun_path)! + path.count + 1
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(length)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }

    let listener = socket(AF_UNIX, SOCK_STREAM, 0)
    guard listener >= 0 else { throw DockerSocketError.posix(errno) }
    defer { close(listener); unlink(endpoint.resolvedPath) }
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(length)) }
    }
    guard bound == 0 else { throw NSError(domain: "test socket bind", code: Int(errno)) }
    guard listen(listener, 1) == 0 else { throw NSError(domain: "test socket listen", code: Int(errno)) }
    DispatchQueue.global().async {
        let fd = accept(listener, nil, nil)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var wait = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout.size(ofValue: wait)))
        var request = [UInt8](repeating: 0, count: 4096)
        guard read(fd, &request, request.count) > 0 else { return }
        _ = Data(response.utf8).withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return 0 }
            return write(fd, base, bytes.count)
        }
    }
    var order: [String] = []
    try DockerSocket.events(endpoint, io: DockerIO(), onReady: {
        order.append("headers")
        beforeRead("headers")
    }, onEvent: {
        order.append($0.Action ?? "")
    })
    return order
}

func runTransportChecks() throws {
    let fm = FileManager.default
    let root = URL(fileURLWithPath: "/private/tmp/cala-docker-" + String(UUID().uuidString.prefix(8)), isDirectory: true)
    try fm.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: root) }

    let alias = root.appendingPathComponent("alias").path
    let canonical = root.appendingPathComponent("test.sock").path
    let endpoint = DockerEndpoint(context: "test", path: alias, resolvedPath: canonical, runtime: .unknown, isContext: true)
    try fm.createSymbolicLink(atPath: alias, withDestinationPath: "test.sock")
    try expect("relative dangling alias is resolved to its future socket", DockerLocal.socketPath(for: endpoint) == canonical)

    let line = #"{"Type":"container","Action":"start","Actor":{"ID":"a"},"time":10}"# + "\n"
    let headers = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
    let order = try testStream(on: endpoint, response: headers + chunk(line) + "0\r\n\r\n", beforeRead: { _ in })
    try expect("socket transport reports HTTP 200 before publishing events", order == ["headers", "start"])
    do {
        _ = try testStream(on: endpoint, response: "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n",
                           beforeRead: { _ in fatalError("failed subscription must not report readiness") })
        try expect("non-200 event stream rejected", false)
    } catch DockerHTTPError.status(404) { try expect("non-200 event stream rejected", true) }

    try fm.removeItem(atPath: alias)
    try fm.createSymbolicLink(atPath: alias, withDestinationPath: "replacement.sock")
    try expect("local retarget invalidates a pinned address", DockerLocal.socketPath(for: endpoint) == nil)

    let parent = root.appendingPathComponent("foreign").path
    let foreign = "/Users/CalaOtherAccount/.docker/run"
    try fm.createSymbolicLink(atPath: parent, withDestinationPath: foreign)
    let nested = parent + "/docker.sock"
    try expect("missing socket with foreign symlinked parent resolves into foreign home",
               DockerLocal.realSocketPath(nested) == foreign + "/docker.sock")
    let unsafe = DockerEndpoint(context: "unsafe", path: nested, resolvedPath: foreign + "/docker.sock",
                                runtime: .unknown, isContext: true)
    try expect("transport rejects even a pinned foreign canonical socket", DockerLocal.socketPath(for: unsafe) == nil)
    print("PASS docker transport: \(checks) checks")
}
#endif

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
    } else if CommandLine.arguments.contains("--transport") {
        try runTransportChecks()
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

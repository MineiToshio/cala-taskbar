import Darwin
import Foundation

enum DockerLocal {
    static func discover(home: String = NSHomeDirectory(), preferredApp: DockerRuntime? = nil) -> DockerResolution {
        let config = try? Data(contentsOf: URL(fileURLWithPath: home + "/.docker/config.json"))
        let root = URL(fileURLWithPath: home + "/.docker/contexts/meta", isDirectory: true)
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        let metadata = folders.sorted().compactMap {
            try? Data(contentsOf: root.appendingPathComponent($0).appendingPathComponent("meta.json"))
        }
        let profiles = (try? FileManager.default.contentsOfDirectory(atPath: home + "/.colima")) ?? []
        let known = DockerDiscovery.knownPaths(home: home, colimaProfiles: profiles.filter { !$0.hasPrefix(".") })
        let paths = Set(known.map(\.path) + DockerDiscovery.contextPaths(metadata, home: home) + [DockerDiscovery.defaultPath])
        let resolved = Dictionary(uniqueKeysWithValues: paths.map { ($0, realSocketPath($0)) })
        let existing = paths.filter { path in
            if path == DockerDiscovery.defaultPath,
               !DockerDiscovery.ownsDefault(resolved[path] ?? path, home: home) { return false }
            return isSocket(path)
        }
        return DockerDiscovery.resolve(home: home, config: config, metadata: metadata,
                                       existing: Set(existing), resolved: resolved, known: known,
                                       preferredApp: preferredApp)
    }

    static func isSocket(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFSOCK
    }

    static func realSocketPath(_ path: String) -> String {
        if let real = realpath(path, nil) {
            defer { free(real) }
            return String(cString: real)
        }
        let url = URL(fileURLWithPath: path)
        // The symlink can be readable even when the other user's socket is down or inaccessible.
        if let link = try? FileManager.default.destinationOfSymbolicLink(atPath: path) {
            let target = link.hasPrefix("/") ? URL(fileURLWithPath: link) :
                url.deletingLastPathComponent().appendingPathComponent(link)
            return target.resolvingSymlinksInPath().standardizedFileURL.path
        }
        return url.resolvingSymlinksInPath().path
    }

    static func socketPath(for endpoint: DockerEndpoint, home: String = NSHomeDirectory()) -> String? {
        guard endpoint.path == DockerDiscovery.defaultPath else { return endpoint.path }
        let real = realSocketPath(endpoint.path)
        return DockerDiscovery.ownsDefault(real, home: home) ? real : nil
    }
}

/// The worker closes each descriptor. Cancellation shuts it down under the same lock so a
/// late cancellation cannot touch a descriptor the OS already reused.
final class DockerIO: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var sockets = Set<Int32>()
    private var processes: [ObjectIdentifier: Process] = [:]

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func add(_ fd: Int32) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        sockets.insert(fd)
    }

    func close(_ fd: Int32) {
        lock.lock()
        defer { lock.unlock() }
        sockets.remove(fd)
        Darwin.close(fd)
    }

    func run(_ process: Process) throws {
        let id = ObjectIdentifier(process)
        try launch(process, id: id)
        process.waitUntilExit()
        lock.lock()
        processes[id] = nil
        lock.unlock()
        guard process.terminationStatus == 0 else { throw DockerSocketError.command }
    }

    private func launch(_ process: Process, id: ObjectIdentifier) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        try process.run()
        processes[id] = process
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        for fd in sockets { Darwin.shutdown(fd, SHUT_RDWR) }
        for process in processes.values where process.isRunning { process.terminate() }
    }
}

enum DockerSocketError: Error {
    case path, posix(Int32), command
}

enum DockerSocket {
    static func request(_ endpoint: DockerEndpoint, _ path: String, method: String = "GET",
                        timeout: Int = 15, io: DockerIO = DockerIO()) throws -> DockerHTTPResponse {
        try connection(endpoint, path, method: method, timeout: timeout, io: io) { fd in
            var response = Data()
            while let data = try read(fd, io: io) { response.append(data) }
            let parsed = try DockerHTTPResponse.parse(response)
            guard (200...299).contains(parsed.head.status) else { throw DockerHTTPError.status(parsed.head.status) }
            return parsed
        }
    }

    static func events(_ endpoint: DockerEndpoint, io: DockerIO,
                       onEvent: (DockerEvent) -> Void) throws {
        let filter = dockerURLComponent(#"{"type":["container"]}"#)
        try connection(endpoint, "/events?filters=" + filter, io: io) { fd in
            var header = Data()
            while let bytes = try read(fd, io: io) {
                header.append(bytes)
                let response: (head: DockerHTTPHead, remainder: Data)
                do { response = try DockerHTTPHead.parse(header) }
                catch DockerHTTPError.incomplete { continue }
                guard response.head.status == 200 else { throw DockerHTTPError.status(response.head.status) }
                // After the handshake the engine can be idle indefinitely. Cancellation interrupts read().
                var wait = timeval()
                guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout.size(ofValue: wait))) == 0
                else { throw DockerSocketError.posix(errno) }
                var stream = DockerEventStream(chunked: response.head.isChunked)
                for event in try stream.append(response.remainder) { onEvent(event) }
                while !stream.finished, let bytes = try read(fd, io: io) {
                    for event in try stream.append(bytes) { onEvent(event) }
                }
                return
            }
            throw DockerHTTPError.incomplete
        }
    }

    private static func connection<Value>(_ endpoint: DockerEndpoint, _ path: String, method: String = "GET",
                                          timeout: Int = 15, io: DockerIO, use: (Int32) throws -> Value) throws -> Value {
        guard !io.isCancelled else { throw CancellationError() }
        guard let socketPath = DockerLocal.socketPath(for: endpoint) else { throw DockerSocketError.path }
        var address = sockaddr_un()
        let name = Array(socketPath.utf8)
        guard name.count < MemoryLayout.size(ofValue: address.sun_path) else { throw DockerSocketError.path }
        let length = MemoryLayout<sockaddr_un>.offset(of: \.sun_path)! + name.count + 1
        address.sun_len = UInt8(length)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in bytes.copyBytes(from: name) }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DockerSocketError.posix(errno) }
        defer { io.close(fd) }
        try io.add(fd)

        var noSignal: Int32 = 1
        var wait = timeval(tv_sec: timeout, tv_usec: 0)
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal))) == 0,
              setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout.size(ofValue: wait))) == 0,
              setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &wait, socklen_t(MemoryLayout.size(ofValue: wait))) == 0
        else { throw DockerSocketError.posix(errno) }

        // A full listener backlog must not hold up a worker. The Unix connect itself is local.
        guard fcntl(fd, F_SETFL, O_NONBLOCK) != -1 else { throw DockerSocketError.posix(errno) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(length)) }
        }
        guard connected == 0, fcntl(fd, F_SETFL, 0) != -1 else { throw DockerSocketError.posix(errno) }
        guard !io.isCancelled else { throw CancellationError() }

        let content = method == "POST" ? "Content-Length: 0\r\n" : ""
        let request = Data("\(method) \(path) HTTP/1.1\r\nHost: docker\r\nConnection: close\r\n\(content)\r\n".utf8)
        try request.withUnsafeBytes { bytes in
            guard let start = bytes.baseAddress else { return }
            var sent = 0
            while sent < bytes.count {
                let count = Darwin.write(fd, start.advanced(by: sent), bytes.count - sent)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw DockerSocketError.posix(errno) }
                sent += count
            }
        }
        return try use(fd)
    }

    private static func read(_ fd: Int32, io: DockerIO) throws -> Data? {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while !io.isCancelled {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 { return Data(buffer.prefix(count)) }
            if count == 0 { return nil }
            let error = errno
            if error == EINTR { continue }
            throw DockerSocketError.posix(error)
        }
        throw CancellationError()
    }
}

#if !DOCKER_CHECK
import AppKit
import Combine

enum DockerTab: CaseIterable, Hashable { case containers, images, volumes }

enum DockerContainerAction: String {
    case start, stop, restart, remove

    var timeout: Int { self == .stop || self == .restart ? 35 : 15 }
}

@MainActor
final class DockerService: ObservableObject {
    static let shared = DockerService()

    @Published private(set) var state: DockerEngineState = .notInstalled
    @Published private(set) var endpoint: DockerEndpoint?
    @Published private(set) var engines: [DockerEndpoint] = []
    @Published private(set) var runtime: DockerRuntime = .unknown
    @Published private(set) var containers: [DockerContainer]?
    @Published private(set) var images: [DockerImage]?
    @Published private(set) var volumes: [DockerVolume]?
    @Published private(set) var usage: DockerDiskUsage?
    @Published private(set) var ram: Int64?
    @Published private(set) var crashed = Set<String>()
    @Published private(set) var busy: [String: DockerContainerAction] = [:]
    @Published private(set) var pendingRows = Set<String>()
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var signedIn = false
    @Published private(set) var dockerCLI: String?
    @Published private(set) var switchingContext = false
    @Published private(set) var tab: DockerTab = .containers
    @Published private(set) var failedLoads = Set<DockerTab>()
    @Published private(set) var usageFailed = false

    private let requests = DispatchQueue(label: "Cala.docker.http", qos: .utility)
    private let events = DispatchQueue(label: "Cala.docker.events", qos: .utility)
    private let commands = DispatchQueue(label: "Cala.docker.commands", qos: .utility)
    private var lifetime: DockerIO?
    private var connection = DockerIO()
    private var eventIO: DockerIO?
    private var panelIO: DockerIO?
    private var watcher: DispatchSourceTimer?
    private var statsTimer: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []
    private var deadline: TimeInterval?
    private var engineOperation: DockerIO?
    private var probing = false
    private var retryProbe = false
    private var refreshing = false
    private var refreshAgain = false
    private var loadingTabs = Set<DockerTab>()
    private var reloadTabs = Set<DockerTab>()
    private var requestedUsage = false
    private var statsTask: Task<Void, Never>?
    private var refreshWork: DispatchWorkItem?
    private var usageWork: DispatchWorkItem?
    private var errorWork: [String: DispatchWorkItem] = [:]
    private var crashHistory = DockerCrashes()
    private var calaStops: [String: TimeInterval] = [:]
    private var panelVisible = false

    var available: Bool { state != .notInstalled }
    var runningCount: Int { containers?.filter(\.isRunning).count ?? 0 }
    var glyph: DockerGlyphState { .resolve(state, running: runningCount, crashed: !crashed.isEmpty) }

    var canToggle: Bool {
        guard let command = runtime.command(start: state != .running && state != .stopping, dockerCLI: dockerCLI != nil) else { return false }
        switch command {
        case .executable(let name, _): return Self.executable(name) != nil
        case .openApp(let id): return NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil
        case .terminateApp: return true
        }
    }

    var canOpenRuntime: Bool { runtime.appID.flatMap(NSWorkspace.shared.urlForApplication(withBundleIdentifier:)) != nil }

    func start() {
        guard lifetime == nil else { return }
        lifetime = DockerIO()
        discover()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
                guard DockerRuntime.appRuntimes.contains(where: { $0.appID == bundleID }) else { return }
                MainActor.assumeIsolated {
                    guard let self, self.lifetime != nil, !self.switchingContext else { return }
                    self.discover()
                    self.probe()
                }
            })
        }
    }

    func stop() {
        guard let lifetime else { return }
        lifetime.cancel()
        self.lifetime = nil
        engineOperation?.cancel()
        engineOperation = nil
        watcher?.cancel()
        watcher = nil
        panelClosed()
        resetConnection()
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers.removeAll()
        endpoint = nil
        engines = []
        runtime = .unknown
        state = .notInstalled
        dockerCLI = nil
        signedIn = false
        switchingContext = false
        deadline = nil
    }

    func panelOpened() {
        guard lifetime != nil, !panelVisible else { return }
        panelVisible = true
        crashHistory.clear()
        crashed = []
        if !switchingContext { discover() }
        if state == .running { startPanelReads() }
    }

    func panelClosed() {
        panelVisible = false
        clearPanelReads()
    }

    func select(_ tab: DockerTab) {
        self.tab = tab
        loadTab(tab)
        if tab != .containers { loadUsage() }
    }

    func openRuntime() {
        guard lifetime != nil, let id = runtime.appID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        NSWorkspace.shared.open(url)
    }

    private func discover() {
        let app = DockerRuntime.appRuntimes.first {
            $0.appID.flatMap(NSWorkspace.shared.urlForApplication(withBundleIdentifier:)) != nil
        }
        let detected = DockerLocal.discover(preferredApp: app)
        dockerCLI = Self.executable("docker")
        signedIn = detected.signedIn
        engines = detected.engines
        let next = detected.active
        runtime = next?.runtime ?? .unknown
        if next?.resolvedPath != endpoint?.resolvedPath {
            resetConnection()
            if state == .running { state = .stopped }
        }
        endpoint = next
        if !detected.hasSocket && dockerCLI == nil && app == nil {
            if state != .starting && state != .stopping {
                if state != .notInstalled { resetConnection() }
                state = .notInstalled
                watcher?.cancel()
                watcher = nil
            }
            return
        }
        if state == .notInstalled { state = .stopped }
        if state != .running {
            if next == nil && deadline == nil { state = .unreachable(.context) }
            watch(immediate: true)
        }
    }

    private func resetConnection(keepContainers: Bool = false) {
        connection.cancel()
        connection = DockerIO()
        disconnectEvents()
        clearPanelReads()
        if !keepContainers { containers = nil }
        crashHistory = DockerCrashes()
        crashed = []
        calaStops = [:]
        probing = false
        retryProbe = false
        refreshing = false
        refreshAgain = false
        busy = [:]
        pendingRows = []
        for work in errorWork.values { work.cancel() }
        errorWork.removeAll()
        errors = [:]
    }

    private func disconnectEvents() {
        eventIO?.cancel()
        eventIO = nil
        refreshWork?.cancel()
        refreshWork = nil
    }

    private func watch(immediate: Bool = false) {
        watcher?.cancel()
        watcher = nil
        guard lifetime != nil, available, endpoint != nil || deadline != nil else { return }
        let fast = state == .starting
        let cadence = fast ? 1 : 10
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .seconds(cadence), repeating: .seconds(cadence),
                       leeway: .milliseconds(fast ? 100 : 3000))
        timer.setEventHandler { [weak self] in self?.probe() }
        watcher = timer
        timer.resume()
        if immediate { probe(coalesce: false) }
    }

    private func probe(coalesce: Bool = true) {
        guard lifetime != nil, !switchingContext else { return }
        if let deadline, uptime >= deadline {
            self.deadline = nil
            engineOperation?.cancel()
            engineOperation = nil
            if state == .starting {
                state = .unreachable(.timedOut)
                watch()
                return
            }
        }
        guard let endpoint else { return }
        if probing {
            retryProbe = retryProbe || coalesce
            return
        }
        probing = true
        let io = connection
        requests.async { [weak self] in
            let exists = DockerLocal.socketPath(for: endpoint).map(DockerLocal.isSocket) == true
            let up = exists && (try? DockerSocket.request(endpoint, "/_ping", io: io)) != nil
            DispatchQueue.main.async { [weak self] in self?.probed(io: io, exists: exists, up: up) }
        }
    }

    private func probed(io: DockerIO, exists: Bool, up: Bool) {
        guard lifetime != nil, connection === io else { return }
        probing = false
        defer {
            if retryProbe {
                retryProbe = false
                if state != .running { probe(coalesce: false) }
            }
        }
        if up {
            if state == .stopping {
                guard deadline == nil else { return }
                showError("engine", tx("Docker is still running.", "Docker sigue en marcha."))
            }
            if state != .running { connected() }
        } else if state != .starting {
            let wasUp = state == .running || state == .stopping
            if wasUp { engineWentDown() }
            let settled: DockerEngineState = exists ? .unreachable(.connection) : .stopped
            if state != .unreachable(.timedOut) && state != .unreachable(.command) { state = settled }
            if wasUp { watch() }
        }
    }

    private func connected() {
        guard let endpoint else { return }
        watcher?.cancel()
        watcher = nil
        deadline = nil
        state = .running
        if eventIO == nil {
            let io = DockerIO()
            eventIO = io
            events.async { [weak self] in
                try? DockerSocket.events(endpoint, io: io) { [weak self] event in
                    DispatchQueue.main.async { [weak self] in self?.received(event, io: io) }
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.eventIO === io else { return }
                    self.engineWentDown()
                    self.watch()
                }
            }
        }
        refreshContainers()
        if panelVisible { startPanelReads() }
    }

    private func engineWentDown() {
        resetConnection(keepContainers: true)
        deadline = nil
        state = endpoint.flatMap { DockerLocal.socketPath(for: $0) }.map(DockerLocal.isSocket) == true
            ? .unreachable(.connection) : .stopped
    }

    private var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func received(_ event: DockerEvent, io: DockerIO) {
        guard eventIO === io else { return }
        let now = uptime
        calaStops = calaStops.filter { $0.value >= now }
        crashHistory.receive(event, calaStopped: Set(calaStops.keys))
        if crashed != crashHistory.ids { crashed = crashHistory.ids }
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.refreshContainers()
        }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(300), execute: work)
    }

    private func decode<T: Decodable>(_: T.Type, _ path: String, at endpoint: DockerEndpoint, io: DockerIO) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            requests.async {
                continuation.resume(with: Result {
                    let response = try DockerSocket.request(endpoint, path, io: io)
                    return try JSONDecoder().decode(T.self, from: response.body)
                })
            }
        }
    }

    private func refreshContainers() {
        guard state == .running, let endpoint else { return }
        if refreshing { refreshAgain = true; return }
        refreshing = true
        let io = connection
        Task {
            let list = try? await decode([DockerContainer].self, "/containers/json?all=1", at: endpoint, io: io)
            guard lifetime != nil, connection === io else { return }
            refreshing = false
            if let list, state == .running {
                containers = list.filter { !$0.id.isEmpty }
                failedLoads.remove(.containers)
                if ram == nil { refreshRAM() }
            } else if containers == nil, state == .running { failedLoads.insert(.containers) }
            if refreshAgain {
                refreshAgain = false
                refreshContainers()
            }
        }
    }

    private func startPanelReads() {
        guard panelVisible, state == .running, panelIO == nil else { return }
        panelIO = DockerIO()
        loadTab(tab)
        if tab == .containers {
            let work = DispatchWorkItem { [weak self] in self?.loadUsage() }
            usageWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(180), execute: work)
        } else {
            loadUsage()
        }
        refreshRAM()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 5, repeating: 5, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in self?.refreshRAM() }
        statsTimer = timer
        timer.resume()
    }

    private func clearPanelReads() {
        panelIO?.cancel()
        panelIO = nil
        statsTimer?.cancel()
        statsTimer = nil
        statsTask?.cancel()
        statsTask = nil
        usageWork?.cancel()
        usageWork = nil
        images = nil
        volumes = nil
        usage = nil
        ram = nil
        loadingTabs = []
        reloadTabs = []
        failedLoads = []
        usageFailed = false
        requestedUsage = false
    }

    private func refreshRAM() {
        guard statsTask == nil, let io = panelIO, let endpoint else { return }
        if containers == nil {
            // The first list is already queued; it will start the opening sample.
            return
        }
        let ids = containers?.filter(\.isRunning).map(\.id) ?? []
        statsTask = Task {
            var values: [Int64?] = []
            for id in ids {
                guard !Task.isCancelled else { return }
                let path = "/containers/" + dockerURLComponent(id) + "/stats?stream=false&one-shot=true"
                let stats = try? await decode(DockerStats.self, path, at: endpoint, io: io)
                values.append(stats?.ram)
            }
            guard panelIO === io else { return }
            statsTask = nil
            ram = values.contains { $0 == nil } ? nil : dockerTotal(values)
        }
    }

    private func loadTab(_ tab: DockerTab, reload: Bool = false) {
        guard let io = panelIO, let endpoint, tab != .containers else { return }
        if loadingTabs.contains(tab) {
            if reload { reloadTabs.insert(tab) }
            return
        }
        if !reload && (tab == .images ? images != nil : volumes != nil) { return }
        loadingTabs.insert(tab)
        failedLoads.remove(tab)
        Task {
            switch tab {
            case .images:
                let list = try? await decode([DockerImage].self, "/images/json", at: endpoint, io: io)
                guard panelIO === io else { return }
                if let list { images = list.filter { !$0.id.isEmpty } }
                else { failedLoads.insert(tab) }
            case .volumes:
                let list = try? await decode(DockerVolumes.self, "/volumes", at: endpoint, io: io)
                guard panelIO === io else { return }
                if let list { volumes = (list.Volumes ?? []).filter { !$0.id.isEmpty } }
                else { failedLoads.insert(tab) }
            case .containers: break
            }
            loadingTabs.remove(tab)
            if reloadTabs.remove(tab) != nil { loadTab(tab, reload: true) }
        }
    }

    private func loadUsage() {
        guard !requestedUsage, let io = panelIO, let endpoint else { return }
        requestedUsage = true
        Task {
            let result = try? await decode(DockerDiskUsage.self, "/system/df?verbose=true", at: endpoint, io: io)
            guard panelIO === io else { return }
            usage = result
            usageFailed = result == nil
        }
    }

    func act(_ action: DockerContainerAction, on container: DockerContainer) {
        act(action, on: [container])
    }

    func act(_ action: DockerContainerAction, on containers: [DockerContainer]) {
        guard state == .running, !switchingContext, let endpoint else { return }
        let targets = containers.filter { busy[$0.id] == nil }
        for container in targets { busy[container.id] = action; clearError(container.id) }
        let io = connection
        Task {
            for container in targets {
                guard connection === io, state == .running else { break }
                let id = container.id
                if action == .stop || action == .restart { calaStops[id] = uptime + Double(action.timeout) + 15 }
                let path = "/containers/" + dockerURLComponent(id) + (action == .remove ? "" : "/" + action.rawValue)
                let method = action == .remove ? "DELETE" : "POST"
                let error = await mutate(endpoint, path, method: method, timeout: action.timeout, io: io)
                guard connection === io else { return }
                if let error {
                    if action == .stop || action == .restart { calaStops[id] = nil }
                    showError(id, actionError(error))
                } else if action == .start || action == .restart {
                    crashHistory.started(id)
                    crashed = crashHistory.ids
                }
            }
            guard connection === io else { return }
            await finishContainerAction(targets, at: endpoint, io: io)
        }
    }

    private func finishContainerAction(_ targets: [DockerContainer], at endpoint: DockerEndpoint, io: DockerIO) async {
        let list = state == .running ? try? await decode([DockerContainer].self, "/containers/json?all=1", at: endpoint, io: io) : nil
        guard connection === io else { return }
        if let list, state == .running { containers = list.filter { !$0.id.isEmpty }; failedLoads.remove(.containers) }
        for container in targets { busy[container.id] = nil }
    }

    func removeImage(_ image: DockerImage) {
        guard let containers, !image.inUse(by: containers) else { return }
        resourceAction("image:" + image.id, "/images/" + dockerURLComponent(image.id), tab: .images)
    }

    func pruneImages() {
        let filter = dockerURLComponent(#"{"dangling":["false"]}"#)
        resourceAction("prune", "/images/prune?filters=" + filter, method: "POST", tab: .images)
    }

    func removeVolume(_ volume: DockerVolume) {
        guard let containers, volume.usedBy(containers).isEmpty else { return }
        resourceAction("volume:" + volume.id, "/volumes/" + dockerURLComponent(volume.id), tab: .volumes)
    }

    private func resourceAction(_ key: String, _ path: String, method: String = "DELETE", tab: DockerTab) {
        guard state == .running, !switchingContext, let endpoint, pendingRows.insert(key).inserted else { return }
        clearError(key)
        let io = connection
        Task {
            let error = await mutate(endpoint, path, method: method, io: io)
            guard connection === io else { return }
            pendingRows.remove(key)
            if let error { showError(key, actionError(error)) }
            else { loadTab(tab, reload: true) }
        }
    }

    private func mutate(_ endpoint: DockerEndpoint, _ path: String, method: String, timeout: Int = 15, io: DockerIO) async -> Error? {
        await withCheckedContinuation { continuation in
            requests.async {
                do {
                    _ = try DockerSocket.request(endpoint, path, method: method, timeout: timeout, io: io)
                    continuation.resume(returning: nil)
                } catch { continuation.resume(returning: error) }
            }
        }
    }

    private func actionError(_ error: Error) -> String {
        switch error {
        case DockerHTTPError.status(404): return tx("This item is no longer there.", "Este elemento ya no existe.")
        case DockerHTTPError.status(409): return tx("This item is busy or in use.", "Este elemento está en uso.")
        case DockerSocketError.posix(EAGAIN): return tx("Docker took too long to respond.", "Docker tardó demasiado en responder.")
        default: return tx("Docker couldn't complete the action.", "Docker no pudo completar la acción.")
        }
    }

    func setEngine(_ start: Bool) {
        guard lifetime != nil, available, !switchingContext, engineOperation == nil,
              state != .starting, state != .stopping, start != (state == .running), canToggle,
              let command = runtime.command(start: start, dockerCLI: dockerCLI != nil) else { return }
        clearError("engine")
        let io = DockerIO()
        engineOperation = io
        state = start ? .starting : .stopping
        if !start {
            for container in containers ?? [] where container.isActive { calaStops[container.id] = uptime + 50 }
            clearPanelReads()
        }
        deadline = uptime + (start ? 180 : 35)
        watch(immediate: start)
        Task {
            do {
                try await run(command, io: io)
                guard engineOperation === io else { return }
                engineOperation = nil
                if state == .stopping { probe() }
            } catch {
                guard engineOperation === io else { return }
                engineOperation = nil
                guard state == .starting || state == .stopping else { return }
                deadline = nil
                if start {
                    state = .unreachable(.command)
                    watch()
                } else {
                    connected()
                    showError("engine", tx("Couldn't stop Docker.", "No se pudo detener Docker."))
                }
            }
        }
    }

    func useContext(_ selected: DockerEndpoint) {
        guard let lifetime, dockerCLI != nil, selected.isContext, selected.id != endpoint?.id,
              !switchingContext, state != .starting, state != .stopping else { return }
        switchingContext = true
        clearError("engine")
        Task {
            do {
                try await run(.executable("docker", ["context", "use", "--", selected.context]), io: lifetime)
                guard self.lifetime === lifetime else { return }
                switchingContext = false
                discover()
            } catch {
                guard self.lifetime === lifetime else { return }
                switchingContext = false
                showError("engine", tx("Couldn't switch Docker context.", "No se pudo cambiar de contexto."))
                if state != .running { probe() }
            }
        }
    }

    private func run(_ command: DockerCommand, io: DockerIO) async throws {
        guard !io.isCancelled else { throw CancellationError() }
        switch command {
        case .openApp(let bundle):
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { throw DockerSocketError.command }
            let options = NSWorkspace.OpenConfiguration()
            options.activates = false
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: options)
        case .terminateApp(let bundle):
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundle) {
                guard app.terminate() else { throw DockerSocketError.command }
            }
        case .executable(let name, let args):
            guard let path = Self.executable(name) else { throw DockerSocketError.command }
            let search = Self.searchDirectories.joined(separator: ":")
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                commands.async {
                    continuation.resume(with: Result {
                        let process = Process()
                        process.executableURL = URL(fileURLWithPath: path)
                        process.arguments = args
                        var environment = ProcessInfo.processInfo.environment
                        environment["PATH"] = search
                        environment["DOCKER_CONTEXT"] = nil
                        environment["DOCKER_HOST"] = nil
                        environment["DOCKER_CONFIG"] = NSHomeDirectory() + "/.docker"
                        process.environment = environment
                        process.standardInput = FileHandle.nullDevice
                        process.standardOutput = FileHandle.nullDevice
                        process.standardError = FileHandle.nullDevice
                        try io.run(process)
                    })
                }
            }
        }
    }

    private static var searchDirectories: [String] {
        let home = NSHomeDirectory()
        return ["/opt/homebrew/bin", "/usr/local/bin", home + "/.docker/bin", home + "/.orbstack/bin",
                home + "/.rd/bin", "/Applications/Docker.app/Contents/Resources/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    }

    private static func executable(_ name: String) -> String? {
        searchDirectories.lazy.map { $0 + "/" + name }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func logs(_ container: DockerContainer) {
        terminal(["logs", "-f", "--tail", "200", "--", container.name], on: endpoint, errorKey: container.id)
    }

    func shell(_ container: DockerContainer) {
        terminal(["exec", "-it", "--", container.name, "sh", "-c", "command -v bash >/dev/null && exec bash || exec sh"],
                 on: endpoint, errorKey: container.id)
    }

    func login() { terminal(["login"], on: nil, errorKey: "login") }

    private func terminal(_ args: [String], on endpoint: DockerEndpoint?, errorKey: String) {
        guard lifetime != nil, let dockerCLI else { return }
        do {
            let home = URL(fileURLWithPath: NSHomeDirectory())
            let bundle = Bundle.main.bundleIdentifier ?? "local.cala"
            let directory = home.appendingPathComponent("Library/Caches/\(bundle)/Docker", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let script = directory.appendingPathComponent(UUID().uuidString + ".command")
            let path = dockerShellQuote(Self.searchDirectories.joined(separator: ":"))
            let config = dockerShellQuote(home.appendingPathComponent(".docker").path)
            var body = "#!/bin/sh\n/bin/rm -f -- \"$0\"\nexport PATH=\(path)\nexport DOCKER_CONFIG=\(config)\nunset DOCKER_HOST DOCKER_CONTEXT\n"
            if let endpoint {
                guard let socket = DockerLocal.socketPath(for: endpoint) else { throw DockerSocketError.path }
                body += "export DOCKER_HOST=" + dockerShellQuote("unix://" + socket) + "\n"
            }
            body += "exec " + ([dockerCLI] + args).map(dockerShellQuote).joined(separator: " ") + "\n"
            try body.write(to: script, atomically: true, encoding: .utf8)
            do {
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
                guard NSWorkspace.shared.open(script) else { throw DockerSocketError.command }
            } catch {
                try? FileManager.default.removeItem(at: script)
                throw error
            }
        } catch {
            showError(errorKey, tx("Couldn't open Terminal.", "No se pudo abrir Terminal."))
        }
    }

    private func clearError(_ key: String) {
        errorWork.removeValue(forKey: key)?.cancel()
        errors[key] = nil
    }

    private func showError(_ key: String, _ message: String) {
        clearError(key)
        errors[key] = message
        let work = DispatchWorkItem { [weak self] in self?.clearError(key) }
        errorWork[key] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }
}
#endif

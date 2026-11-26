import Foundation
import Darwin
import CryptoKit

// Watchdog dependencies. Lock tests never start the watchdog or an app.
final class ConfigStore {
    struct Config { let relaunchOnCrash = false }
    let config = Config()
}

let fm = FileManager.default
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
var passed = 0
func check(_ value: Bool, _ name: String) {
    if !value { print("FAIL \(name)"); exit(1) }
    passed += 1
}
var warnings: [String] = []
func log(_ message: String) { warnings.append(message) }
func mkdir(_ dir: URL) throws { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
func inode(_ url: URL) throws -> ino_t {
    var s = stat()
    guard lstat(url.path, &s) == 0 else { throw POSIXError(.ENOENT) }
    return s.st_ino
}
func mode(_ url: URL) -> mode_t {
    var s = stat()
    precondition(lstat(url.path, &s) == 0)
    return s.st_mode & 0o777
}
func sign(_ path: URL, id: String, requirement: String? = nil) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    p.arguments = ["--force", "--sign", "-", "--identifier", id] +
        (requirement.map { ["-r=designated => " + $0] } ?? []) + [path.path]
    p.standardError = FileHandle.nullDevice
    try p.run()
    p.waitUntilExit()
    check(p.terminationStatus == 0, "real ad-hoc signing \(path.lastPathComponent)")
}
if CommandLine.arguments.last == "--probe-session" {
    exit(CalaSessionLock.acquire(in: root, session: 7) == nil ? 1 : 0)
}

let helperPath = "Contents/Helpers/cala-keychain"
let executable = "Contents/MacOS/Cala"
let resource = "Contents/Resources/release"
let plistPath = "Contents/Info.plist"
let requirement = #"identifier "local.cala""#
func makeApp(_ location: String, version: String, build: Int) throws -> URL {
    let app = root.appendingPathComponent(location + "/Cala.app")
    for dir in ["Contents/Helpers", "Contents/MacOS", "Contents/Resources"] { try mkdir(app.appendingPathComponent(dir)) }
    try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: app.appendingPathComponent(executable))
    try fm.copyItem(at: URL(fileURLWithPath: "packaging/Helpers/cala-keychain"), to: app.appendingPathComponent(helperPath))
    try fm.copyItem(atPath: CommandLine.arguments[2], toPath: app.appendingPathComponent("Contents/Helpers/cala-update").path)
    try Data(version.utf8).write(to: app.appendingPathComponent(resource))
    let plist: [String: Any] = ["CalaUpdateTest": true, "CalaUpdateTestUpTimeout": 0.25, "CFBundlePackageType":"APPL", "CFBundleExecutable":"Cala", "CFBundleIdentifier":"local.cala",
                 "CFBundleVersion":String(build), "CFBundleShortVersionString":version, "LSMinimumSystemVersion":"14.0"]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: app.appendingPathComponent(plistPath))
    try sign(app, id: "local.cala", requirement: requirement)
    return app
}
func snapshot(_ app: URL) throws -> [String: Data] {
    var files = [String: Data]()
    for case let relative as String in fm.enumerator(atPath: app.path)! {
        let entry = app.appendingPathComponent(relative)
        if !(try entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory ?? true) {
            files[relative] = try Data(contentsOf: entry)
        }
    }
    return files
}
let old = try makeApp("old", version: "1.0.0", build: 99999)
let new = try makeApp("new", version: "1.1.0", build: 2)
let oldBytes = try snapshot(old), newBytes = try snapshot(new)
let imageBytes = Data("fixture image, never executed".utf8)
let requiredHash = digest(try Data(contentsOf: old.appendingPathComponent(helperPath)))
let base = UpdateManifest(schema: 1, bundleId: "local.cala", version: "1.1.0", build: 2, minimumSystemVersion: "14",
                          publishedAt: Date(), dmg: .init(url: URL(string: "http://127.0.0.1:8765/test.dmg")!,
                                                        size: Int64(imageBytes.count), sha256: digest(imageBytes)),
                          app: .init(unpackedSize: 5_000_000, keychainHelperSHA256: requiredHash), notes: [:], notesURL: nil)
for url in ["http://localhost:8765/a", "http://127.0.0.2:8765/a", "http://127.0.0.1/a"] {
    check(!UpdateFeed.permitsRedirect(URL(string: url)!, testURLs: true), "test HTTP scope")
}
check(UpdateFeed.permitsRedirect(base.dmg.url, testURLs: true) && !UpdateFeed.permitsRedirect(base.dmg.url, testURLs: false), "test build loopback opt-in")

final class Fixture {
    let dir: URL, target: URL, image: URL
    var tools = InstallerTools.system
    var manifest = base
    var installer: UpdateInstaller?
    var child: Process?
    deinit { if let child, child.isRunning { child.terminate() } }
    var fault = InstallerFaults.none

    init() throws {
        dir = root.appendingPathComponent(UUID().uuidString)
        target = dir.appendingPathComponent("Cala.app")
        let cache = dir.appendingPathComponent("cache")
        image = cache.appendingPathComponent("local.cala/Updates/1.1.0-2/download.dmg")
        tools.cacheDirectory = cache
        try mkdir(image.deletingLastPathComponent())
        try mkdir(dir)
        try fm.copyItem(at: old, to: target)
        try imageBytes.write(to: image)
        tools.capacity = { _ in Int64.max }
        let support = dir.appendingPathComponent("support")
        try mkdir(support)
        tools.supportDirectory = { support }
        tools.blocked = {
            let url = support.appendingPathComponent("update-blocked.json")
            if !fm.fileExists(atPath: url.path) { return [] }
            return try JSONDecoder().decode(Set<String>.self, from: Data(contentsOf: url))
        }
        tools.arm = { [weak self] file, _, _, _ in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sleep")
            process.arguments = ["30"]
            try process.run()
            self?.child = process
            return process
        }
        tools.attach = { verified, mount in
            check(!Thread.isMainThread && (try? Data(contentsOf: verified)) == imageBytes, "background, pinned verified image")
            check(mode(mount.deletingLastPathComponent()) == 0o700, "private stage")
            try fm.copyItem(at: new, to: mount.appendingPathComponent("Cala.app"))
        }
        tools.detach = { mount, _ in
            let file = mount.appendingPathComponent("Cala.app")
            if fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) }
        }
    }

    func run(download: Bool = false, localFile: URL? = nil) -> InstallResult {
        let installer = UpdateInstaller(target: target, tools: tools, faults: fault)
        self.installer = installer
        var result: InstallResult?
        installer.install(manifest: manifest, dmg: download ? manifest.dmg.url : (localFile ?? image)) {
            check(Thread.isMainThread, "completion on main")
            result = $0
        }
        let deadline = Date().addingTimeInterval(60)
        while result == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        guard let result else { print("FAIL installer did not complete"); exit(1) }
        return result
    }

    func cleanFailure(_ name: String, unchanged: Bool = true, _ matches: (InstallResult) -> Bool) throws {
        let before = try inode(target)
        let existing = try fm.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(".cala-update.") && $0 != ".cala-update.lock" }
        let result = run()
        check(matches(result), "\(name) result \(result)")
        if unchanged { check(try inode(target) == before && snapshot(target) == oldBytes, "\(name) unchanged bytes and inode") }
        let remaining = try fm.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(".cala-update.") && $0 != ".cala-update.lock" }
        check(Set(remaining) == Set(existing), "\(name) cleanup")
    }
}
func verification(_ result: InstallResult) -> Bool { if case .verificationFailed = result { return true }; return false }
func failed(_ result: InstallResult) -> Bool { if case .failed = result { return true }; return false }

// Exercise the real URLSessionDownloadTask offline; all writes stay inside the fixture.
final class ImageProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let code = url.lastPathComponent == "missing" ? 404 : 200
        let body = url.lastPathComponent == "short" ? imageBytes.dropLast() : imageBytes[...]
        let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Length": String(body.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

func suite() throws {
    var commands: [(String, [String], Double)] = []
    let tools = InstallerTools.commands { commands.append(($0, $1, $2)) }
    let image = root.appendingPathComponent("verified.dmg"), mount = root.appendingPathComponent("mnt")
    try tools.attach(image, mount)
    try tools.copy(old, new)
    try tools.detach(mount, false)
    try tools.detach(mount, true)
    check(commands[0] == ("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, image.path], 60),
          "read-only mount and timeout")
    check(commands[1] == ("/usr/bin/ditto", [old.path, new.path], 120), "ditto and timeout")
    check(commands[2] == ("/usr/bin/hdiutil", ["detach", mount.path], 60) &&
          commands[3] == ("/usr/bin/hdiutil", ["detach", "-force", mount.path], 60), "detach and forced detach")
    try InstallerTools.run("/bin/sh", ["-c", #"test "$PATH" = /usr/bin:/bin && test "$DEVELOPER_DIR" = /var/empty && test -z "$HOME""#], timeout: 2)
    do {
        try InstallerTools.run("/bin/sleep", ["10"], timeout: 0.05)
        check(false, "tool timeout")
    } catch let e as NSError { check(e.domain == NSPOSIXErrorDomain && e.code == ETIMEDOUT, "tool timeout") }
    for path in ["good", "short", "missing"] {
        let f = try Fixture()
        f.manifest.dmg.url = base.dmg.url.deletingLastPathComponent().appendingPathComponent(path)
        f.tools.cacheDirectory = f.dir.appendingPathComponent("cache")
        f.tools.downloadConfiguration = { version in
            let config = UpdateFeed.configuration(version: version, background: true)
            config.protocolClasses = [ImageProtocol.self]
            return config
        }
        try fm.removeItem(at: f.image)
        let result = f.run(download: true)
        if path == "good" {
            guard case .installed = result else { check(false, "URLSession download: \(result)"); return }
            check(try snapshot(f.target) == newBytes, "completed download installs")
        } else {
            check(path == "short" ? verification(result) : failed(result), "failed download: \(result)")
            check(try snapshot(f.target) == oldBytes, "failed transfer leaves old bytes")
        }
        let files = try fm.subpathsOfDirectory(atPath: f.tools.cacheDirectory.path)
        check(!files.contains { $0.hasSuffix(".dmg") }, "download cache cleanup")
    }

    for scenario in ["swap", "cleanup failure", "detach retry", "image path replaced"] {
        let f = try Fixture()
        var forced = false
        if scenario == "swap" {
            f.tools.capacity = { _ in UpdateRules.requiredSpace(base)! }
            let copy = f.tools.copy
            f.tools.copy = { src, dst in
                try copy(src, dst)
                let file = dst.appendingPathComponent(resource)
                guard chmod(file.path, 0o606) == 0,
                      setxattr(file.path, "com.apple.quarantine", "0081;00000000;Fixture;", 22, 0, 0) == 0
                else { throw POSIXError(.EIO) }
            }
        }
        if scenario == "cleanup failure" { f.tools.cleanup = { _ in throw POSIXError(.EIO) } }
        if scenario == "detach retry" {
            let detach = f.tools.detach
            f.tools.detach = { mount, force in
                if !force { throw POSIXError(.ETIMEDOUT) }
                forced = true
                try detach(mount, true)
            }
        }
        if scenario == "image path replaced" {
            let attach = f.tools.attach, download = f.image
            f.tools.attach = { image, mount in
                try Data("changed cache entry".utf8).write(to: download, options: .atomic)
                try attach(image, mount)
            }
        }
        let before = try inode(f.target)
        let result = f.run()
        guard case let .installed(previous) = result else { check(false, "\(scenario): \(result)"); return }
        check(try snapshot(f.target) == newBytes && snapshot(previous) == oldBytes &&
              inode(previous) == before && inode(f.target) != before, "\(scenario) complete atomic exchange")
        check(previous.path.hasSuffix("/previous/Cala.app"), "rollback path")
        if scenario == "swap" {
            try f.installer!.confirmWatch(previous: previous)
            f.child?.terminate()
            f.child?.waitUntilExit()
            try f.installer!.confirmWatch(previous: previous)
            check(f.installer!.watcher?.isRunning == true, "rearmed from pinned backup")
            f.child?.terminate()
            f.child?.waitUntilExit()
            let changedHelper = previous.appendingPathComponent("Contents/Helpers/cala-update")
            let originalHelper = try Data(contentsOf: changedHelper)
            try Data("different helper".utf8).write(to: changedHelper)
            do { try f.installer!.confirmWatch(previous: previous); check(false, "untrusted helper rejected before exec") }
            catch { check(f.installer!.watcher?.isRunning != true, "changed helper never armed") }
            try originalHelper.write(to: changedHelper)
            let copy = previous.deletingLastPathComponent().appendingPathComponent("displaced")
            try fm.moveItem(at: previous, to: copy)
            try fm.copyItem(at: old, to: previous)
            do { try f.installer!.confirmWatch(previous: previous); check(false, "changed backup prevents quit") }
            catch { check(true, "changed backup prevents quit") }
        }
        let file = f.target.appendingPathComponent(resource)
        let admin = getgrnam("admin")?.pointee.gr_gid
        for (url, expected) in [(f.target, mode_t(0o750)), (file, mode_t(0o640))] {
            var status = stat()
            check(lstat(url.path, &status) == 0 && (mode(url) & 0o772) == (expected | (admin == status.st_gid ? 0o020 : 0)),
                  "normalized permissions follow effective group")
        }
        check(getxattr(file.path, "com.apple.quarantine", nil, 0, 0, 0) < 0 && errno == ENOATTR, "quarantine removed")
        check(mode(file) & 0o111 == 0 && mode(f.target.appendingPathComponent(executable)) & 0o110 == 0o110, "executable bits")
        check(try InstallerTools.system.identity(f.target).identifier == "local.cala", "post-normalization signature")
        if scenario == "detach retry" { check(forced, "forced detach") }
        if scenario == "cleanup failure" { check(warnings.contains { $0.hasPrefix("update: cleanup") }, "cleanup warning logged") }
        if let group = getgrnam("admin") {
            let admin = group.pointee.gr_gid
            var groups = [gid_t](repeating: 0, count: Int(getgroups(0, nil)))
            let belongs = getgroups(Int32(groups.count), &groups) >= 0 && groups.contains(admin)
            var info = stat()
            check(lstat(file.path, &info) == 0 && info.st_uid == geteuid() && (!belongs || info.st_gid == admin), "installed owner and group")
        }
        if scenario == "image path replaced" { check(try Data(contentsOf: f.image) == Data("changed cache entry".utf8), "preserve replacement") }
    }

    check(UpdateInstaller.normalizedMode(0o777, executable: true, group: 20, admin: 80) == 0o755 &&
          UpdateInstaller.normalizedMode(0o666, executable: false, group: 80, admin: 80) == 0o664, "effective admin group")
    let noHelper = try Fixture()
    noHelper.tools.arm = { _, _, _, _ in
        let process = Process()
        process.executableURL = noHelper.dir.appendingPathComponent("missing-helper")
        try process.run()
        return process
    }
    try noHelper.cleanFailure("helper run failure", failed)
    check(try UpdateJournal.read(in: noHelper.tools.supportDirectory()) == nil, "unarmed journal cancelled")

    let deferred = try Fixture()
    deferred.tools.beforeSwap = {
        check(try UpdateJournal.read(in: deferred.tools.supportDirectory())?.from == "1.0.0+99999",
              "pending identifies locked disk bundle")
        throw InstallResult.deferred
    }
    try deferred.cleanFailure("auto gate changed before swap") { $0 == .deferred }

    let cache = try Fixture()
    let baseDir = cache.tools.cacheDirectory
    let file = try DownloadFile(base: baseDir, manifest: base, saved: nil)
    let releaseDir = file.savedURL.deletingLastPathComponent()
    let movedCache = baseDir.appendingPathComponent("moved")
    try fm.moveItem(at: releaseDir, to: movedCache)
    try fm.createSymbolicLink(at: releaseDir, withDestinationURL: cache.dir)
    let outside = cache.dir.appendingPathComponent(file.savedURL.lastPathComponent)
    try mkdir(outside)
    try file.receive(movedCache.appendingPathComponent("download.dmg"), size: base.dmg.size)
    file.discard()
    check(fm.fileExists(atPath: outside.path) && !fm.fileExists(atPath: file.pinnedURL.path), "pinned download and unlink")
    do { _ = try DownloadFile(base: baseDir, manifest: base, saved: nil); check(false, "symlink cache rejected") }
    catch { check(true, "symlink cache rejected") }

    let live = try Fixture()
    let support = live.tools.supportDirectory()
    let backup = live.dir.appendingPathComponent(".cala-update.fixture/previous/Cala.app")
    let journal = UpdateJournal(from: "0.9.0+5", to: "1.0.0+99999", previous: backup.path, transaction: UUID())
    try journal.write(in: support)
    let worker = DispatchQueue(label: "receipt.test")
    var executableStat = stat()
    check(stat(live.target.appendingPathComponent(executable).path, &executableStat) == 0, "fixture executable")
    let runningID = UpdateJournal.fileID(executableStat)
    var mappedStat = stat()
    check(stat(CommandLine.arguments[0], &mappedStat) == 0 && UpdateJournal.runningExecutableID() == UpdateJournal.fileID(mappedStat),
          "kernel mapped executable identity")
    func ping() {
        journal.scheduleHealth(in: support, runningBundle: live.target, delay: 0.01, work: worker, runningID: {
            dispatchPrecondition(condition: .onQueue(worker))
            return runningID
        }) {}
    }
    ping()
    Thread.sleep(forTimeInterval: 0.1)
    let receipt = support.appendingPathComponent(journal.marker)
    check(!fm.fileExists(atPath: receipt.path), "frozen main loop cannot acknowledge")
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    check(fm.fileExists(atPath: receipt.path), "live main loop acknowledges transaction")
    try fm.removeItem(at: receipt)
    try journal.record("healthy", in: support, runningBundle: old, runningID: runningID)
    try journal.record("healthy", in: support, runningBundle: live.target, runningID: "0:0")
    check(!fm.fileExists(atPath: receipt.path), "same build at other path or different mapped inode cannot acknowledge")
    try journal.record("quit", in: support, runningBundle: live.target, runningID: runningID)
    check(try String(contentsOf: receipt, encoding: .utf8) == "quit " + runningID, "voluntary quit identifies installed transaction")
    try fm.removeItem(at: receipt)
    try Data("rollback".utf8).write(to: receipt)
    try journal.record("quit", in: support, runningBundle: live.target, runningID: runningID)
    check(try !journal.acceptsReceipt(in: support), "late quit cannot overwrite rollback claim")
    try fm.removeItem(at: receipt)
    ping()
    let other = UpdateJournal(from: journal.from, to: journal.to, previous: journal.previous, transaction: UUID())
    try other.write(in: support)
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    check(!fm.fileExists(atPath: receipt.path), "stale transaction cannot acknowledge")

    func contender() throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        p.arguments = [live.dir.path, "--probe-session"]
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }
    let held = CalaSessionLock.acquire(in: live.dir, session: 7)!
    check(try contender() == 1, "duplicate process exits before startup")
    let secondLogin = CalaSessionLock.acquire(in: live.dir, session: 8)
    check(secondLogin != nil && fcntl(held, F_GETFD) & FD_CLOEXEC != 0, "independent session and close on exec")
    close(held)
    close(secondLogin!)
    check(try contender() == 0, "fresh process starts after predecessor exits")
    let relaunch = CalaSessionLock.acquire(in: live.dir, session: 7)
    check(relaunch != nil, "session reacquired after exit")
    close(relaunch!)

    let displaced = try Fixture()
    guard case let .installed(previous) = displaced.run() else { check(false, "superseded install setup"); return }
    let manual = try makeApp("manual", version: "1.3.0", build: 4)
    try fm.removeItem(at: displaced.target)
    try fm.copyItem(at: manual, to: displaced.target)
    let installedInode = try inode(displaced.target)
    check(displaced.run() == .upToDate, "superseded install reconciled even on older offer")
    check(try UpdateJournal.read(in: displaced.tools.supportDirectory()) == nil && !fm.fileExists(atPath: previous.path)
          && inode(displaced.target) == installedInode, "C preserved and superseded journal and stage closed")

    let active = try Fixture()
    guard case let .installed(activeBackup) = active.run() else { check(false, "live supersession setup"); return }
    try fm.removeItem(at: active.target)
    try fm.copyItem(at: new, to: active.target) // Same build string, different installed executable.
    try Data("unsealed".utf8).write(to: active.target.appendingPathComponent(resource))
    do { try active.installer!.confirmWatch(previous: activeBackup); check(false, "invalid replacement accepted") }
    catch { check(fm.fileExists(atPath: activeBackup.path), "keep backup while replacement is invalid") }
    try fm.removeItem(at: active.target)
    try fm.copyItem(at: new, to: active.target)
    do { try active.installer!.confirmWatch(previous: activeBackup); check(false, "obsolete handoff was armed") }
    catch InstallResult.upToDate {
        check(try UpdateJournal.read(in: active.tools.supportDirectory()) == nil && !fm.fileExists(atPath: activeBackup.path),
              "deferred restart released after verified same-version replacement")
    }

    let diskFull = try Fixture()
    let diskSupport = diskFull.tools.supportDirectory()
    let restored = UpdateJournal(from: "1.0.0+99999", to: "1.1.0+2",
                                 previous: diskFull.dir.appendingPathComponent(".cala-update.restored/previous/Cala.app").path,
                                 transaction: UUID())
    try restored.write(in: diskSupport)
    try Data().write(to: diskSupport.appendingPathComponent("update-rollback"))
    check(verification(diskFull.run()), "reconcile unrecorded failed build before reinstall")
    check(try UpdateJournal.read(in: diskSupport) == nil && !fm.fileExists(atPath: diskSupport.appendingPathComponent("update-rollback").path),
          "restored pending and rollback markers removed together")

    let otherProfile = diskFull.dir.appendingPathComponent("second-account")
    try mkdir(otherProfile)
    diskFull.tools.supportDirectory = { otherProfile }
    diskFull.tools.blocked = { [] }
    check(try UpdateJournal.sharedBlocks(target: diskFull.target).contains("1.1.0+2"), "second account reads shared block")
    let secondAccountBlocks = try UpdateJournal.sharedBlocks(target: diskFull.target)
    check(UpdateRules.evaluate(base, running: AppVersion(version: "1.0.0", build: "99999")!, bundleId: base.bundleId,
                               os: ProcessInfo.processInfo.operatingSystemVersion, highestSeen: nil, skipped: nil,
                               blocked: secondAccountBlocks, testURLs: true) == .upToDate, "no offer in fresh account")
    check(verification(diskFull.run()), "shared block stops installer with a fresh profile")
    diskFull.tools.supportDirectory = { diskSupport }
    try Data().write(to: diskSupport.appendingPathComponent("update-rollback"))
    // The old build could clear only pending at startup. A later install cleans the orphan under flock.
    diskFull.manifest.version = "1.2.0"
    _ = diskFull.run()
    check(!fm.fileExists(atPath: diskSupport.appendingPathComponent("update-rollback").path), "orphan rollback sentinel")

    try crashCase()

    let before = try Fixture()
    before.fault = .beforeSwap
    try before.cleanFailure("before-swap", failed)

    let symlink = try Fixture()
    try fm.removeItem(at: symlink.target)
    try fm.createSymbolicLink(at: symlink.target, withDestinationURL: old)
    try symlink.cleanFailure("target symlink", unchanged: false) { failed($0) || verification($0) }
    check(try snapshot(old) == oldBytes, "link destination unchanged")

    let stale = try Fixture()
    let wrongFile = stale.target.appendingPathComponent(executable)
    check(verification(stale.run(localFile: wrongFile)), "stale cache path rejected")
    check(try snapshot(stale.target) == oldBytes, "stale cache path cannot delete installed files")

    let inputLink = try Fixture()
    try fm.removeItem(at: inputLink.image)
    try fm.createSymbolicLink(at: inputLink.image, withDestinationURL: old.appendingPathComponent(resource))
    try inputLink.cleanFailure("DMG symlink") { failed($0) || verification($0) }

    let race = try Fixture()
    let target = race.target, elsewhere = race.dir.appendingPathComponent("saved")
    race.tools.beforeSwap = {
        try fm.moveItem(at: target, to: elsewhere)
        try fm.copyItem(at: old, to: target)
    }
    try race.cleanFailure("target inode changed", unchanged: false) { $0 == .busy }
    check(try snapshot(target) == oldBytes && snapshot(elsewhere) == oldBytes, "replacement not overwritten")

    let lateRace = try Fixture()
    let path = lateRace.target, moved = lateRace.dir.appendingPathComponent("moved")
    let swap = lateRace.tools.swap
    lateRace.tools.swap = { incoming, parent in
        // Interleave after fstatat and before the kernel exchange.
        do { try fm.moveItem(at: path, to: moved); try fm.copyItem(at: old, to: path) }
        catch { errno = EIO; return -1 }
        return swap(incoming, parent)
    }
    try lateRace.cleanFailure("last-instant inode change", unchanged: false) { $0 == .busy }
    check(try snapshot(path) == oldBytes && snapshot(moved) == oldBytes, "late contender restored")

    let lockLink = try Fixture()
    try fm.createSymbolicLink(at: lockLink.dir.appendingPathComponent(".cala-update.lock"),
                              withDestinationURL: lockLink.image)
    try lockLink.cleanFailure("symlink lock") { failed($0) || $0 == .busy }

    let locked = try Fixture()
    let fd = open(locked.dir.appendingPathComponent(".cala-update.lock").path, O_RDONLY | O_CREAT, 0o664)
    guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw POSIXError(.EIO) }
    defer { close(fd) }
    try locked.cleanFailure("held lock") { $0 == .busy }
    for version in ["1.0.0", "0.9.0"] {
        let f = try Fixture()
        f.manifest.version = version
        if version == "1.0.0" { f.manifest.build = 99999 }
        try f.cleanFailure("installed already at or above manifest") { $0 == .upToDate }
    }
    for early in [true, false] {
        let f = try Fixture()
        var checks = 0
        f.tools.blocked = { checks += 1; return early || checks > 1 ? ["1.1.0+2"] : [] }
        try f.cleanFailure("blocked build", verification)
    }
    for size in [true, false] {
        let f = try Fixture()
        if size { f.manifest.dmg.size += 1 } else { f.manifest.dmg.sha256 = String(repeating: "0", count: 64) }
        try f.cleanFailure("corrupt image", verification)
        check(!fm.fileExists(atPath: f.image.path), "corrupt download deleted")
    }
    for atStart in [true, false] {
        let f = try Fixture()
        let required = UpdateRules.requiredSpace(f.manifest)!
        if atStart { f.tools.capacity = { _ in required - 1 } }
        else { f.tools.copy = { _, _ in throw POSIXError(.ENOSPC) } }
        try f.cleanFailure("disk full") { $0 == .diskFull(required) }
    }
    for step in ["attach", "copy", "detach"] {
        let f = try Fixture()
        switch step {
        case "attach": f.tools.attach = { _, _ in throw POSIXError(.EIO) }
        case "copy": f.tools.copy = { _, _ in throw POSIXError(.ETIMEDOUT) }
        default:
            let detach = f.tools.detach
            var calls = 0
            f.tools.detach = { mount, force in
                calls += 1
                if calls <= 2 { throw POSIXError(.ETIMEDOUT) }
                try detach(mount, force)
            }
        }
        try f.cleanFailure("failed " + step, failed)
    }
    for code in [EPERM, EACCES] {
        let f = try Fixture()
        f.tools.swap = { _, _ in errno = code; return -1 }
        try f.cleanFailure("macOS denial") { $0 == .blockedByMacOS }
    }
    for field in ["CFBundleIdentifier","CFBundleVersion","CFBundleShortVersionString","CFBundleExecutable","LSMinimumSystemVersion"] {
        let f = try Fixture()
        let copy = f.tools.copy
        f.tools.copy = { src, dst in
            try copy(src, dst)
            let file = dst.appendingPathComponent(plistPath)
            var info = try PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as! [String: Any]
            info[field] = "999"
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: file)
        }
        try f.cleanFailure("plist \(field)") { $0 == .verificationFailed("staged Info.plist") }
    }
    let architecture = try Fixture()
    architecture.tools.architectures = { _ in [] }
    try architecture.cleanFailure("missing host architecture", verification)

    for mutation in ["signature", "requirement", "helper", "link"] {
        let f = try Fixture()
        let copy = f.tools.copy
        f.tools.copy = { src, dst in
            try copy(src, dst)
            switch mutation {
            case "signature": try Data("unsealed".utf8).write(to: dst.appendingPathComponent(resource))
            case "requirement": try sign(dst, id: "local.cala", requirement: #"identifier "local.cala" and info[CFBundleName] exists"#)
            case "helper":
                let helper = dst.appendingPathComponent(helperPath)
                try fm.removeItem(at: helper)
                try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: helper)
                try sign(helper, id: "local.cala.keychain")
                try sign(dst, id: "local.cala", requirement: requirement)
            default: try fm.createSymbolicLink(at: dst.appendingPathComponent("escape"), withDestinationURL: old)
            }
        }
        try f.cleanFailure(mutation) { result in
            if mutation == "helper" { return result == .verificationFailed("helper SHA-256") }
            if mutation == "requirement" { return result == .verificationFailed("designated requirement") }
            return verification(result)
        }
    }
    let hash = try Fixture()
    hash.manifest.app.keychainHelperSHA256 = String(repeating: "a", count: 64)
    try hash.cleanFailure("signed helper digest", verification)

    // Team-ID fixtures use the real ad-hoc signature check for each object; only
    // the returned team metadata changes, so these need no Developer ID key.
    for variant in ["valid", "wrong app team", "wrong helper team", "wrong helper identifier"] {
        let f = try Fixture()
        let identity = f.tools.identity
        f.tools.identity = { url in
            let actual = try identity(url)
            let helper = url.lastPathComponent == "cala-keychain"
            let wrongTeam = variant == "wrong helper team" && helper || variant == "wrong app team" && url.lastPathComponent == "Cala.app" && url.deletingLastPathComponent().lastPathComponent != "installed"
            return .init(identifier: helper && variant == "wrong helper identifier" ? "other" : actual.identifier,
                         requirement: actual.requirement, team: wrongTeam ? "OTHER" : "TEAM")
        }
        if variant == "valid" {
            let result = f.run()
            if case .installed = result { check(true, "team install") } else { check(false, "\(variant): \(result)") }
        } else { try f.cleanFailure(variant, verification) }
    }
}
func crashCase() throws {
    let childRoot = root.appendingPathComponent("crash")
    let fakeOpen = root.appendingPathComponent("fake-open")
    try Data("#!/bin/sh\necho launch >> \"$CALA_LAUNCH_LOG\"\nsleep 0.4\n".utf8).write(to: fakeOpen)
    guard chmod(fakeOpen.path, 0o700) == 0 else { throw POSIXError(.EIO) }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    p.arguments = [childRoot.path, CommandLine.arguments[2], "crash"]
    p.environment = ProcessInfo.processInfo.environment.merging(
        ["CALA_UPDATE_TEST_OPEN": fakeOpen.path, "CALA_LAUNCH_LOG": root.appendingPathComponent("launches").path]) { _, new in new }
    try p.run()
    p.waitUntilExit()
    check(p.terminationStatus == 86, "after-swap exits before completion")
    let dir = URL(fileURLWithPath: try String(contentsOf: childRoot.appendingPathComponent("transaction"), encoding: .utf8))
    let support = dir.appendingPathComponent("support")
    let contender = open(dir.appendingPathComponent(".cala-update.lock").path, O_RDONLY)
    defer { close(contender) }
    check(contender >= 0 && flock(contender, LOCK_EX | LOCK_NB) != 0, "helper retains flock after installer exit")
    let deadline = Date().addingTimeInterval(12)
    while Date() < deadline, try UpdateJournal.read(in: support) != nil { Thread.sleep(forTimeInterval: 0.05) }
    check(try UpdateJournal.identity(at: dir.appendingPathComponent("Cala.app")) == "1.0.0+99999", "armed helper restores after installer crash")
    check(try String(contentsOf: support.appendingPathComponent("update-blocked.json"), encoding: .utf8).contains("1.1.0+2"),
          "after-swap failed build blocked")
    check(try String(contentsOf: root.appendingPathComponent("launches"), encoding: .utf8) == "launch\nlaunch\n", "after-swap relaunches restored bundle")
}

if CommandLine.arguments.last == "crash" {
    let f = try Fixture()
    try f.dir.path.write(to: root.appendingPathComponent("transaction"), atomically: true, encoding: .utf8)
    f.tools.arm = { helper, lock, support, target in
        check(helper.path.contains("/installed/Cala.app/") && !helper.path.hasPrefix(f.dir.path), "verified private helper")
        let p = try UpdateWatch.start(helper: helper, lock: lock, support: support, target: target)
        let contender = open(f.dir.appendingPathComponent(".cala-update.lock").path, O_RDONLY)
        defer { close(contender) }
        check(contender >= 0 && flock(contender, LOCK_EX | LOCK_NB) != 0, "continuous watcher lock")
        return p
    }
    f.fault = .afterSwap
    print("Unexpected crash installer result", f.run())
    exit(1)
}
do { try suite(); print("PASS \(passed) installer checks") }
catch { print("FAIL installer fixture: \(error)"); exit(1) }


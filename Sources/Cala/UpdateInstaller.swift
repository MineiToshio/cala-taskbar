import Foundation
import Darwin
import Security

enum InstallResult: Error, Equatable {
    case installed(previous: URL), upToDate, deferred, verificationFailed(String), diskFull(Int64), busy, blockedByMacOS, failed(String)
}

enum InstallerFaults: String {
    case none
    #if CALA_UPDATE_TEST
    case beforeSwap = "before-swap", afterSwap = "after-swap"
    #endif
}

private let directoryFlags = O_RDONLY | O_NOFOLLOW | O_DIRECTORY | O_CLOEXEC
private let readFlags = O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC

private func posixError(_ code: Int32 = errno) -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(code))
}

private func descriptor(_ fd: Int32) throws -> FileHandle {
    guard fd >= 0 else { throw posixError() }
    return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
}

private func status(_ handle: FileHandle) throws -> stat {
    var info = stat()
    guard fstat(handle.fileDescriptor, &info) == 0 else { throw posixError() }
    return info
}

private func sameEntry(_ parent: FileHandle, _ name: String, _ expected: stat) -> Bool {
    var info = stat()
    return fstatat(parent.fileDescriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 &&
        info.st_dev == expected.st_dev && info.st_ino == expected.st_ino
}

// Darwin's volume-ID paths let path-only APIs address an open directory even
// if another account renames its entry in the shared Applications directory.
private func volumeURL(_ info: stat) throws -> URL {
    let url = URL(fileURLWithPath: "/.vol/\(UInt32(bitPattern: info.st_dev))/\(info.st_ino)", isDirectory: true)
    var actual = stat()
    guard lstat(url.path, &actual) == 0, actual.st_dev == info.st_dev, actual.st_ino == info.st_ino
    else { throw InstallResult.busy }
    return url
}

struct InstallerTools {
    struct Identity {
        let identifier: String
        let requirement: String
        let team: String?
    }

    var attach: (URL, URL) throws -> Void
    var copy: (URL, URL) throws -> Void
    var detach: (URL, Bool) throws -> Void
    var identity: (URL) throws -> Identity
    var architectures: (URL) -> [NSNumber]?
    var capacity: (URL) throws -> Int64
    var blocked: () throws -> Set<String>
    var cleanup: (URL) throws -> Void
    var cacheDirectory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    var downloadConfiguration = { (version: String) in UpdateFeed.configuration(version: version, background: true) }
    var supportDirectory: () -> URL = { AppPaths.supportDirectory }
    var arm: (URL, FileHandle, URL, URL) throws -> Process = UpdateWatch.start
    var beforeSwap: () throws -> Void = {}
    var swap: (Int32, Int32) -> Int32 = { new, parent in
        renameatx_np(new, "Cala.app", parent, "Cala.app", UInt32(RENAME_SWAP))
    }

    static let system = commands(execute: run)

    static func commands(execute: @escaping (String, [String], Double) throws -> Void) -> Self {
        Self(
            attach: { image, mount in
                try execute("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen",
                                             "-mountpoint", mount.path, image.path], 60)
            },
            copy: { source, destination in try execute("/usr/bin/ditto", [source.path, destination.path], 120) },
            detach: { mount, force in
                try execute("/usr/bin/hdiutil", ["detach"] + (force ? ["-force"] : []) + [mount.path], 60)
            },
            identity: signingIdentity,
            architectures: { Bundle(url: $0)?.executableArchitectures },
            capacity: { url in
                let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                guard let capacity = values.volumeAvailableCapacityForImportantUsage else { throw posixError(EIO) }
                return capacity
            },
            blocked: blockedBuilds,
            cleanup: { try FileManager.default.removeItem(at: $0) }
        )
    }

    private static func blockedBuilds() throws -> Set<String> {
        let stored = UserDefaults.standard.object(forKey: "update.state")
        var state = stored as? [String: Any]
        if let data = stored as? Data {
            state = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        guard stored == nil || state != nil else { throw InstallResult.failed("update.state") }
        let entries = state?["blockedBuilds"]
        guard entries == nil || entries is [String] else { throw InstallResult.failed("blockedBuilds") }
        var blocked = Set(entries as? [String] ?? [])
        let file = AppPaths.supportDirectory.appendingPathComponent("update-blocked.json")
        do { blocked.formUnion(try JSONDecoder().decode([String].self, from: Data(contentsOf: file))) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile {}
        return blocked
    }

    private static func signingIdentity(_ url: URL) throws -> Identity {
        var code: SecStaticCode?, requirement: SecRequirement?, string: CFString?, info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess,
              SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement,
              SecRequirementCopyString(requirement, [], &string) == errSecSuccess, let string,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let fields = info as? [String: Any], let identifier = fields[kSecCodeInfoIdentifier as String] as? String
        else { throw InstallResult.verificationFailed("codesign") }
        return Identity(identifier: identifier, requirement: string as String, team: fields[kSecCodeInfoTeamIdentifier as String] as? String)
    }

    static func run(_ executable: String, _ arguments: [String], timeout: Double) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin", "DEVELOPER_DIR": "/var/empty"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        var template = Array((NSTemporaryDirectory() + "/cala-tool.XXXXXXXX").utf8CString)
        let diagnostics = try descriptor(mkstemp(&template))
        unlink(template)
        process.standardError = diagnostics
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        if done.wait(timeout: .now() + timeout) == .timedOut {
            if process.isRunning { process.terminate() }
            if done.wait(timeout: .now() + 2) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = done.wait(timeout: .now() + 2)
            }
            throw posixError(ETIMEDOUT)
        }
        guard process.terminationStatus != 0 else { return }
        try diagnostics.seek(toOffset: 0)
        let message = String(decoding: try diagnostics.read(upToCount: 65536) ?? Data(), as: UTF8.self)
        if message.localizedCaseInsensitiveContains("No space left on device") { throw posixError(ENOSPC) }
        throw InstallResult.failed("\(process.executableURL!.lastPathComponent) (\(process.terminationStatus))")
    }
}

final class UpdateInstaller {
    private let queue = DispatchQueue(label: "Cala.update", qos: .utility)
    private let target: URL
    private let tools: InstallerTools
    private let faults: InstallerFaults
    private(set) var watcher: Process?
    private var backupIdentity: stat?
    private var verifiedHelperDigest: String?
    private var resume: (url: URL, data: Data)?

    init(target: URL, tools: InstallerTools = .system, faults: InstallerFaults = .none) {
        self.target = target
        self.tools = tools
        #if CALA_UPDATE_TEST
        let configured = Bundle.main.object(forInfoDictionaryKey: "CalaUpdateTestFault") as? String
        self.faults = faults == .none ? configured.flatMap(InstallerFaults.init(rawValue:)) ?? .none : faults
        #else
        self.faults = faults
        #endif
    }

    // Call with an envelope verified by UpdateSignature, including when loading a cached update.
    func install(manifest: UpdateManifest, dmg: URL, completion: @escaping (InstallResult) -> Void) {
        queue.async {
            let result: InstallResult
            do {
                guard UpdateRules.validPayload(manifest, testURLs: true),
                      let candidate = AppVersion(version: manifest.version, build: String(manifest.build)),
                      let needed = UpdateRules.requiredSpace(manifest),
                      AppVersion.supports(minimum: manifest.minimumSystemVersion, os: ProcessInfo.processInfo.operatingSystemVersion)
                else { throw InstallResult.verificationFailed("manifest") }
                guard try self.tools.capacity(self.target.deletingLastPathComponent()) >= needed else {
                    throw InstallResult.diskFull(needed)
                }
                try self.checkBlocked(candidate)
                let file = dmg.isFileURL ? dmg : try self.download(manifest, from: dmg)
                result = try self.replace(manifest, candidate: candidate, image: file)
            } catch let failure as InstallResult { result = failure }
            catch {
                let e = error as NSError
                result = (e.domain == NSPOSIXErrorDomain && e.code == ENOSPC) ||
                    (e.domain == NSCocoaErrorDomain && e.code == NSFileWriteOutOfSpaceError)
                    ? .diskFull(UpdateRules.requiredSpace(manifest) ?? 0) : .failed(e.domain + " \(e.code)")
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func confirmWatch(previous: URL) throws {
        let support = tools.supportDirectory()
        guard let pending = try UpdateJournal.read(in: support), pending.previous == previous.path else {
            throw InstallResult.failed("missing handoff")
        }
        let parent = try descriptor(open(target.deletingLastPathComponent().path, directoryFlags))
        if try pending.diskState(at: target) == .superseded {
            let lock = try descriptor(openat(parent.fileDescriptor, ".cala-update.lock", readFlags))
            try withExtendedLifetime(lock) {
                guard flock(lock.fileDescriptor, LOCK_EX | LOCK_NB) == 0,
                      try UpdateJournal.read(in: support) == pending, try pending.diskState(at: target) == .superseded
                else { throw InstallResult.busy }
                try UpdateJournal.reconcileRestored(in: support, target: target)
            }
            throw InstallResult.upToDate
        }
        let stage = previous.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
        let pinned = try descriptor(openat(parent.fileDescriptor, stage + "/previous/Cala.app",
                                           O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC))
        let actual = try status(pinned)
        guard let backupIdentity, actual.st_dev == backupIdentity.st_dev,
              actual.st_ino == backupIdentity.st_ino,
              try UpdateJournal.identity(at: volumeURL(actual)) == pending.from,
              try pending.diskState(at: target) == .incoming else { throw InstallResult.failed("backup changed") }
        if watcher?.isRunning == true { return }
        let lock = try descriptor(open(target.deletingLastPathComponent().appendingPathComponent(".cala-update.lock").path, readFlags))
        guard flock(lock.fileDescriptor, LOCK_EX | LOCK_NB) == 0 else { throw InstallResult.busy }
        var template = Array((NSTemporaryDirectory() + "/cala-watch.XXXXXXXX").utf8CString)
        guard mkdtemp(&template) != nil else { throw posixError() }
        let work = URL(fileURLWithPath: String(cString: template))
        defer { try? FileManager.default.removeItem(at: work) }
        let helperPath = "Contents/Helpers/cala-update"
        let source = try descriptor(openat(pinned.fileDescriptor, helperPath, O_RDONLY | O_NOFOLLOW_ANY | O_CLOEXEC))
        let privateHelper = work.appendingPathComponent(helperPath)
        try FileManager.default.createDirectory(at: privateHelper.deletingLastPathComponent(), withIntermediateDirectories: true)
        let output = try descriptor(open(privateHelper.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o500))
        let digest = try UpdateSignature.hash(source, limit: Int64.max, copyingTo: output).1
        try output.close()
        guard digest == verifiedHelperDigest, try tools.identity(privateHelper).identifier == "local.cala.update" else {
            throw InstallResult.verificationFailed("rollback helper identity")
        }
        watcher = try tools.arm(privateHelper, lock, support, target)
    }

    private func checkBlocked(_ candidate: AppVersion) throws {
        if try UpdateRules.isBlocked(candidate, by: tools.blocked()) { throw InstallResult.verificationFailed("blocked") }
    }

    private func replace(_ m: UpdateManifest, candidate: AppVersion, image: URL) throws -> InstallResult {
        guard target.lastPathComponent == "Cala.app" else { throw InstallResult.verificationFailed("target") }
        let fm = FileManager.default
        let parentURL = target.deletingLastPathComponent()
        let parent = try descriptor(open(parentURL.path, directoryFlags))
        let parentInfo = try status(parent)
        let installed = try descriptor(openat(parent.fileDescriptor, "Cala.app", directoryFlags))
        let original = try status(installed)
        let lockName = ".cala-update.lock"
        let lock = try descriptor(openat(parent.fileDescriptor, lockName, readFlags | O_CREAT, 0o664))
        defer { withExtendedLifetime((parent, installed, lock)) {} }
        let lockInfo = try status(lock)
        guard lockInfo.st_mode & S_IFMT == S_IFREG, lockInfo.st_nlink == 1,
              flock(lock.fileDescriptor, LOCK_EX | LOCK_NB) == 0,
              sameEntry(parent, lockName, lockInfo) else { throw InstallResult.busy }
        // flock only requires read access. Ignore the creating admin's restrictive umask.
        if lockInfo.st_uid == geteuid(), lockInfo.st_mode & 0o444 != 0o444 {
            guard fchmod(lock.fileDescriptor, 0o644) == 0 else { throw posixError() }
        }
        // The lock inode is permanent. The watcher inherits this open file description.
        guard sameEntry(parent, "Cala.app", original) else { throw InstallResult.busy }

        let oldURL = try volumeURL(original)
        let info = try Self.plist(installed)
        guard info["CFBundleIdentifier"] as? String == m.bundleId,
              let version = info["CFBundleShortVersionString"] as? String, let build = info["CFBundleVersion"] as? String,
              let current = AppVersion(version: version, build: build) else { throw InstallResult.verificationFailed("installed Info.plist") }

        let support = tools.supportDirectory()
        try UpdateJournal.reconcileRestored(in: support, target: target)
        guard current < candidate else { return .upToDate }
        guard try UpdateJournal.read(in: support) == nil else { throw InstallResult.busy }
        if try UpdateRules.isBlocked(candidate, by: UpdateJournal.sharedBlocksUnderLock(target: target)) {
            throw InstallResult.verificationFailed("blocked")
        }
        try checkBlocked(candidate)

        var template = Array(".cala-update.XXXXXXXX".utf8CString)
        guard mkdtempat_np(parent.fileDescriptor, &template) != nil else { throw posixError() }
        let name = String(cString: template)
        let stage = try descriptor(openat(parent.fileDescriptor, name, directoryFlags))
        let stageInfo = try status(stage)
        guard stageInfo.st_uid == geteuid(), stageInfo.st_mode & 0o777 == 0o700 else { throw InstallResult.busy }
        var committed = false
        defer {
            if !committed && sameEntry(parent, name, stageInfo) {
                if unlinkat(parent.fileDescriptor, name, AT_REMOVEDIR) != 0 { log("update: stage cleanup \(errno)") }
            }
        }
        let root = try volumeURL(stageInfo)
        // hdiutil, ditto and Security canonicalize paths. Use a second 0700
        // directory under the user's private temp directory for those APIs;
        // no lookup they perform traverses the shared Applications parent.
        var workTemplate = Array((NSTemporaryDirectory() + "/cala-update.XXXXXXXX").utf8CString)
        guard mkdtemp(&workTemplate) != nil else { throw posixError() }
        let work = URL(fileURLWithPath: String(cString: workTemplate), isDirectory: true)
        let mount = work.appendingPathComponent("mnt")
        let verified = work.appendingPathComponent("verified.dmg")
        var workRemoved = false
        var mountMayExist = false
        var children: [String] = []
        defer {
            if mountMayExist {
                do { try tools.detach(mount, true); mountMayExist = false }
                catch { log("update: force detach: \(error)") }
            }
            // If even a forced detach failed, leave the mount alone.
            if !mountMayExist && !workRemoved {
                do { try fm.removeItem(at: work) } catch { log("update: temporary cleanup: \(error)") }
            }
            if !committed {
                for child in children {
                    let entry = root.appendingPathComponent(child)
                    do { try fm.removeItem(at: entry) }
                    catch let e as CocoaError where e.code == .fileNoSuchFile {}
                    catch { log("update: stage cleanup: \(error)") }
                }
            }
        }
        let inputDirectory = try descriptor(open(image.deletingLastPathComponent().path, directoryFlags))
        let source = try descriptor(openat(inputDirectory.fileDescriptor, image.lastPathComponent, readFlags))
        let sourceInfo = try status(source)
        func discardDownload() {
            // A stale cache record can point anywhere, even into the installed bundle.
            // Only files in this release's managed cache are ours to unlink.
            guard let cache = try? openCache(for: m, create: false),
                  let cacheInfo = try? status(cache), let inputInfo = try? status(inputDirectory),
                  cacheInfo.st_dev == inputInfo.st_dev, cacheInfo.st_ino == inputInfo.st_ino,
                  cacheInfo.st_uid == geteuid(), sameEntry(cache, image.lastPathComponent, sourceInfo) else { return }
            if unlinkat(cache.fileDescriptor, image.lastPathComponent, 0) != 0 { log("update: cache cleanup \(errno)") }
        }
        guard sourceInfo.st_mode & S_IFMT == S_IFREG, sourceInfo.st_size == m.dmg.size else {
            if sourceInfo.st_mode & S_IFMT == S_IFREG { discardDownload() }
            throw InstallResult.verificationFailed("size")
        }
        do {
            let out = try descriptor(open(verified.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o600))
            let (size, digest) = try UpdateSignature.hash(source, limit: m.dmg.size, copyingTo: out)
            guard size == m.dmg.size, digest == m.dmg.sha256.lowercased() else { throw InstallResult.verificationFailed("SHA-256") }
        } catch let error as InstallResult { discardDownload(); throw error }
        catch is FeedFailure { discardDownload(); throw InstallResult.verificationFailed("size") }

        for child in ["previous"] {
            guard mkdirat(stage.fileDescriptor, child, 0o700) == 0 else { throw posixError() }
            children.append(child)
        }
        try fm.createDirectory(at: mount, withIntermediateDirectories: false)
        let new = work.appendingPathComponent("Cala.app", isDirectory: true)
        mountMayExist = true
        do { try tools.attach(verified, mount) }
        catch {
            // A failed attach may still have mounted the image. Probe before cleanup.
            var mountInfo = stat(), workInfo = stat()
            if lstat(mount.path, &mountInfo) == 0, lstat(work.path, &workInfo) == 0 {
                mountMayExist = mountInfo.st_dev != workInfo.st_dev
            }
            throw error
        }
        let mounted = mount.appendingPathComponent("Cala.app", isDirectory: true)
        var mountedInfo = stat()
        guard lstat(mounted.path, &mountedInfo) == 0, mountedInfo.st_mode & S_IFMT == S_IFDIR
        else { throw InstallResult.verificationFailed("mounted Cala.app") }
        try tools.copy(mounted, new)
        do { try tools.detach(mount, false) } catch { try tools.detach(mount, true) }
        mountMayExist = false

        let staged = try descriptor(open(new.path, directoryFlags))
        try Self.visit(new) { _, _ in } // Reject links and special files before path-based framework calls.
        // Snapshot using the pinned inode, then hand the stable private path
        // to Security. The installed identifier and helper are also read by fd.
        let oldCopy = work.appendingPathComponent("installed/Cala.app", isDirectory: true)
        try fm.createDirectory(at: oldCopy.deletingLastPathComponent(), withIntermediateDirectories: false)
        try fm.copyItem(at: oldURL, to: oldCopy)
        try verify(m, staged: staged, at: new, installed: installed, at: oldCopy)
        try Self.normalize(new)
        let incoming = try descriptor(openat(stage.fileDescriptor, "previous", directoryFlags))
        let workFD = try descriptor(open(work.path, directoryFlags))
        // Transfer the validated tree without resolving the public stage name.
        // An external home directory can put the private temp on another volume.
        if renameat(workFD.fileDescriptor, "Cala.app", incoming.fileDescriptor, "Cala.app") != 0 {
            guard errno == EXDEV else { throw posixError() }
            let destination = root.appendingPathComponent("previous/Cala.app")
            try fm.copyItem(at: new, to: destination)
            try Self.normalize(destination)
        }
        let ready = try descriptor(openat(incoming.fileDescriptor, "Cala.app", directoryFlags))
        guard fsync(stage.fileDescriptor) == 0 else { throw posixError() }
        #if CALA_UPDATE_TEST
        if faults == .beforeSwap { throw InstallResult.failed("before-swap") }
        #endif
        let backupURL = parentURL.appendingPathComponent(name).appendingPathComponent("previous/Cala.app")
        let journal = UpdateJournal(from: version + "+" + build, to: m.version + "+" + String(m.build),
                                    previous: backupURL.path, transaction: UUID(),
                                    executableID: try UpdateJournal.executableID(in: ready),
                                    backupID: UpdateJournal.fileID(original))
        let helper = oldCopy.appendingPathComponent("Contents/Helpers/cala-update")
        let trustedHelper = try descriptor(open(helper.path, readFlags))
        verifiedHelperDigest = try UpdateSignature.hash(trustedHelper, limit: Int64.max).1
        try journal.write(in: support)
        defer {
            if !committed { try? UpdateJournal.remove("update-pending.json", in: support) }
        }
        watcher = try tools.arm(helper, lock, support, target)
        defer { if !committed, let watcher, watcher.isRunning { watcher.terminate() } }
        for file in [verified, mount] {
            do { try tools.cleanup(file) } catch { log("update: cleanup: \(error)") }
        }
        try fm.removeItem(at: work)
        workRemoved = true
        try checkBlocked(candidate)
        try tools.beforeSwap()
        guard watcher?.isRunning == true else { throw InstallResult.failed("rollback helper exited") }
        let readyInfo = try status(ready)
        var currentParent = stat()
        guard lstat(parentURL.path, &currentParent) == 0,
              currentParent.st_dev == parentInfo.st_dev, currentParent.st_ino == parentInfo.st_ino,
              sameEntry(incoming, "Cala.app", readyInfo), sameEntry(parent, name, stageInfo),
              sameEntry(parent, lockName, lockInfo), sameEntry(parent, "Cala.app", original) else { throw InstallResult.busy }
        guard tools.swap(incoming.fileDescriptor, parent.fileDescriptor) == 0 else {
            let code = errno
            if code == EACCES || code == EPERM { throw InstallResult.blockedByMacOS }
            throw posixError(code)
        }
        // The kernel has no compare-inode-and-exchange operation. If another writer
        // won the final race, restore its entry and never hand that bundle to the watchdog.
        if !sameEntry(incoming, "Cala.app", original) {
            guard sameEntry(parent, "Cala.app", readyInfo),
                  renameatx_np(incoming.fileDescriptor, "Cala.app", parent.fileDescriptor, "Cala.app", UInt32(RENAME_SWAP)) == 0
            else {
                committed = true // Preserve both entries for recovery.
                log("update: concurrent rename during exchange; retained stage " + name)
                throw InstallResult.busy
            }
            throw InstallResult.busy
        }
        committed = true
        backupIdentity = original
        #if CALA_UPDATE_TEST
        if faults == .afterSwap { _exit(86) }
        #endif
        for directory in [incoming, stage, parent] where fsync(directory.fileDescriptor) != 0 {
            log("update: post-swap directory sync \(errno)")
        }
        discardDownload()
        return .installed(previous: backupURL)
    }

    fileprivate static func plist(_ bundle: FileHandle) throws -> [String: Any] {
        let file = try descriptor(openat(bundle.fileDescriptor, "Contents/Info.plist", O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW_ANY))
        let info = try status(file)
        guard info.st_mode & S_IFMT == S_IFREG, info.st_size <= 1024 * 1024,
              let bytes = try file.read(upToCount: 1024 * 1024),
              let plist = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any]
        else { throw InstallResult.verificationFailed("Info.plist") }
        return plist
    }

    private func verify(_ m: UpdateManifest, staged: FileHandle, at url: URL, installed: FileHandle, at oldURL: URL) throws {
        let info = try Self.plist(staged)
        guard info["CFBundleIdentifier"] as? String == m.bundleId, info["CFBundleExecutable"] as? String == "Cala",
              info["CFBundleVersion"] as? String == String(m.build), info["CFBundleShortVersionString"] as? String == m.version,
              let minimum = info["LSMinimumSystemVersion"] as? String,
              AppVersion.supports(minimum: minimum, os: ProcessInfo.processInfo.operatingSystemVersion)
        else { throw InstallResult.verificationFailed("staged Info.plist") }
        #if arch(arm64)
        let cpu = CPU_TYPE_ARM64
        #else
        var translated: Int32 = 0
        var length = MemoryLayout.size(ofValue: translated)
        let rosetta = sysctlbyname("sysctl.proc_translated", &translated, &length, nil, 0) == 0 && translated == 1
        let cpu = rosetta ? CPU_TYPE_ARM64 : CPU_TYPE_X86_64
        #endif
        guard tools.architectures(url)?.contains(NSNumber(value: cpu)) == true else { throw InstallResult.verificationFailed("architecture") }
        let old = try tools.identity(oldURL), new = try tools.identity(url)
        guard new.identifier == m.bundleId, old.identifier == new.identifier, old.requirement == new.requirement,
              old.team == new.team else { throw InstallResult.verificationFailed("designated requirement") }
        let helper = "Contents/Helpers/cala-keychain"
        if let team = old.team {
            let identity = try tools.identity(url.appendingPathComponent(helper))
            guard identity.team == team, identity.identifier == "local.cala.keychain" else { throw InstallResult.verificationFailed("helper identity") }
        } else {
            for bundle in [installed, staged] {
                let fd = try descriptor(openat(bundle.fileDescriptor, helper, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW_ANY))
                guard try status(fd).st_mode & S_IFMT == S_IFREG,
                      try UpdateSignature.hash(fd, limit: Int64.max).1 == m.app.keychainHelperSHA256.lowercased()
                else { throw InstallResult.verificationFailed("helper SHA-256") }
            }
        }
    }

    private static func visit(_ url: URL, action: (URL, stat) throws -> Void) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw posixError() }
        let directory = info.st_mode & S_IFMT == S_IFDIR
        guard directory || (info.st_mode & S_IFMT == S_IFREG && info.st_nlink == 1) else {
            throw InstallResult.verificationFailed("bundle link or special file")
        }
        if directory {
            for name in try FileManager.default.contentsOfDirectory(atPath: url.path) {
                try visit(url.appendingPathComponent(name), action: action)
            }
        }
        try action(url, info)
    }

    static func normalizedMode(_ mode: mode_t, executable: Bool, group: gid_t, admin: gid_t?) -> mode_t {
        (mode & 0o005) | (executable ? 0o750 : 0o640) | (group == admin ? 0o020 : 0)
    }

    private static func normalize(_ url: URL) throws {
        let adminGroup = getgrnam("admin")?.pointee.gr_gid
        var admin: gid_t?
        if let group = getgrnam("admin") {
            let gid = group.pointee.gr_gid
            let count = getgroups(0, nil)
            guard count >= 0 else { throw posixError() }
            var groups = [gid_t](repeating: 0, count: Int(count))
            guard getgroups(count, &groups) >= 0 else { throw posixError() }
            if getegid() == gid || groups.contains(gid) { admin = gid }
        }
        try visit(url) { item, info in
            if removexattr(item.path, "com.apple.quarantine", XATTR_NOFOLLOW) != 0 && errno != ENOATTR { throw posixError() }
            if let admin, chown(item.path, uid_t.max, admin) != 0 { throw posixError() }
            let executable = info.st_mode & S_IFMT == S_IFDIR || info.st_mode & 0o111 != 0
            let mode = normalizedMode(info.st_mode, executable: executable, group: admin ?? info.st_gid, admin: adminGroup)
            guard chmod(item.path, mode) == 0 else { throw posixError() }
        }
    }
}

private extension UpdateInstaller {
    func openCache(for m: UpdateManifest, create: Bool) throws -> FileHandle {
        try DownloadFile.directory(tools.cacheDirectory, m, create: create)
    }

    func download(_ m: UpdateManifest, from url: URL) throws -> URL {
        guard m.dmg.url == url else { throw InstallResult.verificationFailed("download URL") }
        let cache = try openCache(for: m, create: true)
        defer { withExtendedLifetime(cache) {} }
        let file = try volumeURL(status(cache)).appendingPathComponent(UUID().uuidString + ".dmg")
        let delegate = ImageDownload(destination: file, size: m.dmg.size)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let config = tools.downloadConfiguration(version)
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 300
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task: URLSessionDownloadTask
        if let resume, resume.url == url { task = session.downloadTask(withResumeData: resume.data) }
        else { task = session.downloadTask(with: url) }
        resume = nil
        task.resume()
        delegate.done.wait()
        if let data = delegate.resumeData { resume = (url, data) }
        return try delegate.result.get()
    }
}

// Delegate callbacks are serialized by URLSession. The installer reads the result
// only after the terminal callback signals its background queue.
private final class ImageDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let destination: URL
    let size: Int64
    let done = DispatchSemaphore(value: 0)
    var result: Result<URL, Error> = .failure(InstallResult.failed("download"))
    var resumeData: Data?

    init(destination: URL, size: Int64) {
        self.destination = destination
        self.size = size
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map { UpdateFeed.permitsRedirect($0, testURLs: true) } == true ? request : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > size || totalBytesExpectedToWrite > size {
            result = .failure(InstallResult.verificationFailed("size"))
            downloadTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        result = Result {
            guard let response = downloadTask.response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
                  let url = response.url, UpdateFeed.permitsRedirect(url, testURLs: true) else { throw InstallResult.failed("HTTP") }
            try FileManager.default.moveItem(at: location, to: destination)
            return destination
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error as NSError?, error.code != NSURLErrorCancelled {
            resumeData = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            result = .failure(error)
        }
        done.signal()
    }
}

// This journal is shared with the standalone watcher. Mutations and recovery
// use the permanent Applications lock, except for the transaction-specific health receipt.
struct UpdateJournal: Codable, Equatable {
    let from: String
    let to: String
    let previous: String
    let transaction: UUID? // nil for an update started by the original watcher
    var executableID: String? = nil
    var backupID: String? = nil

    var target: URL {
        URL(fileURLWithPath: previous).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Cala.app").resolvingSymlinksInPath()
    }

    static func fileID(_ info: stat) -> String { "\(UInt32(bitPattern: info.st_dev)):\(info.st_ino)" }

    static func executableID(in bundle: FileHandle) throws -> String {
        let file = try descriptor(openat(bundle.fileDescriptor, "Contents/MacOS/Cala", O_RDONLY | O_NONBLOCK | O_NOFOLLOW_ANY | O_CLOEXEC))
        let info = try status(file)
        guard info.st_mode & S_IFMT == S_IFREG else { throw InstallResult.failed("invalid executable") }
        return fileID(info)
    }

    // The vnode mapped at this executable's Mach header survives a rename or exchange.
    static func runningExecutableID() -> String? {
        var region = proc_regionwithpathinfo()
        let size = Int32(MemoryLayout.size(ofValue: region))
        let address = UInt64(UInt(bitPattern: #dsohandle))
        guard proc_pidinfo(getpid(), PROC_PIDREGIONPATHINFO, address, &region, size) == size else { return nil }
        let info = region.prp_vip.vip_vi.vi_stat
        return "\(info.vst_dev):\(info.vst_ino)"
    }

    static let blockPrefix = ".cala-blocked-"
    static func sharedBlocksUnderLock(target: URL) throws -> Set<String> {
        let names = try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path)
        return Set(names.filter { $0.hasPrefix(blockPrefix) }.map { String($0.dropFirst(blockPrefix.count)) })
    }

    static func sharedBlocks(target: URL) throws -> Set<String> {
        let path = target.deletingLastPathComponent().appendingPathComponent(".cala-update.lock")
        let fd = open(path.path, readFlags)
        if fd < 0 && errno == ENOENT { return [] } // No installer has prepared a transaction yet.
        let lock = try descriptor(fd)
        return try withExtendedLifetime(lock) {
            guard flock(fd, LOCK_SH | LOCK_NB) == 0 else { throw InstallResult.busy }
            return try sharedBlocksUnderLock(target: target)
        }
    }

    var marker: String { "update-up-" + (transaction?.uuidString ?? to) }

    static func read(in support: URL) throws -> Self? {
        do { return try JSONDecoder().decode(Self.self, from: Data(contentsOf: support.appendingPathComponent("update-pending.json"))) }
        catch let e as CocoaError where e.code == .fileReadNoSuchFile { return nil }
    }

    func write(in support: URL) throws {
        let file = support.appendingPathComponent("update-pending.json")
        try JSONEncoder().encode(self).write(to: file, options: .atomic)
        let journal = try descriptor(open(file.path, readFlags))
        let dir = try descriptor(open(support.path, directoryFlags))
        guard fsync(journal.fileDescriptor) == 0, fsync(dir.fileDescriptor) == 0 else { throw posixError() }
    }

    static func remove(_ name: String, in dir: URL) throws {
        if unlink(dir.appendingPathComponent(name).path) != 0 && errno != ENOENT { throw posixError() }
    }

    func stage(for target: URL) throws -> URL {
        let backup = URL(fileURLWithPath: previous).standardizedFileURL
        let stage = backup.deletingLastPathComponent().deletingLastPathComponent()
        guard backup.lastPathComponent == "Cala.app", stage.lastPathComponent.hasPrefix(".cala-update."),
              stage.deletingLastPathComponent().path == target.deletingLastPathComponent().standardizedFileURL.path,
              backup.deletingLastPathComponent().lastPathComponent == "previous" ||
                (transaction == nil && backup.deletingLastPathComponent().lastPathComponent == "new")
        else { throw InstallResult.failed("invalid backup path") }
        return stage
    }

    func cleanStage(for target: URL, expectedStage: stat? = nil) throws {
        let stage = try stage(for: target)
        let parent = try descriptor(open(target.deletingLastPathComponent().path, directoryFlags))
        let fd = openat(parent.fileDescriptor, stage.lastPathComponent, directoryFlags)
        if fd < 0 && errno == ENOENT { return }
        let dir = try descriptor(fd)
        let info = try status(dir)
        guard expectedStage.map({ $0.st_dev == info.st_dev && $0.st_ino == info.st_ino }) ?? true,
              info.st_uid == geteuid(), info.st_mode & 0o777 == 0o700 else { throw InstallResult.busy }
        let root = try volumeURL(info)
        for child in try FileManager.default.contentsOfDirectory(atPath: root.path) {
            try FileManager.default.removeItem(at: root.appendingPathComponent(child))
        }
        guard sameEntry(parent, stage.lastPathComponent, info),
              unlinkat(parent.fileDescriptor, stage.lastPathComponent, AT_REMOVEDIR) == 0 else { throw InstallResult.busy }
    }

    static func identity(at app: URL) throws -> String {
        let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let v = info["CFBundleShortVersionString"] as? String, let b = info["CFBundleVersion"] as? String,
              AppVersion(version: v, build: b) != nil else { throw InstallResult.failed("invalid Info.plist") }
        return v + "+" + b
    }

    enum DiskState { case original, incoming, superseded }
    func diskState(at url: URL) throws -> DiskState {
        let bundle = try descriptor(open(url.path, directoryFlags))
        let info = try status(bundle)
        let build = try Self.identity(at: volumeURL(info))
        if build == from, backupID.map({ $0 == Self.fileID(info) }) ?? true { return .original }
        if build == to, let executableID {
            return try Self.executableID(in: bundle) == executableID ? .incoming : .superseded
        }
        return build == to ? .incoming : .superseded
    }

    // Called under flock. Even if the volume filled up during rollback, the
    // original pending record survives until the failed identity is durable.
    static func reconcileRestored(in support: URL, target: URL) throws {
        guard let pending = try read(in: support) else {
            // Older clients could unlink pending before clearing the watchdog sentinel.
            try remove("update-rollback", in: support)
            return
        }
        _ = try pending.stage(for: target)
        let disk = try pending.diskState(at: target)
        if disk == .incoming { return }
        if disk == .superseded {
            try pending.closeSuperseded(in: support, target: target)
            return
        }
        let parts = pending.to.components(separatedBy: "+")
        guard parts.count == 2, AppVersion(version: parts[0], build: parts[1]) != nil else {
            throw InstallResult.failed("invalid blocked build")
        }
        let parent = try descriptor(open(target.deletingLastPathComponent().path, directoryFlags))
        let name = blockPrefix + pending.to
        let shared = openat(parent.fileDescriptor, name, readFlags | O_CREAT | O_EXCL, 0o644)
        if shared >= 0 { close(shared) }
        else if errno != EEXIST { throw posixError() }
        var entry = stat()
        guard fstatat(parent.fileDescriptor, name, &entry, AT_SYMLINK_NOFOLLOW) == 0,
              entry.st_mode & S_IFMT == S_IFREG, fsync(parent.fileDescriptor) == 0 else { throw posixError() }
        let file = support.appendingPathComponent("update-blocked.json")
        var blocked: Set<String>
        do { blocked = try JSONDecoder().decode(Set<String>.self, from: Data(contentsOf: file)) }
        catch let e as CocoaError where e.code == .fileReadNoSuchFile { blocked = [] }
        if blocked.insert(pending.to).inserted {
            try JSONEncoder().encode(blocked.sorted()).write(to: file, options: .atomic)
        }
        let fd = try descriptor(open(file.path, readFlags))
        guard fsync(fd.fileDescriptor) == 0 else { throw posixError() }
        let dir = try descriptor(open(support.path, directoryFlags))
        guard fsync(dir.fileDescriptor) == 0 else { throw posixError() }
        do { try pending.cleanStage(for: target) }
        catch { log("update: restored bundle stage cleanup: \(error)") }
        try remove("update-rollback", in: support)
        try remove(pending.marker, in: support)
        try remove("update-pending.json", in: support)
    }

    private func closeSuperseded(in support: URL, target: URL) throws {
        let parent = try descriptor(open(target.deletingLastPathComponent().path, directoryFlags))
        let installed = try descriptor(openat(parent.fileDescriptor, "Cala.app", directoryFlags))
        let original = try status(installed)
        let current = try InstallerTools.system.identity(target)
        let plist = try UpdateInstaller.plist(installed)
        guard current.identifier == "local.cala", plist["CFBundleIdentifier"] as? String == current.identifier,
              plist["CFBundleExecutable"] as? String == "Cala", sameEntry(parent, "Cala.app", original) else { throw InstallResult.busy }
        // Cleanup may already have finished before a crash. If the stage still exists,
        // authenticate its backup before removing anything.
        let stage = try stage(for: target)
        var exists = stat()
        if lstat(stage.path, &exists) == 0 {
            guard exists.st_mode & S_IFMT == S_IFDIR, exists.st_uid == geteuid(),
                  exists.st_mode & 0o777 == 0o700 else { throw InstallResult.busy }
            let backup = URL(fileURLWithPath: previous)
            let backupName = stage.lastPathComponent + "/" + backup.deletingLastPathComponent().lastPathComponent + "/Cala.app"
            let pinned = try descriptor(openat(parent.fileDescriptor, backupName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC))
            let backupInfo = try status(pinned)
            let old = try InstallerTools.system.identity(backup)
            guard old.identifier == current.identifier, sameEntry(parent, backupName, backupInfo),
                  try diskState(at: volumeURL(backupInfo)) != .superseded,
                  sameEntry(parent, "Cala.app", original) else { throw InstallResult.busy }
        } else if errno != ENOENT { throw posixError() }
        try Self.remove(marker, in: support)
        try Self.remove("update-rollback", in: support)
        try Self.remove("update-pending.json", in: support)
        // A crash during disposal can leave an orphan stage, but cannot strand the journal.
        if exists.st_ino != 0 { try cleanStage(for: target, expectedStage: exists) }
    }

    // Publish a complete verdict with an exclusive hard link. A suspended receipt
    // writer cannot hold up rollback. A late writer cannot replace its decision.
    func record(_ outcome: String, in support: URL, runningBundle: URL, runningID: String?) throws {
        guard let runningID, runningBundle.resolvingSymlinksInPath().path == target.path else { return }
        _ = try stage(for: target)
        guard try Self.read(in: support) == self, try Self.identity(at: target) == to,
              !FileManager.default.fileExists(atPath: support.appendingPathComponent("update-rollback").path)
        else { return }
        let bundle = try descriptor(open(target.path, directoryFlags))
        let diskID = try Self.executableID(in: bundle)
        guard diskID == runningID, executableID.map({ $0 == diskID }) ?? true else { return }
        let temp = support.appendingPathComponent("update-receipt-" + UUID().uuidString)
        try Data((outcome + " " + diskID).utf8).write(to: temp, options: .withoutOverwriting)
        defer { unlink(temp.path) }
        if link(temp.path, support.appendingPathComponent(marker).path) != 0, errno != EEXIST { throw posixError() }
    }

    func acceptsReceipt(in support: URL) throws -> Bool {
        let bundle = try descriptor(open(target.path, directoryFlags))
        let diskID = try Self.executableID(in: bundle)
        guard executableID.map({ $0 == diskID }) ?? true,
              let data = try? Data(contentsOf: support.appendingPathComponent(marker)) else { return false }
        let body = String(decoding: data, as: UTF8.self)
        return body == "healthy " + diskID || body == "quit " + diskID
    }

    func scheduleHealth(in support: URL, runningBundle: URL, delay: TimeInterval, work: DispatchQueue,
                        runningID: @escaping () -> String? = UpdateJournal.runningExecutableID,
                        completion: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            work.async {
                do { try self.record("healthy", in: support, runningBundle: runningBundle, runningID: runningID()) }
                catch { log("update: launch receipt failed: \(error)") }
                completion()
            }
        }
    }
}

enum UpdateWatch {
    static func start(helper: URL, lock: FileHandle, support: URL, target: URL) throws -> Process {
        // Both the original verified snapshot and a rearmed copy are private.
        // Verify the named executable still identifies the descriptor before exec.
        let snapshot = helper.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bundle = try descriptor(open(snapshot.path, directoryFlags))
        let executable = try descriptor(openat(bundle.fileDescriptor, "Contents/Helpers/cala-update",
                                               O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY))
        guard try status(executable).st_mode & S_IFMT == S_IFREG,
              try InstallerTools.system.identity(helper).identifier == "local.cala.update" else {
            throw InstallResult.verificationFailed("rollback helper")
        }
        let pipe = Pipe()
        let p = Process()
        p.executableURL = helper
        p.standardInput = lock
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.arguments = ["arm", "--pending", support.appendingPathComponent("update-pending.json").path,
                       "--pid", String(getpid()), "--target", target.path]
        guard sameEntry(bundle, "Contents/Helpers/cala-update", try status(executable)) else { throw InstallResult.busy }
        try p.run()
        let fd = pipe.fileHandleForReading.fileDescriptor
        var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        var byte: UInt8 = 0
        guard poll(&pollFD, 1, 15000) > 0, read(fd, &byte, 1) == 1, byte == 1, p.isRunning else {
            if p.isRunning { p.terminate() }
            throw InstallResult.failed("rollback helper did not acknowledge")
        }
        return p
    }
}

// Keep the private cache directory and the exact destination inode open for
// the lifetime of the URLSession transfer, including cancellation and cleanup.
final class DownloadFile {
    let directory: FileHandle
    let file: FileHandle
    let savedURL: URL
    let pinnedURL: URL
    let cached: Bool

    fileprivate static func directory(_ base: URL, _ m: UpdateManifest, create: Bool) throws -> FileHandle {
        var dir = try descriptor(open(base.path, directoryFlags))
        for component in ["local.cala", "Updates", "\(m.version)-\(m.build)"] {
            if create, mkdirat(dir.fileDescriptor, component, 0o700) != 0, errno != EEXIST { throw posixError() }
            dir = try descriptor(openat(dir.fileDescriptor, component, directoryFlags))
            guard try status(dir).st_uid == geteuid(), fchmod(dir.fileDescriptor, 0o700) == 0 else { throw posixError(EACCES) }
        }
        return dir
    }

    init(base: URL, manifest: UpdateManifest, saved: URL?) throws {
        directory = try Self.directory(base, manifest, create: true)
        let path = base.appendingPathComponent("local.cala/Updates/\(manifest.version)-\(manifest.build)")
        var existing: FileHandle?
        if let saved, saved.deletingLastPathComponent().standardizedFileURL.path == path.standardizedFileURL.path,
           saved.pathExtension == "dmg" {
            let fd = openat(directory.fileDescriptor, saved.lastPathComponent, readFlags)
            if fd >= 0 {
                let handle = try descriptor(fd)
                let info = try status(handle)
                if info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_nlink == 1,
                   info.st_size == manifest.dmg.size { existing = handle }
            }
        }
        cached = existing != nil
        if let existing, let saved {
            savedURL = saved
            file = existing
        } else {
            savedURL = path.appendingPathComponent(UUID().uuidString + ".dmg")
            file = try descriptor(openat(directory.fileDescriptor, savedURL.lastPathComponent,
                                         O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600))
        }
        pinnedURL = try volumeURL(status(directory)).appendingPathComponent(savedURL.lastPathComponent)
    }

    func receive(_ temporary: URL, size: Int64) throws {
        let source = try descriptor(open(temporary.path, readFlags))
        guard try status(source).st_size == size else { throw InstallResult.verificationFailed("download size") }
        _ = try UpdateSignature.hash(source, limit: size, copyingTo: file)
    }

    func discard() {
        if let info = try? status(file), sameEntry(directory, savedURL.lastPathComponent, info) {
            unlinkat(directory.fileDescriptor, savedURL.lastPathComponent, 0)
        }
    }
}

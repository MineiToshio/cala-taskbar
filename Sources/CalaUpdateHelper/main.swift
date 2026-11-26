import Darwin
import Foundation
import Security

private struct Failure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

private struct Pending: Decodable {
    let from: String
    let to: String
    let previous: String
    let transaction: UUID?
}

private struct Watch {
    let pendingURL: URL
    let support: URL
    let target: URL
    let previous: URL
    let stage: URL
    let oldPID: pid_t
    let arm: Bool
    let pending: Pending

    init(_ args: [String]) throws {
        guard args.count == 7, ["arm", "watch"].contains(args[0]), args[1] == "--pending", args[3] == "--pid",
              let pid = pid_t(args[4]), pid > 1, args[5] == "--target",
              args[2].hasPrefix("/"), args[6].hasPrefix("/") else {
            throw Failure("Usage: cala-update watch --pending FILE --pid PID --target APP")
        }
        arm = args[0] == "arm"
        pendingURL = URL(fileURLWithPath: args[2]).standardizedFileURL
        support = pendingURL.deletingLastPathComponent()
        target = URL(fileURLWithPath: args[6]).standardizedFileURL
        oldPID = pid
        let decoder = JSONDecoder()
        pending = try decoder.decode(Pending.self, from: Data(contentsOf: pendingURL))
        previous = URL(fileURLWithPath: pending.previous).standardizedFileURL
        let previousDirectory = previous.deletingLastPathComponent()
        stage = previousDirectory.deletingLastPathComponent()
        let version = #"^[0-9]+(\.[0-9]+){0,2}\+[0-9]+$"#
        guard pendingURL.lastPathComponent == "update-pending.json", pending.previous.hasPrefix("/"),
              target.lastPathComponent == "Cala.app", previous.lastPathComponent == "Cala.app",
              previousDirectory.lastPathComponent == "previous",
              stage.lastPathComponent.hasPrefix(".cala-update."),
              stage.deletingLastPathComponent().path == target.deletingLastPathComponent().path,
              pending.from.range(of: version, options: .regularExpression) != nil,
              pending.to.range(of: version, options: .regularExpression) != nil else {
            throw Failure("Unexpected update paths or versions")
        }
    }

    func run() throws {
        var prepared = false
        defer {
            if !arm && !prepared && wait(seconds: 120, until: { kill(oldPID, 0) != 0 && errno == ESRCH }) {
                try? reopen()
            }
        }
        let parent = target.deletingLastPathComponent()
        let parentFD = try descriptor(open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC), "open app parent")
        defer { close(parentFD) }
        let lock = try descriptor(arm ? dup(STDIN_FILENO) :
            openat(parentFD, ".cala-update.lock", O_CREAT | O_RDONLY | O_NOFOLLOW | O_CLOEXEC, 0o664), "open update lock")
        defer { close(lock) }
        var held = stat(), named = stat()
        guard fstat(lock, &held) == 0, held.st_mode & S_IFMT == S_IFREG,
              fstatat(parentFD, ".cala-update.lock", &named, AT_SYMLINK_NOFOLLOW) == 0,
              held.st_dev == named.st_dev, held.st_ino == named.st_ino,
              flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw Failure("Missing update lock") }
        let stageFD = try descriptor(openat(parentFD, stage.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC),
                                     "open update stage")
        defer { close(stageFD) }
        var stageInfo = stat()
        guard fstat(stageFD, &stageInfo) == 0, stageInfo.st_uid == getuid(), stageInfo.st_mode & 0o777 == 0o700 else {
            throw Failure("Update stage is not private")
        }
        let previousFD = try descriptor(openat(stageFD, "previous", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC),
                                        "open previous app directory")
        defer { close(previousFD) }
        let oldDir: Int32, newDir: Int32
        if try bundleBuild(infoPlist(target)) == pending.from {
            guard arm else { throw Failure("Unexpected installed version") }
            oldDir = parentFD
            newDir = previousFD
        } else {
            oldDir = previousFD
            newDir = parentFD
        }
        // Pin both bundle identities from preparation until rollback.
        let old = try descriptor(openat(oldDir, "Cala.app", O_RDONLY | O_DIRECTORY | O_NOFOLLOW), "open backup")
        defer { close(old) }
        let new = try descriptor(openat(newDir, "Cala.app", O_RDONLY | O_DIRECTORY | O_NOFOLLOW), "open incoming")
        defer { close(new) }
        func pinned(_ fd: Int32) throws -> URL {
            var s = stat()
            guard fstat(fd, &s) == 0 else { throw posixFailure("stat pinned directory") }
            return URL(fileURLWithPath: "/.vol/\(UInt32(bitPattern: s.st_dev))/\(s.st_ino)", isDirectory: true)
        }
        func matchesEntry(_ fd: Int32, in directory: Int32) -> Bool {
            var s = stat()
            guard fstat(fd, &s) == 0, let named = try? bundleStat(directory) else { return false }
            return s.st_dev == named.st_dev && s.st_ino == named.st_ino
        }
        let oldURL = try pinned(old)
        let oldInfo = try infoPlist(oldURL)
        let newInfo = try infoPlist(pinned(new))
        guard bundleBuild(oldInfo) == pending.from, bundleBuild(newInfo) == pending.to,
              let id = oldInfo["CFBundleIdentifier"] as? String, id == newInfo["CFBundleIdentifier"] as? String else {
            throw Failure("Unexpected installed or rollback bundle")
        }
        func validateOld(in directory: Int32) throws {
            guard matchesEntry(old, in: directory) else { throw Failure("Rollback inode changed") }
            // Security canonicalizes paths and cannot verify Darwin volume-ID
            // URLs. Resolve the still-open bundle, then compare both identities.
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard fcntl(old, F_GETPATH, &path) == 0 else { throw posixFailure("resolve rollback bundle") }
            let app = URL(fileURLWithPath: String(cString: path))
            try validateSignature(app)
            var verified = stat(), expected = stat()
            guard lstat(app.path, &verified) == 0, fstat(old, &expected) == 0,
                  verified.st_dev == expected.st_dev, verified.st_ino == expected.st_ino else {
                throw Failure("Validated rollback bundle changed")
            }
            guard matchesEntry(old, in: directory) else { throw Failure("Rollback inode changed") }
        }
        try validateOld(in: oldDir)
        let blockedURL = support.appendingPathComponent("update-blocked.json")
        var blocks: Set<String>
        do { blocks = try JSONDecoder().decode(Set<String>.self, from: Data(contentsOf: blockedURL)) }
        catch let e as CocoaError where e.code == .fileReadNoSuchFile { blocks = [] }
        guard blocks.insert(pending.to).inserted else { throw Failure("Build already blocked") }
        let reserve = support.appendingPathComponent("update-block-reserve")
        try JSONEncoder().encode(blocks.sorted()).write(to: reserve, options: .atomic)
        defer { unlink(reserve.path) }
        let saved = try descriptor(open(reserve.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC), "open reserved block list")
        defer { close(saved) }
        guard fsync(saved) == 0 else { throw posixFailure("sync reserved block list") }
        let supportFD = try descriptor(open(support.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC), "open support")
        defer { close(supportFD) }
        let token = pending.transaction?.uuidString ?? pending.to
        let marker = support.appendingPathComponent("update-up-" + token)
        let rollback = support.appendingPathComponent("update-rollback")
        let sentinelReserve = support.appendingPathComponent("update-rollback-reserve")
        try Data(String(getpid()).utf8).write(to: sentinelReserve, options: .atomic)
        defer { unlink(sentinelReserve.path) }
        let stageRoot = try pinned(stageFD)
        func clean() throws {
            for child in try FileManager.default.contentsOfDirectory(atPath: stageRoot.path) {
                try FileManager.default.removeItem(at: stageRoot.appendingPathComponent(child))
            }
            var entry = stat()
            if fstatat(parentFD, stage.lastPathComponent, &entry, AT_SYMLINK_NOFOLLOW) == 0,
               entry.st_dev == stageInfo.st_dev, entry.st_ino == stageInfo.st_ino {
                guard unlinkat(parentFD, stage.lastPathComponent, AT_REMOVEDIR) == 0 else { throw posixFailure("remove stage") }
            }
        }
        if arm {
            var byte: UInt8 = 1
            guard write(STDOUT_FILENO, &byte, 1) == 1 else { throw Failure("Could not confirm helper ready") }
        }
        prepared = true
        while kill(oldPID, 0) == 0 || errno == EPERM {
            if !FileManager.default.fileExists(atPath: pendingURL.path) { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard matchesEntry(new, in: parentFD), matchesEntry(old, in: previousFD) else {
            try reopen()
            return
        }
        let launched = launch()
        if launched && wait(seconds: upTimeout(oldInfo), until: { FileManager.default.fileExists(atPath: marker.path) }) {
            try clean()
            try FileManager.default.removeItem(at: pendingURL)
            unlink(marker.path)
            return
        }

        // All allocation for the block list happened before the handoff. The
        // pending record also fails closed if even this rename cannot be saved.
        let recorded = rename(reserve.path, blockedURL.path) == 0 && fsync(supportFD) == 0
        do {
            guard matchesEntry(new, in: parentFD), matchesEntry(old, in: previousFD),
                  access(try pinned(previousFD).path, W_OK | X_OK) == 0, access(parent.path, W_OK | X_OK) == 0
            else { throw Failure("Rollback directories changed or became unwritable") }
            try validateOld(in: previousFD)
            // A full volume may prevent a new sentinel. Restore under the lock
            // anyway when the failed build is already gone.
            if rename(sentinelReserve.path, rollback.path) != 0 {
                let failure = posixFailure("publish rollback sentinel")
                guard try matchingProcesses(target.appendingPathComponent("Contents/MacOS/Cala").path).isEmpty else { throw failure }
            }
            try stopTarget()
            #if CALA_UPDATE_TEST
            if ProcessInfo.processInfo.environment["CALA_UPDATE_TEST_RESTORE_ERROR"] == "1" {
                throw Failure("Injected restore failure")
            }
            #endif
            guard matchesEntry(new, in: parentFD), matchesEntry(old, in: previousFD),
                  renameatx_np(previousFD, "Cala.app", parentFD, "Cala.app", UInt32(RENAME_SWAP)) == 0
            else { throw posixFailure("restore previous Cala") }
        } catch {
            unlink(rollback.path)
            try reopen()
            throw error
        }
        log("rolled back \(pending.to) to \(pending.from)", in: support)
        try reopen()
        if recorded {
            try clean()
            if unlink(rollback.path) != 0 && errno != ENOENT { throw posixFailure("remove rollback marker") }
            try FileManager.default.removeItem(at: pendingURL)
        }
    }

    private func upTimeout(_ info: [String: Any]) -> TimeInterval {
        #if CALA_UPDATE_TEST
        if info["CalaUpdateTest"] as? Bool == true,
           let seconds = info["CalaUpdateTestUpTimeout"] as? Double, seconds.isFinite, seconds > 0 { return seconds }
        #endif
        return 120
    }

    private func reopen() throws {
        if launch() { return }
        // LaunchServices may itself be unresponsive. Only start the validated
        // installed executable directly if the session has no such process.
        let executable = target.appendingPathComponent("Contents/MacOS/Cala")
        do {
            try validateSignature(target)
            guard try matchingProcesses(executable.path).isEmpty else { return }
            #if CALA_UPDATE_TEST
            if ProcessInfo.processInfo.environment["CALA_UPDATE_TEST_OPEN"] != nil { throw Failure("Test opener failed") }
            #endif
            let app = Process()
            app.executableURL = executable
            app.standardInput = FileHandle.nullDevice
            app.standardOutput = FileHandle.nullDevice
            app.standardError = FileHandle.nullDevice
            try app.run()
        } catch { throw Failure("Could not reopen Cala: \(error)") }
    }

    private func launch() -> Bool {
        let process = Process()
        var executable = "/usr/bin/open"
        #if CALA_UPDATE_TEST
        if let fake = ProcessInfo.processInfo.environment["CALA_UPDATE_TEST_OPEN"], fake.hasPrefix("/") {
            executable = fake
        }
        #endif
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-g", target.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            var limit = 10.0
            #if CALA_UPDATE_TEST
            if ProcessInfo.processInfo.environment["CALA_UPDATE_TEST_OPEN"] != nil { limit = 1 }
            #endif
            guard wait(seconds: limit, until: { !process.isRunning }) else {
                if process.isRunning { process.terminate() }
                return false
            }
            return process.terminationStatus == 0
        } catch {
            log("could not open Cala: \(error.localizedDescription)", in: support)
            return false
        }
    }

    private func bundleStat(_ parentFD: Int32) throws -> stat {
        var info = stat()
        guard fstatat(parentFD, "Cala.app", &info, AT_SYMLINK_NOFOLLOW) == 0,
              info.st_mode & S_IFMT == S_IFDIR else { throw Failure("Expected a Cala.app directory") }
        return info
    }

    private func stopTarget() throws {
        let executable = target.resolvingSymlinksInPath().appendingPathComponent("Contents/MacOS/Cala").path
        let processes = try matchingProcesses(executable)
        for pid in processes where matches(pid, executable: executable) {
            if kill(pid, SIGTERM) != 0, errno != ESRCH { throw posixFailure("terminate Cala") }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        repeat {
            if try matchingProcesses(executable).isEmpty { return }
            Thread.sleep(forTimeInterval: 0.1)
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw Failure("Cala did not quit after SIGTERM; leaving both apps in place")
    }


}

private func matchingProcesses(_ executable: String) throws -> [pid_t] {
    let count = proc_listallpids(nil, 0)
    guard count > 0 else { throw posixFailure("list running processes") }
    var pids = [pid_t](repeating: 0, count: Int(count) + 64)
    let size = Int32(pids.count * MemoryLayout<pid_t>.stride)
    let listed = proc_listallpids(&pids, size)
    guard listed > 0, listed < pids.count else { throw Failure("Could not read the process list") }
    return pids.prefix(Int(listed)).filter { matches($0, executable: executable) }
}

private func matches(_ pid: pid_t, executable: String) -> Bool {
    guard pid > 1 else { return false }
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid == getuid() else { return false }
    var path = [CChar](repeating: 0, count: 4096)
    let length = UInt32(path.count)
    return proc_pidpath(pid, &path, length) > 0 && String(cString: path) == executable
}

private func infoPlist(_ app: URL) throws -> [String: Any] {
    let file = app.appendingPathComponent("Contents/Info.plist")
    let data = try Data(contentsOf: file)
    guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
        throw Failure("Invalid Info.plist")
    }
    return info
}

private func bundleBuild(_ info: [String: Any]) -> String? {
    guard let version = info["CFBundleShortVersionString"] as? String,
          let build = info["CFBundleVersion"] as? String else { return nil }
    return "\(version)+\(build)"
}

private func validateSignature(_ previous: URL) throws {
    var code: SecStaticCode?
    let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
    guard SecStaticCodeCreateWithPath(previous as CFURL, [], &code) == errSecSuccess, let code,
          SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess else {
        throw Failure("Previous app signature is invalid")
    }
}

private func posixFailure(_ operation: String) -> Failure {
    Failure("\(operation): \(String(cString: strerror(errno)))")
}

private func descriptor(_ fd: Int32, _ operation: String) throws -> Int32 {
    guard fd >= 0 else { throw posixFailure(operation) }
    return fd
}

private func wait(seconds: TimeInterval, until condition: () -> Bool) -> Bool {
    let deadline = ProcessInfo.processInfo.systemUptime + seconds
    while !condition() {
        if ProcessInfo.processInfo.systemUptime >= deadline { return false }
        Thread.sleep(forTimeInterval: 0.1)
    }
    return true
}

private func log(_ message: String, in directory: URL? = nil) {
    let line = "cala-update: \(message)\n"
    fputs(line, stderr)
    guard let directory else { return }
    let path = directory.appendingPathComponent("debug.log").path
    let fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
    if fd >= 0 {
        defer { close(fd) }
        let data = Data(line.utf8)
        _ = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    }
}

private func main() throws {
    let watch = try Watch(Array(CommandLine.arguments.dropFirst()))
    do { try watch.run() }
    catch {
        log(error.localizedDescription, in: watch.support)
        exit(1)
    }
}

do { try main() }
catch {
    log(error.localizedDescription)
    exit(1)
}

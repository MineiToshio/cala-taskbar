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
    let deadline: Date
}

private struct Watch {
    let pendingURL: URL
    let support: URL
    let target: URL
    let previous: URL
    let stage: URL
    let oldPID: pid_t
    let pending: Pending

    init(_ args: [String]) throws {
        guard args.count == 7, args[0] == "watch", args[1] == "--pending", args[3] == "--pid",
              let pid = pid_t(args[4]), pid > 1, args[5] == "--target",
              args[2].hasPrefix("/"), args[6].hasPrefix("/") else {
            throw Failure("Usage: cala-update watch --pending FILE --pid PID --target APP")
        }
        pendingURL = URL(fileURLWithPath: args[2]).standardizedFileURL
        support = pendingURL.deletingLastPathComponent()
        target = URL(fileURLWithPath: args[6]).standardizedFileURL
        oldPID = pid
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { value in
            let text = try value.singleValueContainer().decode(String.self)
            let iso = ISO8601DateFormatter()
            if let date = iso.date(from: text) { return date }
            iso.formatOptions.insert(.withFractionalSeconds)
            guard let date = iso.date(from: text) else { throw Failure("Invalid update deadline") }
            return date
        }
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
        let parent = target.deletingLastPathComponent()
        let parentFD = try descriptor(open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC), "open app parent")
        defer { close(parentFD) }
        let lock = try descriptor(openat(parentFD, ".cala-update.lock", O_CREAT | O_RDONLY | O_NOFOLLOW | O_CLOEXEC, 0o664),
                                  "open update lock")
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw Failure("Another update is in progress") }
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
        let before = try bundleStat(parentFD)
        let installedInfo = try infoPlist(target)
        let previousInfo = try infoPlist(previous)
        guard bundleBuild(installedInfo) == pending.to, bundleBuild(previousInfo) == pending.from else {
            throw Failure("Installed or previous app is no longer the expected build")
        }

        guard wait(seconds: 120, until: { kill(oldPID, 0) != 0 && errno == ESRCH }) else {
            throw Failure("Old Cala did not quit")
        }
        let marker = support.appendingPathComponent("update-up-\(pending.to)")
        let timeout = upTimeout(previousInfo)
        let launched = launch()
        // A failed open needs no startup grace period.
        if launched && wait(seconds: timeout, until: { FileManager.default.fileExists(atPath: marker.path) }) {
            try FileManager.default.removeItem(at: pendingURL)
            remove(stage)
            remove(marker)
            return
        }

        let rollback = support.appendingPathComponent("update-rollback")
        try Data().write(to: rollback, options: .atomic)
        defer { remove(rollback) }
        guard let bundleID = installedInfo["CFBundleIdentifier"] as? String,
              previousInfo["CFBundleIdentifier"] as? String == bundleID else {
            throw Failure("Previous app has the wrong bundle identifier")
        }
        try validateSignature(previous)
        try stopTarget()

        let after = try bundleStat(parentFD)
        guard before.st_dev == after.st_dev, before.st_ino == after.st_ino else {
            throw Failure("Installed Cala changed before rollback")
        }
        let blockedURL = support.appendingPathComponent("update-blocked.json")
        var blocked: Set<String> = []
        if FileManager.default.fileExists(atPath: blockedURL.path) {
            blocked = try JSONDecoder().decode(Set<String>.self, from: Data(contentsOf: blockedURL))
        }
        blocked.insert(pending.to)
        let blockedData = try JSONEncoder().encode(blocked.sorted())
        guard renameatx_np(previousFD, "Cala.app", parentFD, "Cala.app", UInt32(RENAME_SWAP)) == 0 else {
            throw posixFailure("restore previous Cala")
        }

        // The restored app consumes the pending record and the blocked list to report the rollback.
        do {
            try blockedData.write(to: blockedURL, options: .atomic)
        } catch {
            log("could not save blocked build: \(error.localizedDescription)", in: support)
        }
        log("rolled back \(pending.to) to \(pending.from)", in: support)
        let restored = launch()
        remove(stage)
        guard restored else { throw Failure("Cala was restored but could not reopen") }
    }

    private func upTimeout(_ info: [String: Any]) -> TimeInterval {
        #if CALA_UPDATE_TEST
        if info["CalaUpdateTest"] as? Bool == true,
           let seconds = info["CalaUpdateTestUpTimeout"] as? Double, seconds.isFinite, seconds > 0 {
            return seconds
        }
        #endif
        return max(0, min(120, pending.deadline.timeIntervalSinceNow))
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
            process.waitUntilExit()
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

    private func remove(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do { try FileManager.default.removeItem(at: url) }
        catch { log("could not remove \(url.lastPathComponent): \(error.localizedDescription)", in: support) }
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

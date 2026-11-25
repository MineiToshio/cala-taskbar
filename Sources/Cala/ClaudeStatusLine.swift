import Foundation
import Darwin

/// Tracks where Cala installed its command so cleanup can finish across tray stops and process restarts.
struct ClaudeStatusLine {
    enum Outcome: Equatable {
        case installed, alreadyInstalled, removed, folderMissing
        case existingCommand(String)
    }

    enum ReconciliationError: LocalizedError {
        case concurrentEdits

        var errorDescription: String? { "Claude settings kept changing during the update." }
    }

    let support: URL
    let legacySupport: URL
    var beforeReplace: ((URL) throws -> Void)? = nil
    private var script: URL { support.appendingPathComponent("claude-statusline.sh") }
    private var record: URL { support.appendingPathComponent("claude-statusline-directory") }

    var hasRecordedInstallation: Bool { FileManager.default.fileExists(atPath: record.path) }
    var hasInstallationEvidence: Bool {
        let fm = FileManager.default
        return hasRecordedInstallation || fm.fileExists(atPath: script.path)
            || fm.fileExists(atPath: legacySupport.appendingPathComponent(script.lastPathComponent).path)
    }

    func reconcilePreference(_ preference: Bool?, directory: String, previousDirectory: String? = nil) throws -> Outcome? {
        guard let preference else { return nil }
        return try reconcile(enabled: preference, directory: directory, previousDirectory: previousDirectory)
    }

    func reconcile(enabled: Bool, directory: String, previousDirectory: String? = nil,
                   requireReadableCandidates: Bool = false) throws -> Outcome {
        let tracked: String?
        do {
            tracked = try String(contentsOf: record, encoding: .utf8)
        } catch CocoaError.fileReadNoSuchFile {
            tracked = nil
        }
        let paths = Set([tracked, previousDirectory, enabled ? nil : directory].compactMap { $0 })
        for old in paths.sorted() where !enabled || old != directory {
            try remove(from: old, requireReadable: old == tracked || requireReadableCandidates)
        }
        if !enabled || (tracked != nil && tracked != directory) {
            do { try FileManager.default.removeItem(at: record) }
            catch CocoaError.fileNoSuchFile {}
        }
        guard enabled else { return .removed }
        return try install(in: directory)
    }

    private func quote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func owns(_ value: Any?) -> Bool {
        guard let entry = value as? [String: Any], entry["type"] as? String == "command",
              let command = entry["command"] as? String else { return false }
        let legacy = legacySupport.appendingPathComponent(script.lastPathComponent).path
        return [script.path, quote(script.path), legacy, quote(legacy)].contains(command)
    }

    private func bytes(at url: URL) throws -> Data? {
        do { return try Data(contentsOf: url) }
        catch CocoaError.fileReadNoSuchFile { return nil }
    }

    private func read(_ settings: URL) throws -> (Data?, [String: Any]) {
        guard let data = try bytes(at: settings) else { return (nil, [:]) }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return (data, object)
    }

    /// Stage the update beside the real file, then compare the bytes again just before replacing it.
    /// A changed file is read and reconciled from scratch, including a fresh ownership check.
    private func write(_ object: [String: Any], to settings: URL, replacing original: Data?) throws -> Bool {
        let fm = FileManager.default
        let temporary = settings.deletingLastPathComponent().appendingPathComponent(".cala-\(UUID())", isDirectory: true)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: temporary) }

        let staged = temporary.appendingPathComponent(settings.lastPathComponent)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: staged)
        let permissions = (try? fm.attributesOfItem(atPath: settings.path))?[.posixPermissions] ?? 0o600
        try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: staged.path)

        if let original {
            let backup = settings.appendingPathExtension("mactaskbar.bak")
            if !fm.fileExists(atPath: backup.path) {
                let stagedBackup = temporary.appendingPathComponent(backup.lastPathComponent)
                try original.write(to: stagedBackup)
                try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: stagedBackup.path)
                if renamex_np(stagedBackup.path, backup.path, UInt32(RENAME_EXCL)) != 0, errno != EEXIST {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        }

        try beforeReplace?(settings)
        guard try bytes(at: settings) == original else { return false }
        // If the file didn’t exist, a writer creating it after the comparison must still win.
        if original == nil {
            if renamex_np(staged.path, settings.path, UInt32(RENAME_EXCL)) == 0 { return true }
            if errno == EEXIST { return false }
        } else if rename(staged.path, settings.path) == 0 {
            return true
        }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private func remove(from directory: String, requireReadable: Bool) throws {
        let settings = URL(fileURLWithPath: directory).appendingPathComponent("settings.json").resolvingSymlinksInPath()
        for attempt in 0..<3 {
            let original: Data?
            var object: [String: Any]
            do { (original, object) = try read(settings) }
            catch {
                // After finding our command, inability to read a newer version must also keep the retry state.
                if requireReadable || attempt > 0 { throw error }
                return
            }
            guard owns(object["statusLine"]) else { return }
            object.removeValue(forKey: "statusLine")
            if try write(object, to: settings, replacing: original) { return }
        }
        throw ReconciliationError.concurrentEdits
    }

    private func install(in directory: String) throws -> Outcome {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else { return .folderMissing }
        let settings = URL(fileURLWithPath: directory).appendingPathComponent("settings.json").resolvingSymlinksInPath()
        let command = quote(script.path)
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        for _ in 0..<3 {
            let (original, saved) = try read(settings)
            let owned = owns(saved["statusLine"])
            if !fm.fileExists(atPath: script.path) { try writeScript() }
            if saved["statusLine"] != nil && !owned {
                return .existingCommand("printf '%s' \"$input\" | " + command + " >/dev/null # input must contain your original stdin JSON")
            }
            // Record the directory first so an interruption cannot leave an untracked installation.
            try directory.write(to: record, atomically: true, encoding: .utf8)
            if owned { return .alreadyInstalled }
            var object = saved
            object["statusLine"] = ["type": "command", "command": command]
            if try write(object, to: settings, replacing: original) { return .installed }
        }
        throw ReconciliationError.concurrentEdits
    }

    private func writeScript() throws {
        // JXA is provided by macOS.
        let body = """
        #!/bin/sh
        exec /usr/bin/osascript -l JavaScript -e '\
        ObjC.import("Foundation");
        var input = $.NSFileHandle.fileHandleWithStandardInput.readDataToEndOfFile;
        var text = ObjC.unwrap($.NSString.alloc.initWithDataEncoding(input, $.NSUTF8StringEncoding));
        try {
          var d = JSON.parse(text);
          var out = JSON.stringify({timestamp: Date.now()/1000, rate_limits: d.rate_limits || {}});
          var base = $.NSHomeDirectory().stringByAppendingPathComponent("Library/Application Support/Cala/claude-usage.json");
          var data = $(out).dataUsingEncoding($.NSUTF8StringEncoding);
          data.writeToFileAtomically(base, true);
          var name = (d.model || {}).display_name || "Claude";
          $.NSFileHandle.fileHandleWithStandardOutput.writeData($(name + "\\n").dataUsingEncoding($.NSUTF8StringEncoding));
        } catch (_) {}
        '
        """
        try Data(body.utf8).write(to: script, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    }
}

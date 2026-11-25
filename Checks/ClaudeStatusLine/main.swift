import Foundation

// ConfigStore is linked for the real Config coding implementation, but is never opened by these checks.
func log(_ message: String) {}

private var assertions = 0

private func expect(_ label: String, _ value: Bool) {
    guard value else { print("FAIL \(label)"); exit(1) }
    assertions += 1
    print("PASS \(label)")
}

private func run() throws {
    let decode = JSONDecoder()
    let malformedConfig = Data("not JSON".utf8)
    var recovered = (try? decode.decode(Config.self, from: malformedConfig)) ?? Config()
    recovered.autoHide.toggle()
    let savedRecovery = try JSONEncoder().encode(recovered)
    let invalidField = try decode.decode(Config.self, from: Data(#"{"usageClaudeStatusLine":"invalid"}"#.utf8))
    let explicitOptOut = try decode.decode(Config.self, from: Data(#"{"usageClaudeStatusLine":false}"#.utf8))
    let reopenedRecovery = try decode.decode(Config.self, from: savedRecovery)
    expect("Recovered or invalid preferences stay unknown across unrelated saves",
           reopenedRecovery.usageClaudeStatusLine == nil && invalidField.usageClaudeStatusLine == nil
           && explicitOptOut.usageClaudeStatusLine == false)

    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("cala-statusline-\(UUID())", isDirectory: true)
    defer { try? fm.removeItem(at: root) }
    let support = root.appendingPathComponent("Cala's files")
    let legacy = root.appendingPathComponent("MacTaskbar")
    let first = root.appendingPathComponent("first")
    let second = root.appendingPathComponent("second")
    for dir in [first, second] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }

    func file(_ directory: URL) -> URL { directory.appendingPathComponent("settings.json") }
    func contents(_ directory: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: file(directory))) as! [String: Any]
    }
    func coordinator() -> ClaudeStatusLine { ClaudeStatusLine(support: support, legacySupport: legacy) }

    let original = Data(#"{"theme":"dark"}"#.utf8)
    try original.write(to: file(first))
    let install = try coordinator().reconcile(enabled: true, directory: first.path)
    expect("Installs the command and records its custom directory", install == .installed)
    let record = support.appendingPathComponent("claude-statusline-directory")
    let installedDirectory = try String(contentsOf: record, encoding: .utf8)
    expect("The installation directory is persisted", installedDirectory == first.path && coordinator().hasRecordedInstallation)
    let paused = try coordinator().reconcile(enabled: false, directory: second.path)
    let cleaned = try contents(first)
    let backup = try Data(contentsOf: file(first).appendingPathExtension("mactaskbar.bak"))
    expect("Restart after disabling the tray can clean up the old directory with a new configured path",
           paused == .removed && cleaned["statusLine"] == nil && cleaned["theme"] as? String == "dark"
           && backup == original && !fm.fileExists(atPath: record.path))

    _ = try coordinator().reconcile(enabled: true, directory: first.path)
    let move = try coordinator().reconcile(enabled: true, directory: second.path)
    let previous = try contents(first)
    let current = try contents(second)
    expect("Changing config directories moves only Cala's command", move == .installed && previous["statusLine"] == nil && current["statusLine"] != nil)

    let malformed = Data("not JSON".utf8)
    try malformed.write(to: file(second))
    do {
        _ = try coordinator().reconcile(enabled: false, directory: first.path)
        expect("An unreadable tracked file keeps its cleanup record", false)
    } catch {
        let kept = try String(contentsOf: record, encoding: .utf8)
        expect("An unreadable tracked file keeps its cleanup record", kept == second.path)
    }
    let custom = Data(#"{"statusLine":{"type":"command","command":"my-own-script"}}"#.utf8)
    try custom.write(to: file(second))
    _ = try coordinator().reconcile(enabled: false, directory: first.path)
    let afterOptOut = try Data(contentsOf: file(second))
    expect("Cleanup leaves a user's replacement command intact", afterOptOut == custom && !fm.fileExists(atPath: record.path))

    let legacyCommand = ["statusLine": ["type": "command", "command": legacy.appendingPathComponent("claude-statusline.sh").path]]
    let legacyBytes = try JSONSerialization.data(withJSONObject: legacyCommand)
    try legacyBytes.write(to: file(second))
    let unknown = try coordinator().reconcilePreference(nil, directory: first.path, previousDirectory: second.path)
    let stillOwned = try Data(contentsOf: file(second))
    expect("An unknown preference from unreadable config leaves a legacy command alone",
           unknown == nil && stillOwned == legacyBytes)
    _ = try coordinator().reconcilePreference(false, directory: first.path, previousDirectory: second.path)
    let migrated = try contents(second)
    expect("Cold opt-out can read the legacy directory from cache even without a record", migrated["statusLine"] == nil)

    _ = try coordinator().reconcile(enabled: true, directory: first.path)
    var concurrent = coordinator()
    var replaced = false
    concurrent.beforeReplace = { url in
        if !replaced {
            replaced = true
            try custom.write(to: url, options: .atomic)
        }
    }
    _ = try concurrent.reconcile(enabled: false, directory: first.path)
    let replacement = try Data(contentsOf: file(first))
    expect("A concurrent replacement statusLine is preserved during removal",
           replaced && replacement == custom && !coordinator().hasRecordedInstallation)

    try original.write(to: file(first))
    replaced = false
    concurrent.beforeReplace = { url in
        if !replaced {
            replaced = true
            try Data(#"{"theme":"light","newPreference":42}"#.utf8).write(to: url, options: .atomic)
        }
    }
    let retriedInstall = try concurrent.reconcile(enabled: true, directory: first.path)
    let withEdits = try contents(first)
    expect("Install retries on changed bytes and keeps concurrent unrelated preferences",
           retriedInstall == .installed && withEdits["theme"] as? String == "light" && withEdits["newPreference"] as? Int == 42
           && withEdits["statusLine"] != nil)

    var editCount = 0
    concurrent.beforeReplace = { url in
        editCount += 1
        var edited = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        edited["newPreference"] = editCount
        try JSONSerialization.data(withJSONObject: edited).write(to: url, options: .atomic)
    }
    do {
        _ = try concurrent.reconcile(enabled: false, directory: first.path, requireReadableCandidates: true)
        expect("Exhausted retries fail cleanup before uninstall", false)
    } catch ClaudeStatusLine.ReconciliationError.concurrentEdits {
        let latest = try contents(first)
        let script = support.appendingPathComponent("claude-statusline.sh")
        expect("Exhausted retries fail cleanup before uninstall and retain the script, record and latest edit",
               editCount == 3 && latest["newPreference"] as? Int == 3 && latest["statusLine"] != nil
               && coordinator().hasRecordedInstallation && fm.fileExists(atPath: script.path))
    }
    _ = try coordinator().reconcile(enabled: false, directory: first.path, requireReadableCandidates: true)
    let afterRetry = try contents(first)
    expect("A later uninstall retry removes only Cala's command",
           afterRetry["newPreference"] as? Int == 3 && afterRetry["statusLine"] == nil)

    try malformed.write(to: file(second))
    do {
        _ = try coordinator().reconcile(enabled: false, directory: first.path, previousDirectory: second.path,
                                         requireReadableCandidates: true)
        expect("Uninstall propagates a read failure on an untracked legacy directory", false)
    } catch {
        let legacyUnreadable = try Data(contentsOf: file(second))
        expect("Uninstall propagates a read failure on an untracked legacy directory and preserves its bytes",
               legacyUnreadable == malformed)
    }

}

do {
    try run()
    print("\(assertions) PASS, 0 FAIL")
} catch {
    print("FAIL Claude statusLine: \(error)")
    exit(1)
}

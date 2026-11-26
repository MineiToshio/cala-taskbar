import Foundation

#if CALA_SIGNATURE_CROSSCHECK
let args = CommandLine.arguments
let key = try String(contentsOfFile: args[1], encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
let feed = try Data(contentsOf: URL(fileURLWithPath: args[2]))
let bytes = try Data(contentsOf: URL(fileURLWithPath: args[3]))
let result = try UpdateSignature.verify(feed: feed, publicKeys: [Data(base64Encoded: key)!])
precondition(result.bytes == bytes && result.manifest.version == "1.1.0" && result.manifest.build == 131)
print("PASS update-sign feed verified by UpdateSignature")
#else
private let fm = FileManager.default
private let helper = CommandLine.arguments[1]
private let root = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL

private func expect(_ condition: Bool, _ message: String) {
    guard condition else {
        fputs("FAIL update helper: \(message)\n", stderr)
        exit(1)
    }
}

@discardableResult
private func run(_ executable: String, _ args: [String], environment: [String: String]? = nil) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = args
    process.environment = environment
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

private func makeApp(_ bundle: URL, version: String, build: String, sign: Bool) throws {
    let macOS = bundle.appendingPathComponent("Contents/MacOS")
    try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
    // The stub is only for codesign. Neither this executable nor the real Cala is ever launched.
    try fm.copyItem(atPath: "/usr/bin/true", toPath: macOS.appendingPathComponent("Cala").path)
    let info: [String: Any] = [
        "CFBundleIdentifier": "local.cala",
        "CFBundleExecutable": "Cala",
        "CFBundleShortVersionString": version,
        "CFBundleVersion": build,
        "CFBundlePackageType": "APPL",
        "CalaUpdateTest": true,
        "CalaUpdateTestUpTimeout": 0.25,
    ]
    let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try data.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
    if sign {
        let status = try run("/usr/bin/codesign", ["--force", "--sign", "-", bundle.path])
        expect(status == 0, "could not sign fake app")
    }
}

private func watchCase(_ name: String, healthy: Bool, signedPrevious: Bool = true) throws {
    let parent = root.appendingPathComponent(name)
    let support = parent.appendingPathComponent("support")
    let stage = parent.appendingPathComponent(".cala-update.fixture")
    let previous = stage.appendingPathComponent("previous/Cala.app")
    let target = parent.appendingPathComponent("Cala.app")
    let pending = support.appendingPathComponent("update-pending.json")
    let transaction = UUID()
    let marker = support.appendingPathComponent("update-up-" + transaction.uuidString)
    let blocked = support.appendingPathComponent("update-blocked.json")
    let sentinel = support.appendingPathComponent("update-rollback")
    let opens = support.appendingPathComponent("opens")
    let fakeOpen = support.appendingPathComponent("fake-open")
    try fm.createDirectory(at: support, withIntermediateDirectories: true)
    try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    try makeApp(previous, version: "1.0.0", build: "120", sign: signedPrevious)
    try makeApp(target, version: "1.1.0", build: "131", sign: true)
    let corruptList = name == "unreadable-list"
    try Data((corruptList ? "invalid" : #"["0.9.0+119"]"#).utf8).write(to: blocked)
    var statInfo = stat()
    expect(stat(target.appendingPathComponent("Contents/MacOS/Cala").path, &statInfo) == 0, "target executable stat")
    let id = "\(UInt32(bitPattern: statInfo.st_dev)):\(statInfo.st_ino)"
    let record = [
        "transaction": transaction.uuidString, "executableID": id,
        "from": "1.0.0+120", "to": "1.1.0+131", "previous": previous.path,
        "deadline": ISO8601DateFormatter().string(from: Date().addingTimeInterval(-120)),
    ]
    try JSONEncoder().encode(record).write(to: pending)
    let script = """
    #!/bin/sh
    set -eu
    [ "$1" = -g ] && [ "$2" = "$TEST_TARGET" ]
    if kill -0 "$TEST_OLD_PID" 2>/dev/null; then exit 3; fi
    version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$2/Contents/Info.plist")
    case "$version" in
      1.1.0)
        [ ! -e "$TEST_SENTINEL" ]
        if [ "$TEST_NAME" = hung-open ]; then exec /bin/sleep 12; fi
        if [ "$TEST_NAME" = replaced-backup ] && [ -d "$TEST_PREVIOUS" ]; then mv "$TEST_PREVIOUS" "$TEST_PREVIOUS.saved"; fi
        if [ "$TEST_NAME" = block-write-failure ]; then rm -f "$TEST_RESERVE"; fi
        if [ -n "$TEST_RECEIPT" ]; then (sleep 0.08; printf '%s' "$TEST_RECEIPT" > "$TEST_MARKER") & fi ;;
      1.0.0)
        [ -f "$TEST_SENTINEL" ] && { [ "$TEST_NAME" = block-write-failure ] || /usr/bin/grep -q '1.1.0+131' "$TEST_BLOCKED"; } ;;
      *) exit 4 ;;
    esac
    printf '%s\\n' "$version" >> "$TEST_OPENS"
    """
    try Data(script.utf8).write(to: fakeOpen)
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeOpen.path)

    let stub = support.appendingPathComponent("stubborn-stub")
    let frozen = Process()
    if name == "frozen" {
        try fm.copyItem(atPath: "/bin/sleep", toPath: stub.path)
        frozen.executableURL = URL(fileURLWithPath: "/bin/sh")
        frozen.arguments = ["-c", "trap '' TERM; exec \"$0\" 10", stub.path]
        try frozen.run()
    }
    let old = Process()
    old.executableURL = URL(fileURLWithPath: "/bin/sleep")
    old.arguments = ["0.2"]
    try old.run()
    let start = ProcessInfo.processInfo.systemUptime
    let result = try run(helper, ["watch", "--pending", pending.path, "--pid", String(old.processIdentifier),
                                  "--target", target.path], environment: [
        "CALA_UPDATE_TEST_OPEN": fakeOpen.path, "TEST_NAME": name, "TEST_PREVIOUS": previous.path,
        "CALA_UPDATE_TEST_RESTORE_ERROR": name == "restore-error" ? "1" : "0",
        "TEST_RESERVE": support.appendingPathComponent("update-block-reserve").path, "TEST_TARGET": target.path,
        "CALA_UPDATE_TEST_STUB": name == "frozen" ? stub.path : "",
        "TEST_RECEIPT": name == "wrong-inode" ? "healthy 0:0" : healthy ? (name == "quit" ? "quit " : "healthy ") + id : "", "TEST_MARKER": marker.path,
        "TEST_SENTINEL": sentinel.path, "TEST_BLOCKED": blocked.path, "TEST_OPENS": opens.path,
        "TEST_OLD_PID": String(old.processIdentifier),
    ])
    old.waitUntilExit()
    let invalid = !signedPrevious || corruptList
    let changed = name == "replaced-backup"
    let full = name == "block-write-failure"
    expect(result == (invalid || changed ? 1 : 0), "unexpected watch exit status for \(name)")
    if invalid {
        expect(!fm.fileExists(atPath: opens.path) && !fm.fileExists(atPath: sentinel.path),
               "invalid recovery state leaves the installed build alone")
        return
    }
    if name == "frozen" {
        frozen.waitUntilExit()
        expect(frozen.terminationReason == .uncaughtSignal && frozen.terminationStatus == SIGKILL, "SIGTERM-resistant stub stopped")
    }
    if name == "hung-open" { expect(ProcessInfo.processInfo.systemUptime - start < 8, "open is bounded") }
    let launchLog = try String(contentsOf: opens, encoding: .utf8)
    let blockedBuilds = try JSONDecoder().decode([String].self, from: Data(contentsOf: blocked))
    let expectedLaunches = healthy ? "1.1.0\n" : changed ? "1.1.0\n" : name == "hung-open" ? "1.0.0\n" : "1.1.0\n1.0.0\n"
    expect(launchLog == expectedLaunches, "unexpected opens for \(name)")
    expect(fm.fileExists(atPath: sentinel.path) == full, "unexpected rollback sentinel")
    expect(fm.fileExists(atPath: stage.path) == (changed || full), "unexpected stage cleanup for \(name)")
    expect(fm.fileExists(atPath: pending.path) == (changed || full), "unexpected pending state for \(name)")
    expect(blockedBuilds == (healthy || full || changed ? ["0.9.0+119"] : ["0.9.0+119", "1.1.0+131"]),
           "unexpected blocked list for \(name)")
    expect(fm.fileExists(atPath: parent.appendingPathComponent(".cala-blocked-1.1.0+131").path) == (!healthy && !changed),
           "shared install block for \(name)")
    let restoredPlist = try Data(contentsOf: target.appendingPathComponent("Contents/Info.plist"))
    let info = try PropertyListSerialization.propertyList(from: restoredPlist, format: nil) as? [String: Any]
    expect(info?["CFBundleVersion"] as? String == (healthy || changed ? "131" : "120"),
           "unexpected build at target for \(name)")
}

try watchCase("marker", healthy: true)
try watchCase("quit", healthy: true)
try watchCase("timeout", healthy: false)
try watchCase("unsigned", healthy: false, signedPrevious: false)
for fault in ["frozen", "wrong-inode", "unreadable-list", "hung-open", "restore-error", "replaced-backup", "block-write-failure"] {
    try watchCase(fault, healthy: false)
}
print("PASS helper launch deadline, timeout rollback, signature, unreadable-list, hung-open, replaced-backup, block-write-failure")
#endif

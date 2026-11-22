import Foundation
import Darwin

/// Reopens Cala by itself if it crashes or is force-quit, so nobody is left without a taskbar.
///
/// A crashed process cannot restart itself, so at launch Cala starts a tiny detached shell script that watches its pid.
/// When the process disappears the script looks for the "clean exit" marker that `cleanExit()` writes on a normal quit
/// (Salir de Cala, logout, shutdown, installer): if it is there it does nothing, otherwise it opens Cala again.
/// A loop guard stops after 3 relaunches in 2 minutes, so a crash at startup cannot cause an endless loop.
enum Watchdog {
    private static var dir: URL { AppPaths.supportDirectory }
    private static var lockURL: URL { dir.appendingPathComponent("running.lock") }
    private static var disabledURL: URL { dir.appendingPathComponent("no-relaunch") }
    private static func markerURL(_ pid: pid_t) -> URL { dir.appendingPathComponent("clean-exit-\(pid)") }

    /// True when the previous run did not end with a normal quit (it crashed, or was killed).
    private(set) static var previousRunEnded = false

    private static let script = """
    #!/bin/sh
    # Cala watchdog: relaunches Cala if its process vanished without a clean-exit marker.
    PID="$1"; DIR="$2"; APP="$3"
    trap '' HUP
    while kill -0 "$PID" 2>/dev/null; do sleep 1; done
    sleep 1
    MARK="$DIR/clean-exit-$PID"
    if [ -e "$MARK" ]; then rm -f "$MARK"; exit 0; fi
    [ -e "$DIR/no-relaunch" ] && exit 0
    NOW=$(date +%s); STATE="$DIR/relaunch-times"
    RECENT=$(awk -v now="$NOW" 'now - $1 < 120' "$STATE" 2>/dev/null | wc -l | tr -d ' ')
    [ "$RECENT" -ge 3 ] && exit 0
    echo "$NOW" >> "$STATE"
    /usr/bin/open "$APP"
    """

    private static func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

    /// Call once at launch.
    static func start(store: ConfigStore) {
        let fm = FileManager.default
        let me = ProcessInfo.processInfo.processIdentifier
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        if let text = try? String(contentsOf: lockURL, encoding: .utf8), let old = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
           old != me, !alive(old) {
            previousRunEnded = true
            log("watchdog: the previous run (pid \(old)) did not exit cleanly")
        }
        try? String(me).write(to: lockURL, atomically: true, encoding: .utf8)
        // Old markers (their watchers are long gone).
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasPrefix("clean-exit-") {
            let url = dir.appendingPathComponent(name)
            if let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, Date().timeIntervalSince(date) > 3600 { try? fm.removeItem(at: url) }
        }
        sync(store)
        guard store.config.relaunchOnCrash else { return }

        let scriptURL = dir.appendingPathComponent("watchdog.sh")
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        } catch { log("watchdog: could not write the script"); return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [scriptURL.path, String(me), dir.path, Bundle.main.bundlePath]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        do { try p.run(); log("watchdog: watching pid \(me)") } catch { log("watchdog: could not start") }
    }

    /// Applies the on/off setting to the watcher that is already running.
    static func sync(_ store: ConfigStore) {
        if store.config.relaunchOnCrash { try? FileManager.default.removeItem(at: disabledURL) }
        else { try? Data().write(to: disabledURL) }
    }

    /// Call from `applicationWillTerminate`: a normal quit, so the watcher must not relaunch.
    static func cleanExit() {
        let me = ProcessInfo.processInfo.processIdentifier
        try? Data().write(to: markerURL(me))
        try? FileManager.default.removeItem(at: lockURL)
    }
}

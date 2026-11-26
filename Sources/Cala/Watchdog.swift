import Foundation
import Darwin
import Security

// The audit session is shared by Finder, LaunchServices and direct exec in a login.
// CLOEXEC and process exit release the flock without a cleanup or unlink race.
enum CalaSessionLock {
    static func acquire(in directory: URL, session: SecuritySessionId) -> Int32? {
        let file = directory.appendingPathComponent("local.cala.\(getuid()).\(session).lock")
        let fd = open(file.path, O_RDONLY | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1, flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return nil }
        return fd
    }

    static func acquireForCurrentLogin() -> Int32? {
        var session: SecuritySessionId = 0
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard SessionGetInfo(SecuritySessionId(callerSecuritySession), &session, nil) == errSecSuccess,
              confstr(_CS_DARWIN_USER_TEMP_DIR, &path, path.count) > 0 else { return nil }
        return acquire(in: URL(fileURLWithPath: String(cString: path)), session: session)
    }
}

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
    if [ -e "$DIR/update-rollback" ]; then
        HELPER=$(cat "$DIR/update-rollback" 2>/dev/null)
        case "$HELPER" in
            ''|*[!0-9]*) exit 0 ;; # legacy watcher
            *) kill -0 "$HELPER" 2>/dev/null && exit 0 ;;
        esac
    fi
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

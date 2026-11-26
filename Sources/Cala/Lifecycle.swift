import AppKit
import ServiceManagement

/// Open at login through macOS's own Login Items (System Settings → General → Login Items), so the user sees and
/// controls it there. Replaces the LaunchAgent that older versions wrote by hand.
enum LoginItem {
    private static let registrationPathKey = "loginItemRegistrationPath"
    private static let desiredKey = "loginItemDesired"
    private static var defaults: UserDefaults { .standard }
    static var savedPreference: Bool? { defaults.object(forKey: desiredKey) as? Bool }

    private static var status: LoginItemPolicy.Status {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered, .notFound: return .missing
        @unknown default: return .unknown
        }
    }

    static var preference: LoginItemPolicy.Preference {
        let registeredPath = defaults.string(forKey: registrationPathKey)
        let current = status
        let path = AppLocation.bundleURL.path
        let rebind = LoginItemPolicy.rebind(desired: true, status: current, registeredPath: registeredPath,
                                           bundlePath: path, firstSharedLaunch: path == "/Applications/Cala.app")
        return LoginItemPolicy.preference(saved: savedPreference, registeredPath: registeredPath, status: current,
                                          pointsToPreviousBundle: AppLocation.isInstalled && rebind == .replace)
    }

    static func retry() {
        let choice = preference
        if choice.desired, status == .enabled { rebindAfterMove() }
        else { set(choice.desired) }
    }

    private static var legacyAgents: [URL] {
        let agents = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
        return ["local.cala.plist", "local.mactaskbar.plist"].map { agents.appendingPathComponent($0) }
    }

    /// Save the user's choice even if Service Management can't apply it yet.
    @discardableResult
    static func set(_ on: Bool) -> Bool {
        defaults.set(on, forKey: desiredKey)
        let current = status
        do {
            if on {
                if current == .requiresApproval { return true }
                if current != .enabled { try SMAppService.mainApp.register() }
                defaults.set(AppLocation.bundleURL.path, forKey: registrationPathKey)
            } else {
                if current != .missing { try SMAppService.mainApp.unregister() }
                defaults.removeObject(forKey: registrationPathKey)
            }
            log("login item: \(on ? "on" : "off") status=\(SMAppService.mainApp.status.rawValue)")
            return true
        } catch {
            log("login item: \(on ? "register" : "unregister") failed: \(error)")
            return false
        }
    }

    static func rebindAfterMove() {
        guard AppLocation.isInstalled else { return }
        let path = AppLocation.bundleURL.path
        let registeredPath = defaults.string(forKey: registrationPathKey)
        let current = status
        let desired = LoginItemPolicy.preference(saved: savedPreference, registeredPath: registeredPath,
                                                 status: current).desired
        // An existing registration is evidence of intent for upgrades from builds that saved no preference.
        if savedPreference == nil, desired { defaults.set(true, forKey: desiredKey) }
        let action = LoginItemPolicy.rebind(desired: desired, status: current, registeredPath: registeredPath,
                                           bundlePath: path, firstSharedLaunch: path == "/Applications/Cala.app")
        guard action != .none else {
            if current == .enabled, registeredPath == nil { defaults.set(path, forKey: registrationPathKey) }
            return
        }
        log("login item: rebinding from \(registeredPath ?? "an existing preference") to \(path)")
        if action == .replace {
            do { try SMAppService.mainApp.unregister() }
            catch {
                log("login item: unregister before rebinding failed: \(error)")
                return
            }
        }
        set(true)
    }

    /// Older versions started at login through a LaunchAgent pointing at a fixed path. Move that choice to Login Items
    /// once, keeping it on only if it was on, and only for an installed copy (never a build folder).
    static func migrateLegacy() {
        let fm = FileManager.default
        let found = legacyAgents.filter { fm.fileExists(atPath: $0.path) }
        guard !found.isEmpty else { return }
        for url in found { try? fm.removeItem(at: url) }
        log("login item: removed legacy launch agent(s) \(found.map(\.lastPathComponent))")
        if AppLocation.isInstalled, savedPreference == nil { defaults.set(true, forKey: desiredKey) }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// Where the running copy lives, and moving it to Applications.
enum AppLocation {
    static var bundleURL: URL { Bundle.main.bundleURL.resolvingSymlinksInPath() }

    /// In /Applications or ~/Applications.
    static var isInstalled: Bool {
        let path = bundleURL.deletingLastPathComponent().path
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
        return path == "/Applications" || path == home
    }

    /// macOS runs a downloaded app from a random read-only folder until it is moved ("App Translocation").
    static var isTranslocated: Bool { bundleURL.path.contains("/AppTranslocation/") }

    /// Opened from the disk image itself.
    static var onDiskImage: Bool { bundleURL.path.hasPrefix("/Volumes/") }

    /// The original location of a translocated app (where the user double-clicked it), if macOS tells us.
    private static func originalURL() -> URL? {
        guard isTranslocated,
              let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY) else { return nil }
        defer { dlclose(handle) }
        typealias Fn = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        guard let sym = dlsym(handle, "SecTranslocateCreateOriginalPathForURL") else { return nil }
        let fn = unsafeBitCast(sym, to: Fn.self)
        return fn(bundleURL as CFURL, nil)?.takeRetainedValue() as URL?
    }

    /// Copies Cala into /Applications (or ~/Applications when that is not writable), moves the downloaded copy to the
    /// Trash when possible, and opens the new copy. Returns an error message for the user, or nil on success.
    static func moveToApplications() -> String? {
        let fm = FileManager.default
        let system = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let user = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        let folder = fm.isWritableFile(atPath: system.path) ? system : user
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(bundleURL.lastPathComponent)
        let source = originalURL() ?? bundleURL
        do {
            if fm.fileExists(atPath: destination.path) {
                // An older copy: put it in the Trash rather than deleting it.
                try fm.trashItem(at: destination, resultingItemURL: nil)
            }
            try fm.copyItem(at: bundleURL, to: destination)
        } catch {
            log("move: copy to \(folder.path) failed: \(error)")
            return tx("Could not copy Cala to \(folder.path). Drag it to Applications in Finder instead.",
                      "No se pudo copiar Cala a \(folder.path). Arrástrala a Aplicaciones en Finder.")
        }
        // Only the downloaded copy: never the disk image (read-only) and never the new copy.
        if !source.path.hasPrefix("/Volumes/"), source.standardizedFileURL != destination.standardizedFileURL {
            try? fm.trashItem(at: source, resultingItemURL: nil)
        }
        log("move: installed at \(destination.path)")
        Relaunch.open(destination)
        return nil
    }
}

enum Relaunch {
    private static var pending: (app: URL, inBackground: Bool)?

    static func open(_ app: URL = AppLocation.bundleURL, inBackground: Bool = false) {
        guard pending == nil else { return }
        pending = (app, inBackground)
        defer { pending = nil }
        NSApp.terminate(nil)
    }

    /// Start the helper only after AppKit commits to quitting and module cleanup has finished.
    static func openAfterTermination() {
        guard let request = pending else { return }
        pending = nil
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        let script = """
        for i in $(/usr/bin/seq 1 600); do
            kill -0 "$1" 2>/dev/null || break
            /bin/sleep 0.1
        done
        shift
        exec /usr/bin/open "$@" "$0"
        """
        p.arguments = ["-c", script, request.app.path, String(ProcessInfo.processInfo.processIdentifier)]
        if request.inBackground { p.arguments?.append("-g") }
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { log("relaunch: could not schedule: \(error)") }
    }
}

/// Removes everything Cala added to this Mac and then moves the app to the Trash.
enum Uninstaller {
    static func confirmAndRun(store: ConfigStore) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = tx("Uninstall Cala?", "¿Desinstalar Cala?")
        alert.informativeText = tx("""
        Cala will put back the Dock and menu bar as they were, stop opening at login, remove its settings and logs \
        (and its Claude Code statusLine entry, if you turned it on) and move itself to the Trash.

        Permissions you granted stay listed in System Settings → Privacy & Security until you remove them there.
        """, """
        Cala devolverá el Dock y la barra de menús a como estaban, dejará de abrirse al iniciar sesión, borrará sus \
        ajustes y registros (y su entrada statusLine de Claude Code, si la activaste) y se moverá a la Papelera.

        Los permisos que diste siguen en Ajustes del Sistema → Privacidad y seguridad hasta que los quites allí.
        """)
        alert.addButton(withTitle: tx("Cancel", "Cancelar"))
        alert.addButton(withTitle: tx("Uninstall", "Desinstalar")).hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        run(store: store)
    }

    private static func run(store: ConfigStore) {
        log("uninstall: start")
        do {
            try UsageService.shared.removeStatusLineNow(config: store.config)
        } catch {
            log("uninstall: Claude statusLine cleanup failed: \(error)")
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = tx("Cala couldn’t remove its Claude Code command", "Cala no pudo retirar su comando de Claude Code")
            alert.informativeText = tx("Cala is still installed. Check the Claude Code settings file and retry. \(error.localizedDescription)",
                                       "Cala sigue instalada. Revisa el archivo de ajustes de Claude Code y vuelve a intentarlo. \(error.localizedDescription)")
            alert.runModal()
            return
        }
        let fm = FileManager.default
        // 1. Give back what Cala changed in the system.
        if store.config.hideNativeDock { DockControl.setHidden(false, store) }
        if store.config.hideMenuBar {
            if !ModuleRegistry.shared.isRunning(.bar) { MenuBarControl.onBarStop(store) }
            MenuBarControl.setHidden(false, store)
        }
        MenuBarIcons.restoreForTrayStop(store)
        // 2. Stop starting at login and stop the crash watchdog.
        LoginItem.set(false)
        LoginItem.migrateLegacy()
        store.config.relaunchOnCrash = false
        Watchdog.sync(store)
        Watchdog.cleanExit()
        // 3. Settings, logs, caches and preferences.
        store.disableSaving()
        let app = AppLocation.bundleURL
        let support = AppPaths.supportDirectory
        let legacy = AppPaths.legacySupportDirectory
        if let id = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: id)
            UserDefaults.standard.synchronize()
            let library = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library")
            for path in ["Caches/\(id)", "HTTPStorages/\(id)", "Saved Application State/\(id).savedState"] {
                try? fm.removeItem(at: library.appendingPathComponent(path))
            }
        }
        // 4. The app goes to the Trash (recoverable; a running app can be moved). The support folder is removed by a
        // helper once Cala has quit, because the log and the watchdog live there.
        do { try fm.trashItem(at: app, resultingItemURL: nil) } catch { log("uninstall: could not trash the app: \(error)") }
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].standardizedFileURL.path
        let folders = [support, legacy].map(\.standardizedFileURL.path).filter {
            // Only Cala's own folders, never anything else.
            ($0 == base + "/Cala" || $0 == base + "/MacTaskbar")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; for f in \"$@\"; do /bin/rm -rf \"$f\"; done", "cala-uninstall"] + folders
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try? p.run()
        log("uninstall: done, quitting")
        NSApp.terminate(nil)
    }
}

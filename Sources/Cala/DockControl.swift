import Foundation

/// Hides / restores the native macOS Dock from inside the app (no Terminal needed).
/// The Dock keeps running (we read its badges), it just never reveals itself: auto-hide on + a very long delay.
enum DockControl {
    private static let app = "com.apple.dock" as CFString
    private static let hiddenDelay = 1000.0

    private static func value(_ key: String) -> Any? {
        CFPreferencesCopyAppValue(key as CFString, app)
    }
    private static func set(_ key: String, _ v: Any?) {
        CFPreferencesSetValue(key as CFString, v as CFPropertyList?, app, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    /// True when the Dock is currently set to never show itself.
    static var isHidden: Bool {
        (value("autohide") as? Bool) == true && ((value("autohide-delay") as? Double) ?? 0) >= 100
    }

    private static var hasCalaValues: Bool {
        (value("autohide") as? Bool) == true && (value("autohide-delay") as? Double) == hiddenDelay
    }

    private static func synchronize() -> Bool {
        CFPreferencesSynchronize(app, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    private static func restartDock() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        p.arguments = ["Dock"]
        if (try? p.run()) != nil { p.waitUntilExit() }
    }

    /// Hides the Dock, recording the backup before writing the override.
    static func hide(_ store: ConfigStore) {
        if isHidden {
            if !store.config.dockBackupSaved { rememberAdoption(store) }
            return
        }
        var config = store.config
        config.dockBackupAutohide = value("autohide") as? Bool
        config.dockBackupDelay = value("autohide-delay") as? Double
        config.dockBackupSaved = true
        config.dockOverridePending = true
        store.config = config
        set("autohide", true)
        set("autohide-delay", hiddenDelay)
        if synchronize() { restartDock() }
    }

    private static func rememberAdoption(_ store: ConfigStore) {
        var config = store.config
        config.hideNativeDock = true
        config.dockBackupAutohide = true
        config.dockBackupDelay = nil
        config.dockBackupSaved = true
        config.dockOverridePending = false
        store.config = config
    }

    private static func restore(_ store: ConfigStore, includeAdopted: Bool) {
        var config = store.config
        guard config.dockBackupSaved else { return }
        // Legacy backups have no ownership flag. Match the values Cala wrote before using one.
        let restore = config.dockOverridePending == false ? includeAdopted && isHidden : hasCalaValues
        if restore {
            set("autohide", config.dockBackupAutohide)
            set("autohide-delay", config.dockBackupDelay)
            guard synchronize() else { return }
        }
        config.dockBackupSaved = false
        config.dockOverridePending = false
        store.config = config
        if restore { restartDock() }
    }

    /// Re-apply the user's choice or adopt a Dock already hidden by hand while the bar runs.
    static func applyOnLaunch(_ store: ConfigStore) {
        if store.config.hideNativeDock && !isHidden { hide(store) }
        if !store.config.hideNativeDock && isHidden && !store.configLoadFailed && !store.config.recoveredFromInvalidFields {
            if store.config.dockBackupSaved, store.config.dockOverridePending != false, hasCalaValues {
                store.config.hideNativeDock = true
            } else {
                rememberAdoption(store)
            }
        }
    }

    static func setHidden(_ on: Bool, _ store: ConfigStore) {
        store.config.hideNativeDock = on
        guard ModuleRegistry.shared.isRunning(.bar) else { return }
        if on { hide(store) } else { restore(store, includeAdopted: true) }
    }

    static func onBarStop(_ store: ConfigStore) {
        restore(store, includeAdopted: true)
    }

    /// Restore only a pending Cala override when launching with the bar disabled.
    static func restoreAfterCrashIfNeeded(_ store: ConfigStore) {
        restore(store, includeAdopted: false)
    }

    static func onQuit(_ store: ConfigStore) {
        if store.config.restoreDockOnQuit { restore(store, includeAdopted: true) }
    }
}

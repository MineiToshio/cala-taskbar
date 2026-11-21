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

    private static func restartDock() {
        CFPreferencesSynchronize(app, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        p.arguments = ["Dock"]
        try? p.run()
        p.waitUntilExit()
    }

    /// Hides the Dock, remembering how it was so it can be restored exactly.
    static func hide(_ store: ConfigStore) {
        if !isHidden || !store.config.dockBackupSaved {
            // If it was already hidden (set by hand), "normal" means auto-hide with the default delay.
            let was = isHidden
            store.config.dockBackupAutohide = was ? true : (value("autohide") as? Bool)
            store.config.dockBackupDelay = was ? nil : (value("autohide-delay") as? Double)
            store.config.dockBackupSaved = true
        }
        guard !isHidden else { return }
        set("autohide", true)
        set("autohide-delay", hiddenDelay)
        restartDock()
    }

    /// Puts the Dock back the way it was before `hide`.
    static func restore(_ store: ConfigStore) {
        guard isHidden || store.config.dockBackupSaved else { return }
        set("autohide", store.config.dockBackupAutohide)
        set("autohide-delay", store.config.dockBackupDelay)
        restartDock()
    }

    /// Called at launch: re-applies the user's choice (e.g. after the Dock was restored on quit).
    static func applyOnLaunch(_ store: ConfigStore) {
        if store.config.hideNativeDock && !isHidden { hide(store) }
        // Already hidden by hand: adopt that state so the switch reflects reality.
        if !store.config.hideNativeDock && isHidden && !store.configLoadFailed && !store.config.recoveredFromInvalidFields {
            store.config.hideNativeDock = true
            store.config.dockBackupAutohide = true
            store.config.dockBackupDelay = nil
            store.config.dockBackupSaved = true
        }
    }

    /// Called when the toggle changes.
    static func setHidden(_ on: Bool, _ store: ConfigStore) {
        store.config.hideNativeDock = on
        if on { hide(store) } else { restore(store); store.config.dockBackupSaved = false }
    }

    /// Called on quit: give the user their Dock back so they are never left without one.
    static func onQuit(_ store: ConfigStore) {
        if store.config.hideNativeDock && store.config.restoreDockOnQuit && isHidden { restore(store) }
    }
}

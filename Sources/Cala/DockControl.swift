import Foundation

/// Hides / restores the native macOS Dock from inside the app (no Terminal needed).
/// The Dock keeps running (we read its badges), it just never reveals itself: auto-hide on + a very long delay,
/// and `no-bouncing` on, because an app asking for attention opens the Dock whatever the delay (the bar shows that cue).
enum DockControl {
    private static let app = "com.apple.dock" as CFString
    private static let hiddenDelay = 1000.0
    private static let noBouncingKey = "no-bouncing"

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

    private static func noBouncingBackup(_ config: Config) -> DockNoBouncing.Backup {
        .init(saved: config.dockBackupNoBouncingSaved, value: config.dockBackupNoBouncing)
    }

    private static func record(_ backup: DockNoBouncing.Backup, in config: inout Config) {
        config.dockBackupNoBouncingSaved = backup.saved
        config.dockBackupNoBouncing = backup.value
    }

    private static func write(_ w: DockNoBouncing.Write) {
        switch w {
        case .keep: break
        case .set(let v): set(noBouncingKey, v)
        case .remove: set(noBouncingKey, nil)
        }
    }

    /// Cala's `no-bouncing` step. `unrecorded`: the Dock holds Cala's hidden values with no backup saying so.
    private static func noBouncingStep(_ config: Config, unrecorded: Bool) -> (backup: DockNoBouncing.Backup, write: DockNoBouncing.Write) {
        DockNoBouncing.apply(current: value(noBouncingKey) as? Bool, backup: noBouncingBackup(config), calaHidDockUnrecorded: unrecorded)
    }

    /// Starting to suppress needs no restart (the Dock reads the key on every request), but a tile already bouncing keeps
    /// going (and the hidden Dock stays open) until the Dock restarts: restart only when some app wants attention now.
    private static func finishNoBouncing() {
        if synchronize(), AppAttention.anyAppWantsAttention() { restartDock() }
    }

    /// Hides the Dock, recording the backup before writing the override.
    static func hide(_ store: ConfigStore) {
        if isHidden {
            if !store.config.dockBackupSaved { rememberAdoption(store) } else { ensureNoBouncing(store) }
            return
        }
        var config = store.config
        config.dockBackupAutohide = value("autohide") as? Bool
        config.dockBackupDelay = value("autohide-delay") as? Double
        config.dockBackupSaved = true
        config.dockOverridePending = true
        let bounce = noBouncingStep(config, unrecorded: false)
        record(bounce.backup, in: &config)
        store.config = config
        // The backup must be on disk before the Dock is touched, or the user's values could be lost.
        guard store.save() else { log("dock: config not saved, Dock left as it is"); return }
        write(bounce.write)
        set("autohide", true)
        set("autohide-delay", hiddenDelay)
        if synchronize() { restartDock() }
    }

    private static func rememberAdoption(_ store: ConfigStore) {
        let unrecorded = hasCalaValues && !store.config.dockBackupSaved
        var config = store.config
        config.hideNativeDock = true
        config.dockBackupAutohide = true
        config.dockBackupDelay = nil
        config.dockBackupSaved = true
        config.dockOverridePending = false
        let bounce = noBouncingStep(config, unrecorded: unrecorded)
        record(bounce.backup, in: &config)
        store.config = config
        guard bounce.write != .keep else { return }
        guard store.save() else { log("dock: config not saved, no-bouncing left as it is"); return }
        write(bounce.write)
        finishNoBouncing()
    }

    /// A Dock hidden by an earlier version (its backup has no `no-bouncing`) gets the override too, keeping the user's value.
    private static func ensureNoBouncing(_ store: ConfigStore) {
        var config = store.config
        let bounce = noBouncingStep(config, unrecorded: hasCalaValues && !config.dockBackupSaved)
        guard bounce.backup != noBouncingBackup(config) || bounce.write != .keep else { return }
        record(bounce.backup, in: &config)
        store.config = config
        guard bounce.write != .keep else { return }
        guard store.save() else { log("dock: config not saved, no-bouncing left as it is"); return }
        write(bounce.write)
        finishNoBouncing()
    }

    private static func restore(_ store: ConfigStore, includeAdopted: Bool) {
        var config = store.config
        let current = value(noBouncingKey) as? Bool
        guard let plan = DockRestore.plan(.init(
            hideBackupSaved: config.dockBackupSaved, overridePending: config.dockOverridePending, includeAdopted: includeAdopted,
            isHidden: isHidden, hasCalaValues: hasCalaValues, noBouncing: current, noBouncingRecord: noBouncingBackup(config)
        )) else { return }
        let before: [String: Any?] = ["autohide": value("autohide"), "autohide-delay": value("autohide-delay"), noBouncingKey: value(noBouncingKey)]
        write(plan.noBouncing)
        if plan.restoreHide {
            set("autohide", config.dockBackupAutohide)
            set("autohide-delay", config.dockBackupDelay)
        }
        let synced = plan.needsSync ? synchronize() : true
        guard DockRestore.clearsRecords(plan, synced: synced) else {
            // Not saved: put Cala's values back in memory too, so the next try still sees them and restores.
            for (key, v) in before { set(key, v) }
            log("dock: restore not saved, backup kept")
            return
        }
        record(plan.noBouncingRecord, in: &config)
        if config.dockBackupSaved {
            config.dockBackupSaved = false
            config.dockOverridePending = false
        }
        store.config = config
        // Bouncing only comes back after a Dock restart, even when only `no-bouncing` changed.
        if plan.restartDock { restartDock() }
    }

    /// Re-apply the user's choice or adopt a Dock already hidden by hand while the bar runs.
    static func applyOnLaunch(_ store: ConfigStore) {
        if store.config.hideNativeDock && !isHidden { hide(store) }
        let trusted = !store.configLoadFailed && !store.config.recoveredFromInvalidFields
        if !store.config.hideNativeDock && isHidden && trusted {
            if store.config.dockBackupSaved, store.config.dockOverridePending != false, hasCalaValues {
                store.config.hideNativeDock = true
            } else {
                rememberAdoption(store)
            }
        }
        // Covers a Dock hidden before Cala wrote `no-bouncing` (upgrade) and any case above that kept the Dock hidden.
        if store.config.hideNativeDock && isHidden && trusted { ensureNoBouncing(store) }
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

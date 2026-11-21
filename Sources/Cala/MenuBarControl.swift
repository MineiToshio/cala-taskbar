import Foundation

/// Hides / restores the macOS menu bar (the strip at the top of the screen).
///
/// macOS cannot remove the menu bar, only auto-hide it: it slides away and reappears when the pointer touches the
/// top edge. This writes the same three preferences System Settings → Control Center → "Automatically hide and show
/// the menu bar" writes, then posts the two notifications that make the change apply live:
///
///     mode                 AutoHideMenuBarOption   _HIHideMenuBar   AppleMenuBarVisibleInFullscreen
///     Always (hidden)              0                    true              false
///     On desktop only              1                    true              true
///     In full screen only (default) 2                   false             false
///     Never (always visible)       3                    false             true
///
/// These keys are undocumented, so every value is restored exactly as it was found.
enum MenuBarControl {
    private static let controlCenter = "com.apple.controlcenter" as CFString
    private static let global = kCFPreferencesAnyApplication
    private static let hiddenOption = 0

    private static func option() -> Int? { CFPreferencesCopyAppValue("AutoHideMenuBarOption" as CFString, controlCenter) as? Int }
    private static func hideFlag() -> Bool? { CFPreferencesCopyAppValue("_HIHideMenuBar" as CFString, global) as? Bool }
    private static func fullscreenFlag() -> Bool? { CFPreferencesCopyAppValue("AppleMenuBarVisibleInFullscreen" as CFString, global) as? Bool }

    private static func write(option: Int?, hide: Bool?, fullscreen: Bool?) {
        CFPreferencesSetValue("AutoHideMenuBarOption" as CFString, option.map { $0 as CFNumber }, controlCenter, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSetValue("_HIHideMenuBar" as CFString, hide.map { $0 as CFBoolean }, global, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSetValue("AppleMenuBarVisibleInFullscreen" as CFString, fullscreen.map { $0 as CFBoolean }, global, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(controlCenter, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(global, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        for name in ["AppleInterfaceMenuBarHidingChangedNotification", "AppleInterfaceFullScreenMenuBarVisibilityChangedNotification"] {
            DistributedNotificationCenter.default().postNotificationName(Notification.Name(name), object: nil, userInfo: nil, deliverImmediately: true)
        }
        log("menubar: option=\(option.map(String.init) ?? "nil") hide=\(hide.map(String.init) ?? "nil") fullscreen=\(fullscreen.map(String.init) ?? "nil")")
    }

    /// True when the menu bar is set to hide itself everywhere.
    static var isHidden: Bool { option() == hiddenOption && hideFlag() == true && fullscreenFlag() != true }

    static func hide(_ store: ConfigStore) {
        if !isHidden || !store.config.menuBarBackupSaved {
            store.config.menuBarBackupOption = option()
            store.config.menuBarBackupHide = hideFlag()
            store.config.menuBarBackupFullscreen = fullscreenFlag()
            store.config.menuBarBackupSaved = true
        }
        guard !isHidden else { return }
        write(option: hiddenOption, hide: true, fullscreen: false)
    }

    /// Puts the menu bar back the way it was before `hide`.
    static func restore(_ store: ConfigStore) {
        guard isHidden || store.config.menuBarBackupSaved else { return }
        write(option: store.config.menuBarBackupOption, hide: store.config.menuBarBackupHide, fullscreen: store.config.menuBarBackupFullscreen)
    }

    static func setHidden(_ on: Bool, _ store: ConfigStore) {
        store.config.hideMenuBar = on
        if on { hide(store) } else { restore(store); store.config.menuBarBackupSaved = false }
    }

    /// At launch: re-applies the user's choice (it was restored on quit, or the OS reset it).
    static func applyOnLaunch(_ store: ConfigStore) {
        if store.config.hideMenuBar && !isHidden { hide(store) }
    }

    /// On quit: give the menu bar back so nobody is left without one.
    static func onQuit(_ store: ConfigStore) {
        if store.config.hideMenuBar && store.config.restoreMenuBarOnQuit && isHidden { restore(store) }
    }
}

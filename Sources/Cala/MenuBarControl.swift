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


/// Hides individual macOS icons on the right of the menu bar (the ones Cala already shows in its own tray).
///
/// This is what System Settings → Control Center → "Show in Menu Bar" does. The per-host key of each module in
/// `com.apple.controlcenter` holds 18 (shown) or 24 (not shown); absent means the system default. ControlCenter is
/// restarted so it re-reads them. (The `NSStatusItem VisibleCC …` keys are only ControlCenter's own echo of that
/// state: writing them has no effect because ControlCenter rewrites them when it quits.)
///
/// Verified on macOS 26.6: Wi-Fi, Battery and Fast User Switching each lose one menu bar item. The clock is always
/// shown (Apple's documentation), and the Control Center and Spotlight icons did not respond, so they are not offered.
/// Icons that belong to other apps (Claude, Slack…) are controlled by those apps.
enum MenuBarIcons {
    struct Icon: Identifiable {
        let id: String
        let title: String
        let note: String
        let key: String
    }

    static let all: [Icon] = [
        Icon(id: "wifi", title: "Wi-Fi", note: "Cala ya muestra el Wi-Fi.", key: "WiFi"),
        Icon(id: "battery", title: "Batería", note: "Cala ya muestra la batería.", key: "Battery"),
        Icon(id: "user", title: "Cambio rápido de usuario", note: "Cala ya permite cambiar de usuario.", key: "UserSwitcher"),
    ]
    private static let domain = "com.apple.controlcenter" as CFString
    private static let hiddenValue = 24

    private static func current(_ icon: Icon) -> Int? {
        CFPreferencesCopyValue(icon.key as CFString, domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost) as? Int
    }

    private static func write(_ icon: Icon, _ value: Int?) {
        CFPreferencesSetValue(icon.key as CFString, value.map { $0 as CFNumber }, domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
    }

    private static func restartControlCenter() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        p.arguments = ["ControlCenter"]
        try? p.run()
        p.waitUntilExit()
    }

    private static func saved(_ s: String) -> Int? { s == "nil" ? nil : Int(s) }

    /// Makes the menu bar match the user's choice, remembering each icon's original value ("nil" = key absent).
    static func apply(_ store: ConfigStore) {
        var changed = false
        var backup = store.config.menuBarIconBackupV2
        let known = Set(all.map(\.id))
        let hidden = Set(store.config.menuBarHiddenIcons).intersection(known)
        for icon in all {
            if hidden.contains(icon.id) {
                if backup[icon.id] == nil { backup[icon.id] = current(icon).map(String.init) ?? "nil" }
                if current(icon) != hiddenValue { write(icon, hiddenValue); changed = true }
            } else if let original = backup[icon.id] {
                write(icon, saved(original))
                backup[icon.id] = nil
                changed = true
            }
        }
        if backup != store.config.menuBarIconBackupV2 { store.config.menuBarIconBackupV2 = backup }
        if changed { restartControlCenter(); log("menubar: icons hidden=\(hidden.sorted())") }
    }

    /// On quit: show everything again, if the user asked for that.
    static func onQuit(_ store: ConfigStore) {
        guard store.config.restoreMenuBarOnQuit, !store.config.menuBarIconBackupV2.isEmpty else { return }
        var restored = false
        for icon in all {
            if let original = store.config.menuBarIconBackupV2[icon.id] { write(icon, saved(original)); restored = true }
        }
        if restored { restartControlCenter() }
    }
}

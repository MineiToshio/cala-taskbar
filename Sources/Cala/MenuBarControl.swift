import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

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
            var config = store.config
            config.menuBarBackupOption = option()
            config.menuBarBackupHide = hideFlag()
            config.menuBarBackupFullscreen = fullscreenFlag()
            config.menuBarBackupSaved = true
            store.config = config
        }
        guard !isHidden else { return }
        write(option: hiddenOption, hide: true, fullscreen: false)
    }

    /// Puts the menu bar back the way it was before `hide`.
    private static func restore(_ store: ConfigStore) {
        guard store.config.menuBarBackupSaved else { return }
        if isHidden {
            write(option: store.config.menuBarBackupOption, hide: store.config.menuBarBackupHide,
                  fullscreen: store.config.menuBarBackupFullscreen)
        }
        store.config.menuBarBackupSaved = false
    }

    static func setHidden(_ on: Bool, _ store: ConfigStore) {
        store.config.hideMenuBar = on
        guard ModuleRegistry.shared.isRunning(.bar) else { return }
        if on { hide(store) } else { restore(store) }
    }

    /// At launch: re-applies the user's choice (it was restored on quit, or the OS reset it).
    static func applyOnLaunch(_ store: ConfigStore) {
        if store.config.hideMenuBar && !isHidden { hide(store) }
    }

    static func onBarStop(_ store: ConfigStore) {
        restore(store)
    }

    /// On quit: give the menu bar back so nobody is left without one.
    static func onQuit(_ store: ConfigStore) {
        if store.config.restoreMenuBarOnQuit { restore(store) }
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
        let domain: String
        let key: String
        /// ControlCenter modules are stored per host (18 shown / 24 not shown); the input menu is a plain Bool.
        let perHost: Bool
        let hiddenValue: Any
        let process: String
    }

    static var all: [Icon] { [
        Icon(id: "wifi", title: "Wi-Fi", note: tx("Cala already shows Wi-Fi.", "Cala ya muestra el Wi-Fi."), domain: "com.apple.controlcenter", key: "WiFi", perHost: true, hiddenValue: 24, process: "ControlCenter"),
        Icon(id: "battery", title: tx("Battery", "Batería"), note: tx("Cala already shows the battery.", "Cala ya muestra la batería."), domain: "com.apple.controlcenter", key: "Battery", perHost: true, hiddenValue: 24, process: "ControlCenter"),
        Icon(id: "user", title: tx("Fast User Switching", "Cambio rápido de usuario"), note: tx("Cala already lets you switch users.", "Cala ya permite cambiar de usuario."), domain: "com.apple.controlcenter", key: "UserSwitcher", perHost: true, hiddenValue: 24, process: "ControlCenter"),
        Icon(id: "input", title: tx("Keyboard language", "Idioma del teclado"), note: tx("The text icon (for example EN). Cala also shows it if you have several keyboards.", "El icono de texto (por ejemplo ES). Cala también lo muestra si tienes varios teclados."), domain: "com.apple.TextInputMenu", key: "visible", perHost: false, hiddenValue: false, process: "SystemUIServer"),
    ] }

    private static func host(_ icon: Icon) -> CFString { icon.perHost ? kCFPreferencesCurrentHost : kCFPreferencesAnyHost }

    private static func current(_ icon: Icon) -> String? {
        guard let v = CFPreferencesCopyValue(icon.key as CFString, icon.domain as CFString, kCFPreferencesCurrentUser, host(icon)) else { return nil }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }
    private static func isHiddenValue(_ icon: Icon, _ v: String?) -> Bool {
        guard let v else { return false }
        return icon.perHost ? v == String(icon.hiddenValue as! Int) : (v == "0")
    }

    private static func write(_ icon: Icon, _ value: String?) {
        let object: CFPropertyList? = value.flatMap { v in
            icon.perHost ? Int(v).map { $0 as CFNumber } : (v == "1" || v == "0" ? ((v == "1") as CFBoolean) : nil)
        }
        CFPreferencesSetValue(icon.key as CFString, object, icon.domain as CFString, kCFPreferencesCurrentUser, host(icon))
        CFPreferencesSynchronize(icon.domain as CFString, kCFPreferencesCurrentUser, host(icon))
    }

    private static func restart(_ processes: Set<String>) {
        for name in processes.sorted() {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            p.arguments = [name]
            try? p.run()
            p.waitUntilExit()
        }
    }

    private static func hide(_ icon: Icon) {
        let value: String = icon.perHost ? String(icon.hiddenValue as! Int) : "0"
        write(icon, value)
    }

    /// Makes the menu bar match the user's choice, remembering each icon's original value ("nil" = key absent).
    static func apply(_ store: ConfigStore) {
        guard ModuleRegistry.shared.isRunning(.tray) else { return }
        var restart_ = Set<String>()
        var backup = store.config.menuBarIconBackupV2
        let known = Set(all.map(\.id))
        let hidden = Set(store.config.menuBarHiddenIcons).intersection(known)
        for icon in all {
            if hidden.contains(icon.id) {
                if backup[icon.id] == nil { backup[icon.id] = current(icon) ?? "nil" }
                if !isHiddenValue(icon, current(icon)) { hide(icon); restart_.insert(icon.process) }
            } else if let original = backup[icon.id] {
                write(icon, original == "nil" ? nil : original)
                backup[icon.id] = nil
                restart_.insert(icon.process)
            }
        }
        if backup != store.config.menuBarIconBackupV2 { store.config.menuBarIconBackupV2 = backup }
        if !restart_.isEmpty { restart(restart_); log("menubar: icons hidden=\(hidden.sorted())") }
    }

    /// On quit: show everything again, if the user asked for that.
    static func onQuit(_ store: ConfigStore) {
        if store.config.restoreMenuBarOnQuit { restoreForTrayStop(store) }
    }

    /// Restore backed-up overrides and keep the user's selection for the next start.
    static func restoreForTrayStop(_ store: ConfigStore) {
        guard !store.config.menuBarIconBackupV2.isEmpty else { return }
        var processes = Set<String>()
        for icon in all {
            guard let saved = store.config.menuBarIconBackupV2[icon.id] else { continue }
            let original = saved == "nil" ? nil : saved
            let value = current(icon)
            guard value != original, isHiddenValue(icon, value) else { continue }
            write(icon, original)
            processes.insert(icon.process)
        }
        store.config.menuBarIconBackupV2 = [:]
        if !processes.isEmpty { restart(processes) }
    }
}

/// Lists the icons currently on the right of the menu bar and which app owns each one, through Accessibility
/// (`AXExtrasMenuBar`). Trigger it from a terminal with `notifyutil -p local.cala.listMenuBarExtras`; the result goes to
/// the debug log (`menubar-extra:` lines). Useful to find out which app an unknown icon belongs to.
enum MenuBarDiagnostics {
    static func install() {
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, _, _, _ in
            DispatchQueue.global(qos: .utility).async { MenuBarDiagnostics.dump() }
        }, "local.cala.listMenuBarExtras" as CFString, nil, .deliverImmediately)
        // Same idea for the report window: `notifyutil -p local.cala.openFeedback` (handy to test it without the menu).
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, _, _, _ in
            DispatchQueue.main.async { FeedbackWindowController.shared.show() }
        }, "local.cala.openFeedback" as CFString, nil, .deliverImmediately)
    }

    private static func string(_ e: AXUIElement, _ attr: String) -> String {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success, let s = v as? String else { return "" }
        return s
    }
    private static func point(_ e: AXUIElement, _ attr: String) -> CGPoint? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success,
              let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
    }

    struct Extra: Identifiable {
        let id: String
        let app: String
        let bundle: String
        let detail: String
    }

    @MainActor
    static func screenGeometry() -> MenuBarGeometry {
        let screens = NSScreen.screens.map { screen in
            let frame = screen.frame
            return MenuBarGeometry.Screen(
                frame: frame,
                menuBarHeight: frame.maxY - screen.visibleFrame.maxY,
                unobscuredTopAreas: [screen.auxiliaryTopLeftArea, screen.auxiliaryTopRightArea].compactMap { $0 }
            )
        }
        return MenuBarGeometry(screens: screens, fallbackHeight: NSStatusBar.system.thickness)
    }

    /// Icons from apps other than Control Center (which Cala handles above), in menu bar order.
    static func extras(in geometry: MenuBarGeometry) -> [Extra] {
        var out: [(x: CGFloat, e: Extra)] = []
        for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier != "com.apple.controlcenter" {
            let el = AXUIElementCreateApplication(app.processIdentifier)
            var bar: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, "AXExtrasMenuBar" as CFString, &bar) == .success, let bar else { continue }
            var kids: CFTypeRef?
            guard AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &kids) == .success, let list = kids as? [AXUIElement] else { continue }
            for (i, item) in list.enumerated() {
                guard let p = point(item, kAXPositionAttribute),
                      geometry.contains(p) else { continue }
                let bundle = app.bundleIdentifier ?? "?"
                let name = bundle == "com.apple.TextInputMenuAgent" ? tx("Keyboard language", "Idioma del teclado") : (app.localizedName ?? bundle)
                out.append((p.x, Extra(id: "\(bundle)#\(i)", app: name, bundle: bundle, detail: string(item, kAXDescriptionAttribute))))
            }
        }
        return out.sorted { $0.x < $1.x }.map(\.e)
    }

    static func dump() {
        var found = 0
        for app in NSWorkspace.shared.runningApplications {
            let el = AXUIElementCreateApplication(app.processIdentifier)
            var bar: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, "AXExtrasMenuBar" as CFString, &bar) == .success, let bar else { continue }
            var kids: CFTypeRef?
            guard AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &kids) == .success, let list = kids as? [AXUIElement] else { continue }
            for item in list {
                let x = point(item, kAXPositionAttribute).map { String(Int($0.x)) } ?? "?"
                log("menubar-extra: x=\(x) app=\(app.localizedName ?? "?") (\(app.bundleIdentifier ?? "?")) title=\(string(item, kAXTitleAttribute)) desc=\(string(item, kAXDescriptionAttribute)) id=\(string(item, "AXIdentifier"))")
                found += 1
            }
        }
        log("menubar-extra: \(found) items listed")
    }
}

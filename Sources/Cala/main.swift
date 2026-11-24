import AppKit
import SwiftUI
import Darwin

func CGSMainConnectionID() -> Int32 {
    typealias MainConnection = @convention(c) () -> Int32
    guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY) else { return 0 }
    defer { dlclose(handle) }
    guard let symbol = dlsym(handle, "CGSMainConnectionID") else { return 0 }
    return unsafeBitCast(symbol, to: MainConnection.self)()
}

final class BlockItem: NSMenuItem {
    var block: (() -> Void)?
    convenience init(_ title: String, checked: Bool = false, _ block: @escaping () -> Void) {
        self.init(title: title, action: #selector(run), keyEquivalent: "")
        self.target = self
        self.block = block
        self.state = checked ? .on : .off
    }
    @objc func run() { block?() }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let registry = ModuleRegistry.shared
    private let store = ConfigStore.shared
    private var terminationSource: DispatchSourceSignal?
    var bar: BarController? { registry.bar.controller }
    var tray: TrayModule { registry.tray }

    /// Opening the app again while it is running (Finder, Launchpad, Spotlight) shows the settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show(); return true
    }

    func applicationWillTerminate(_ n: Notification) {
        registry.shutdown()
        terminationSource?.cancel()
        terminationSource = nil
        Watchdog.cleanExit()
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        ZoneEditor.install()
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            // Renders before any module starts: no bar, tap, Dock or menu-bar change while taking pictures.
            Snapshots.render(to: CommandLine.arguments[i + 1])
            exit(0)
        }
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            // A sheet or a modal alert makes AppKit refuse to quit, which left Cala running after a SIGTERM (an
            // installer, a logout script, `pkill`). Close them first, then quit normally so Dock and menu bar are restored.
            log("signal: SIGTERM, quitting")
            if NSApp.modalWindow != nil { NSApp.abortModal() }
            for window in NSApp.windows { if let sheet = window.attachedSheet { window.endSheet(sheet) } }
            DispatchQueue.main.async { NSApp.terminate(nil) }
            // If AppKit still refuses (a SwiftUI sheet can keep it busy), do the same cleanup and exit anyway.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                log("signal: quit was refused, exiting after cleanup")
                self?.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
                exit(0)
            }
        }
        terminationSource = source
        source.resume()
        LoginItem.migrateLegacy()
        Watchdog.start(store: store)
        let modules = registry.launch(onboardingCompleted: OnboardingWindowController.completed,
                                      onboardingPending: OnboardingWindowController.pending, axTrusted: AXIsProcessTrusted())
        MenuBarDiagnostics.install()
        // `notifyutil -p local.cala.openSystemPanel` opens the CPU panel while the tray is running.
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(), { _, observer, _, _, _ in
            guard let observer else { return }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(observer).takeUnretainedValue()
            DispatchQueue.main.async { delegate.tray.openSystemPanel() }
        }, "local.cala.openSystemPanel" as CFString, nil, .deliverImmediately)
        CrashReporter.checkAtLaunch(store: store)

        // Usage and mail can prompt for Keychain access, so let the welcome finish first.
        let onboarding = OnboardingWindowController.shared
        onboarding.onFinish = { [weak self] in
            guard let self, !self.registry.isShuttingDown else { return }
            self.tray.finishOnboarding()
        }
        if !onboarding.showIfNeeded(modules.needsOnboarding) {
            onboarding.onFinish = nil
            tray.finishOnboarding()
        }
        if CommandLine.arguments.contains("--settings") { SettingsWindowController.shared.show() }
    }

}

/// `Cala --snapshot <dir>`: every Settings pane in the current language (the Zones pane reads zones.json directly for
/// its per-monitor layout menus; no module starts), the General and Zones panes and the welcome's module question and zones-only permission page in English
/// and Spanish, plus the zones editor (`zones-editor-en/es`, and `zones-editor-light-en/es` in the Snow theme) at 1512 × 982, as 2x PNGs. Views are drawn through an offscreen NSHostingView so AppKit controls (switches, menus,
/// sliders) render as they do on screen.
@MainActor
enum Snapshots {
    private final class Window: NSWindow {
        override var backingScaleFactor: CGFloat { 2 }
    }

    static func render(to dir: String) {
        func write<V: View>(_ view: V, _ name: String, width: CGFloat) {
            let host = NSHostingView(rootView: view.frame(width: width, alignment: .leading)
                .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light)
                .environment(\.controlActiveState, .active))
            let window = Window(contentRect: CGRect(x: 0, y: 0, width: width, height: 100), styleMask: .borderless,
                                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = host
            let size = host.fittingSize
            window.setContentSize(size)
            host.frame = CGRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            defer { window.close() }
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let data = bitmap.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
            }
        }
        func pane(_ p: SettingsPane) -> some View {
            VStack(alignment: .leading, spacing: 26) { Text(p.title).font(.system(size: 28, weight: .bold)); PaneBody(pane: p, store: ConfigStore.shared) }
                .padding(34)
        }
        // No module is started (no bar, no event tap): the Zones pane reads zones.json directly for its layout menus.
        ZonesSettingsPane.snapshotStore = try? ZonesStore(templateName: ZonesModule.templateName)
        defer { ZonesSettingsPane.snapshotStore = nil }
        for p in SettingsPane.allCases { write(pane(p), p.rawValue, width: 640) }
        let language = appLanguageOverride
        for code in ["en", "es"] {
            appLanguageOverride = code
            write(OnboardingView(finish: {}, step: .modules), "onboarding-modules-\(code)", width: 600)
            write(OnboardingView(finish: {}, step: .essentials, bar: false, zones: true), "onboarding-essentials-zones-\(code)", width: 600)
            write(pane(.general), "general-\(code)", width: 640)
            write(pane(.zones), "zones-\(code)", width: 640)
            try? ZoneEditor.renderSnapshot(to: URL(fileURLWithPath: "\(dir)/zones-editor-\(code).png"),
                                           size: CGSize(width: 1512, height: 982), scale: 2)
            try? ZoneEditor.renderSnapshot(to: URL(fileURLWithPath: "\(dir)/zones-editor-light-\(code).png"),
                                           size: CGSize(width: 1512, height: 982), scale: 2, theme: "snow")
        }
        appLanguageOverride = language
    }
}

/// The system's app grid: "Apps" on macOS 26, Launchpad before it. Finder's Applications folder as a last resort.
func openAppLauncher() {
    let fm = FileManager.default
    for path in ["/System/Applications/Apps.app", "/System/Applications/Launchpad.app", "/Applications/Launchpad.app"] where fm.fileExists(atPath: path) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path)); return
    }
    NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications", isDirectory: true))
}

let app = NSApplication.shared
// QA builds (CALA_QA_REGULAR=1 in build.sh) run as a regular app so UI-automation tools can see and drive it.
app.setActivationPolicy(Bundle.main.object(forInfoDictionaryKey: "CalaQARegular") as? Bool == true ? .regular : .accessory)
#if DEBUG
if let index = CommandLine.arguments.firstIndex(of: "--render-system"), index + 1 < CommandLine.arguments.count {
    let dir = CommandLine.arguments[index + 1]
    DispatchQueue.main.async { SystemRender.run(dir: dir) }
    app.run()
}
#endif
let delegate = AppDelegate()
app.delegate = delegate
app.run()

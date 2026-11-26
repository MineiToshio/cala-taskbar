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
    private let updates = BundleUpdateMonitor()
    var bar: BarController? { registry.bar.controller }
    var tray: TrayModule { registry.tray }

    /// Opening the app again while it is running (Finder, Launchpad, Spotlight) shows the settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show(); return true
    }

    func applicationWillTerminate(_ n: Notification) {
        UpdateService.shared.stop()
        updates.stop()
        registry.shutdown()
        terminationSource?.cancel()
        terminationSource = nil
        Watchdog.cleanExit()
        Relaunch.openAfterTermination()
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        #if CALA_UPDATE_TEST
        if Bundle.main.object(forInfoDictionaryKey: "CalaUpdateTest") as? Bool == true,
           Bundle.main.object(forInfoDictionaryKey: "CalaUpdateTestCrashAtLaunch") as? Bool == true {
            abort()
        }
        #endif
        ZoneEditor.install()
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
        LoginItem.rebindAfterMove()
        Watchdog.start(store: store)
        let axTrusted = AXIsProcessTrusted()
        let modules = registry.launch(onboardingCompleted: OnboardingWindowController.completed,
                                      onboardingPending: OnboardingWindowController.pending, axTrusted: axTrusted)
        DispatchQueue.global(qos: .utility).async {
            log("launch: version=\(Telemetry.appVersion()) accessibility=\(axTrusted) screenRecording=\(CGPreflightScreenCaptureAccess())")
        }
        UpdateService.shared.start(store: store)
        UsageService.shared.finishStatusLineCleanup(config: store.config)
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
        updates.start()
    }

}

/// `Cala --snapshot <dir>`: each Settings page by ID, plus off-module variants. The Zones page reads zones.json
/// without starting the module. Also renders the full Settings window at both supported sizes, and the General
/// and Zones panes and welcome steps in English
/// and Spanish, the welcome's last page with "How to use Zones" (`onboarding-ready-zones*`), the drag-time layout strip
/// (`zones-strip-pill|expanded-light|dark-<lang>`), plus the zones editor (`zones-editor-en/es`, and `zones-editor-light-en/es` in the Snow theme) at 1512 × 982, as 2x PNGs. Views are drawn through an offscreen NSHostingView so AppKit controls (switches, menus,
/// sliders) render as they do on screen.
@MainActor
enum Snapshots {
    private final class Window: NSWindow {
        override var backingScaleFactor: CGFloat { 2 }
    }

    static func render(to dir: String) {
        func write<V: View>(_ view: V, _ name: String, width: CGFloat, height: CGFloat? = nil) {
            let host = NSHostingView(rootView: view.frame(width: width, height: height, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light)
                .environment(\.controlActiveState, .active))
            let window = Window(contentRect: CGRect(x: 0, y: 0, width: width, height: height ?? 100),
                                styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = host
            defer { window.close() }

            let size = height.map { CGSize(width: width, height: $0) } ?? host.fittingSize
            window.setContentSize(size)
            host.frame = CGRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            if height != nil {
                // The full Settings view contains two scroll views. Give SwiftUI a turn to lay out
                // their hosted content at the final size before caching the host itself.
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
            }
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let data = bitmap.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
            }
        }
        let enabled = ModuleSet(bar: true, switcher: true, tray: true, zones: true)
        // Capture display state without starting any modules or changing config.json.
        let store = ConfigStore.shared
        let zones = try? ZonesStore(templateName: ZonesModule.templateName, readOnly: true)
        let layouts = zones?.state ?? ZoneTemplates.seedState()
        let mail = MailService.snapshot()
        func pane(_ p: SettingsPane, modules: ModuleSet? = nil, ready: Bool = true, language: String? = nil,
                  update: UpdateSettingsSnapshot = UpdateSettingsSnapshot(state: .idle, ready: false)) -> some View {
            SettingsPage(pane: p, store: store, open: { _ in }, openDetail: { _ in })
                .environment(\.settingsSnapshot, SettingsSnapshot(modules: modules ?? enabled, ready: ready, language: language,
                                                                 layouts: layouts, mail: mail, update: update))
                .padding(34)
        }
        for p in SettingsPane.pages { write(pane(p), p.id, width: 640) }
        write(pane(.switcher, ready: false), "switcher-starting", width: 640)
        write(pane(.switcher, modules: ModuleSet.none), "switcher-off", width: 640)
        write(pane(.tray, modules: ModuleSet(bar: true, switcher: true, tray: false, zones: true)), "tray-off", width: 640)
        write(pane(.tray, modules: ModuleSet(bar: false, switcher: true, tray: true, zones: true)), "tray-bar-off", width: 640)
        func detail(_ page: SettingsDetail, origin: SettingsPane? = nil, modules: ModuleSet? = nil) -> some View {
            SettingsDetailPage(detail: page, origin: origin ?? page.home, store: store, back: {})
                .environment(\.settingsSnapshot, SettingsSnapshot(modules: modules ?? enabled, layouts: layouts, mail: mail))
                .padding(34)
        }
        write(detail(.cpuMemory), "tray-detail-cpu", width: 640)
        write(detail(.disk), "tray-detail-disk", width: 640)
        write(detail(.mail, origin: .tray), "tray-detail-mail", width: 640)
        write(detail(.mail), "integrations-mail", width: 640)
        write(detail(.calendar), "integrations-calendar", width: 640)
        write(detail(.usage), "integrations-usage", width: 640)
        write(detail(.cpuMemory, modules: ModuleSet.none), "tray-detail-cpu-off", width: 640)

        let window = SettingsView(store: store, navigation: SettingsNavigation())
            .environment(\.settingsSnapshot, SettingsSnapshot(modules: enabled, layouts: layouts, mail: mail))
        let defaultSize = SettingsWindowController.defaultSize
        let minimumSize = SettingsWindowController.minimumSize
        write(window, "settings-window", width: defaultSize.width, height: defaultSize.height)
        let minimumNavigation = SettingsNavigation()
        minimumNavigation.select(.mail)
        let minimumWindow = SettingsView(store: store, navigation: minimumNavigation)
            .environment(\.settingsSnapshot, SettingsSnapshot(modules: enabled, layouts: layouts, mail: mail))
        write(minimumWindow, "settings-window-min", width: minimumSize.width, height: minimumSize.height)
        let fixture = UpdateManifest(schema: 1, bundleId: "local.cala", version: "1.1.0", build: 131,
                                     minimumSystemVersion: "14.0", publishedAt: Date(timeIntervalSince1970: 1_796_117_200),
                                     dmg: .init(url: UpdateService.releases, size: 6_123_456, sha256: ""),
                                     app: .init(unpackedSize: 21_000_000, keychainHelperSHA256: ""),
                                     notes: ["en": "Improved window previews and more reliable keyboard shortcuts.",
                                             "es": "Vistas previas mejoradas y atajos de teclado más fiables."],
                                     notesURL: UpdateService.releases)
        let updateStates: [(String, UpdateState)] = [
            ("idle", .idle), ("checking", .checking), ("up-to-date", .upToDate(fixture.publishedAt)),
            ("available", .available(fixture.version)), ("skipped", .skipped(fixture.version)),
            ("downloading", .downloading(42)), ("verifying", .verifying), ("installing", .installing),
            ("pending-restart", .pendingRestart(UpdatePolicy.Blocker.zonesEditor.rawValue)),
            ("rolled-back", .rolledBack(fixture.version, "1.0.0")), ("offline", .offline),
            ("feed-unavailable", .feedUnavailable), ("verification-failed", .verificationFailed),
            ("disk-full", .diskFull(154_000_000)), ("busy", .busy), ("blocked-by-macos", .blockedByMacOS),
            ("needs-admin", .needsAdmin), ("needs-newer-macos", .needsNewerMacOS(fixture.version, "26.0")),
            ("manual-install", .manualInstall), ("unsupported", .unsupported), ("unavailable", .unavailable),
            ("failed", .failed), ("restart-failed", .restartFailed)
        ]
        let language = appLanguageOverride
        for code in ["en", "es"] {
            appLanguageOverride = code
            write(OnboardingView(finish: {}, step: .modules), "onboarding-modules-\(code)", width: 600)
            write(OnboardingView(finish: {}, step: .essentials, bar: false, zones: true), "onboarding-essentials-zones-\(code)", width: 600)
            write(OnboardingView(finish: {}, step: .ready, bar: false, zones: true), "onboarding-ready-zones-\(code)", width: 600)
            write(OnboardingView(finish: {}, step: .ready, bar: true, zones: true), "onboarding-ready-bar-zones-\(code)", width: 600)
            write(pane(.general, language: code), "general-\(code)", width: 640)
            write(pane(.zones), "zones-\(code)", width: 640)
            for (name, state) in updateStates {
                let ready = ![UpdateState.needsAdmin, .unsupported].contains(state)
                let offer = state.isInstallOffer || state == .offline ? fixture : nil
                let update = UpdateSettingsSnapshot(state: state, offer: offer, ready: ready)
                write(pane(.help, update: update), "update-\(name)-\(code)", width: 640)
            }
            let availableUpdate = UpdateSettingsSnapshot(state: .available(fixture.version), offer: fixture)
            write(UpdateWindowView(service: .shared, store: store, snapshot: availableUpdate),
                  "update-window-\(code)", width: 420, height: 380)
            let updateNavigation = SettingsNavigation()
            updateNavigation.select(.help)
            let updateSettings = SettingsView(store: store, navigation: updateNavigation)
                .environment(\.settingsSnapshot, SettingsSnapshot(modules: enabled, layouts: layouts, mail: mail, update: availableUpdate))
            write(updateSettings, "update-settings-window-\(code)", width: defaultSize.width, height: defaultSize.height)
            if let store = zones {
                // The drag-time layout strip as it draws on screen: the collapsed pill and the open strip.
                let layouts = store.state.layouts
                let screen = NSScreen.screens.first?.frame ?? CGRect(x: 0, y: 0, width: 1512, height: 982)
                let key = NSScreen.screens.first.map { ZonesModule.displayKey($0, keys: ZoneDisplays.keys(for: NSScreen.screens)) } ?? ""
                let active = store.layout(forDisplay: key)?.id ?? layouts.first?.id
                let accent = ZoneOverlay.accent(theme: ConfigStore.shared.config.theme)
                let entries = layouts.map { layout in
                    ZoneLayoutStrip.Entry(id: layout.id, name: ZoneEditorSession.displayName(layout),
                                          picture: ZoneThumbnailRenderer.image(layout.zones, aspect: ZoneThumbnailRenderer.aspect(of: screen),
                                                                               fitting: ZoneStripGeometry.picture, accent: accent))
                }
                let current = layouts.firstIndex { $0.id == active }
                for (expanded, dark) in [(false, false), (false, true), (true, false), (true, true)] {
                    ZoneLayoutStrip.renderSnapshot(entries: entries, current: current, expanded: expanded, accent: accent, dark: dark,
                                                   to: URL(fileURLWithPath: "\(dir)/zones-strip-\(expanded ? "expanded" : "pill")-\(dark ? "dark" : "light")-\(code).png"))
                }
            }
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
if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), index + 1 < CommandLine.arguments.count {
    // Snapshots need AppKit layout, but can render before Launch Services starts the application lifecycle.
    MainActor.assumeIsolated { Snapshots.render(to: CommandLine.arguments[index + 1]) }
    exit(0)
}
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

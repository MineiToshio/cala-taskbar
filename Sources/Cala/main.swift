import AppKit
import SwiftUI
import Combine
import ScreenCaptureKit
import CoreWLAN
import Darwin

func CGSMainConnectionID() -> Int32 {
    typealias MainConnection = @convention(c) () -> Int32
    guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY) else { return 0 }
    defer { dlclose(handle) }
    guard let symbol = dlsym(handle, "CGSMainConnectionID") else { return 0 }
    return unsafeBitCast(symbol, to: MainConnection.self)()
}

private func enableBackgroundCursor() {
    typealias MainConnection = @convention(c) () -> Int32
    typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
    guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY) else { return }
    defer { dlclose(handle) }
    guard let mainSymbol = dlsym(handle, "CGSMainConnectionID"),
          let propertySymbol = dlsym(handle, "CGSSetConnectionProperty") else { return }
    let connection = unsafeBitCast(mainSymbol, to: MainConnection.self)()
    let setProperty = unsafeBitCast(propertySymbol, to: SetProperty.self)
    _ = setProperty(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
}

final class BarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
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

final class VolumeSlider: NSView {
    let slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    let onChange: (Float) -> Void
    init(volume: Float, muted: Bool, onChange: @escaping (Float) -> Void) {
        self.onChange = onChange
        super.init(frame: NSRect(x: 0, y: 0, width: 230, height: 34))
        let lo = NSImageView(image: NSImage(systemSymbolName: "speaker.fill", accessibilityDescription: nil)!)
        let hi = NSImageView(image: NSImage(systemSymbolName: "speaker.wave.3.fill", accessibilityDescription: nil)!)
        lo.frame = NSRect(x: 12, y: 9, width: 16, height: 16)
        hi.frame = NSRect(x: 202, y: 9, width: 20, height: 16)
        slider.frame = NSRect(x: 34, y: 7, width: 164, height: 20)
        slider.doubleValue = muted ? 0 : Double(volume)
        slider.isContinuous = true
        slider.target = self; slider.action = #selector(changed)
        [lo, hi, slider].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc func changed() { onChange(Float(slider.doubleValue)) }
}

final class Bar {
    var screen: NSScreen
    let primary: Bool
    let panel: BarPanel
    var frames: [String: CGRect] = [:]
    var hidden = false
    var lastInside = Date()

    init(screen: NSScreen, primary: Bool, model: TaskbarModel, store: ConfigStore) {
        self.screen = screen
        self.primary = primary
        panel = BarPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: BarView(model: model, store: store, showTray: true, screenKey: screen.key,
                                                            onFrames: { [weak self] in self?.frames = $0 }))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = ConfigStore.shared
    lazy var model = TaskbarModel(store: store)
    var bars: [Bar] = []
    var hoverBar: Bar?
    var overlayBar: Bar?
    let preview = PreviewController()
    lazy var flyout = FlyoutController(model: model)
    var bag = Set<AnyCancellable>()
    var lastHover = Date.distantPast
    var hoverID: String?
    var lastBadge = Date.distantPast
    var lastReserve = Date.distantPast
    var lastTray = Date.distantPast
    var lastCalendar = Date.distantPast
    var lastMonitor = Date.distantPast
    var windowsInFlight = false
    var badgesInFlight = false
    var terminationSource: DispatchSourceSignal?
    var failedResizeIDs = Set<CGWindowID>()

    /// Opening the app again while it is running (Finder, Launchpad, Spotlight) shows the settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show(); return true
    }

    func applicationWillTerminate(_ n: Notification) { DockControl.onQuit(store) }

    func applicationDidFinishLaunching(_ n: Notification) {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        terminationSource = source
        source.resume()
        LoginItem.migrateLegacy()
        DockControl.applyOnLaunch(store)
        WindowSwitcher.shared.ensureTap()
        MinimizeWatcher.shared.start()
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in WindowSwitcher.shared.ensureTap(); MinimizeWatcher.shared.sync() }
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        enableBackgroundCursor()
        WifiInfo.shared.requestLocation()
        WifiInfo.shared.scan()

        rebuildBars()
        let usageVisible = !store.config.autoHide || bars.contains(where: { !$0.hidden })
        UsageService.shared.start(store: store, visible: usageVisible)
        UsagePace.shared.start(store: store)
        if usageVisible { UsageService.shared.refresh() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, !self.store.config.autoHide || self.bars.contains(where: { !$0.hidden }) else { return }
            UsageService.shared.refresh()
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.rebuildBars() }
        }

        store.$config.receive(on: DispatchQueue.main).sink { [weak self] _ in
            DispatchQueue.main.async { self?.layoutAll(animated: false) }
        }.store(in: &bag)

        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] e in
            guard let self, self.bars.contains(where: { $0.panel === e.window }) else { return e }
            // Left press on an app icon: wait for mouse-up so it can become a drag.
            if e.type == .leftMouseDown, let hi = self.hitInfo(NSEvent.mouseLocation),
               let id = hi.id, self.model.items.contains(where: { $0.id == id }) {
                self.pressed = (id, hi.bar, NSEvent.mouseLocation.x, e)
                self.grab = NSEvent.mouseLocation.x - self.iconCenterX(hi.bar, id, fallback: NSEvent.mouseLocation.x)
                self.dragging = false
                return nil
            }
            self.handleClick(e)
            return nil
        }
        NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [weak self] e in
            guard let self, e.buttonNumber == 2 else { return e }
            let m = NSEvent.mouseLocation
            if e.window === self.preview.panel { self.preview.middleClick(m); return nil }
            guard self.bars.contains(where: { $0.panel === e.window }),
                  let id = self.hitInfo(m)?.id, let item = self.model.items.first(where: { $0.id == id }) else { return e }
            self.preview.commitPeek()
            self.preview.hide()
            if let pid = item.pid { newWindow(pid: pid) } else { self.model.click(item) }
            return nil
        }
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDragged) { [weak self] e in
            guard let self, let p = self.pressed else { return e }
            let m = NSEvent.mouseLocation
            if !self.dragging && abs(m.x - p.x) > 5 {
                self.dragging = true; self.preview.hide()
                self.model.dragScreen = p.bar.screen.key; self.model.dragID = p.id
            }
            if self.dragging {
                let lo = p.bar.panel.frame.minX
                self.model.dragX = min(max(m.x - self.grab - lo, 20), p.bar.panel.frame.width - 20)
            }
            if self.dragging, let hi = self.hitInfo(m), hi.bar === p.bar, let t = hi.id,
               t != p.id, self.model.items.contains(where: { $0.id == t }) {
                self.model.move(p.id, to: t)
            }
            return nil
        }
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] e in
            guard let self, let p = self.pressed else { return e }
            self.pressed = nil
            if self.dragging {
                self.dragging = false
                if let r = p.bar.frames[p.id] {
                    withAnimation(.easeOut(duration: 0.15)) { self.model.dragX = r.midX }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.17) { self.model.dragID = nil }
            } else { self.handleClick(p.event) }
            return nil
        }

        NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
            guard let self, self.bars.contains(where: { $0.panel === e.window }),
                  self.hitInfo(NSEvent.mouseLocation)?.id == trayVol else { return e }
            SystemTray.setVolume(self.model.volume + Float(e.scrollingDeltaY) * (e.hasPreciseScrollingDeltas ? 0.004 : 0.03))
            self.model.refreshTray()
            return nil
        }

        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in self?.tick() }
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            let dir = CommandLine.arguments[i + 1]
            for p in SettingsPane.allCases {
                let r = ImageRenderer(content: VStack(alignment: .leading, spacing: 26) { Text(p.title).font(.system(size: 28, weight: .bold)); PaneBody(pane: p, store: ConfigStore.shared) }.padding(34).frame(width: 640, alignment: .leading).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light))
                r.scale = 2
                if let img = r.nsImage, let t = img.tiffRepresentation, let b = NSBitmapImageRep(data: t)?.representation(using: .png, properties: [:]) {
                    try? b.write(to: URL(fileURLWithPath: "\(dir)/\(p.rawValue).png"))
                }
            }
            exit(0)
        }
        if CommandLine.arguments.contains("--settings") { SettingsWindowController.shared.show() }
    }

    func rebuildBars() {
        bars.forEach { $0.panel.orderOut(nil) }
        preview.hide(); flyout.hide()
        bars = NSScreen.screens.enumerated().map { i, sc in
            Bar(screen: sc, primary: i == 0, model: model, store: store)
        }
        layoutAll(animated: false)
        bars.forEach { $0.panel.orderFrontRegardless() }
    }

    func layoutAll(animated: Bool) { bars.forEach { layoutBar($0, animated: animated) } }

    func barFrame(_ b: Bar, hidden: Bool) -> NSRect {
        let f = b.screen.frame
        let h = store.barHeight
        return NSRect(x: f.minX, y: hidden ? f.minY - h : f.minY, width: f.width, height: h)
    }

    func layoutBar(_ b: Bar, animated: Bool) {
        if !store.config.autoHide { b.hidden = false }
        let target = barFrame(b, hidden: b.hidden)
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                b.panel.animator().setFrame(target, display: true)
            }
        } else {
            b.panel.setFrame(target, display: true)
        }
    }

    /// The bar under the mouse and the icon id (nil if over empty bar space).
    func hitInfo(_ m: NSPoint) -> (bar: Bar, id: String?)? {
        for b in bars where !b.hidden && barFrame(b, hidden: false).contains(m) {
            let lx = m.x - b.panel.frame.minX
            return (b, b.frames.first { $0.value.minX <= lx && lx <= $0.value.maxX }?.key)
        }
        return nil
    }

    func iconCenterX(_ b: Bar, _ id: String, fallback: CGFloat) -> CGFloat {
        guard let r = b.frames[id] else { return fallback }
        return b.panel.frame.minX + r.midX
    }

    func iconLeftX(_ b: Bar, _ id: String) -> CGFloat {
        b.panel.frame.minX + (b.frames[id]?.minX ?? 0)
    }

    var pressed: (id: String, bar: Bar, x: CGFloat, event: NSEvent)?
    var dragging = false
    var grab: CGFloat = 0

    func tick() {
        let m = NSEvent.mouseLocation
        let overPreview = preview.contains(m) || flyout.contains(m)
        if flyout.isVisible { flyout.refit() }

        if store.config.autoHide {
            for b in bars {
                let f = b.screen.frame
                let overBar = !b.hidden && barFrame(b, hidden: false).contains(m)
                let atEdge = f.contains(m) && m.y <= f.minY + 2
                if atEdge || overBar || (overPreview && overlayBar === b) {
                    b.lastInside = Date()
                    if b.hidden { b.hidden = false; layoutBar(b, animated: true) }
                } else if !b.hidden && Date().timeIntervalSince(b.lastInside) > 0.5 {
                    b.hidden = true
                    if overlayBar === b { preview.hide(); flyout.hide() }
                    layoutBar(b, animated: true)
                }
            }
        }

        UsageService.shared.visibility(visible: bars.contains(where: { !$0.hidden }), alwaysVisible: !store.config.autoHide)
        let hi = hitInfo(m)
        // Our panels never become key, so the cursor has to be set by hand.
        if dragging {
            NSCursor.closedHand.set()
        } else if overPreview {
            NSCursor.pointingHand.set()
        } else if let hi {
            (hi.id != nil ? NSCursor.pointingHand : NSCursor.arrow).set()
        }

        let id = hi?.id
        if id != hoverID || hi?.bar !== hoverBar {
            hoverID = id
            hoverBar = hi?.bar
            model.hoverSince = Date()
            model.startHover = (id == startID)
            model.deskHover = (id == deskID)
            model.trayHover = (id?.hasPrefix("__t_") == true) ? id : nil
            model.hovered = model.items.first { $0.id == id }
        }
        if dragging || model.dragID != nil { model.hovered = nil }
        if id != nil || overPreview { lastHover = Date() }

        if let h = model.hovered, let b = hoverBar {
            if preview.shownID != h.id || overlayBar !== b,
               Date().timeIntervalSince(model.hoverSince) >= store.config.previewDelay {
                overlayBar = b
                preview.show(item: h, barTop: barFrame(b, hidden: false).maxY, mouseX: iconCenterX(b, h.id, fallback: m.x), screen: b.screen)
            }
        } else if preview.isVisible, !overPreview, Date().timeIntervalSince(lastHover) > 0.3 {
            preview.hide()
        }

        if Date().timeIntervalSince(lastTray) > 3 { lastTray = Date(); model.refreshTray() }
        if store.config.monitorEnabled, Date().timeIntervalSince(lastMonitor) > 3 { lastMonitor = Date(); SystemMonitor.shared.tick() }
        if Date().timeIntervalSince(lastCalendar) > 60 { lastCalendar = Date(); CalendarService.shared.backgroundRefresh(config: store.config) }
        if Date().timeIntervalSince(lastBadge) > 2 {
            lastBadge = Date()
            if !windowsInFlight {
                windowsInFlight = true
                let pids = model.items.compactMap(\.pid)
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    let none = Set(pids.filter { AXIsProcessTrusted() && WindowService.windows(for: $0).isEmpty })
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.windowsInFlight = false
                        if self.model.windowless != none { self.model.windowless = none }
                    }
                }
            }
            if !badgesInFlight {
                badgesInFlight = true
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    let b = DockBadges.read()
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.badgesInFlight = false
                        if self.model.badges != b { self.model.badges = b }
                    }
                }
            }
        }
        if Date().timeIntervalSince(lastReserve) > 0.6 { lastReserve = Date(); reserveSpace() }
    }

    func handleClick(_ e: NSEvent) {
        let m = NSEvent.mouseLocation
        guard let hi = hitInfo(m) else { return }
        let id = hi.id, bar = hi.bar
        if e.type != .rightMouseDown, id == startID || id == deskID || model.items.contains(where: { $0.id == id }) {
            preview.commitPeek()
        }
        preview.hide()
        if !(id?.hasPrefix("__t_") ?? false) { flyout.hide() }
        let item = model.items.first { $0.id == id }
        if let id, id.hasPrefix("__t_") { trayClick(id, bar: bar); return }
        if e.type == .rightMouseDown {
            let menu = item.map(itemMenu) ?? settingsMenu()
            popUp(menu, x: id.map { iconLeftX(bar, $0) } ?? m.x, bar: bar)
        } else if id == deskID {
            toggleDesktop()
        } else if id == startID {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Apps.app"))
        } else if let item {
            if e.modifierFlags.contains(.shift), let pid = item.pid { newWindow(pid: pid) } else { model.click(item) }
        }
    }

    func trayClick(_ id: String, bar: Bar) {
        if id == trayJoin {
            flyout.hide()
            if let url = CalendarLogic.joinCandidate(CalendarService.shared.events, now: Date())?.joinURL { NSWorkspace.shared.open(url) }
            return
        }
        if flyout.isVisible && flyout.kind == id { flyout.hide(); return }
        model.refreshTray()
        overlayBar = bar
        flyout.show(kind: id, barTop: barFrame(bar, hidden: false).maxY,
                    centerX: iconCenterX(bar, id, fallback: NSEvent.mouseLocation.x), screen: bar.screen)
    }

    /// Windows minimized by "show desktop", and the app that was in front, so a second click restores them.
    var desktopMinimized: [WinRef] = []
    var desktopFront: pid_t?
    var desktopInProgress = false

    func toggleDesktop() {
        guard !desktopInProgress else { return }
        desktopInProgress = true
        // Default action: minimize every visible window of every regular app (thumbnails first).
        let me = ProcessInfo.processInfo.processIdentifier
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var found: [WinRef] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app.processIdentifier != me && !app.isHidden {
            found += WindowService.windows(for: app.processIdentifier).filter { !$0.minimized && $0.ax != nil }
        }
        let candidates = found
        let ids = candidates.map(\.id)
        Task {
            await WindowService.snapshot(ids)
            await MainActor.run {
                defer { self.desktopInProgress = false }
                var done: [WinRef] = []
                for w in candidates {
                    if let ax = w.ax, AXUIElementSetAttributeValue(ax, kAXMinimizedAttribute as CFString, kCFBooleanTrue) == .success { done.append(w) }
                }
                if !done.isEmpty {
                    if self.desktopMinimized.isEmpty { self.desktopFront = front }
                    let recorded = Set(self.desktopMinimized.map(\.id))
                    self.desktopMinimized += done.filter { !recorded.contains($0.id) }
                    log("desktop: minimized \(done.count) windows")
                    return
                }
                // Nothing left to minimize: the desktop is already clear, so bring back what the last click minimized.
                let wins = self.desktopMinimized
                self.desktopMinimized = []
                for w in wins {
                    guard let ax = w.ax else { continue }
                    let result = AXUIElementSetAttributeValue(ax, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                    if result != .success, result != .invalidUIElement { self.desktopMinimized.append(w) }
                }
                if let pid = self.desktopFront, let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated {
                    bringFront(app)
                }
                if self.desktopMinimized.isEmpty { self.desktopFront = nil }
                log("desktop: restored \(wins.count - self.desktopMinimized.count) windows")
            }
        }
    }

    /// With the bar always visible, keep the front window from sliding under it (main screen only).
    func reserveSpace() {
        guard !store.config.autoHide, let pb = bars.first(where: { $0.primary }), !pb.hidden,
              NSEvent.pressedMouseButtons == 0,
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let w = WindowService.focusedWindow(pid: app.processIdentifier),
              !WindowService.isFullScreen(w),
              let f = WindowService.frame(w) else { return }
        guard let first = NSScreen.screens.first else { return }
        let primary = first.frame
        guard f.minX >= primary.minX - 5, f.minX < primary.maxX else { return }
        let barTop = primary.height - store.barHeight
        if f.maxY > barTop + 1 && f.minY < barTop - 120 {
            var id: CGWindowID = 0
            guard _AXUIElementGetWindow(w, &id) == .success, id != 0, !failedResizeIDs.contains(id) else { return }
            let height = barTop - f.minY
            failedResizeIDs.insert(id)
            WindowService.setHeight(w, height, width: f.width)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                if let resized = WindowService.frame(w), abs(resized.height - height) <= 1 {
                    self?.failedResizeIDs.remove(id)
                }
            }
        }
    }

    func popUp(_ menu: NSMenu, x: CGFloat, bar: Bar) {
        let top = barFrame(bar, hidden: false).maxY + menu.size.height + 4
        menu.popUp(positioning: nil, at: NSPoint(x: x, y: top), in: nil)
    }

    func itemMenu(_ item: AppItem) -> NSMenu {
        let menu = NSMenu()
        if let pid = item.pid {
            let news = WindowService.newItems(pid: pid)
            for n in news {
                menu.addItem(BlockItem(n.title) { WindowService.press(n.el, pid: pid) })
            }
            if !news.isEmpty { menu.addItem(.separator()) }
        }
        if item.pid == nil, let url = item.url {
            menu.addItem(BlockItem("Abrir") {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            })
        }
        menu.addItem(BlockItem(item.pinned ? "Desanclar de la barra" : "Anclar a la barra") { [model] in
            model.togglePin(item)
        })
        if let url = item.url {
            menu.addItem(BlockItem("Mostrar en Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) })
        }
        if let pid = item.pid {
            menu.addItem(.separator())
            menu.addItem(BlockItem("Cerrar todas las ventanas") {
                WindowService.windows(for: pid).forEach(WindowService.close)
            })
            menu.addItem(BlockItem("Salir de \(item.name)") {
                NSRunningApplication(processIdentifier: pid)?.terminate()
            })
        }
        return menu
    }

    func settingsMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(BlockItem("Ocultar barra automáticamente", checked: store.config.autoHide) { [store] in
            store.config.autoHide.toggle()
        })
        let themes = NSMenu()
        for t in BarTheme.all {
            themes.addItem(BlockItem(t.name, checked: store.config.theme == t.id) { [store] in store.config.theme = t.id })
        }
        let themeItem = NSMenuItem(title: "Tema", action: nil, keyEquivalent: "")
        themeItem.submenu = themes
        menu.addItem(themeItem)
        let trans = NSMenu()
        for (label, v) in [("Ninguna", 1.0), ("Ligera", 0.82), ("Media", 0.62), ("Alta", 0.42), ("Muy alta", 0.22)] {
            trans.addItem(BlockItem(label, checked: abs(store.config.barOpacity - v) < 0.01) { [store] in store.config.barOpacity = v })
        }
        let transItem = NSMenuItem(title: "Transparencia", action: nil, keyEquivalent: "")
        transItem.submenu = trans
        menu.addItem(transItem)
        menu.addItem(.separator())
        menu.addItem(BlockItem("Configuración…") { SettingsWindowController.shared.show() })
        return menu
    }

}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()

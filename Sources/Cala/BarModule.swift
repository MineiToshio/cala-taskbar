import AppKit
import SwiftUI
import Combine

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

final class Bar {
    var screen: NSScreen
    let primary: Bool
    let panel: BarPanel
    var frames: [String: CGRect] = [:]
    var hidden = false
    /// systemUptime of the last moment the pointer was on (or revealing) this bar.
    var lastInside = ProcessInfo.processInfo.systemUptime
    /// Reveal / quick-hide state for the bottom edge (EdgeIntent).
    var edge = EdgeIntent.State()

    init(screen: NSScreen, primary: Bool, model: TaskbarModel, store: ConfigStore) {
        self.screen = screen
        self.primary = primary
        panel = BarPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: BarView(model: model, store: store, screenKey: screen.key,
                                                            onFrames: { [weak self] in self?.frames = $0 }))
    }
}

final class BarModule: CalaModule {
    let id = ModuleID.bar
    var isRunning: Bool { controller != nil }
    private(set) var controller: BarController?
    weak var tray: TrayModule?
    private let store: ConfigStore

    init(store: ConfigStore) { self.store = store }

    func start() {
        guard controller == nil else { return }
        DockControl.applyOnLaunch(store)
        MenuBarControl.applyOnLaunch(store)
        let controller = BarController(store: store, tray: tray)
        self.controller = controller
        controller.start()
    }

    func stop() {
        guard let controller else { return }
        self.controller = nil
        controller.stop()
        if ModuleRegistry.shared.isShuttingDown {
            DockControl.onQuit(store)
            MenuBarControl.onQuit(store)
        } else {
            DockControl.onBarStop(store)
            MenuBarControl.onBarStop(store)
        }
    }
}

/// A new controller owns each run so results from a previous run cannot update restarted bars.
final class BarController {
    let store: ConfigStore
    let model: TaskbarModel
    private(set) var bars: [Bar] = []
    private var hoverBar: Bar?
    var overlayBar: Bar?
    /// While the flyout is open this bar never auto-hides (PanelPolicy).
    var flyoutBar: Bar?
    private let run: ModuleCancellation
    private let preview: PreviewController
    private weak var tray: TrayModule?
    private var configObserver: AnyCancellable?
    private var screenObserver: NSObjectProtocol?
    private var monitors: [Any] = []
    /// Mouse-moved monitors feeding EdgeIntent's push detection; only installed while auto-hide is on.
    private var moveMonitors: [Any] = []
    /// NSEvent.timestamp (systemUptime) of the last mouse press anywhere: a click at the edge never reveals.
    private var lastPressAt: TimeInterval?
    private var lastTick = ProcessInfo.processInfo.systemUptime
    static let edgeConfig = EdgeIntent.Config()
    private var timer: Timer?
    private var screenUpdate: DispatchWorkItem?
    private var dragCleanup: DispatchWorkItem?
    private var desktopTask: Task<Void, Never>?
    private(set) var isRunning = false
    private var lastHover = Date.distantPast
    private var hoverID: String?
    private var lastBadge = Date.distantPast
    private var lastReserve = Date.distantPast
    private var windowsInFlight = false
    private var badgesInFlight = false
    private var failedResizeIDs = Set<CGWindowID>()
    /// Attention glow at the bottom edge while the bar is auto-hidden (see AttentionEdgeCue).
    private lazy var attentionEdge = AttentionEdgeCue { [weak self] in self?.attentionEdgeTargets() ?? [] }

    init(store: ConfigStore, tray: TrayModule?) {
        self.store = store
        self.tray = tray
        let run = ModuleCancellation()
        self.run = run
        model = TaskbarModel(store: store, run: run)
        preview = PreviewController(run: run)
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        enableBackgroundCursor()
        LaunchFeedback.shared.model = model
        rebuildBars()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.isRunning else { return }
            self.screenUpdate?.cancel()
            let update = DispatchWorkItem { [weak self] in self?.rebuildBars() }
            self.screenUpdate = update
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: update)
        }
        configObserver = store.$config.receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self, self.isRunning else { return }
            self.layoutAll(animated: false)
            self.syncMoveMonitors()
        }
        installMonitors()
        syncMoveMonitors()
        AppAttention.shared.start()
        attentionEdge.start()
        timer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in self?.tick() }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        run.cancel()
        timer?.invalidate()
        timer = nil
        AppAttention.shared.stop()
        attentionEdge.stop()
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        moveMonitors.forEach(NSEvent.removeMonitor)
        moveMonitors.removeAll()
        lastPressAt = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        configObserver?.cancel()
        configObserver = nil
        screenUpdate?.cancel()
        screenUpdate = nil
        dragCleanup?.cancel()
        dragCleanup = nil
        desktopTask?.cancel()
        desktopTask = nil
        model.teardown()
        preview.stop()
        closeFlyout()
        closeBars()
        hoverBar = nil; overlayBar = nil; pressed = nil; dragging = false
        desktopMinimized.removeAll()
        failedResizeIDs.removeAll()
        LaunchFeedback.shared.stopAll()
    }

    private func closeBars() {
        for bar in bars {
            bar.panel.close()
            bar.panel.contentView = nil
        }
        bars.removeAll()
    }

    private func addMonitor(_ mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> NSEvent?) {
        if let token = NSEvent.addLocalMonitorForEvents(matching: mask, handler: handler) { monitors.append(token) }
    }

    /// Global monitors see events sent to other apps; their tokens live in `monitors` with the local ones.
    private func addGlobalMonitor(_ mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> Void) {
        if let token = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler) { monitors.append(token) }
    }

    /// Stamped on arrival with systemUptime, the clock EdgeIntent's anchors use, rather than trusting e.timestamp.
    private func notePress(_ e: NSEvent) { lastPressAt = ProcessInfo.processInfo.systemUptime }

    /// Push detection needs every mouse move, not just the 30 ms polls; only while auto-hide is on.
    private func syncMoveMonitors() {
        let want = isRunning && store.config.autoHide
        if want == !moveMonitors.isEmpty { return }
        if !want {
            moveMonitors.forEach(NSEvent.removeMonitor)
            moveMonitors.removeAll()
            return
        }
        // Auto-hide just turned on (or the bar started): every bar gets the full delay from now, not an instant hide.
        let now = ProcessInfo.processInfo.systemUptime
        for b in bars { b.lastInside = now }
        if let token = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] e in self?.noteMove(e) }) {
            moveMonitors.append(token)
        }
        if let token = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] e in self?.noteMove(e); return e }) {
            moveMonitors.append(token)
        }
    }

    /// O(bars). NSEvent.deltaY for mouse moves is the raw CGEvent kCGMouseEventDeltaY, passed through unflipped
    /// (checked: a CGEvent with kCGMouseEventDeltaY = 5 gives NSEvent.deltaY == 5 while its location is flipped).
    /// CG uses global display coordinates with the origin at the top-left and y growing downward, so a positive
    /// deltaY is a move DOWN. It is the device delta, so it keeps reporting while the cursor is clamped at the edge.
    private func noteMove(_ e: NSEvent) {
        guard isRunning, store.config.autoHide else { return }
        let m = NSEvent.mouseLocation
        let buttons = NSEvent.pressedMouseButtons
        let now = ProcessInfo.processInfo.systemUptime // one clock with the polls (see notePress)
        for (i, b) in bars.enumerated() where b.hidden {
            let f = b.screen.frame
            guard m.x >= f.minX, m.x < f.maxX else { continue }
            let screen = EdgeIntent.Rect(f)
            let others = bars.enumerated().filter { $0.offset != i }.map { EdgeIntent.Rect($0.element.screen.frame) }
            EdgeIntent.noteMove(&b.edge, .init(t: now, x: Double(m.x), y: Double(m.y), dx: Double(e.deltaX), dyDown: Double(e.deltaY)),
                                screen: screen, hardEdge: EdgeIntent.isHardBottom(screen: screen, others: others, x: Double(m.x)),
                                buttons: buttons, Self.edgeConfig)
        }
    }

    private func installMonitors() {
        addGlobalMonitor([.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] e in self?.notePress(e) }
        addMonitor([.leftMouseDown, .rightMouseDown]) { [weak self] e in
            self?.notePress(e)
            guard let self, let bar = self.bars.first(where: { $0.panel === e.window }) else { return e }
            // Pressing the bar means it is in use: it gets the normal hide delay, not the quick one.
            bar.edge.engaged = true
            // Left press on an app icon: wait for mouse-up so it can become a drag.
            if e.type == .leftMouseDown, let hi = self.hitInfo(NSEvent.mouseLocation),
               let id = hi.id, self.model.items.contains(where: { $0.id == id }) {
                self.dragCleanup?.cancel()
                self.model.dragID = nil
                self.pressed = (id, hi.bar, NSEvent.mouseLocation.x, e)
                self.grab = NSEvent.mouseLocation.x - self.iconCenterX(hi.bar, id, fallback: NSEvent.mouseLocation.x)
                self.dragging = false
                return nil
            }
            self.handleClick(e)
            return nil
        }
        addMonitor(.otherMouseDown) { [weak self] e in
            self?.notePress(e)
            guard let self, e.buttonNumber == 2 else { return e }
            let m = NSEvent.mouseLocation
            if let panel = self.preview.panel, e.window === panel { self.preview.middleClick(m); return nil }
            guard self.bars.contains(where: { $0.panel === e.window }),
                  let id = self.hitInfo(m)?.id, let item = self.model.items.first(where: { $0.id == id }) else { return e }
            self.preview.commitPeek()
            self.preview.hide()
            if let pid = item.pid { newWindow(pid: pid, run: self.run); self.launchFeedback(item) } else if self.model.click(item) { self.launchFeedback(item) }
            return nil
        }
        addMonitor(.leftMouseDragged) { [weak self] e in
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
        addMonitor(.leftMouseUp) { [weak self] e in
            guard let self, let p = self.pressed else { return e }
            self.pressed = nil
            if self.dragging {
                self.dragging = false
                if let r = p.bar.frames[p.id] {
                    withAnimation(.easeOut(duration: 0.15)) { self.model.dragX = r.midX }
                }
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.isRunning else { return }
                    self.model.dragID = nil
                }
                self.dragCleanup = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.17, execute: work)
            } else { self.handleClick(p.event) }
            return nil
        }

        addMonitor(.scrollWheel) { [weak self] e in
            guard let self, self.tray?.isRunning == true, self.bars.contains(where: { $0.panel === e.window }),
                  self.hitInfo(NSEvent.mouseLocation)?.id == trayVol else { return e }
            SystemTray.setVolume(self.model.volume + Float(e.scrollingDeltaY) * (e.hasPreciseScrollingDeltas ? 0.004 : 0.03))
            self.model.refreshTray()
            return nil
        }
    }

    func rebuildBars() {
        guard isRunning else { return }
        dragCleanup?.cancel()
        pressed = nil; dragging = false
        model.dragID = nil
        hoverBar = nil; overlayBar = nil
        closeBars()
        preview.hide(); closeFlyout()
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
            let hit = b.frames.first { id, frame in
                (model.trayVisible || !id.hasPrefix("__t_")) && frame.minX <= lx && lx <= frame.maxX
            }
            return (b, hit?.key)
        }
        return nil
    }

    func iconCenterX(_ b: Bar, _ id: String, fallback: CGFloat) -> CGFloat {
        guard let r = b.frames[id] else { return fallback }
        return b.panel.frame.minX + r.midX
    }

    /// Ghost zoom + pulse on the item's icon (on `bar`, or the bar under the mouse / the first one showing it).
    func launchFeedback(_ item: AppItem, bar: Bar? = nil) {
        let m = NSEvent.mouseLocation
        let shown = bars.filter { !$0.hidden && $0.frames[item.id] != nil }
        guard let b = bar ?? shown.first(where: { $0.screen.frame.contains(m) }) ?? shown.first,
              let r = b.frames[item.id] else { return }
        let f = b.panel.frame
        let center = NSPoint(x: f.minX + r.midX, y: f.maxY - r.midY)
        LaunchFeedback.shared.play(item, center: center, size: CGFloat(store.config.iconSize))
    }

    func iconLeftX(_ b: Bar, _ id: String) -> CGFloat {
        b.panel.frame.minX + (b.frames[id]?.minX ?? 0)
    }

    var pressed: (id: String, bar: Bar, x: CGFloat, event: NSEvent)?
    var dragging = false
    var grab: CGFloat = 0

    func tick() {
        guard isRunning else { return }
        let m = NSEvent.mouseLocation
        let flyout = tray?.flyout
        let overFlyout = flyout?.contains(m) == true
        let overPreview = preview.contains(m) || overFlyout
        if flyout?.isVisible == true { flyout?.refit() }

        if store.config.autoHide {
            let now = ProcessInfo.processInfo.systemUptime
            let dt = min(max(now - lastTick, 0), 0.1)
            let cfg = Self.edgeConfig
            let buttons = NSEvent.pressedMouseButtons
            let rects = bars.map { EdgeIntent.Rect($0.screen.frame) }
            for (i, b) in bars.enumerated() {
                let f = rects[i]
                let overBar = !b.hidden && barFrame(b, hidden: false).contains(m)
                // One rule for every tray panel: while one is open on this bar the bar stays, wherever the pointer is.
                // Refreshing lastInside also gives the usual 0.5 s delay from the moment the panel closes.
                // Reordering an icon on this bar also keeps it out, so it cannot slide away mid-drag.
                let pinned = PanelPolicy.keepsBarVisible(panelOpen: flyout?.isVisible == true, panelBarIsThisBar: flyoutBar === b)
                    || (dragging && pressed?.bar === b)
                if overBar { EdgeIntent.noteInside(&b.edge, dt: dt, cfg) }
                if pinned { b.edge.engaged = true }
                // Touching the edge alone no longer reveals: the pointer has to rest there or push down (EdgeIntent).
                // Drags never reveal: the bar has no drop target.
                var others = rects
                others.remove(at: i)
                let wants = b.hidden && EdgeIntent.reveal(&b.edge, .init(
                    now: now, x: Double(m.x), y: Double(m.y), screen: f,
                    hardEdge: EdgeIntent.isHardBottom(screen: f, others: others, x: Double(m.x)),
                    buttons: buttons, dragSession: false, dropTargets: false, lastPressAt: lastPressAt), cfg)
                let near = overBar || (overPreview && overlayBar === b)
                if near || pinned || wants {
                    b.lastInside = now
                    if b.hidden {
                        b.hidden = false
                        EdgeIntent.didShow(&b.edge, now: now)
                        layoutBar(b, animated: true)
                    }
                } else if PanelPolicy.barShouldHide(autoHide: true, barHidden: b.hidden, pointerNearBar: near, panelPinsBar: pinned,
                                                    secondsSinceInside: now - b.lastInside, delay: EdgeIntent.hideDelay(b.edge, cfg)) {
                    b.hidden = true
                    EdgeIntent.didHide(&b.edge)
                    if overlayBar === b { preview.hide() }
                    layoutBar(b, animated: true)
                }
            }
            lastTick = now
        }

        let hi = hitInfo(m)
        // Our panels never become key, so the cursor has to be set by hand.
        if dragging {
            NSCursor.closedHand.set()
        } else if overPreview {
            if !(overFlyout && flyout?.kind == trayMail) { NSCursor.pointingHand.set() }
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

        tray?.tick()
        if Date().timeIntervalSince(lastBadge) > 2 {
            lastBadge = Date()
            if !windowsInFlight {
                windowsInFlight = true
                let pids = Set(model.items.compactMap(\.pid))
                let ownPID = ProcessInfo.processInfo.processIdentifier
                let ownWindowless = pids.contains(ownPID) && TaskbarModel.ownWindows().isEmpty
                DispatchQueue.global(qos: .utility).async { [weak self, run] in
                    var none = Set<pid_t>()
                    if !run.isCancelled, AXIsProcessTrusted() {
                        if ownWindowless { none.insert(ownPID) }
                        for pid in pids where pid != ownPID {
                            guard !run.isCancelled else { return }
                            if WindowService.windows(for: pid, run: run).isEmpty { none.insert(pid) }
                        }
                    }
                    let windowless = none
                    DispatchQueue.main.async {
                        guard let self, self.isRunning else { return }
                        self.windowsInFlight = false
                        if self.model.windowless != windowless { self.model.windowless = windowless }
                    }
                }
            }
            if !badgesInFlight {
                badgesInFlight = true
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    let b = DockBadges.read()
                    DispatchQueue.main.async {
                        guard let self, self.isRunning else { return }
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
        if !(id?.hasPrefix("__t_") ?? false) { closeFlyout() }
        let item = model.items.first { $0.id == id }
        if let id, id.hasPrefix("__t_") { trayClick(id, bar: bar); return }
        if e.type == .rightMouseDown {
            let menu = item.map(itemMenu) ?? settingsMenu()
            popUp(menu, x: id.map { iconLeftX(bar, $0) } ?? m.x, bar: bar)
        } else if id == updateID {
            UpdateWindowController.shared.show()
        } else if id == deskID {
            toggleDesktop()
        } else if id == startID {
            openAppLauncher()
        } else if let item {
            if e.modifierFlags.contains(.shift), let pid = item.pid { newWindow(pid: pid, run: run); launchFeedback(item, bar: bar) }
            else if model.click(item) { launchFeedback(item, bar: bar) }
        }
    }

    func trayClick(_ id: String, bar: Bar) {
        guard isRunning, bars.contains(where: { $0 === bar }) else { return }
        tray?.click(id, bar: bar, controller: self)
    }

    func closeFlyout() {
        tray?.flyout?.hide()
        flyoutBar = nil
    }

    /// Windows minimized by "show desktop", and the app that was in front, so a second click restores them.
    var desktopMinimized: [WinRef] = []
    var desktopFront: pid_t?
    var desktopInProgress = false

    func toggleDesktop() {
        guard isRunning, !desktopInProgress else { return }
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
        desktopTask = Task { @MainActor [weak self] in
            await WindowService.snapshot(ids)
            guard !Task.isCancelled, let self, self.isRunning else { return }
            defer { self.desktopInProgress = false; self.desktopTask = nil }
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
                guard let self, self.isRunning else { return }
                if let resized = WindowService.frame(w), abs(resized.height - height) <= 1 {
                    self.failedResizeIDs.remove(id)
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
        if let update = UpdateWindowController.menuItem() { menu.addItem(update) }
        if let pid = item.pid {
            let news = WindowService.newItems(pid: pid)
            for n in news {
                menu.addItem(BlockItem(n.title) { [weak self] in
                    guard let self, self.isRunning else { return }
                    WindowService.press(n.el, pid: pid, run: self.run)
                    self.launchFeedback(item)
                })
            }
            if !news.isEmpty { menu.addItem(.separator()) }
        }
        if item.pid == nil, let url = item.url {
            menu.addItem(BlockItem(tx("Open", "Abrir")) { [weak self] in
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                self?.launchFeedback(item)
            })
        }
        if item.pid != ProcessInfo.processInfo.processIdentifier {
            menu.addItem(BlockItem(item.pinned ? tx("Unpin from bar", "Desanclar de la barra") : tx("Pin to bar", "Anclar a la barra")) { [weak self] in
                guard let self, self.isRunning else { return }
                self.model.togglePin(item)
            })
        }
        if let url = item.url {
            menu.addItem(BlockItem(tx("Show in Finder", "Mostrar en Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) })
        }
        if let pid = item.pid, pid == ProcessInfo.processInfo.processIdentifier {
            if !TaskbarModel.ownWindows().isEmpty {
                menu.addItem(.separator())
                menu.addItem(BlockItem(calendarText("Close windows", "Cerrar ventanas")) {
                    for window in TaskbarModel.ownWindows() {
                        if window.isMiniaturized { window.close() }
                        else { window.performClose(nil) }
                    }
                })
            }
        } else if let pid = item.pid {
            menu.addItem(.separator())
            menu.addItem(BlockItem(calendarText("Close all windows", "Cerrar todas las ventanas")) { [run] in
                WindowService.windows(for: pid, run: run).forEach { WindowService.close($0, run: run) }
            })
            if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular,
               !["com.apple.finder", "com.apple.dock"].contains(app.bundleIdentifier?.lowercased() ?? "") {
                menu.addItem(BlockItem(calendarText("Quit \(item.name)", "Salir de \(item.name)")) {
                    app.terminate()
                })
            }
        }
        return menu
    }

    func settingsMenu() -> NSMenu {
        let menu = NSMenu()
        if let update = UpdateWindowController.menuItem() { menu.addItem(update) }
        menu.addItem(BlockItem(tx("Hide bar automatically", "Ocultar barra automáticamente"), checked: store.config.autoHide) { [store] in
            store.config.autoHide.toggle()
        })
        let themes = NSMenu()
        for t in BarTheme.all {
            themes.addItem(BlockItem(t.name, checked: store.config.theme == t.id) { [store] in store.config.theme = t.id })
        }
        let themeItem = NSMenuItem(title: tx("Theme", "Tema"), action: nil, keyEquivalent: "")
        themeItem.submenu = themes
        menu.addItem(themeItem)
        let trans = NSMenu()
        for (label, v) in [(tx("None", "Ninguna"), 1.0), (tx("Light", "Ligera"), 0.82), (tx("Medium", "Media"), 0.62), (tx("High", "Alta"), 0.42), (tx("Very high", "Muy alta"), 0.22)] {
            trans.addItem(BlockItem(label, checked: abs(store.config.barOpacity - v) < 0.01) { [store] in store.config.barOpacity = v })
        }
        let transItem = NSMenuItem(title: tx("Transparency", "Transparencia"), action: nil, keyEquivalent: "")
        transItem.submenu = trans
        menu.addItem(transItem)
        menu.addItem(.separator())
        menu.addItem(BlockItem(tx("Settings…", "Configuración…")) { SettingsWindowController.shared.show() })
        menu.addItem(BlockItem(tx("Report a Problem…", "Reportar un problema…")) { FeedbackWindowController.shared.show() })
        return menu
    }

}

extension EdgeIntent.Rect {
    init(_ r: CGRect) { self.init(minX: Double(r.minX), minY: Double(r.minY), maxX: Double(r.maxX), maxY: Double(r.maxY)) }
}

extension BarController {
    /// One glow per hidden bar and app wanting attention, under where its icon sits. Nothing while the bar shows:
    /// the icon itself carries the cue then.
    func attentionEdgeTargets() -> [AttentionEdgeCue.Target] {
        guard isRunning, store.config.autoHide else { return [] }
        let pids = AppAttention.shared.pids
        let items = model.items.filter { $0.pid.map(pids.contains) ?? false }
        return bars.filter(\.hidden).flatMap { b in
            items.map { AttentionEdgeCue.Target(screen: b.screen.frame, x: iconCenterX(b, $0.id, fallback: b.screen.frame.midX)) }
        }
    }
}

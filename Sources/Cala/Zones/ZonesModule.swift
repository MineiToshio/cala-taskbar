import AppKit
import Combine

/// Zones: drag another app's window, right-click (or hold Shift) to show the zones, release over one to snap.
/// Main-thread owner of the store, the drag tap, the worker and the overlay. Nothing exists while stopped.
final class ZonesModule: CalaModule, ZonesStatusMenuProvider, ObservableObject {
    let id = ModuleID.zones
    private(set) var isRunning = false
    @Published private(set) var dragTapReady = false
    @Published private(set) var layoutLoadFailed = false
    @Published private(set) var layoutSaveFailed = false
    /// Loaded in start() (the only place zones.json is read), released in stop(). The editor uses it.
    private(set) var store: ZonesStore?

    /// Set by the zones editor while it is open: drags are ignored meanwhile.
    static var editorOpen = false {
        didSet {
            guard editorOpen != oldValue else { return }
            current?.editorStateChanged()
        }
    }
    /// Opens the zones editor for a display key. Set at launch by `ZoneEditor.install()`; it works with the module
    /// off too (the editor then loads zones.json on its own).
    static var openEditor: ((String) -> Void)?
    /// Posted on the main thread when layouts or per-display choices change (menu, Settings, editor) or the module
    /// starts or stops, so Settings can re-read them.
    static let didChange = Notification.Name("CalaZonesDidChange")
    private(set) static weak var current: ZonesModule?

    private struct SessionScreen {
        var index: Int
        var key: String
        var frame: CGRect
        var usable: CGRect
        var zones: [Zone]
    }

    /// One zones-mode episode during a drag. Usable rects are computed when it starts, never cached longer.
    private struct Session {
        var generation: UInt64
        var screens: [SessionScreen]
        var anchor = ZoneSpanAnchor()
        var screenKey: String?
    }

    private struct StripState {
        var screenIndex: Int
        var key: String
        var layouts: [UUID]
        var current: Int?
        var expanded = false
        var dwell = ZoneStripDwell()
        var point = CGPoint.zero
    }

    private let config: ConfigStore
    private unowned let bar: BarModule
    private var tap: ZoneDragTap?
    private var mover: ZoneWindowMover?
    private let overlay = ZoneOverlay()
    private let strip = ZoneLayoutStrip()
    private let toast = ZoneToast()
    private var session: Session?
    var isInZonesMode: Bool { session != nil }
    /// The layout strip of the display under the cursor while zones mode is on (setting `zonesLayoutStrip`).
    private var stripState: StripState?
    /// Runs only while the strip is expanded: the dwell must progress while the pointer rests (no mouse events).
    private var stripTimer: Timer?
    private var runID: UUID?
    private var retryTimer: Timer?
    private var screenObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    private var accessibilityObserver: NSObjectProtocol?
    private var configObserver: AnyCancellable?
    private var tapProblemLogged = false
    private static var tilingChecked = false

    init(store: ConfigStore, bar: BarModule) {
        self.config = store
        self.bar = bar
    }

    // MARK: Lifecycle

    func start() {
        precondition(Thread.isMainThread)
        guard !isRunning else { return }
        let zones: ZonesStore
        do {
            zones = try ZonesStore(templateName: Self.templateName)
        } catch {
            layoutLoadFailed = true
            log("zones: could not load zones.json: \(error)")
            return
        }
        if let error = zones.recoveryError { log("zones: zones.json was invalid and could not be backed up (\(error)); saving is off") }
        if layoutLoadFailed { layoutLoadFailed = false }
        layoutSaveFailed = zones.recoveryError != nil
        store = zones
        isRunning = true
        Self.current = self
        let run = UUID()
        runID = run
        log("zones: \(zones.state.layouts.count) layouts loaded")
        NotificationCenter.default.post(name: Self.didChange, object: nil)

        let mover = ZoneWindowMover()
        let tap = ZoneDragTap(
            onPress: { [weak mover] gen, point in mover?.press(generation: gen, at: point) },
            onMoveCheck: { [weak mover] gen in mover?.checkMove(generation: gen) },
            onSync: { [weak self] in DispatchQueue.main.async { self?.sync(run) } },
            onRelease: { [weak self] release in DispatchQueue.main.async { self?.release(release, run: run) } },
            onDisabled: { [weak self] type in DispatchQueue.main.async { self?.tapDisabled(type, run: run) } })
        mover.attach(tap)
        tap.setActivation(ZoneActivation(config: config.config.zonesActivation))
        tap.setIgnoring(Self.editorOpen)
        self.mover = mover
        self.tap = tap

        configObserver = config.$config.map(\.zonesActivation).removeDuplicates()
            .sink { [weak tap] value in tap?.setActivation(ZoneActivation(config: value)) }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.screensChanged(run) }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.spaceChanged(run) }
        // Posted when any app's Accessibility permission changes: react sooner than the 3 s poll (the trust
        // state settles a moment after the notification).
        accessibilityObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, self.runID == run else { return }
                self.ensureTap()
            }
        }

        tapProblemLogged = false
        ensureTap()
        // Installs the tap once Accessibility is granted, and repairs it if the system invalidates it.
        retryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.ensureTap() }
        Self.logNativeTiling()
    }

    func stop() {
        precondition(Thread.isMainThread)
        guard isRunning else { return }
        isRunning = false
        runID = nil
        retryTimer?.invalidate()
        retryTimer = nil
        tap?.uninstall()          // disables and invalidates the port, stops the tap thread's run loop
        tap = nil
        if dragTapReady { dragTapReady = false }
        mover?.stop()             // cancels queued AX work and drops snap records
        mover = nil
        overlay.close()           // orders out, closes and releases every panel
        closeStrip()              // the layout strip panel and its dwell timer
        toast.close()
        session = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        if let accessibilityObserver { DistributedNotificationCenter.default().removeObserver(accessibilityObserver) }
        screenObserver = nil
        spaceObserver = nil
        accessibilityObserver = nil
        configObserver?.cancel()
        configObserver = nil
        store = nil
        if Self.current === self { Self.current = nil }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    private func ensureTap() {
        guard isRunning, let tap else { return }
        defer {
            if dragTapReady != tap.isInstalled { dragTapReady = tap.isInstalled }
        }
        let trusted = AXIsProcessTrusted()
        if tap.isInstalled && !trusted {
            // Accessibility was revoked: drop the tap rather than keep an active tap the system may stop serving.
            tap.uninstall()
            endSession()
        }
        if tap.isInstalled {
            switch tap.ensureEnabled() {
            case .ok:
                return
            case .reenabled:
                // The gesture was cancelled with it: never leave a click-through overlay on screen.
                endSession()
                log("zones: tap found disabled, re-enabled")
                return
            case .broken:
                tap.uninstall()
                endSession()
                log("zones: event tap stopped working, reinstalling")
            }
        }
        guard trusted else {
            if !tapProblemLogged { log("zones: no Accessibility, tap not installed") }
            tapProblemLogged = true
            return
        }
        if tap.install() {
            tapProblemLogged = false
            log("zones: event tap active (mouse only, mask 0x\(String(ZoneDragTap.mask, radix: 16)))")
        } else if !tapProblemLogged {
            tapProblemLogged = true
            log("zones: event tap could not be created")
        }
    }

    private func tapDisabled(_ type: CGEventType, run: UUID) {
        guard isRunning, runID == run else { return }
        log(type == .tapDisabledByTimeout ? "zones: tap disabled by timeout, re-enabled"
                                          : "zones: tap disabled by user input, re-enabled")
        endSession()
    }

    private func editorStateChanged() {
        tap?.setIgnoring(Self.editorOpen)
        if Self.editorOpen { endSession() }
    }

    // MARK: Zones mode (main)

    /// Coalesced from the tap: show, update or hide the overlay for the latest pointer state.
    private func sync(_ run: UUID) {
        guard isRunning, runID == run, let tap else { return }
        let snapshot = tap.takeSnapshot()
        guard snapshot.zonesMode else { endSession(); return }
        if session?.generation != snapshot.generation { startSession(snapshot.generation) }
        updateTarget(point: snapshot.point, command: snapshot.command)
    }

    private func release(_ release: ZoneDragMachine.Release, run: UUID) {
        guard isRunning, runID == run, let mover else { return }
        var target: CGRect?
        var usable: CGRect?
        if release.zonesMode {
            if session?.generation != release.generation { session = makeSession(release.generation) }
            if stripSuspendsPicking(at: release.point) {
                log("zones: released over the layout strip, the window stays")
            } else if let picked = updateTarget(point: release.point, command: release.command, show: false),
               let height = Self.primaryHeight {
                target = ZoneGeometry.axRect(fromAppKit: picked.target.frame, primaryHeight: height)
                usable = ZoneGeometry.axRect(fromAppKit: picked.usable, primaryHeight: height)
            } else {
                log("zones: released outside any zone, the window stays")
            }
        }
        endSession()
        mover.finish(generation: release.generation, cursorX: release.point.x, target: target, usable: usable)
    }

    private func startSession(_ generation: UInt64) {
        endSession()
        let session = makeSession(generation)
        self.session = session
        showOverlay(session)
    }

    private func showOverlay(_ session: Session) {
        let gap = CGFloat(config.config.zonesGap)
        let screens = session.screens.map { screen in
            ZoneOverlay.Screen(index: screen.index, usable: screen.usable, zones: screen.zones.map { zone in
                (zone.id, ZoneGeometry.applyGap(ZoneGeometry.frame(for: zone.rect, in: screen.usable), gap: gap, usable: screen.usable))
            })
        }
        overlay.show(screens, palette: .make(theme: config.config.theme))
    }

    private func endSession() {
        session = nil
        if overlay.isVisible { overlay.close() }
        closeStrip()
    }

    private func cancelMode(_ run: UUID, reason: String) {
        guard isRunning, runID == run else { return }
        tap?.cancel(resetButtons: false)
        if session != nil { log("zones: zones mode cancelled (\(reason))") }
        endSession()
    }

    private func makeSession(_ generation: UInt64) -> Session {
        let screens = NSScreen.screens
        let keys = ZoneDisplays.keys(for: screens)
        // Cala's bar overlays the bottom strip of every screen when it is always visible; auto-hide leaves it free.
        let barReserves = bar.isRunning && !config.config.autoHide
        let list = screens.enumerated().map { index, screen -> SessionScreen in
            let key = Self.displayKey(screen, keys: keys)
            let usable = ZoneGeometry.usableRect(frame: screen.frame, visibleFrame: screen.visibleFrame,
                                                 barHeight: config.barHeight, barReserves: barReserves)
            return SessionScreen(index: index, key: key, frame: screen.frame, usable: usable,
                                 zones: store?.layout(forDisplay: key)?.zones ?? [])
        }
        return Session(generation: generation, screens: list)
    }

    /// Picks the zone (or ⌘ span) under a CG point and, when `show`, highlights it.
    @discardableResult
    private func updateTarget(point cgPoint: CGPoint, command: Bool, show: Bool = true)
        -> (target: ZonePicking.Target, usable: CGRect)? {
        guard var session, let height = Self.primaryHeight else { return nil }
        let point = ZoneGeometry.appKitPoint(fromCG: cgPoint, primaryHeight: height)
        let index = ZoneGeometry.screenIndex(containing: point, frames: session.screens.map(\.frame))
        let screen = index.map { session.screens[$0] }
        session.screenKey = screen?.key
        var result: (ZonePicking.Target, CGRect)?
        self.session = session
        // The expanded layout strip takes the pointer: no zone is highlighted (and a release there snaps nothing).
        if show, let screen, updateStrip(point: point, screen: screen) {
            overlay.update(screen: screen.index, target: nil)
            return nil
        }
        if let screen, !screen.zones.isEmpty {
            // A pointer over the menu bar, Cala's bar strip or the Dock picks the nearest zone edge.
            let pick = ZoneWindowFit.clampPoint(point, into: screen.usable)
            let single = ZonePicking.chosen(pick, zones: screen.zones, usable: screen.usable)?.id
            let anchor = session.anchor.update(command: command, screen: screen.index, single: single)
            if let target = ZonePicking.target(point: pick, zones: screen.zones, usable: screen.usable,
                                               gap: CGFloat(config.config.zonesGap), spanAnchor: anchor) {
                result = (target, screen.usable)
            }
        } else {
            session.anchor.reset()
        }
        self.session = session
        if show { overlay.update(screen: screen?.index, target: result?.0) }
        return result
    }

    // MARK: Layout strip (main)

    /// Shows the strip on the display under the cursor, expands it when the cursor enters it and collapses it when
    /// the cursor leaves. Returns true while the cursor is inside the expanded strip (zone picking suspended).
    private func updateStrip(point: CGPoint, screen: SessionScreen) -> Bool {
        guard config.config.zonesLayoutStrip, let store, !store.state.layouts.isEmpty else {
            closeStrip()
            return false
        }
        if stripState?.screenIndex != screen.index { openStrip(on: screen, store: store) }
        guard var state = stripState else { return false }
        state.point = point
        let count = state.layouts.count
        let inside = ZoneStripGeometry.inside(point, expanded: state.expanded, usable: screen.usable,
                                              count: count, current: state.current, pill: strip.pillSize)
        if inside != state.expanded {
            state.expanded = inside
            state.dwell.reset()
            strip.setExpanded(inside)
        }
        stripState = state
        if state.expanded {
            stripTick()
            if stripTimer == nil {
                stripTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.stripTick() }
            }
        } else {
            stripTimer?.invalidate()
            stripTimer = nil
        }
        return state.expanded
    }

    private func openStrip(on screen: SessionScreen, store: ZonesStore) {
        closeStrip()
        let layouts = store.state.layouts
        let active = activeLayout(forDisplay: screen.key)
        let current = layouts.firstIndex { $0.id == active }
        let aspect = ZoneThumbnailRenderer.aspect(of: screen.frame)
        let accent = ZoneOverlay.accent(theme: config.config.theme)
        let entries = layouts.map { layout in
            ZoneLayoutStrip.Entry(id: layout.id, name: ZoneEditorSession.displayName(layout),
                                  picture: ZoneThumbnailRenderer.image(layout.zones, aspect: aspect,
                                                                       fitting: ZoneStripGeometry.picture, accent: accent))
        }
        strip.show(usable: screen.usable, entries: entries, current: current, accent: accent)
        stripState = StripState(screenIndex: screen.index, key: screen.key, layouts: layouts.map(\.id), current: current)
    }

    private func stripSuspends(_ point: CGPoint, state: StripState, usable: CGRect) -> Bool {
        ZoneStripGeometry.suspendsPicking(point, expanded: state.expanded, usable: usable,
                                          count: state.layouts.count, current: state.current)
    }

    /// For a release: whether the cursor (CG point) is inside the expanded strip.
    private func stripSuspendsPicking(at cgPoint: CGPoint) -> Bool {
        guard let state = stripState, state.expanded, let height = Self.primaryHeight,
              let screen = session?.screens.first(where: { $0.index == state.screenIndex }) else { return false }
        return stripSuspends(ZoneGeometry.appKitPoint(fromCG: cgPoint, primaryHeight: height), state: state, usable: screen.usable)
    }

    /// Dwell progress for the item under the (possibly resting) pointer; switches the layout when it completes.
    private func stripTick() {
        guard isRunning, var state = stripState, state.expanded,
              let screen = session?.screens.first(where: { $0.index == state.screenIndex }) else { return }
        let geometry = ZoneStripGeometry.expanded(usable: screen.usable, count: state.layouts.count, current: state.current)
        let item = ZoneStripGeometry.item(at: state.point, in: geometry)
        let output = state.dwell.update(item: item, now: CACurrentMediaTime(), current: state.current)
        stripState = state
        switch output {
        case .idle:
            strip.setHover(state.dwell.hovered, progress: 0)
        case let .progress(item, fraction):
            strip.setHover(item, progress: fraction)
        case let .switchTo(index):
            switchStripLayout(to: index)
        }
    }

    /// Persists the display's new layout (like a Settings change), crossfades the overlay to its zones, shows its
    /// name and keeps zones mode on, so the window can be dropped into a zone of the new layout.
    private func switchStripLayout(to index: Int) {
        guard var state = stripState, state.layouts.indices.contains(index), var session, let store,
              let screenPosition = session.screens.firstIndex(where: { $0.index == state.screenIndex }) else { return }
        let id = state.layouts[index]
        setLayout(id, forDisplay: state.key)
        guard activeLayout(forDisplay: state.key) == id, let layout = store.state.layouts.first(where: { $0.id == id })
        else { return }
        state.current = index
        stripState = state
        strip.setCurrent(index)
        var screen = session.screens[screenPosition]
        screen.zones = layout.zones
        session.screens[screenPosition] = screen
        session.anchor.reset()
        self.session = session
        let gap = CGFloat(config.config.zonesGap)
        overlay.replace(ZoneOverlay.Screen(index: screen.index, usable: screen.usable, zones: layout.zones.map { zone in
            (zone.id, ZoneGeometry.applyGap(ZoneGeometry.frame(for: zone.rect, in: screen.usable), gap: gap, usable: screen.usable))
        }), palette: .make(theme: config.config.theme))
        let body = strip.expandedBody ?? ZoneStripGeometry.collapsed(usable: screen.usable, pill: strip.pillSize).body
        toast.show(ZoneEditorSession.displayName(layout), below: body.minY, centerX: screen.usable.midX)
        log("zones: layout strip switched a display to \(layout.name)")
    }

    private func closeStrip() {
        stripTimer?.invalidate()
        stripTimer = nil
        stripState = nil
        strip.close()
    }

    /// A Space change never cancels zones mode. With "Displays have separate Spaces" (the macOS default) it fires
    /// whenever the pointer carries a window onto another display, and an edge push to an adjacent Space carries
    /// the window along too. In both cases the drag goes on, the panels join every Space and the target is
    /// recomputed from the pointer, so the gesture stays valid. Only bring the panels back to the front.
    private func spaceChanged(_ run: UUID) {
        guard isRunning, runID == run, let current = session else { return }
        showOverlay(current)
        if let snapshot = tap?.takeSnapshot(), snapshot.zonesMode {
            updateTarget(point: snapshot.point, command: snapshot.command)
        } else {
            endSession()
        }
    }

    private func screensChanged(_ run: UUID) {
        guard isRunning, runID == run, let current = session else { return }
        let rebuilt = makeSession(current.generation)
        if let key = current.screenKey, !rebuilt.screens.contains(where: { $0.key == key }) {
            cancelMode(run, reason: "its screen was disconnected")
            return
        }
        // Rebuild the overlay for the new arrangement and keep zones mode on.
        session = rebuilt
        showOverlay(rebuilt)
        if let snapshot = tap?.takeSnapshot() { updateTarget(point: snapshot.point, command: snapshot.command) }
        log("zones: screens changed, overlay rebuilt")
    }

    // MARK: Status menu

    func zonesStatusMenuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        let editor = BlockItem(tx("Zones editor…", "Editor de zonas…")) { Self.openEditorForPointerScreen() }
        editor.isEnabled = Self.openEditor != nil
        items.append(editor)
        guard let store else { return items }
        let screens = NSScreen.screens
        let keys = ZoneDisplays.keys(for: screens)
        let labels = ZoneDisplays.labels(for: screens)
        for (index, screen) in screens.enumerated() {
            let key = Self.displayKey(screen, keys: keys)
            let off = store.state.activeByDisplay[key] == ZonesState.off
            let active = off ? nil : store.layout(forDisplay: key)
            // Each layout is pictured at this monitor's shape, so the choice is visual and per monitor.
            let aspect = ZoneThumbnailRenderer.aspect(of: screen.frame)
            let menu = NSMenu()
            menu.autoenablesItems = false
            for layout in store.state.layouts {
                let item = BlockItem(ZoneEditorSession.displayName(layout), checked: layout.id == active?.id) { [weak self] in
                    self?.setLayout(layout.id, forDisplay: key)
                }
                item.image = ZoneThumbnailRenderer.image(layout.zones, aspect: aspect)
                menu.addItem(item)
            }
            menu.addItem(.separator())
            menu.addItem(BlockItem(tx("Off on this display", "Desactivadas en esta pantalla"), checked: off) { [weak self] in
                self?.setLayout(nil, forDisplay: key)
            })
            menu.addItem(.separator())
            menu.addItem(BlockItem(tx("Edit zones on this display…", "Editar zonas en esta pantalla…")) {
                Self.openEditor?(key)
            })
            let name = labels[index]
            let current = active.map(ZoneEditorSession.displayName) ?? tx("Off", "Desactivadas")
            let item = NSMenuItem(title: tx("\(name): \(current)", "\(name): \(current)"), action: nil, keyEquivalent: "")
            item.image = active.map { ZoneThumbnailRenderer.image($0.zones, aspect: aspect) }
                ?? NSImage(systemSymbolName: "nosign", accessibilityDescription: nil)
            item.toolTip = ZoneDisplays.sizeText(screen)
            item.submenu = menu
            items.append(item)
        }
        return items
    }

    /// The layout shown on a display, or nil for "Off". Used by the status menu and Settings.
    func setLayout(_ layout: UUID?, forDisplay key: String) {
        guard isRunning, let store else { return }
        do {
            guard try store.setActiveLayout(layout, forDisplay: key) else {
                NotificationCenter.default.post(name: Self.didChange, object: nil)
                return
            }
            if layoutSaveFailed { layoutSaveFailed = false }
            log("zones: display layout set to \(layout.map { id in store.state.layouts.first { $0.id == id }?.name ?? "?" } ?? "off")")
        } catch {
            if !layoutSaveFailed { layoutSaveFailed = true }
            log("zones: could not save the layout choice: \(error)")
        }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    func reopenLayoutStore() {
        guard isRunning else { return }
        do {
            let reopened = try ZonesStore(templateName: Self.templateName)
            if let error = reopened.recoveryError { throw error }
            endSession()
            store = reopened
            layoutSaveFailed = false
        } catch {
            layoutSaveFailed = true
            log("zones: could not reopen zones.json: \(error)")
        }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// The layout id active on a display, or nil when the display is set to Off.
    func activeLayout(forDisplay key: String) -> UUID? {
        guard let store, store.state.activeByDisplay[key] != ZonesState.off else { return nil }
        return store.layout(forDisplay: key)?.id
    }

    /// Opens the editor on the screen under the pointer (the status menu's "Zones editor…").
    static func openEditorForPointerScreen() {
        guard let open = openEditor else { return }
        let screens = NSScreen.screens
        let index = ZoneGeometry.screenIndex(containing: NSEvent.mouseLocation, frames: screens.map(\.frame)) ?? 0
        guard screens.indices.contains(index) else { return }
        open(displayKey(screens[index], keys: ZoneDisplays.keys(for: screens)))
    }

    /// The zones.json key of a screen, given the keys of every connected screen.
    static func displayKey(_ screen: NSScreen, keys: [CGDirectDisplayID: String]) -> String {
        displayID(screen).flatMap { keys[$0] } ?? screen.key
    }

    // MARK: Helpers

    private static var primaryHeight: CGFloat? { NSScreen.screens.first?.frame.height }

    private static func displayID(_ screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    static func templateName(_ id: String) -> String {
        switch id {
        case "two-columns": return tx("Two columns", "Dos columnas")
        case "three-columns": return tx("Three columns", "Tres columnas")
        case "grid-2x2": return tx("2 × 2 grid", "Cuadrícula 2 × 2")
        case "main-side": return tx("Main + side", "Principal + lateral")
        case "side-main": return tx("Side + main", "Lateral + principal")
        case "two-rows": return tx("Two rows", "Dos filas")
        case "main-two-stacked": return tx("Main + two stacked", "Principal + dos apiladas")
        case "wide-center": return tx("Wide center", "Centro ancho")
        default: return ZoneTemplates.name(id)
        }
    }

    /// macOS 15+ tiles windows dropped on screen edges by itself. Zones cannot turn that off; log it once so
    /// the docs and a support report can point to System Settings → Desktop & Dock.
    /// Whether macOS's own "Drag windows to screen edges to tile" (macOS 15+) is on. Unset means the default: on.
    static var nativeTilingOn: Bool {
        guard #available(macOS 15, *) else { return false }
        let value = CFPreferencesCopyAppValue("EnableTilingByEdgeDrag" as CFString, "com.apple.WindowManager" as CFString)
        return (value as? Bool) ?? true
    }

    private static func logNativeTiling() {
        guard !tilingChecked else { return }
        tilingChecked = true
        guard #available(macOS 15, *) else { return }
        let value = CFPreferencesCopyAppValue("EnableTilingByEdgeDrag" as CFString, "com.apple.WindowManager" as CFString)
        if nativeTilingOn {
            log("zones: macOS window tiling by edge drag is on (com.apple.WindowManager EnableTilingByEdgeDrag"
                + (value == nil ? " unset, default" : "=1") + "); drops near screen edges may also tile natively")
        }
    }
}

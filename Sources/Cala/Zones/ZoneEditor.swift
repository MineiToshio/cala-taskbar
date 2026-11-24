import AppKit
import Observation
import SwiftUI

@MainActor
final class ZoneEditor: NSObject {
    static let shared = ZoneEditor()

    var gridEnabled: Bool {
        get { ConfigStore.shared.config.zonesEditorGrid }
        set {
            ConfigStore.shared.config.zonesEditorGrid = newValue
            session?.gridEnabled = newValue
        }
    }

    var linked: Bool {
        get { ConfigStore.shared.config.zonesEditorLinked }
        set {
            ConfigStore.shared.config.zonesEditorLinked = newValue
            session?.linked = newValue
        }
    }

    var isOpen: Bool { window != nil }

    private var window: ZoneEditorWindow?
    private var session: ZoneEditorSession?
    private var store: ZonesStore?
    private var displayID: CGDirectDisplayID?
    private var barIsRunning: () -> Bool = { true }

    private override init() { super.init() }

    /// Lets the status menu and Settings open the editor (`ZonesModule.openEditor`). Called once at launch.
    static func install() {
        ZonesModule.openEditor = { key in MainActor.assumeIsolated { ZoneEditor.shared.open(displayKey: key) } }
    }

    /// Edits the running module's store, so a Save is live at once. With Zones off it loads zones.json on its own:
    /// a Save writes the file and the module reads it when it starts. An open editor keeps its draft and moves
    /// to the requested display.
    func open(displayKey: String?) {
        let barIsRunning = { ModuleRegistry.shared.bar.isRunning }
        if let store {
            open(store: store, displayKey: displayKey, barIsRunning: barIsRunning)
            return
        }
        let module = ModuleRegistry.shared.zones
        if module.isRunning, let live = module.store {
            open(store: live, displayKey: displayKey, barIsRunning: barIsRunning)
            return
        }
        do {
            let standalone = try ZonesStore(templateName: ZonesModule.templateName)
            log("zones editor: opened with Zones off, zones.json loaded on its own")
            open(store: standalone, displayKey: displayKey, barIsRunning: barIsRunning)
        } catch {
            log("zones editor: could not load zones.json: \(error)")
            NSSound.beep()
        }
    }

    /// Pass the current bar-module state when the bar can be stopped independently.
    func open(store: ZonesStore, displayKey: String? = nil, barIsRunning: @escaping () -> Bool = { true }) {
        if let window, self.store === store {
            self.barIsRunning = barIsRunning
            showDisplay(key: displayKey, selectLayout: displayKey != nil && displayKey != session?.displayKey)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        if isOpen {
            session?.requestCancel()
            return
        }
        guard let screen = NSScreen.screens.first else { return }
        let session = ZoneEditorSession(state: store.state, gridEnabled: gridEnabled, linked: linked,
                                        theme: BarTheme.named(ConfigStore.shared.config.theme))
        let window = ZoneEditorWindow(contentRect: screen.frame, styleMask: [.borderless],
                                      backing: .buffered, defer: false)
        window.session = session
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.isMovable = false
        // Not `.clear`: the window server sends a click through any point where the window's own surface is fully
        // transparent, and the canvas is drawn by SwiftUI layers that do not count. With a clear background every
        // click and drag on the canvas went to the app or desktop underneath (only the panel's AppKit controls got
        // them), so drawing seemed not to work. A 1 % tint, invisible under the editor's dimming, keeps them here.
        window.backgroundColor = NSColor(white: 0, alpha: 0.01)
        window.hasShadow = false
        window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        window.acceptsMouseMovedEvents = true
        window.title = tx("Cala · Zones editor", "Cala · Editor de zonas")
        let content = ZoneEditorHostingView(rootView: ZoneEditorScene(session: session))
        content.sizingOptions = []
        window.contentView = content

        self.store = store
        self.session = session
        self.window = window
        self.barIsRunning = barIsRunning
        session.selectDisplay = { [weak self] key in self?.showDisplay(key: key, selectLayout: true) }
        session.changeGrid = { [weak self] enabled in self?.gridEnabled = enabled }
        session.changeLinked = { [weak self] linked in self?.linked = linked }
        session.save = { [weak self] in self?.save() }
        session.discard = { [weak self] in self?.close() }
        showDisplay(key: displayKey, selectLayout: true)
        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersChanged(_:)),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        content.layoutSubtreeIfNeeded()
        session.focusCanvas()
        ZonesModule.editorOpen = true   // the drag tap ignores drags while the editor is open
        log("zones editor: opened")
    }

    /// Discards the draft and closes the editor, including when the module stops.
    func close() {
        guard let window else { return }
        NotificationCenter.default.removeObserver(self, name: NSApplication.didChangeScreenParametersNotification, object: nil)
        window.close()
        self.window = nil
        session = nil
        store = nil
        displayID = nil
        barIsRunning = { true }
        ZonesModule.editorOpen = false
        log("zones editor: closed")
    }

    @objc private func screenParametersChanged(_ notification: Notification) {
        showDisplay(key: nil, selectLayout: false)
    }

    private func showDisplay(key: String?, selectLayout: Bool) {
        guard let window, let session else { return }
        let screens = NSScreen.screens
        let keys = ZoneDisplays.keys(for: screens)
        let displays = screens.compactMap { screen -> (screen: NSScreen, id: CGDirectDisplayID, key: String)? in
            guard let id = ZoneDisplays.id(for: screen),
                  let key = keys[id] else { return nil }
            return (screen, id, key)
        }
        let preferred = displays.first { display in
            if let key { return display.key == key }
            return display.id == displayID
        }
        guard let display = preferred ?? displays.first else { return }
        let labels = ZoneDisplays.labels(for: displays.map(\.screen))
        session.monitors = displays.indices.map { index in
            .init(key: displays[index].key, name: labels[index], size: ZoneDisplays.sizeText(displays[index].screen))
        }

        let screen = display.screen
        let config = ConfigStore.shared
        let usable = ZoneGeometry.usableRect(frame: screen.frame, visibleFrame: screen.visibleFrame,
                                             barHeight: config.barHeight,
                                             barReserves: barIsRunning() && !config.config.autoHide)
        let local = usable.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        session.place(on: display.key, usable: local, aspect: ZoneThumbnailRenderer.aspect(of: screen.frame),
                      selectLayout: selectLayout)
        displayID = display.id
        window.setFrame(screen.frame, display: true)
    }

    private func save() {
        guard let session, session.dialog == nil, let store else { return }
        // If Zones was started (or restarted) while editing, save into the running module's store: the draft is
        // merged onto its current state, so the module uses the new layouts at once and nothing is stale.
        let target = ZonesModule.current.flatMap { $0.isRunning ? $0.store : nil } ?? store
        do {
            try target.saveEditorDraft(session.finishedDraft, basedOn: session.original)
            log("zones editor: saved \(target.state.layouts.count) layouts\(target === store ? "" : " into the running module")")
            close()
            NotificationCenter.default.post(name: ZonesModule.didChange, object: nil)
        } catch {
            let message = error is ZonesStore.SaveError
                ? tx("Cala couldn’t back up the damaged zones file.", "Cala no pudo respaldar el archivo de zonas dañado.")
                : error.localizedDescription
            session.present(.saveError(message))
        }
    }

    static func templateName(_ id: String) -> String {
        ZoneTemplates.name(id, localizedWith: tx)
    }

    static func renderSnapshot(to url: URL, size: CGSize = CGSize(width: 1280, height: 800),
                               scale: CGFloat = 1) throws {
        let width = (size.width * scale).rounded()
        let height = (size.height * scale).rounded()
        guard size.width > 0, size.height > 0, scale > 0,
              width >= 1, width < CGFloat(Int.max), height >= 1, height < CGFloat(Int.max) else {
            throw SnapshotError.invalidSize
        }
        var layout = ZoneTemplates.makeLayout("grid-2x2", name: templateName("grid-2x2"))
        let (overlap, guides) = ZoneSnapping.draw(from: (0.33, 0.33), to: (0.67, 0.83),
                                                 others: layout.zones.map(\.rect), grid: true,
                                                 snapping: true, threshold: (0.01, 0.01), minSize: (0.05, 0.05))
        let selected = layout.addZone(overlap)
        // Every built-in layout, with the edited 2 × 2 grid in its place, so the gallery is pictured full.
        var state = ZoneTemplates.seedState(names: templateName)
        if let index = state.layouts.firstIndex(where: { $0.template == "grid-2x2" }) {
            layout.id = state.layouts[index].id
            state.layouts[index] = layout
        }
        state.defaultLayout = layout.id
        let session = ZoneEditorSession(state: state, gridEnabled: true, linked: true, theme: .named("graphite"))
        session.monitors = [.init(key: "sample", name: tx("Right display", "Pantalla derecha"), size: "1280 × 800"),
                            .init(key: "external", name: tx("Left display", "Pantalla izquierda"), size: "3840 × 1080")]
        let bounds = CGRect(origin: .zero, size: size)
        // Include the area reserved for the menu bar in the sample.
        let visible = CGRect(x: 0, y: 0, width: size.width, height: max(0, size.height - 28))
        let usable = ZoneGeometry.usableRect(frame: bounds, visibleFrame: visible, barHeight: 34, barReserves: true)
        session.place(on: "sample", usable: usable, aspect: Double(size.width / size.height), selectLayout: true)
        session.selectedZone = selected
        session.preview = .init(zoneID: selected, rect: overlap, guides: guides)

        // Give AppKit-backed controls the same backing scale as the SwiftUI canvas.
        let window = ZoneEditorSnapshotWindow(contentRect: bounds, styleMask: .borderless,
                                              backing: .buffered, defer: false)
        window.scale = scale
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = NSHostingView(rootView: ZoneEditorScene(session: session, interactive: false)
            .frame(width: size.width, height: size.height)
            .environment(\.displayScale, scale)
            .environment(\.controlActiveState, .active))
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: Int(height),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            throw SnapshotError.renderFailed
        }
        bitmap.size = size
        view.cacheDisplay(in: bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw SnapshotError.renderFailed
        }
        try data.write(to: url, options: .atomic)
    }

    private enum SnapshotError: Error { case invalidSize, renderFailed }
}

private final class ZoneEditorSnapshotWindow: NSWindow {
    var scale: CGFloat = 1
    override var backingScaleFactor: CGFloat { scale }
}

/// The editor's root view. It takes the first click even when Cala was not active (the editor is opened from the
/// menu-bar icon or the bar, which do not activate the app), so a drag or a button press is never swallowed by
/// the click that activates the window.
private final class ZoneEditorHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
private final class ZoneEditorWindow: NSWindow {
    weak var session: ZoneEditorSession?
    override var canBecomeKey: Bool { true }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "s":
                if session?.dialog == nil { session?.save() }
                return true
            case "d":
                if session?.dialog == nil { session?.duplicateZone() }
                return true
            case "z" where !(firstResponder is NSText):
                if session?.dialog == nil { session?.undo() }
                return true
            default: break
            }
        }
        // ⇧⌘Z redoes; while the layout name is being typed, the text field keeps its own undo.
        if modifiers == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "z", !(firstResponder is NSText) {
            if session?.dialog == nil { session?.redo() }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) { session?.requestCancel() }
    override func performClose(_ sender: Any?) { session?.requestCancel() }
}

@MainActor
@Observable
final class ZoneEditorSession {
    struct Monitor: Identifiable {
        var key: String
        var name: String
        var size: String
        var id: String { key }
    }

    struct Preview {
        var zoneID: UUID?
        var rect: ZoneRect
        var guides: [ZoneSnapping.Guide]
        /// Other zones that change with this gesture: linked neighbours, or the zone a moved zone swaps with.
        var others: [UUID: ZoneRect] = [:]
    }

    enum Dialog {
        case discard
        case deleteLayout(UUID, name: String)
        case saveError(String)
        case zoneSize(UUID)
    }

    let original: ZonesState
    let theme: BarTheme
    private(set) var draft: ZonesState
    /// The layout on the canvas: the one this monitor uses (or would use, when zones are off on it).
    private(set) var layoutID: UUID?
    private(set) var displayKey = ""
    private(set) var usable = CGRect.zero
    /// Width / height of the edited monitor, so the gallery pictures have its shape.
    private(set) var aspect = 16.0 / 10
    @ObservationIgnored weak var canvas: ZoneCanvasView?
    @ObservationIgnored var hudFrame = CGRect.zero
    var monitors: [Monitor] = []
    var selectedZone: UUID?
    var preview: Preview?
    var hudCollapsed = false
    var gridEnabled: Bool
    /// Linked: shared edges move together and moves never overlap. Free: every zone on its own (`zonesEditorLinked`).
    var linked: Bool
    /// Bumped to put the cursor in the layout-name field (a new or duplicated layout, or "Rename").
    var renameRequest = 0
    private(set) var dialog: Dialog?

    var selectDisplay: (String) -> Void = { _ in }
    var changeGrid: (Bool) -> Void = { _ in }
    var changeLinked: (Bool) -> Void = { _ in }
    var save: () -> Void = {}
    var discard: () -> Void = {}

    /// Editor-session undo: each entry is the draft and the layout on the canvas before one change.
    private var undoStack: [(ZonesState, UUID?)] = []
    private var redoStack: [(ZonesState, UUID?)] = []
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    init(state: ZonesState, gridEnabled: Bool, linked: Bool, theme: BarTheme) {
        original = state
        draft = state
        self.gridEnabled = gridEnabled
        self.linked = linked
        self.theme = theme
        layoutID = state.defaultLayout ?? state.layouts.first?.id
    }

    private var layoutIndex: Int? { draft.layouts.firstIndex { $0.id == layoutID } }
    var layout: ZoneLayout? { layoutIndex.map { draft.layouts[$0] } }
    var layoutName: String {
        get { layout?.name ?? "" }
        set { if let layoutIndex { draft.layouts[layoutIndex].name = newValue } }
    }
    var hasChanges: Bool { draft != original }
    var monitorName: String { monitors.first { $0.key == displayKey }?.name ?? "" }

    var finishedDraft: ZonesState {
        var result = draft
        let originalNames = Dictionary(uniqueKeysWithValues: original.layouts.map { ($0.id, $0.name) })
        for index in result.layouts.indices where result.layouts[index].name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let layout = result.layouts[index]
            if layout.name != originalNames[layout.id] { result.layouts[index].name = Self.untitled }
        }
        return result
    }

    nonisolated static var untitled: String { tx("Untitled layout", "Distribución sin título") }

    nonisolated static func displayName(_ layout: ZoneLayout) -> String {
        layout.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? untitled : layout.name
    }

    /// Zones are switched off on this monitor (menu-bar icon or Settings): the canvas still shows a layout to edit.
    var isOff: Bool { draft.activeByDisplay[displayKey] == ZonesState.off }

    func place(on key: String, usable: CGRect, aspect: Double, selectLayout: Bool) {
        displayKey = key
        self.usable = usable
        self.aspect = aspect
        if selectLayout {
            show(draft.layout(forDisplay: key)?.id ?? draft.defaultLayout)
        } else {
            resetGesture()
        }
    }

    /// Shows a layout without changing which one the monitor uses.
    private func show(_ id: UUID?) {
        layoutID = id
        selectedZone = nil
        resetGesture()
    }

    /// The gallery's click: the layout goes on the canvas and becomes the one this monitor uses (on Save).
    func select(_ id: UUID) {
        guard draft.layouts.contains(where: { $0.id == id }) else { return }
        if isOff || draft.layout(forDisplay: displayKey)?.id != id {
            record()
            show(id)
            draft.activeByDisplay[displayKey] = id.uuidString
        } else {
            show(id)
        }
    }

    // MARK: Undo

    /// Call before every change to the draft.
    private func record() {
        undoStack.append((draft, layoutID))
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    /// Drops the step just recorded when the change turned out to change nothing (a blocked move, a zone already centred).
    private func dropIfUnchanged() {
        if let last = undoStack.last, last.0 == draft { undoStack.removeLast() }
    }

    func undo() { step(from: &undoStack, to: &redoStack) }
    func redo() { step(from: &redoStack, to: &undoStack) }

    private func step(from source: inout [(ZonesState, UUID?)], to target: inout [(ZonesState, UUID?)]) {
        guard let (state, shown) = source.popLast() else { NSSound.beep(); return }
        target.append((draft, layoutID))
        draft = state
        let keep = selectedZone
        show(draft.layouts.contains { $0.id == shown } ? shown : draft.layout(forDisplay: displayKey)?.id ?? draft.defaultLayout)
        if layout?.zones.contains(where: { $0.id == keep }) == true { selectedZone = keep }
        focusCanvas()
    }

    private func resetGesture() {
        preview = nil
        canvas?.resetGesture()
    }

    func focusCanvas() {
        if let canvas { canvas.window?.makeFirstResponder(canvas) }
    }

    func present(_ dialog: Dialog) {
        resetGesture()
        self.dialog = dialog
        focusCanvas()
    }

    func dismissDialog() {
        dialog = nil
        focusCanvas()
    }

    func requestCancel() {
        if dialog != nil { dismissDialog() }
        else if hasChanges { present(.discard) }
        else { discard() }
    }

    func confirmDialog() {
        switch dialog {
        case .discard: discard()
        case let .deleteLayout(id, _):
            record()
            if draft.delete(id) { show(draft.layout(forDisplay: displayKey)?.id ?? draft.defaultLayout) }
            dismissDialog()
        case .saveError, .zoneSize, nil: dismissDialog()
        }
    }

    // MARK: Layouts

    private func insert(_ layout: ZoneLayout, rename: Bool) {
        record()
        draft.layouts.append(layout)
        select(layout.id)
        if rename { renameRequest += 1 }
    }

    func createBlankLayout() {
        let name = ZoneEditing.uniqueName(tx("My layout", "Mi distribución"), existing: draft.layouts.map(\.name))
        insert(ZoneLayout(name: name), rename: true)
    }

    func addBuiltIn(_ template: String) {
        insert(ZoneTemplates.makeLayout(template, name: ZoneEditor.templateName(template)), rename: false)
    }

    func duplicateLayout(_ id: UUID? = nil) {
        guard let source = draft.layouts.first(where: { $0.id == (id ?? layoutID) }) else { return }
        let name = ZoneEditing.uniqueName(tx("\(Self.displayName(source)) copy", "Copia de \(Self.displayName(source))"),
                                          existing: draft.layouts.map(\.name))
        record()
        let copy = draft.duplicate(source.id, name: name)
        select(copy)
        renameRequest += 1
    }

    func rename(_ id: UUID) {
        select(id)
        renameRequest += 1
    }

    func restoreOriginal(_ id: UUID) {
        guard let index = draft.layouts.firstIndex(where: { $0.id == id }) else { return }
        record()
        draft.layouts[index] = ZoneTemplates.restored(draft.layouts[index])
        select(id)
    }

    func requestDeleteLayout(_ id: UUID? = nil) {
        guard let layout = draft.layouts.first(where: { $0.id == (id ?? layoutID) }), draft.layouts.count > 1 else { return }
        present(.deleteLayout(layout.id, name: Self.displayName(layout)))
    }

    // MARK: Zones

    func apply(_ preview: Preview) {
        guard let layoutIndex else { return }
        record()
        if let id = preview.zoneID {
            guard let index = draft.layouts[layoutIndex].zones.firstIndex(where: { $0.id == id }) else { return }
            draft.layouts[layoutIndex].zones[index].rect = preview.rect
        } else {
            selectedZone = draft.layouts[layoutIndex].addZone(preview.rect)
        }
        for (id, rect) in preview.others {
            if let index = draft.layouts[layoutIndex].zones.firstIndex(where: { $0.id == id }) {
                draft.layouts[layoutIndex].zones[index].rect = rect
            }
        }
        dropIfUnchanged()
    }

    /// Replaces zone rects by index of the current layout's zones (one undo step).
    private func setRects(_ changes: [Int: ZoneRect]) {
        guard let layoutIndex, !changes.isEmpty else { return }
        record()
        for (index, rect) in changes where draft.layouts[layoutIndex].zones.indices.contains(index) {
            draft.layouts[layoutIndex].zones[index].rect = rect
        }
        dropIfUnchanged()
        resetGesture()
    }

    private var selectedIndex: Int? { layout?.zones.firstIndex { $0.id == selectedZone } }

    /// The smallest zone a gesture may leave: 5 % of the screen or 80 pt, whichever is larger.
    var minimumSize: (w: Double, h: Double) {
        (max(0.05, 80 / max(1, Double(usable.width))), max(0.05, 80 / max(1, Double(usable.height))))
    }

    func addZone() {
        guard let layoutIndex else { return }
        record()
        let rect = ZoneEditing.newZoneRect(existing: draft.layouts[layoutIndex].zones.map(\.rect))
        selectedZone = draft.layouts[layoutIndex].addZone(rect)
        resetGesture()
        focusCanvas()
    }

    func deleteZone() {
        guard let layoutIndex, let selectedZone else { return }
        record()
        draft.layouts[layoutIndex].zones.removeAll { $0.id == selectedZone }
        self.selectedZone = nil
        resetGesture()
        focusCanvas()
    }

    func duplicateZone() {
        guard let layoutIndex, let zone = layout?.zones.first(where: { $0.id == selectedZone }) else { return }
        record()
        selectedZone = draft.layouts[layoutIndex].addZone(zone.rect)
        resetGesture()
    }

    func centerZone(horizontally: Bool) {
        guard let index = selectedIndex, let zone = layout?.zones[index] else { return }
        setRects([index: ZoneLinking.centered(zone.rect, horizontally: horizontally)])
    }

    /// Equal widths for the selected zone's row (horizontally) or heights for its column.
    func equalizeZones(horizontally: Bool) {
        guard let index = selectedIndex, let zones = layout?.zones.map(\.rect) else { return }
        setRects(ZoneLinking.equalized(zones, index: index, horizontal: horizontally))
    }

    /// Whether the selected zone has row (or column) mates to share sizes with.
    func canEqualize(horizontally: Bool) -> Bool {
        guard let index = selectedIndex, let zones = layout?.zones.map(\.rect) else { return false }
        let zone = zones[index]
        return zones.filter { other in
            horizontally ? abs(other.y - zone.y) <= ZoneLinking.tolerance && abs(other.h - zone.h) <= ZoneLinking.tolerance
                : abs(other.x - zone.x) <= ZoneLinking.tolerance && abs(other.w - zone.w) <= ZoneLinking.tolerance
        }.count > 1
    }

    /// Arrow keys: 8 pt, or a twelfth of the screen with Shift. Linked mode never moves onto another zone.
    func nudge(dx: Double, dy: Double, large: Bool) {
        guard let index = selectedIndex, let zones = layout?.zones.map(\.rect), usable.width > 0, usable.height > 0 else { return }
        let step = large ? (1.0 / 12, 1.0 / 12) : (8 / Double(usable.width), 8 / Double(usable.height))
        let zone = zones[index]
        let moved = ZoneGeometry.clamp(ZoneRect(x: zone.x + dx * step.0, y: zone.y + dy * step.1, w: zone.w, h: zone.h),
                                       minW: 0, minH: 0)
        let target = linked ? ZoneLinking.move(zones, index: index, to: moved) : moved
        if target != zone { setRects([index: target]) }
    }

    func requestSize() {
        guard let selectedZone else { return }
        present(.zoneSize(selectedZone))
    }

    /// The size typed in the size dialog, in points.
    func setSize(_ id: UUID, width: Double, height: Double) {
        guard let index = layout?.zones.firstIndex(where: { $0.id == id }), let zone = layout?.zones[index] else { return }
        setRects([index: ZoneMeasure.resized(zone.rect, to: (width, height), in: usable.size, minSize: minimumSize)])
        dismissDialog()
    }

    func pointSize(of rect: ZoneRect) -> (w: Int, h: Int) { ZoneMeasure.size(rect, in: usable.size) }
}

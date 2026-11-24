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
        let session = ZoneEditorSession(state: store.state, gridEnabled: gridEnabled,
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
                               scale: CGFloat = 1, theme: String = "graphite") throws {
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
        let session = ZoneEditorSession(state: state, gridEnabled: true, theme: .named(theme))
        session.monitors = [.init(key: "sample", name: tx("Right display", "Pantalla derecha"), size: "1512 × 982"),
                            .init(key: "external", name: tx("Left display", "Pantalla izquierda"), size: "3840 × 1080")]
        let bounds = CGRect(origin: .zero, size: size)
        // Include the area reserved for the menu bar in the sample.
        let visible = CGRect(x: 0, y: 0, width: size.width, height: max(0, size.height - 28))
        let usable = ZoneGeometry.usableRect(frame: bounds, visibleFrame: visible, barHeight: 34, barReserves: true)
        session.place(on: "sample", usable: usable, aspect: Double(size.width / size.height), selectLayout: true)
        session.selectedZone = selected
        _ = guides   // the action bar shows only without a drag in progress

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
        // A second pass once the panel has reported its frame, so zone labels move out from under it.
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
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
        case cannotLink
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
    /// The panel's frame on the canvas: zone labels avoid it, the cursor ignores it.
    var hudFrame = CGRect.zero
    var monitors: [Monitor] = []
    var selectedZone: UUID?
    var preview: Preview?
    var hudCollapsed = false
    /// The "?" shortcuts popover.
    var showsHelp = false
    var gridEnabled: Bool
    /// Zones besides `selectedZone` picked with ⇧-click, for Merge.
    var extraSelection: Set<UUID> = []
    /// Linked mode's split preview: the zone, the cut's direction and its position (a screen fraction).
    var splitPreview: (zone: UUID, vertical: Bool, position: Double)?
    /// A short note shown in the panel for a few seconds (e.g. why a Linked zone did not move).
    var notice: String?
    /// Bumped when a switch to Linked is refused, so the mode control is redrawn showing Free again.
    var modeRefusals = 0
    @ObservationIgnored private var noticeShown: Set<String> = []
    @ObservationIgnored private var noticeTimer: Timer?
    /// Bumped to put the cursor in the layout-name field (a new or duplicated layout, or "Rename").
    var renameRequest = 0
    private(set) var dialog: Dialog?

    var selectDisplay: (String) -> Void = { _ in }
    var changeGrid: (Bool) -> Void = { _ in }
    var save: () -> Void = {}
    var discard: () -> Void = {}

    /// Editor-session undo: each entry is the draft and the layout on the canvas before one change.
    private var undoStack: [(ZonesState, UUID?)] = []
    private var redoStack: [(ZonesState, UUID?)] = []
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    init(state: ZonesState, gridEnabled: Bool, theme: BarTheme) {
        original = state
        draft = state
        self.gridEnabled = gridEnabled
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
        extraSelection = []
        splitPreview = nil
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
        // Esc with the shortcuts popover open closes only the popover (it never takes the editor's key focus).
        if showsHelp { showsHelp = false; return }
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
        case .saveError, .zoneSize, .cannotLink, nil: dismissDialog()
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
        // A new layout starts Linked with one zone covering the screen: split it to make more.
        insert(ZoneLayout(name: name, zones: [Zone(rect: ZoneRect(x: 0, y: 0, w: 1, h: 1))], nextSeq: 1), rename: true)
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

    // MARK: Mode

    /// The layout's editing model; Linked for a layout not yet chosen.
    var mode: ZoneLayoutMode { layout?.mode ?? .linked }
    var linked: Bool { mode == .linked }

    /// Linked → Free is always possible. Free → Linked only when the zones already tile the screen; otherwise
    /// a message explains why (there is no automatic fix that would not move the user's zones unpredictably).
    func setMode(_ mode: ZoneLayoutMode) {
        guard let layoutIndex, draft.layouts[layoutIndex].mode != mode else { return }
        if mode == .linked && !ZoneTiling.tiles(draft.layouts[layoutIndex].zones.map(\.rect)) {
            modeRefusals += 1   // the segmented control already shows Linked: rebuild it on Free
            present(.cannotLink)
            return
        }
        record()
        draft.layouts[layoutIndex].mode = mode
        extraSelection = []
        splitPreview = nil
        resetGesture()
        focusCanvas()
    }

    /// Shows a note in the panel for a few seconds; `once` notes appear only once per editor session.
    func notify(_ text: String, once: Bool = false) {
        if once {
            guard !noticeShown.contains(text) else { return }
            noticeShown.insert(text)
        }
        notice = text
        noticeTimer?.invalidate()
        noticeTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.notice = nil }
        }
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

    /// Replaces zone rects by index of the current layout's zones (one undo step). In Linked mode a result that
    /// would not tile the screen is refused.
    private func setRects(_ changes: [Int: ZoneRect]) {
        guard let layoutIndex, !changes.isEmpty else { return }
        var zones = draft.layouts[layoutIndex].zones
        for (index, rect) in changes where zones.indices.contains(index) { zones[index].rect = rect }
        if linked && !ZoneTiling.tiles(zones.map(\.rect)) {
            NSSound.beep()
            return
        }
        record()
        draft.layouts[layoutIndex].zones = zones
        dropIfUnchanged()
        resetGesture()
    }

    private var selectedIndex: Int? { layout?.zones.firstIndex { $0.id == selectedZone } }
    /// The selected zones: the main one plus any ⇧-clicked.
    var selection: Set<UUID> { extraSelection.union(selectedZone.map { [$0] } ?? []) }

    /// A plain click selects one zone (or none).
    func selectOnly(_ id: UUID?) {
        selectedZone = id
        extraSelection = []
    }

    /// ⇧-click adds a zone to the selection or takes it out.
    func toggleSelection(_ id: UUID) {
        if selectedZone == id {
            selectedZone = extraSelection.first
            extraSelection.remove(selectedZone ?? id)
        } else if extraSelection.contains(id) {
            extraSelection.remove(id)
        } else if selectedZone == nil {
            selectedZone = id
        } else {
            extraSelection.insert(id)
        }
    }

    /// The smallest zone a gesture may leave: 5 % of the screen or 80 pt, whichever is larger.
    var minimumSize: (w: Double, h: Double) {
        (max(0.05, 80 / max(1, Double(usable.width))), max(0.05, 80 / max(1, Double(usable.height))))
    }

    /// Width / height of the usable area, for "the longer side".
    var usableAspect: Double { usable.height > 0 ? Double(usable.width / usable.height) : 16.0 / 10 }

    /// "Add zone". Linked: split the selected zone (else the largest) along its longer side, ⇧ the other way.
    /// Free: a new rectangle in the largest empty gap, else cascaded from the newest zone.
    func addZone(flip: Bool = false) {
        guard let layoutIndex, let layout else { return }
        if linked {
            let target = layout.zones.first { $0.id == selectedZone } ?? layout.zones.max { $0.rect.area < $1.rect.area }
            guard let target else { return }
            split(target.id, vertically: ZoneTiling.splitsVertically(target.rect, aspect: usableAspect) != flip)
            return
        }
        record()
        let rects = layout.zones.map(\.rect)
        let newest = layout.zones.max { $0.seq < $1.seq }?.rect
        let rect = ZoneTiling.freeZoneRect(rects, last: newest, minSize: minimumSize)
        selectOnly(draft.layouts[layoutIndex].addZone(rect))
        resetGesture()
        focusCanvas()
    }

    /// Cuts a zone in two (Linked's way of adding one); at `position` or the midpoint. Selects the new part.
    func split(_ id: UUID, vertically: Bool, at position: Double? = nil) {
        guard let layoutIndex else { return }
        var copy = draft.layouts[layoutIndex]
        guard let part = copy.split(id, vertically: vertically, at: position, minSize: minimumSize) else {
            NSSound.beep()
            notify(tx("This zone is too small to split.", "Esta zona es demasiado pequeña para dividirla."))
            return
        }
        record()
        draft.layouts[layoutIndex] = copy
        selectOnly(part)
        splitPreview = nil
        resetGesture()
        focusCanvas()
    }

    var canSplitSelection: Bool {
        guard let zone = layout?.zones.first(where: { $0.id == selectedZone }) else { return linked }
        return ZoneTiling.split(zone.rect, vertically: true, minSize: minimumSize) != nil
            || ZoneTiling.split(zone.rect, vertically: false, minSize: minimumSize) != nil
    }

    /// Whether the selected zones (two or more) make a rectangle together.
    var canMerge: Bool {
        guard let zones = layout?.zones, selection.count >= 2 else { return false }
        let indices = Set(zones.indices.filter { selection.contains(zones[$0].id) })
        return ZoneTiling.mergedRect(zones.map(\.rect), indices: indices) != nil
    }

    func mergeSelection() {
        guard let layoutIndex, canMerge else {
            NSSound.beep()
            return
        }
        record()
        let kept = draft.layouts[layoutIndex].merge(selection)
        selectOnly(kept)
        resetGesture()
        focusCanvas()
    }

    /// Delete in Free mode removes the zone; in Linked mode its space goes to a neighbour sharing a whole side.
    var canDeleteZone: Bool {
        guard let index = selectedIndex, let zones = layout?.zones else { return false }
        return !linked || ZoneTiling.deletionMerge(zones.map(\.rect), index: index) != nil
    }

    func deleteZone() {
        guard let layoutIndex, let selectedZone else { return }
        if linked {
            var copy = draft.layouts[layoutIndex]
            guard let neighbour = copy.removeByMerging(selectedZone) else {
                NSSound.beep()
                notify(tx("No neighbour shares a whole side with this zone, so deleting it would leave a hole. Merge or split first.",
                          "Ninguna vecina comparte un lado entero con esta zona; borrarla dejaría un hueco. Une o divide antes."))
                return
            }
            record()
            draft.layouts[layoutIndex] = copy
            selectOnly(neighbour)
        } else {
            record()
            draft.layouts[layoutIndex].zones.removeAll { $0.id == selectedZone }
            selectOnly(nil)
        }
        resetGesture()
        focusCanvas()
    }

    func duplicateZone() {
        guard !linked, let layoutIndex, let zone = layout?.zones.first(where: { $0.id == selectedZone }) else { return }
        record()
        selectOnly(draft.layouts[layoutIndex].addZone(zone.rect))
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

    /// Whether the selected zone has row (or column) mates to share sizes with (and, Linked, the result tiles).
    func canEqualize(horizontally: Bool) -> Bool {
        guard let index = selectedIndex, let zones = layout?.zones.map(\.rect) else { return false }
        let changes = ZoneLinking.equalized(zones, index: index, horizontal: horizontally)
        let zone = zones[index]
        let mates = zones.filter { other in
            horizontally ? abs(other.y - zone.y) <= ZoneLinking.tolerance && abs(other.h - zone.h) <= ZoneLinking.tolerance
                : abs(other.x - zone.x) <= ZoneLinking.tolerance && abs(other.w - zone.w) <= ZoneLinking.tolerance
        }.count > 1
        guard mates, linked else { return mates }
        var result = zones
        for (i, r) in changes { result[i] = r }
        return ZoneTiling.tiles(result)
    }

    /// Arrow keys: 8 pt, or a twelfth of the screen with Shift. Free mode only (Linked zones move by dividers).
    func nudge(dx: Double, dy: Double, large: Bool) {
        guard let index = selectedIndex, let zones = layout?.zones.map(\.rect), usable.width > 0, usable.height > 0 else { return }
        guard !linked else {
            notify(linkedMoveHint, once: true)
            return
        }
        let step = large ? (1.0 / 12, 1.0 / 12) : (8 / Double(usable.width), 8 / Double(usable.height))
        let zone = zones[index]
        let moved = ZoneGeometry.clamp(ZoneRect(x: zone.x + dx * step.0, y: zone.y + dy * step.1, w: zone.w, h: zone.h),
                                       minW: 0, minH: 0)
        if moved != zone { setRects([index: moved]) }
    }

    var linkedMoveHint: String {
        tx("In Tiles, zones resize with the lines between them. Drop a zone on another to swap them, or switch to Free to place zones anywhere.",
           "En Mosaico, las zonas cambian de tamaño con las líneas entre ellas. Suelta una zona sobre otra para intercambiarlas, o cambia a Libre para colocarlas donde quieras.")
    }

    func requestSize() {
        guard let selectedZone else { return }
        present(.zoneSize(selectedZone))
    }

    /// The size typed in the size dialog, in points. Free: around the zone's centre. Linked: by moving the zone's
    /// right (else left) divider and its bottom (else top) one, so the layout still tiles; neighbours give way
    /// down to their minimum.
    func setSize(_ id: UUID, width: Double, height: Double) {
        guard let index = layout?.zones.firstIndex(where: { $0.id == id }), let zones = layout?.zones.map(\.rect),
              usable.width > 0, usable.height > 0 else { return }
        let zone = zones[index]
        guard linked else {
            setRects([index: ZoneMeasure.resized(zone, to: (width, height), in: usable.size, minSize: minimumSize)])
            dismissDialog()
            return
        }
        let w = width / Double(usable.width), h = height / Double(usable.height)
        let border = ZoneTiling.borderEdges(zone)
        var rects = zones
        func drag(_ edge: ZoneSnapping.Edges, to proposed: ZoneRect) {
            for (i, r) in ZoneLinking.resize(rects, index: index, edges: edge, proposed: proposed, minSize: minimumSize) { rects[i] = r }
        }
        var current = rects[index]
        if !border.contains(.right) { drag(.right, to: ZoneRect(x: current.x, y: current.y, w: w, h: current.h)) }
        else if !border.contains(.left) { drag(.left, to: ZoneRect(x: current.maxX - w, y: current.y, w: w, h: current.h)) }
        current = rects[index]
        if !border.contains(.bottom) { drag(.bottom, to: ZoneRect(x: current.x, y: current.y, w: current.w, h: h)) }
        else if !border.contains(.top) { drag(.top, to: ZoneRect(x: current.x, y: current.maxY - h, w: current.w, h: h)) }
        var changes: [Int: ZoneRect] = [:]
        for i in rects.indices where rects[i] != zones[i] { changes[i] = rects[i] }
        if changes.isEmpty { NSSound.beep() } else { setRects(changes) }
        dismissDialog()
    }

    func pointSize(of rect: ZoneRect) -> (w: Int, h: Int) { ZoneMeasure.size(rect, in: usable.size) }

    /// Linked split preview while the pointer is over the selected zone: the cut follows the pointer and snaps to
    /// the zone's middle, the grid and other zones' edges; ⇧ turns it the other way. Nil when it cannot split.
    func splitCandidate(at point: (x: Double, y: Double), flip: Bool) -> (zone: UUID, vertical: Bool, position: Double)? {
        guard linked, let zone = layout?.zones.first(where: { $0.id == selectedZone }),
              point.x >= zone.rect.x, point.x < zone.rect.maxX, point.y >= zone.rect.y, point.y < zone.rect.maxY,
              usable.width > 0, usable.height > 0 else { return nil }
        let vertical = ZoneTiling.splitsVertically(zone.rect, aspect: usableAspect) != flip
        let others = layout?.zones.filter { $0.id != zone.id }.map(\.rect) ?? []
        let lines = ZoneSnapping.candidates(others: others, grid: gridEnabled)
        let (value, lower, upper, middle, threshold) = vertical
            ? (point.x, zone.rect.x + minimumSize.w, zone.rect.maxX - minimumSize.w, zone.rect.x + zone.rect.w / 2, 8 / Double(usable.width))
            : (point.y, zone.rect.y + minimumSize.h, zone.rect.maxY - minimumSize.h, zone.rect.y + zone.rect.h / 2, 8 / Double(usable.height))
        guard lower <= upper else { return nil }
        let snapped = ZoneSnapping.snap(value, to: [middle] + (vertical ? lines.xs : lines.ys), threshold: threshold) ?? value
        return (zone.id, vertical, min(max(snapped, lower), upper))
    }
}

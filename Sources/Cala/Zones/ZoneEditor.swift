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
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        window.acceptsMouseMovedEvents = true
        window.title = tx("Cala · Zones editor", "Cala · Editor de zonas")
        let content = NSHostingView(rootView: ZoneEditorScene(session: session))
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
        session.monitors = displays.enumerated().map { position, item in
            let name = item.screen.localizedName
            let duplicateName = displays.filter { $0.screen.localizedName == name }.count > 1
            return .init(key: item.key, name: duplicateName ? "\(name) (\(position + 1))" : name)
        }

        let screen = display.screen
        let config = ConfigStore.shared
        let usable = ZoneGeometry.usableRect(frame: screen.frame, visibleFrame: screen.visibleFrame,
                                             barHeight: config.barHeight,
                                             barReserves: barIsRunning() && !config.config.autoHide)
        let local = usable.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        session.place(on: display.key, usable: local, selectLayout: selectLayout)
        displayID = display.id
        window.setFrame(screen.frame, display: true)
    }

    private func save() {
        guard let session, session.dialog == nil, let store else { return }
        do {
            try store.saveEditorDraft(session.finishedDraft, basedOn: session.original)
            close()
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
        let session = ZoneEditorSession(state: ZonesState(layouts: [layout, ZoneTemplates.makeLayout(
            "two-columns", name: templateName("two-columns"))], defaultLayout: layout.id),
                                        gridEnabled: true, theme: .named("graphite"))
        session.monitors = [.init(key: "sample", name: tx("Built-in Display", "Pantalla integrada")),
                            .init(key: "external", name: tx("External Display", "Pantalla externa"))]
        let bounds = CGRect(origin: .zero, size: size)
        // Include the area reserved for the menu bar in the sample.
        let visible = CGRect(x: 0, y: 0, width: size.width, height: max(0, size.height - 28))
        let usable = ZoneGeometry.usableRect(frame: bounds, visibleFrame: visible, barHeight: 34, barReserves: true)
        session.place(on: "sample", usable: usable, selectLayout: true)
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
            default: break
            }
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
        var id: String { key }
    }

    struct Preview {
        var zoneID: UUID?
        var rect: ZoneRect
        var guides: [ZoneSnapping.Guide]
    }

    enum Dialog {
        case discard
        case deleteLayout(UUID, name: String)
        case saveError(String)
    }

    let original: ZonesState
    let theme: BarTheme
    private(set) var draft: ZonesState
    private(set) var layoutID: UUID?
    private(set) var displayKey = ""
    private(set) var usable = CGRect.zero
    @ObservationIgnored weak var canvas: ZoneCanvasView?
    @ObservationIgnored var hudFrame = CGRect.zero
    var monitors: [Monitor] = []
    var selectedZone: UUID?
    var preview: Preview?
    var drawArmed = false
    var hudCollapsed = false
    var gridEnabled: Bool
    private(set) var dialog: Dialog?

    var selectDisplay: (String) -> Void = { _ in }
    var changeGrid: (Bool) -> Void = { _ in }
    var save: () -> Void = {}
    var discard: () -> Void = {}

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

    var finishedDraft: ZonesState {
        var result = draft
        let originalNames = Dictionary(uniqueKeysWithValues: original.layouts.map { ($0.id, $0.name) })
        for index in result.layouts.indices where result.layouts[index].name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let layout = result.layouts[index]
            if layout.name != originalNames[layout.id] { result.layouts[index].name = Self.untitled }
        }
        return result
    }

    static var untitled: String { tx("Untitled layout", "Diseño sin título") }

    var isAssigned: Bool { layoutID != nil && draft.layout(forDisplay: displayKey)?.id == layoutID }

    func assignToDisplay() {
        if let layoutID { draft.activeByDisplay[displayKey] = layoutID.uuidString }
    }

    func place(on key: String, usable: CGRect, selectLayout: Bool) {
        displayKey = key
        self.usable = usable
        if selectLayout {
            chooseLayout(draft.layout(forDisplay: key)?.id ?? draft.defaultLayout)
        } else {
            resetGesture()
        }
    }

    func chooseLayout(_ id: UUID?) {
        layoutID = id
        selectedZone = nil
        drawArmed = false
        resetGesture()
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
        else if draft != original { present(.discard) }
        else { discard() }
    }

    func confirmDialog() {
        switch dialog {
        case .discard: discard()
        case let .deleteLayout(id, _):
            if draft.delete(id) { chooseLayout(draft.layout(forDisplay: displayKey)?.id ?? draft.defaultLayout) }
            dismissDialog()
        case .saveError, nil: dismissDialog()
        }
    }

    func createLayout(template id: String? = nil) {
        let layout = id.map { ZoneTemplates.makeLayout($0, name: ZoneEditor.templateName($0)) }
            ?? ZoneLayout(name: Self.untitled)
        draft.layouts.append(layout)
        chooseLayout(layout.id)
    }

    func duplicateLayout() {
        guard let layout else { return }
        let name = tx("\(layout.name) copy", "Copia de \(layout.name)")
        let id = draft.duplicate(layout.id, name: name)
        chooseLayout(id)
    }

    func requestDeleteLayout() {
        guard let layout, draft.layouts.count > 1 else { return }
        present(.deleteLayout(layout.id, name: layout.name.isEmpty ? Self.untitled : layout.name))
    }

    func apply(_ preview: Preview) {
        guard let layoutIndex else { return }
        if let id = preview.zoneID {
            guard let index = draft.layouts[layoutIndex].zones.firstIndex(where: { $0.id == id }) else { return }
            draft.layouts[layoutIndex].zones[index].rect = preview.rect
        } else {
            selectedZone = draft.layouts[layoutIndex].addZone(preview.rect)
            drawArmed = false
        }
    }

    func deleteZone() {
        guard let layoutIndex, let selectedZone else { return }
        draft.layouts[layoutIndex].zones.removeAll { $0.id == selectedZone }
        self.selectedZone = nil
        resetGesture()
    }

    func duplicateZone() {
        guard let layoutIndex, let zone = layout?.zones.first(where: { $0.id == selectedZone }) else { return }
        selectedZone = draft.layouts[layoutIndex].addZone(zone.rect)
        resetGesture()
    }
}

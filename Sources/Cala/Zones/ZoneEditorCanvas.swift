import AppKit
import SwiftUI

struct ZoneEditorScene: View {
    let session: ZoneEditorSession
    var interactive = true
    @Environment(\.colorScheme) private var systemScheme
    private let coordinateSpace = "zonesEditorScene"

    var body: some View {
        GeometryReader { proxy in
            let usable = ZoneGeometry.axRect(fromAppKit: session.usable, primaryHeight: proxy.size.height)
            let scheme = session.theme.dark.map { $0 ? ColorScheme.dark : .light } ?? systemScheme
            ZStack(alignment: .topLeading) {
                ZoneEditorArtwork(session: session)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                if interactive {
                    ZoneEditorCanvasInput(session: session)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityHidden(session.dialog != nil)
                }
                if usable.width > 0, usable.height > 0, session.layout?.zones.isEmpty == true, session.preview == nil {
                    ZoneEditorEmptyHint(theme: session.theme)
                        .frame(width: usable.width, height: usable.height)
                        .padding(.leading, usable.minX)
                        .padding(.top, usable.minY)
                        .allowsHitTesting(false)
                }
                if session.dialog != nil {
                    Color.black.opacity(0.32)
                        .onTapGesture {}
                        .accessibilityHidden(true)
                }
                if usable.width > 0, usable.height > 0 {
                    // Laid out with padding (not an offset) so what is drawn and what takes clicks always agree.
                    VStack(spacing: 12) {
                        ZoneEditorHUD(session: session)
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(coordinateSpace)) } action: {
                                session.hudFrame = $0
                            }
                            .disabled(session.dialog != nil)
                            .accessibilityHidden(session.dialog != nil)
                            .frame(maxWidth: .infinity, alignment: session.hudCollapsed ? .trailing : .center)
                        if let dialog = session.dialog {
                            ZoneEditorDialog(session: session, dialog: dialog)
                        }
                    }
                    .frame(width: max(0, usable.width - 24))
                    .padding(.leading, usable.minX + 12)
                    .padding(.top, usable.minY + 14)
                }
            }
            .coordinateSpace(name: coordinateSpace)
            .environment(\.colorScheme, scheme)
        }
    }
}

/// Shown on an empty layout: what to do first.
private struct ZoneEditorEmptyHint: View {
    let theme: BarTheme

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.dashed")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(theme.accent)
            Text(tx("Drag on the screen to draw a zone", "Arrastra sobre la pantalla para dibujar una zona"))
                .font(.system(size: 22, weight: .semibold))
            Text(tx("or use Add zone", "o usa Añadir zona"))
                .font(.system(size: 14))
                .flyoutSecondary()
        }
        .accessibilityHidden(true)
    }
}

private struct ZoneEditorArtwork: View {
    let session: ZoneEditorSession
    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var scale

    var body: some View {
        let usable = session.usable
        let theme = session.theme
        let zones = session.layout?.zones ?? []
        let selected = session.selectedZone
        let preview = session.preview
        let grid = session.gridEnabled
        let dark = scheme == .dark
        let equalColor = StatusColor.color(.ok, dark: dark)
        let selection = session.selection
        let cut = session.splitPreview
        let cutHint = tx("Click to split · ⇧ turns the cut", "Clic para dividir · ⇧ gira el corte")
        Canvas { context, size in
            func flipped(_ rect: CGRect) -> CGRect {
                ZoneGeometry.axRect(fromAppKit: rect, primaryHeight: size.height)
            }
            func frame(_ rect: ZoneRect) -> CGRect {
                flipped(ZoneGeometry.frame(for: rect, in: usable))
            }
            let screen = CGRect(origin: .zero, size: size)
            let work = flipped(usable)
            context.fill(Path(screen), with: .color(.black.opacity(dark ? 0.83 : 0.52)))
            guard work.width > 0, work.height > 0 else { return }
            context.fill(Path(work), with: .color(FlyoutStyle.surface(dark: dark).opacity(0.96)))
            if !theme.colors.isEmpty {
                context.fill(Path(work), with: .linearGradient(Gradient(colors: theme.colors.map { $0.opacity(0.38) }),
                    startPoint: work.origin, endPoint: CGPoint(x: work.maxX, y: work.maxY)))
            }

            /// Snapping guides are dashed so they never read as a zone border; grid lines stay solid and faint. The
            /// screen-centre guide is dash-dotted and the equal-size guide green, so each snap says what it did.
            func line(_ guide: ZoneSnapping.Guide, color: Color, dashed: Bool = false) {
                let fraction = guide.axis == .x ? ZoneRect(x: guide.position, y: 0, w: 0, h: 1)
                    : ZoneRect(x: 0, y: guide.position, w: 1, h: 0)
                let rect = frame(fraction)
                let pixel = 1 / scale
                let x = min(max(floor(rect.minX * scale) / scale + pixel / 2, work.minX + pixel / 2), work.maxX - pixel / 2)
                let y = min(max(floor(rect.minY * scale) / scale + pixel / 2, work.minY + pixel / 2), work.maxY - pixel / 2)
                var path = Path()
                if guide.axis == .x {
                    path.move(to: CGPoint(x: x, y: work.minY))
                    path.addLine(to: CGPoint(x: x, y: work.maxY))
                } else {
                    path.move(to: CGPoint(x: work.minX, y: y))
                    path.addLine(to: CGPoint(x: work.maxX, y: y))
                }
                if dashed {
                    let pattern: [CGFloat] = guide.kind == .center ? [10, 3, 2, 3] : [6, 4]
                    let width = guide.kind == .edge ? max(pixel, 1) : 1.5
                    context.stroke(path, with: .color(guide.kind == .equalSize ? equalColor : color),
                                   style: StrokeStyle(lineWidth: width, lineCap: .butt, dash: pattern))
                } else {
                    context.stroke(path, with: .color(color), lineWidth: pixel)
                }
            }

            if grid {
                let lines = ZoneSnapping.candidates(others: [], grid: true)
                for x in lines.xs.dropFirst().dropLast() { line(.init(axis: .x, position: x), color: .primary.opacity(0.10)) }
                for y in lines.ys.dropFirst().dropLast() { line(.init(axis: .y, position: y), color: .primary.opacity(0.10)) }
            }
            context.strokeBorderOfWorkArea(work, scale: scale, accent: theme.accent)

            let activeID = preview == nil ? selected : preview?.zoneID
            let activeIndex = zones.firstIndex { $0.id == activeID }
            let activeRect = preview?.rect ?? activeIndex.map { zones[$0].rect }
            let activeSize = activeRect.map { ZoneMeasure.size($0, in: usable.size) }

            /// The zone number, and under it its size in the monitor's points. A width or height equal to the
            /// selected (or dragged) zone's is shown in green, so equal side zones are easy to make.
            func drawZone(_ rect: CGRect, zone: ZoneRect, number: Int, active: Bool, affected: Bool = false) {
                let width: CGFloat = active || affected ? 2 : 1
                func align(_ position: CGFloat) -> CGFloat { (position * scale).rounded() / scale }
                let aligned = CGRect(x: align(rect.minX), y: align(rect.minY),
                                     width: align(rect.maxX) - align(rect.minX),
                                     height: align(rect.maxY) - align(rect.minY))
                let outline = Path(roundedRect: aligned.insetBy(dx: width / 2, dy: width / 2), cornerRadius: 3)
                context.fill(outline, with: .color(theme.accent.opacity(active ? 0.24 : affected ? 0.15 : 0.07)))
                context.stroke(outline, with: .color(theme.accent.opacity(active || affected ? 1 : 0.7)), lineWidth: width)
                guard rect.width >= 30, rect.height >= 24 else { return }
                let showSize = rect.width >= 84 && rect.height >= 64
                let label = Text(number.formatted()).font(.system(size: active ? 28 : 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(active ? theme.accent : FlyoutStyle.secondary(dark: dark))
                context.draw(label, at: CGPoint(x: rect.midX, y: rect.midY - (showSize ? 10 : 0)))
                guard showSize else { return }
                let size = ZoneMeasure.size(zone, in: usable.size)
                let base = active ? theme.accent : FlyoutStyle.secondary(dark: dark)
                let sameW = !active && activeSize?.w == size.w
                let sameH = !active && activeSize?.h == size.h
                let font = Font.system(size: 12, weight: active ? .semibold : .medium).monospacedDigit()
                // Verbatim: a size is "1512 × 949", never "1,512 × 949".
                let text = Text(verbatim: String(size.w)).foregroundStyle(sameW ? equalColor : base)
                    + Text(verbatim: " × ").foregroundStyle(base)
                    + Text(verbatim: String(size.h)).foregroundStyle(sameH ? equalColor : base)
                context.draw(text.font(font), at: CGPoint(x: rect.midX, y: rect.midY + (active ? 18 : 15)))
            }

            for (index, zone) in zones.enumerated() where zone.id != activeID {
                let moved = preview?.others[zone.id]
                drawZone(frame(moved ?? zone.rect), zone: moved ?? zone.rect, number: index + 1, active: false,
                         affected: moved != nil || (preview == nil && selection.contains(zone.id)))
            }
            // Linked split preview: a dashed cut across the selected zone with a short hint next to it.
            if preview == nil, let cut, let zone = zones.first(where: { $0.id == cut.zone }) {
                let line = cut.vertical ? ZoneRect(x: cut.position, y: zone.rect.y, w: 0, h: zone.rect.h)
                    : ZoneRect(x: zone.rect.x, y: cut.position, w: zone.rect.w, h: 0)
                let r = frame(line)
                var path = Path()
                path.move(to: CGPoint(x: r.minX, y: r.minY))
                path.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
                context.stroke(path, with: .color(theme.accent), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [7, 5]))
                let text = context.resolve(Text(cutHint).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.white))
                let size = text.measure(in: CGSize(width: 400, height: 40))
                let zoneFrame = frame(zone.rect)
                // Beside the cut, clear of the zone's number and size in its middle.
                let anchor = cut.vertical ? CGPoint(x: r.midX + size.width / 2 + 18, y: zoneFrame.midY + 64)
                    : CGPoint(x: zoneFrame.minX + size.width / 2 + 24, y: r.midY - 18)
                let pill = CGRect(x: anchor.x - size.width / 2 - 8, y: anchor.y - size.height / 2 - 4,
                                  width: size.width + 16, height: size.height + 8)
                context.fill(Path(roundedRect: pill, cornerRadius: pill.height / 2), with: .color(.black.opacity(0.72)))
                context.draw(text, at: anchor)
            }
            if let activeRect {
                let rect = frame(activeRect)
                drawZone(rect, zone: activeRect, number: (activeIndex ?? zones.count) + 1, active: true)
                for guide in preview?.guides ?? [] { line(guide, color: theme.accent, dashed: true) }
                if preview == nil || preview?.zoneID != nil {
                    let appKitRect = ZoneGeometry.frame(for: activeRect, in: usable)
                    let side = ZonePicking.EditorHandle.side
                    for grip in ZonePicking.editorHandles(in: appKitRect) {
                        let p = ZoneGeometry.cgPoint(fromAppKit: grip.center, primaryHeight: size.height)
                        let handle = Path(roundedRect: CGRect(x: p.x - side / 2, y: p.y - side / 2,
                                                              width: side, height: side), cornerRadius: 2)
                        context.fill(handle, with: .color(theme.accent))
                        context.stroke(handle, with: .color(FlyoutStyle.surface(dark: dark)), lineWidth: 1)
                    }
                }
            }
        }
    }
}

private extension GraphicsContext {
    func strokeBorderOfWorkArea(_ rect: CGRect, scale: CGFloat, accent: Color) {
        let inset = 0.5 / scale
        stroke(Path(rect.insetBy(dx: inset, dy: inset)), with: .color(accent.opacity(0.48)), lineWidth: 1 / scale)
    }
}

private struct ZoneEditorCanvasInput: NSViewRepresentable {
    let session: ZoneEditorSession

    func makeNSView(context: Context) -> ZoneCanvasView { ZoneCanvasView(session: session) }
    func updateNSView(_ view: ZoneCanvasView, context: Context) {}
}

final class ZoneCanvasView: NSView {
    private typealias Point = (x: Double, y: Double)

    private struct Gesture {
        let start: Point
        let hit: ZonePicking.EditorHit?
        let others: [ZoneRect]
        /// The layout's zones when the gesture began, and whether Linked mode applies to it.
        let zones: [Zone]
        let linked: Bool
        /// Linked: the zone was already the only selection when pressed, so a click without a drag splits it.
        var splitsOnClick = false
        /// Free ⇧-press: a click without a drag toggles this zone in the selection (a drag draws).
        var toggles: UUID?
        var last: Point?
    }

    private let session: ZoneEditorSession
    private var gesture: Gesture?
    private var tracking: NSTrackingArea?

    init(session: ZoneEditorSession) {
        self.session = session
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    /// The first click on an inactive editor already draws or grabs a zone.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        session.canvas = self
        window.initialFirstResponder = self
        window.makeFirstResponder(self)
    }

    func resetGesture() { gesture = nil }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .layoutArea }
    override func accessibilityRoleDescription() -> String? { tx("zones canvas", "lienzo de zonas") }

    override func accessibilityLabel() -> String? {
        let zones = session.layout?.zones ?? []
        let name = session.layoutName.isEmpty ? ZoneEditorSession.untitled : session.layoutName
        var text = tx("\(name): \(zones.count) zones", "\(name): \(zones.count) zonas")
        if let index = zones.firstIndex(where: { $0.id == session.selectedZone }) {
            text += tx(", zone \(index + 1) selected", ", zona \(index + 1) seleccionada")
        }
        return text
    }

    override func accessibilityHelp() -> String? {
        tx("Drag on an empty area to draw a zone (hold Shift to draw over other zones), drag a zone to move it or its edges to resize it. Delete removes the selected zone, Return saves, Esc closes.",
           "Arrastra en un área vacía para dibujar una zona (mantén Mayús para dibujar sobre otras), arrastra una zona para moverla o sus bordes para cambiar su tamaño. Suprimir borra la zona seleccionada, Retorno guarda, Esc cierra.")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeInKeyWindow, .mouseMoved,
                                                            .mouseEnteredAndExited, .cursorUpdate], owner: self, userInfo: nil)
        addTrackingArea(tracking)
        self.tracking = tracking
    }

    override func mouseEntered(with event: NSEvent) { updateCursor(for: event) }
    override func mouseMoved(with event: NSEvent) {
        updateCursor(for: event)
        updateSplitPreview(for: event)
    }
    override func cursorUpdate(with event: NSEvent) { updateCursor(for: event) }
    override func mouseExited(with event: NSEvent) {
        if gesture == nil { NSCursor.arrow.set() }
    }

    override func mouseDown(with event: NSEvent) {
        guard session.dialog == nil else { return }
        window?.makeFirstResponder(self)
        resetGesture()
        session.preview = nil
        let point = appKitPoint(for: event)
        guard let layout = session.layout, !session.usable.isEmpty else { return }
        let shift = event.modifierFlags.contains(.shift)
        let linked = session.linked
        if linked && shift {
            // Linked ⇧-click builds a selection to merge.
            if let zone = ZonePicking.chosen(point, zones: layout.zones, usable: session.usable) { session.toggleSelection(zone.id) }
            session.splitPreview = nil
            return
        }
        let hit = editorHit(at: point, in: layout, drawing: shift && !linked)
        guard hit != nil || isOnCanvas(point) else { return }
        let alreadyOnly = hit.map { session.selectedZone == $0.zone.id && session.extraSelection.isEmpty } ?? false
        var toggles: UUID?
        if shift {
            toggles = ZonePicking.chosen(point, zones: layout.zones, usable: session.usable)?.id
        } else {
            session.selectOnly(hit?.zone.id)
        }
        if !linked, event.clickCount == 2, hit != nil {
            session.requestSize()   // Free: double-click a zone to type its exact size
            return
        }
        gesture = Gesture(start: fraction(point), hit: hit,
                          others: layout.zones.filter { $0.id != hit?.zone.id }.map(\.rect),
                          zones: layout.zones, linked: linked,
                          splitsOnClick: linked && alreadyOnly && hit?.edges.isEmpty == true, toggles: toggles)
        if !(gesture?.splitsOnClick ?? false) { session.splitPreview = nil }
    }

    /// Right-click a zone. Linked: size, split, merge, equal sizes, delete. Free: size, centring, equal sizes,
    /// merge, duplicate, delete.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard session.dialog == nil, let layout = session.layout else { return nil }
        let point = appKitPoint(for: event)
        guard let zone = ZonePicking.chosen(point, zones: layout.zones, usable: session.usable) else { return nil }
        resetGesture()
        session.splitPreview = nil
        if !session.selection.contains(zone.id) { session.selectOnly(zone.id) }
        let session = session
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, enabled: Bool = true, _ action: @escaping () -> Void) {
            let item = BlockItem(title, action)
            item.isEnabled = enabled
            menu.addItem(item)
        }
        add(tx("Size…", "Tamaño…")) { session.requestSize() }
        menu.addItem(.separator())
        if session.linked {
            let canSplitV = ZoneTiling.split(zone.rect, vertically: true, minSize: session.minimumSize) != nil
            let canSplitH = ZoneTiling.split(zone.rect, vertically: false, minSize: session.minimumSize) != nil
            add(tx("Split into Left and Right", "Dividir en izquierda y derecha"), enabled: canSplitV) {
                session.split(zone.id, vertically: true)
            }
            add(tx("Split into Top and Bottom", "Dividir en arriba y abajo"), enabled: canSplitH) {
                session.split(zone.id, vertically: false)
            }
        } else {
            add(tx("Center Horizontally", "Centrar horizontalmente")) { session.centerZone(horizontally: true) }
            add(tx("Center Vertically", "Centrar verticalmente")) { session.centerZone(horizontally: false) }
        }
        add(tx("Merge Selected Zones", "Unir zonas seleccionadas"), enabled: session.canMerge) { session.mergeSelection() }
        add(tx("Equal Widths in This Row", "Igualar anchos de esta fila"), enabled: session.canEqualize(horizontally: true)) {
            session.equalizeZones(horizontally: true)
        }
        add(tx("Equal Heights in This Column", "Igualar altos de esta columna"), enabled: session.canEqualize(horizontally: false)) {
            session.equalizeZones(horizontally: false)
        }
        menu.addItem(.separator())
        if !session.linked { add(tx("Duplicate Zone", "Duplicar zona")) { session.duplicateZone() } }
        add(tx("Delete Zone", "Eliminar zona"), enabled: session.canDeleteZone) { session.deleteZone() }
        return menu
    }

    override func mouseDragged(with event: NSEvent) {
        guard let current = gesture else { return }
        let point = fraction(appKitPoint(for: event))
        let usable = session.usable
        let traveled = hypot((point.x - current.start.x) * usable.width, (point.y - current.start.y) * usable.height)
        guard current.last != nil || traveled >= 3 else { return }
        gesture?.last = point
        cursor(for: current.hit, dragging: true).set()
        update(current, to: point, snapping: !event.modifierFlags.contains(.option))
    }

    override func flagsChanged(with event: NSEvent) {
        guard let gesture, let last = gesture.last else {
            updateCursor(for: event)
            updateSplitPreview(for: event)
            super.flagsChanged(with: event)
            return
        }
        update(gesture, to: last, snapping: !event.modifierFlags.contains(.option))
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            resetGesture()
            updateCursor(for: event)
            updateSplitPreview(for: event)
        }
        guard let gesture, gesture.last != nil else {
            session.preview = nil   // a click without a drag never leaves a picture of a change behind
            if let gesture, let id = gesture.toggles {
                session.toggleSelection(id)
            } else if gesture?.splitsOnClick == true, let cut = session.splitPreview, cut.zone == gesture?.hit?.zone.id {
                session.split(cut.zone, vertically: cut.vertical, at: cut.position)
            }
            return
        }
        update(gesture, to: fraction(appKitPoint(for: event)), snapping: !event.modifierFlags.contains(.option))
        if gesture.linked, gesture.hit?.edges.isEmpty == true, session.preview?.others.isEmpty ?? true {
            // A Linked zone body dropped on nothing: nothing moves; say once how Linked zones change.
            session.preview = nil
            session.notify(session.linkedMoveHint, once: true)
            return
        }
        if let preview = session.preview { session.apply(preview) }
        session.preview = nil
    }

    override func keyDown(with event: NSEvent) {
        if session.dialog != nil {
            if event.keyCode == 53 { session.dismissDialog() }
            return
        }
        let large = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 51, 117: session.deleteZone()
        case 53: session.requestCancel()
        case 36, 76: session.save()
        case 123: session.nudge(dx: -1, dy: 0, large: large)
        case 124: session.nudge(dx: 1, dy: 0, large: large)
        case 125: session.nudge(dx: 0, dy: 1, large: large)
        case 126: session.nudge(dx: 0, dy: -1, large: large)
        default: super.keyDown(with: event)
        }
    }

    /// Free: Shift draws a new zone anywhere, also over existing ones. Linked: an edge on the screen's border is not
    /// a divider (dragging it would open a hole), so grabbing there counts as grabbing the zone.
    private func editorHit(at point: CGPoint, in layout: ZoneLayout, drawing: Bool) -> ZonePicking.EditorHit? {
        guard !drawing else { return nil }
        guard var hit = ZonePicking.editorHit(at: point, zones: layout.zones, usable: session.usable,
                                              selectedID: session.selectedZone) else { return nil }
        if layout.mode == .linked { hit.edges.subtract(ZoneTiling.borderEdges(hit.zone.rect)) }
        return hit
    }

    /// Linked: over the selected zone (away from its dividers) a dashed line shows where a click would split it.
    private func updateSplitPreview(for event: NSEvent) {
        guard gesture == nil, session.linked, session.dialog == nil, let layout = session.layout,
              let window, !session.usable.isEmpty else {
            if gesture == nil, session.splitPreview != nil { session.splitPreview = nil }
            return
        }
        let location = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let point = ZoneGeometry.appKitPoint(fromCG: location, primaryHeight: bounds.height)
        let onBody = !session.hudFrame.contains(location)
            && editorHit(at: point, in: layout, drawing: false).map { $0.edges.isEmpty && $0.zone.id == session.selectedZone } == true
            && session.extraSelection.isEmpty
        let next = onBody ? session.splitCandidate(at: fraction(point), flip: NSEvent.modifierFlags.contains(.shift)) : nil
        if next?.zone != session.splitPreview?.zone || next?.vertical != session.splitPreview?.vertical
            || next?.position != session.splitPreview?.position {
            session.splitPreview = next
        }
    }

    private func isOnCanvas(_ point: CGPoint) -> Bool {
        let usable = session.usable
        return point.x >= usable.minX && point.x <= usable.maxX && point.y >= usable.minY && point.y <= usable.maxY
    }

    private func updateCursor(for event: NSEvent) {
        if let gesture {
            cursor(for: gesture.hit, dragging: gesture.last != nil).set()
            return
        }
        // Key events (Shift pressed or released) carry no reliable pointer position.
        let inWindow = event.type == .flagsChanged ? window?.mouseLocationOutsideOfEventStream ?? .zero : event.locationInWindow
        let location = convert(inWindow, from: nil)
        guard !session.hudFrame.contains(location) else { return }
        guard session.dialog == nil, let layout = session.layout, !session.usable.isEmpty else {
            NSCursor.arrow.set()
            return
        }
        let point = ZoneGeometry.appKitPoint(fromCG: location, primaryHeight: bounds.height)
        let hit = editorHit(at: point, in: layout, drawing: event.modifierFlags.contains(.shift))
        let cursor = hit != nil || isOnCanvas(point) ? cursor(for: hit, dragging: false) : .arrow
        cursor.set()
    }

    /// Free: crosshair to draw, hands to move, arrows to resize. Linked: a plain arrow over a zone (it does not
    /// move), a closed hand while dragging it onto another to swap, resize arrows on dividers.
    private func cursor(for hit: ZonePicking.EditorHit?, dragging: Bool) -> NSCursor {
        guard let edges = hit?.edges else { return session.linked ? .arrow : .crosshair }
        guard !edges.isEmpty else {
            if session.linked { return dragging ? .closedHand : .arrow }
            return dragging ? .closedHand : .openHand
        }
        return ZoneEditorResizeCursor.forEdges(edges)
    }

    private func appKitPoint(for event: NSEvent) -> CGPoint {
        ZoneGeometry.appKitPoint(fromCG: convert(event.locationInWindow, from: nil), primaryHeight: bounds.height)
    }

    private func fraction(_ point: CGPoint) -> Point {
        let rect = ZoneGeometry.fraction(for: CGRect(origin: point, size: .zero), in: session.usable)
        return (rect.x, rect.y)
    }

    private func update(_ gesture: Gesture, to point: Point, snapping: Bool) {
        let usable = session.usable
        let width = Double(usable.width)
        let height = Double(usable.height)
        let threshold = (x: 8 / width, y: 8 / height)
        let minimum = session.minimumSize
        let grid = session.gridEnabled
        guard let hit = gesture.hit, let index = gesture.zones.firstIndex(where: { $0.id == hit.zone.id }) else {
            let result = ZoneSnapping.draw(from: gesture.start, to: point, others: gesture.others,
                                           grid: grid, snapping: snapping, threshold: threshold, minSize: minimum)
            session.preview = .init(zoneID: nil, rect: result.0, guides: result.1)
            return
        }
        let rects = gesture.zones.map(\.rect)
        let delta = (dx: point.x - gesture.start.x, dy: point.y - gesture.start.y)
        if hit.edges.isEmpty {
            // Linked zones never move freely: dropping one on another swaps the two, anything else does nothing.
            if gesture.linked {
                if let target = swapTarget(at: point, excluding: hit.zone.id, in: gesture.zones) {
                    session.preview = .init(zoneID: hit.zone.id, rect: target.rect, guides: [], others: [target.id: hit.zone.rect])
                } else {
                    session.preview = nil
                }
                return
            }
            let result = ZoneSnapping.move(hit.zone.rect, by: delta, others: gesture.others,
                                           grid: grid, snapping: snapping, threshold: threshold)
            session.preview = .init(zoneID: hit.zone.id, rect: result.0, guides: result.1)
            return
        }
        guard gesture.linked else {
            let result = ZoneSnapping.resize(hit.zone.rect, edges: hit.edges, by: delta, others: gesture.others,
                                             grid: grid, snapping: snapping, threshold: threshold, minSize: minimum)
            session.preview = .init(zoneID: hit.zone.id, rect: result.0, guides: result.1)
            return
        }
        // Linked resize: every edge joined to the dragged one follows; joined zones are not snap targets.
        var joined = Set<Int>()
        for edge in [ZoneSnapping.Edges.left, .right, .top, .bottom] where hit.edges.contains(edge) {
            joined.formUnion(ZoneLinking.linkedEdges(rects, index: index, edge: edge).map(\.index))
        }
        let others = rects.indices.filter { $0 != index && !joined.contains($0) }.map { rects[$0] }
        let proposed = ZoneSnapping.resize(hit.zone.rect, edges: hit.edges, by: delta, others: others,
                                           grid: grid, snapping: snapping, threshold: threshold, minSize: minimum)
        let changes = ZoneLinking.resize(rects, index: index, edges: hit.edges, proposed: proposed.0, minSize: minimum)
        let rect = changes[index] ?? hit.zone.rect
        var moved: [UUID: ZoneRect] = [:]
        for (i, r) in changes where i != index { moved[gesture.zones[i].id] = r }
        session.preview = .init(zoneID: hit.zone.id, rect: rect, guides: rect == proposed.0 ? proposed.1 : [], others: moved)
    }

    /// The zone under the pointer, other than the one being moved (the smallest when they overlap).
    private func swapTarget(at point: Point, excluding id: UUID, in zones: [Zone]) -> Zone? {
        zones.filter { zone in
            zone.id != id && point.x >= zone.rect.x && point.x < zone.rect.maxX && point.y >= zone.rect.y && point.y < zone.rect.maxY
        }.min { $0.rect.area < $1.rect.area }
    }
}

@MainActor
private enum ZoneEditorResizeCursor {
    static func forEdges(_ edges: ZoneSnapping.Edges) -> NSCursor {
        if #available(macOS 15.0, *) {
            let position: NSCursor.FrameResizePosition
            switch edges {
            case .left: position = .left
            case .right: position = .right
            case .top: position = .top
            case .bottom: position = .bottom
            case [.left, .top]: position = .topLeft
            case [.right, .top]: position = .topRight
            case [.left, .bottom]: position = .bottomLeft
            default: position = .bottomRight
            }
            return .frameResize(position: position, directions: .all)
        }
        switch edges {
        case .left, .right: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        case [.left, .bottom], [.right, .top]: return rising
        default: return falling
        }
    }

    private static let rising = diagonal(rising: true)
    private static let falling = diagonal(rising: false)

    private static func diagonal(rising: Bool) -> NSCursor {
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: rising ? y : 20 - y) }
            let path = NSBezierPath()
            path.move(to: point(4, 4))
            path.line(to: point(16, 16))
            path.move(to: point(4, 9))
            path.line(to: point(4, 4))
            path.line(to: point(9, 4))
            path.move(to: point(11, 16))
            path.line(to: point(16, 16))
            path.line(to: point(16, 11))
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            NSColor.white.setStroke()
            path.lineWidth = 3.5
            path.stroke()
            NSColor.black.setStroke()
            path.lineWidth = 1.5
            path.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: CGPoint(x: 10, y: 10))
    }
}

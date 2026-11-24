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
                if session.dialog != nil {
                    Color.black.opacity(0.32)
                        .onTapGesture {}
                        .accessibilityHidden(true)
                }
                if usable.width > 0, usable.height > 0 {
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
                    .offset(x: usable.minX + 12, y: usable.minY + 18)
                }
            }
            .coordinateSpace(name: coordinateSpace)
            .environment(\.colorScheme, scheme)
        }
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

            func line(_ guide: ZoneSnapping.Guide, color: Color) {
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
                context.stroke(path, with: .color(color), lineWidth: pixel)
            }

            if grid {
                let lines = ZoneSnapping.candidates(others: [], grid: true)
                for x in lines.xs.dropFirst().dropLast() { line(.init(axis: .x, position: x), color: .primary.opacity(0.10)) }
                for y in lines.ys.dropFirst().dropLast() { line(.init(axis: .y, position: y), color: .primary.opacity(0.10)) }
            }
            context.strokeBorderOfWorkArea(work, scale: scale, accent: theme.accent)

            func drawZone(_ rect: CGRect, number: Int, active: Bool) {
                let width: CGFloat = active ? 2 : 1
                func align(_ position: CGFloat) -> CGFloat { (position * scale).rounded() / scale }
                let aligned = CGRect(x: align(rect.minX), y: align(rect.minY),
                                     width: align(rect.maxX) - align(rect.minX),
                                     height: align(rect.maxY) - align(rect.minY))
                let outline = Path(roundedRect: aligned.insetBy(dx: width / 2, dy: width / 2), cornerRadius: 3)
                context.fill(outline, with: .color(theme.accent.opacity(active ? 0.24 : 0.07)))
                context.stroke(outline, with: .color(theme.accent.opacity(active ? 1 : 0.7)), lineWidth: width)
                if rect.width >= 30, rect.height >= 24 {
                    let label = Text(number.formatted()).font(.system(size: active ? 28 : 20, weight: .semibold, design: .rounded))
                        .foregroundStyle(active ? theme.accent : FlyoutStyle.secondary(dark: dark))
                    context.draw(label, at: CGPoint(x: rect.midX, y: rect.midY))
                }
            }

            let activeID = preview == nil ? selected : preview?.zoneID
            for (index, zone) in zones.enumerated() where zone.id != activeID {
                drawZone(frame(zone.rect), number: index + 1, active: false)
            }
            let activeIndex = zones.firstIndex { $0.id == activeID }
            if let activeRect = preview?.rect ?? activeIndex.map({ zones[$0].rect }) {
                let rect = frame(activeRect)
                drawZone(rect, number: (activeIndex ?? zones.count) + 1, active: true)
                for guide in preview?.guides ?? [] { line(guide, color: theme.accent) }
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        session.canvas = self
        window.initialFirstResponder = self
        window.makeFirstResponder(self)
    }

    func resetGesture() { gesture = nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeInKeyWindow, .mouseMoved,
                                                            .mouseEnteredAndExited, .cursorUpdate], owner: self, userInfo: nil)
        addTrackingArea(tracking)
        self.tracking = tracking
    }

    override func mouseEntered(with event: NSEvent) { updateCursor(for: event) }
    override func mouseMoved(with event: NSEvent) { updateCursor(for: event) }
    override func cursorUpdate(with event: NSEvent) { updateCursor(for: event) }
    override func mouseExited(with event: NSEvent) {
        if gesture == nil { NSCursor.arrow.set() }
    }

    override func mouseDown(with event: NSEvent) {
        guard session.dialog == nil else { return }
        window?.makeFirstResponder(self)
        resetGesture()
        let point = appKitPoint(for: event)
        guard let layout = session.layout, !session.usable.isEmpty else { return }
        let hit = editorHit(at: point, in: layout)
        guard hit != nil || isOnCanvas(point) else { return }
        session.selectedZone = hit?.zone.id
        gesture = Gesture(start: fraction(point), hit: hit,
                          others: layout.zones.filter { $0.id != hit?.zone.id }.map(\.rect))
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
            super.flagsChanged(with: event)
            return
        }
        update(gesture, to: last, snapping: !event.modifierFlags.contains(.option))
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            resetGesture()
            updateCursor(for: event)
        }
        guard let gesture, gesture.last != nil else { return }
        update(gesture, to: fraction(appKitPoint(for: event)), snapping: !event.modifierFlags.contains(.option))
        if let preview = session.preview { session.apply(preview) }
        session.preview = nil
    }

    override func keyDown(with event: NSEvent) {
        if session.dialog != nil {
            if event.keyCode == 53 { session.dismissDialog() }
            return
        }
        switch event.keyCode {
        case 51, 117: session.deleteZone()
        case 53: session.requestCancel()
        case 36, 76: session.save()
        default: super.keyDown(with: event)
        }
    }

    private func editorHit(at point: CGPoint, in layout: ZoneLayout) -> ZonePicking.EditorHit? {
        guard !session.drawArmed else { return nil }
        return ZonePicking.editorHit(at: point, zones: layout.zones, usable: session.usable,
                                     selectedID: session.selectedZone)
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
        let location = convert(event.locationInWindow, from: nil)
        guard !session.hudFrame.contains(location) else { return }
        guard session.dialog == nil, let layout = session.layout, !session.usable.isEmpty else {
            NSCursor.arrow.set()
            return
        }
        let point = ZoneGeometry.appKitPoint(fromCG: location, primaryHeight: bounds.height)
        let hit = editorHit(at: point, in: layout)
        let cursor = hit != nil || isOnCanvas(point) ? cursor(for: hit, dragging: false) : .arrow
        cursor.set()
    }

    private func cursor(for hit: ZonePicking.EditorHit?, dragging: Bool) -> NSCursor {
        guard let edges = hit?.edges else { return .crosshair }
        guard !edges.isEmpty else { return dragging ? .closedHand : .openHand }
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
        let minimum = (w: max(0.05, 80 / width), h: max(0.05, 80 / height))
        let grid = session.gridEnabled
        let result: (ZoneRect, [ZoneSnapping.Guide])
        if let hit = gesture.hit {
            let delta = (dx: point.x - gesture.start.x, dy: point.y - gesture.start.y)
            if hit.edges.isEmpty {
                result = ZoneSnapping.move(hit.zone.rect, by: delta, others: gesture.others,
                                           grid: grid, snapping: snapping, threshold: threshold)
            } else {
                result = ZoneSnapping.resize(hit.zone.rect, edges: hit.edges, by: delta, others: gesture.others,
                                             grid: grid, snapping: snapping, threshold: threshold, minSize: minimum)
            }
        } else {
            result = ZoneSnapping.draw(from: gesture.start, to: point, others: gesture.others,
                                       grid: grid, snapping: snapping, threshold: threshold, minSize: minimum)
        }
        session.preview = .init(zoneID: gesture.hit?.zone.id, rect: result.0, guides: result.1)
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

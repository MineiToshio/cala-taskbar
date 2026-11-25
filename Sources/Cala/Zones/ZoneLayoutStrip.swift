import AppKit

/// The drag-time layout strip (geometry and dwell rules in `ZoneStripModel.swift`): a click-through,
/// non-activating panel at the top centre of one display, above the zone overlay. It never takes the mouse:
/// the module hit-tests the pointer position it already receives from the drag tap. Main thread only.
final class ZoneLayoutStrip {
    struct Entry {
        var id: UUID
        var name: String
        var picture: NSImage
    }

    private var panel: NSPanel?
    private var view: ZoneStripView?
    private var usable = CGRect.zero
    private(set) var isExpanded = false

    var isVisible: Bool { panel != nil }

    /// The collapsed pill's size for the current layout (its width follows the name); the module hit-tests it.
    var pillSize: CGSize {
        guard let view else { return ZoneStripGeometry.grip }
        return ZoneStripView.pillSize(name: view.currentName, usableWidth: usable.width)
    }

    func show(usable: CGRect, entries: [Entry], current: Int?, accent: NSColor) {
        precondition(Thread.isMainThread)
        close()
        self.usable = usable
        isExpanded = false
        let panel = NSPanel(contentRect: ZoneStripGeometry.collapsed(usable: usable, pill: ZoneStripGeometry.grip).panel,
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        // Above the zone overlay (+1).
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let view = ZoneStripView(entries: entries, current: current, accent: accent)
        panel.contentView = view
        self.panel = panel
        self.view = view
        layout()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
            panel.animator().alphaValue = 1
        }
    }

    func setExpanded(_ expanded: Bool) {
        guard isExpanded != expanded else { return }
        isExpanded = expanded
        view?.hover = nil
        layout()
    }

    func setCurrent(_ current: Int?) {
        view?.current = current
        view?.hover = nil
        layout()
    }

    /// The hovered item and its dwell progress (0...1), or nil.
    func setHover(_ item: Int?, progress: Double) {
        guard let view else { return }
        let hover = item.map { ($0, progress) }
        if view.hover?.0 == hover?.0, abs((view.hover?.1 ?? -1) - (hover?.1 ?? -1)) < 0.005 { return }
        view.hover = hover
        view.needsDisplay = true
    }

    /// The expanded body, for placing the name toast under it.
    var expandedBody: CGRect? {
        guard let view else { return nil }
        return ZoneStripGeometry.expanded(usable: usable, count: view.entries.count, current: view.current).body
    }

    /// Offscreen render for `--snapshot`: the pill or the expanded strip over a neutral backdrop, at 2x.
    @MainActor
    static func renderSnapshot(entries: [Entry], current: Int?, expanded: Bool, accent: NSColor, dark: Bool, to url: URL) {
        let usable = CGRect(x: 0, y: 0, width: 1512, height: 400)
        let frame: CGRect
        if expanded {
            frame = ZoneStripGeometry.expanded(usable: usable, count: entries.count, current: current).panel
        } else {
            let name = current.map { entries[$0].name } ?? tx("Off", "Desactivadas")
            frame = ZoneStripGeometry.collapsed(usable: usable,
                                                pill: ZoneStripView.pillSize(name: name, usableWidth: usable.width)).panel
        }
        final class Window: NSWindow { override var backingScaleFactor: CGFloat { 2 } }
        let window = Window(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let container = NSView(frame: CGRect(origin: .zero, size: frame.size))
        container.wantsLayer = true
        container.layer?.backgroundColor = (dark ? NSColor(white: 0.18, alpha: 1) : NSColor(white: 0.78, alpha: 1)).cgColor
        let view = ZoneStripView(entries: entries, current: current, accent: accent)
        view.frame = container.bounds
        if expanded { view.expanded = ZoneStripGeometry.expanded(usable: usable, count: entries.count, current: current) }
        if expanded, let first = view.expanded?.items.first(where: { $0.index != current }) { view.hover = (first.index, 0.6) }
        container.addSubview(view)
        window.contentView = container
        window.setFrame(frame, display: false)
        defer { window.close() }
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            guard let bitmap = container.bitmapImageRepForCachingDisplay(in: container.bounds) else { return }
            container.cacheDisplay(in: container.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
        }
    }

    func close() {
        guard let panel else { return }
        panel.orderOut(nil)
        panel.contentView = nil
        panel.close()
        self.panel = nil
        view = nil
    }

    private func layout() {
        guard let panel, let view else { return }
        if isExpanded {
            let geometry = ZoneStripGeometry.expanded(usable: usable, count: view.entries.count, current: view.current)
            view.expanded = geometry
            panel.setFrame(geometry.panel, display: false)
        } else {
            view.expanded = nil
            panel.setFrame(ZoneStripGeometry.collapsed(usable: usable, pill: pillSize).panel, display: false)
        }
        view.needsDisplay = true
    }
}

final class ZoneStripView: NSView {
    let entries: [ZoneLayoutStrip.Entry]
    var current: Int?
    var expanded: ZoneStripGeometry.Expanded?
    var hover: (Int, Double)?
    private let accent: NSColor

    init(entries: [ZoneLayoutStrip.Entry], current: Int?, accent: NSColor) {
        self.entries = entries
        self.current = current
        self.accent = accent
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let body = bounds.insetBy(dx: ZoneStripGeometry.margin, dy: ZoneStripGeometry.margin)
        guard body.width > 0, body.height > 0 else { return }
        let radius = expanded == nil ? body.height / 2 : 12
        let shape = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 10
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.set()
        NSColor.windowBackgroundColor.withAlphaComponent(expanded == nil ? 0.82 : 0.95).setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.separatorColor.setStroke()
        shape.lineWidth = 1
        shape.stroke()

        guard let expanded, let window else {
            drawPill(in: body)
            return
        }
        let origin = window.frame.origin
        for item in expanded.items where entries.indices.contains(item.index) {
            drawItem(item.index, frame: item.frame.offsetBy(dx: -origin.x, dy: -origin.y), scale: expanded.scale)
        }
    }

    /// The collapsed pill, always the same: the current layout's mini picture, its name, "Change layout" and a
    /// down chevron, so it says what it is and that it opens.
    private func drawPill(in body: CGRect) {
        let g = ZoneStripGeometry.self
        var x = body.minX + g.pillPadding
        let pictureBox = CGRect(x: x, y: body.midY - g.pillPicture.height / 2, width: g.pillPicture.width, height: g.pillPicture.height)
        if let current, entries.indices.contains(current) {
            let size = entries[current].picture.size
            let fit = min(pictureBox.width / max(size.width, 1), pictureBox.height / max(size.height, 1))
            entries[current].picture.draw(in: CGRect(x: pictureBox.midX - size.width * fit / 2, y: pictureBox.midY - size.height * fit / 2,
                                                     width: size.width * fit, height: size.height * fit))
        } else if let off = NSImage(systemSymbolName: "nosign", accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 12, weight: .medium)) {
            NSColor.secondaryLabelColor.set()
            off.draw(in: CGRect(x: pictureBox.midX - 7, y: pictureBox.midY - 7, width: 14, height: 14))
        }
        x = pictureBox.maxX + g.pillGap
        let text = Self.pillText(name: currentName)
        let chevronX = body.maxX - g.pillPadding - g.pillChevron
        let textRect = CGRect(x: x, y: body.midY - ceil(text.size().height) / 2, width: max(0, chevronX - g.pillGap - x),
                              height: ceil(text.size().height))
        text.draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        let chevron = NSBezierPath()
        chevron.move(to: CGPoint(x: chevronX, y: body.midY + 2))
        chevron.line(to: CGPoint(x: chevronX + g.pillChevron / 2, y: body.midY - 2.5))
        chevron.line(to: CGPoint(x: chevronX + g.pillChevron, y: body.midY + 2))
        chevron.lineWidth = 1.8
        chevron.lineCapStyle = .round
        chevron.lineJoinStyle = .round
        accent.setStroke()
        chevron.stroke()
    }

    var currentName: String {
        current.flatMap { entries.indices.contains($0) ? entries[$0].name : nil } ?? tx("Off", "Desactivadas")
    }

    static func pillText(name: String) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let text = NSMutableAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.labelColor, .paragraphStyle: style])
        text.append(NSAttributedString(string: "  ·  " + tx("Change layout", "Cambiar distribución"), attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style]))
        return text
    }

    static func pillSize(name: String, usableWidth: CGFloat) -> CGSize {
        ZoneStripGeometry.pillSize(textWidth: ceil(pillText(name: name).size().width), usableWidth: usableWidth)
    }

    private func drawItem(_ index: Int, frame: CGRect, scale: CGFloat) {
        let entry = entries[index]
        let pictureBox = CGRect(x: frame.minX + 4 * scale, y: frame.maxY - (4 + ZoneStripGeometry.picture.height) * scale,
                                width: ZoneStripGeometry.picture.width * scale,
                                height: ZoneStripGeometry.picture.height * scale)
        let hovered = hover?.0 == index
        if hovered {
            accent.withAlphaComponent(0.14).setFill()
            NSBezierPath(roundedRect: frame, xRadius: 8, yRadius: 8).fill()
        }
        let size = entry.picture.size
        let fit = min(pictureBox.width / max(size.width, 1), pictureBox.height / max(size.height, 1))
        let picture = CGRect(x: pictureBox.midX - size.width * fit / 2, y: pictureBox.midY - size.height * fit / 2,
                             width: size.width * fit, height: size.height * fit)
        entry.picture.draw(in: picture)
        if index == current {
            accent.setStroke()
            let ring = NSBezierPath(roundedRect: picture.insetBy(dx: -3, dy: -3), xRadius: 5, yRadius: 5)
            ring.lineWidth = 2
            ring.stroke()
        }
        if let hover, hover.0 == index, hover.1 > 0 {
            // Dwell progress: a small ring filling clockwise at the picture's top-right corner.
            let center = CGPoint(x: picture.maxX - 2, y: picture.maxY - 2)
            let r: CGFloat = 7
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath(ovalIn: CGRect(x: center.x - r - 2, y: center.y - r - 2, width: 2 * r + 4, height: 2 * r + 4)).fill()
            NSColor.tertiaryLabelColor.setStroke()
            let track = NSBezierPath(ovalIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
            track.lineWidth = 2
            track.stroke()
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: r, startAngle: 90, endAngle: 90 - 360 * CGFloat(min(1, hover.1)),
                          clockwise: true)
            arc.lineWidth = 2.5
            arc.lineCapStyle = .round
            accent.setStroke()
            arc.stroke()
        }
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        let selected = index == current || hovered
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: max(8, 10 * scale), weight: selected ? .semibold : .regular),
            .foregroundColor: selected ? NSColor.labelColor : NSColor.secondaryLabelColor,
            .paragraphStyle: style,
        ]
        let label = CGRect(x: frame.minX + 2, y: frame.minY + 2 * scale, width: frame.width - 4, height: 14 * scale)
        (entry.name as NSString).draw(with: label, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                      attributes: attributes)
    }
}

/// A short name toast at the top centre of a display, gone after about 1.2 s. Click-through.
final class ZoneToast {
    private var panel: NSPanel?
    private var timer: Timer?

    func show(_ text: String, below top: CGFloat, centerX: CGFloat) {
        precondition(Thread.isMainThread)
        close()
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .labelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        let width = min(360, ceil(label.intrinsicContentSize.width) + 28)
        let frame = CGRect(x: (centerX - width / 2).rounded(), y: top - 8 - 30, width: width, height: 30)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let background = NSVisualEffectView(frame: CGRect(origin: .zero, size: frame.size))
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 15
        background.layer?.masksToBounds = true
        label.frame = CGRect(x: 14, y: (frame.height - 17) / 2, width: width - 28, height: 17)
        background.addSubview(label)
        panel.contentView = background
        panel.orderFrontRegardless()
        self.panel = panel
        timer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in self?.close() }
    }

    func close() {
        timer?.invalidate()
        timer = nil
        guard let panel else { return }
        panel.orderOut(nil)
        panel.contentView = nil
        panel.close()
        self.panel = nil
    }
}

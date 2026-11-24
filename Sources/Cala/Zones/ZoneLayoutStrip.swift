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

    func show(usable: CGRect, entries: [Entry], current: Int?, accent: NSColor) {
        precondition(Thread.isMainThread)
        close()
        self.usable = usable
        isExpanded = false
        let panel = NSPanel(contentRect: ZoneStripGeometry.collapsed(usable: usable).panel,
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
            panel.setFrame(ZoneStripGeometry.collapsed(usable: usable).panel, display: false)
        }
        view.needsDisplay = true
    }
}

private final class ZoneStripView: NSView {
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
            // Collapsed: a calm grip.
            let grip = NSRect(x: body.midX - 18, y: body.midY - 2, width: 36, height: 4)
            NSColor.secondaryLabelColor.withAlphaComponent(0.7).setFill()
            NSBezierPath(roundedRect: grip, xRadius: 2, yRadius: 2).fill()
            return
        }
        let origin = window.frame.origin
        for item in expanded.items where entries.indices.contains(item.index) {
            drawItem(item.index, frame: item.frame.offsetBy(dx: -origin.x, dy: -origin.y), scale: expanded.scale)
        }
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

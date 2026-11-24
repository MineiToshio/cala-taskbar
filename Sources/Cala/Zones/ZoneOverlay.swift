import AppKit
import QuartzCore

/// Click-through, non-activating panels (one per screen with an active layout) that show the zones while
/// zones mode is on. Main thread only. Created on entry, closed and released on exit.
final class ZoneOverlay {
    struct Screen {
        var index: Int
        /// Usable area in AppKit global coordinates: the panel covers exactly this.
        var usable: CGRect
        /// Gapped zone frames in AppKit global coordinates: what the window will get.
        var zones: [(id: UUID, frame: CGRect)]
    }

    struct Palette {
        var strongFill: CGColor
        var strongStroke: CGColor
        var softFill: CGColor
        var idleFill: CGColor
        var idleStroke: CGColor

        /// Theme accent from Theme.swift, resolved for the current light/dark appearance.
        static func make(theme: String) -> Palette {
            let accent = ZoneOverlay.accent(theme: theme)
            var palette: Palette?
            NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
                palette = Palette(strongFill: accent.withAlphaComponent(0.35).cgColor,
                                  strongStroke: accent.cgColor,
                                  softFill: accent.withAlphaComponent(0.12).cgColor,
                                  idleFill: NSColor.black.withAlphaComponent(0.10).cgColor,
                                  idleStroke: NSColor.labelColor.withAlphaComponent(0.35).cgColor)
            }
            return palette ?? Palette(strongFill: accent.cgColor, strongStroke: accent.cgColor, softFill: accent.cgColor,
                                      idleFill: .clear, idleStroke: NSColor.gray.cgColor)
        }
    }

    /// The theme's accent (Theme.swift); the system accent for the "system" theme.
    static func accent(theme: String) -> NSColor {
        theme == "system" ? .controlAccentColor : NSColor(BarTheme.named(theme).accent)
    }

    private var panels: [Int: (panel: NSPanel, view: ZoneOverlayView)] = [:]
    /// Panels fading out after a layout switch; closed when the fade ends or with everything else.
    private var retiring: [NSPanel] = []
    var isVisible: Bool { !panels.isEmpty || !retiring.isEmpty }

    func show(_ screens: [Screen], palette: Palette) {
        precondition(Thread.isMainThread)
        close()
        for screen in screens {
            if let entry = makePanel(screen, palette: palette, fadeIn: 0.12) { panels[screen.index] = entry }
        }
    }

    /// Swaps one screen's zones (a layout switched mid-drag) with a ~150 ms crossfade.
    func replace(_ screen: Screen, palette: Palette) {
        precondition(Thread.isMainThread)
        let old = panels.removeValue(forKey: screen.index)
        if let entry = makePanel(screen, palette: palette, fadeIn: 0.15) { panels[screen.index] = entry }
        guard let old else { return }
        retiring.append(old.panel)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = reduceMotion ? 0 : 0.15
            old.panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.retire(old.panel)
        })
    }

    private func retire(_ panel: NSPanel) {
        guard let index = retiring.firstIndex(where: { $0 === panel }) else { return }
        retiring.remove(at: index)
        panel.orderOut(nil)
        panel.contentView = nil
        panel.close()
    }

    private func makePanel(_ screen: Screen, palette: Palette, fadeIn: TimeInterval) -> (panel: NSPanel, view: ZoneOverlayView)? {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard !screen.zones.isEmpty && screen.usable.width > 0 && screen.usable.height > 0 else { return nil }
        let panel = NSPanel(contentRect: screen.usable, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        // Above normal windows and Cala's bar, below the switcher (+2).
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let local = screen.zones.map { (id: $0.id, frame: $0.frame.offsetBy(dx: -screen.usable.minX, dy: -screen.usable.minY)) }
        let view = ZoneOverlayView(frame: CGRect(origin: .zero, size: screen.usable.size), zones: local, palette: palette)
        panel.contentView = view
        panel.setFrame(screen.usable, display: false)
        panel.alphaValue = reduceMotion ? 1 : 0
        panel.orderFrontRegardless()
        if !reduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = fadeIn
                panel.animator().alphaValue = 1
            }
        }
        return (panel, view)
    }

    /// Highlights `target` on screen `index` (frame in AppKit global coordinates); other screens show no choice.
    func update(screen index: Int?, target: ZonePicking.Target?) {
        let animated = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for (i, entry) in panels {
            let origin = entry.panel.frame.origin
            let mine = i == index ? target : nil
            entry.view.apply(target: mine, frame: mine.map { $0.frame.offsetBy(dx: -origin.x, dy: -origin.y) }, animated: animated)
        }
    }

    func close() {
        for panel in panels.values.map(\.panel) + retiring {
            panel.orderOut(nil)
            panel.contentView = nil
            panel.close()
        }
        panels.removeAll()
        retiring.removeAll()
    }
}

private final class ZoneOverlayView: NSView {
    private var zoneLayers: [UUID: CAShapeLayer] = [:]
    private let highlight = CAShapeLayer()
    private let palette: ZoneOverlay.Palette
    private var highlighted = false
    private var shown: (frame: CGRect?, soft: Set<UUID>)?

    init(frame: CGRect, zones: [(id: UUID, frame: CGRect)], palette: ZoneOverlay.Palette) {
        self.palette = palette
        super.init(frame: frame)
        wantsLayer = true
        guard let root = layer else { return }
        for zone in zones {
            let shape = CAShapeLayer()
            shape.frame = bounds
            shape.path = Self.path(zone.frame)
            shape.fillColor = palette.idleFill
            shape.strokeColor = palette.idleStroke
            shape.lineWidth = 1
            root.addSublayer(shape)
            zoneLayers[zone.id] = shape
        }
        highlight.frame = bounds
        highlight.fillColor = palette.strongFill
        highlight.strokeColor = palette.strongStroke
        highlight.lineWidth = 3
        highlight.opacity = 0
        root.addSublayer(highlight)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func apply(target: ZonePicking.Target?, frame: CGRect?, animated: Bool) {
        let soft = target.map { $0.soft.union($0.chosen) } ?? []
        // The pointer moves far more often than the choice changes: only touch the layers on a change.
        if let shown, shown.frame == frame, shown.soft == soft { return }
        shown = (frame, soft)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        CATransaction.setDisableActions(!animated)
        for (id, shape) in zoneLayers {
            shape.fillColor = soft.contains(id) ? palette.softFill : palette.idleFill
        }
        if let frame {
            if !highlighted {
                // Appear in place: fade in without sliding from the previous zone.
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                highlight.path = Self.path(frame)
                CATransaction.commit()
            } else {
                highlight.path = Self.path(frame)
            }
            highlight.opacity = 1
        } else {
            highlight.opacity = 0
        }
        highlighted = frame != nil
        CATransaction.commit()
    }

    private static func path(_ rect: CGRect) -> CGPath {
        let r = rect.insetBy(dx: 1.5, dy: 1.5)
        guard r.width > 0, r.height > 0 else { return CGPath(rect: .zero, transform: nil) }
        let corner = min(10, r.width / 2, r.height / 2)
        return CGPath(roundedRect: r, cornerWidth: corner, cornerHeight: corner, transform: nil)
    }
}

import Foundation
import CoreGraphics

/// Geometry of the drag-time layout strip: a collapsed grip at the top centre of a display's usable area that
/// expands into a row of layout pictures. AppKit coordinates (y grows up). Every panel has a transparent
/// `margin` around its visible body (room for the shadow); only the body is the hit area.
enum ZoneStripGeometry {
    struct Expanded: Equatable {
        var panel: CGRect
        var body: CGRect
        /// Visible items: index into the display's layout list, and the item frame (picture + name).
        var items: [Item]
        var scale: CGFloat
    }

    struct Item: Equatable {
        var index: Int
        var frame: CGRect
    }

    static let margin: CGFloat = 16
    /// Distance from the top of the usable area (below the menu bar) to the body.
    static let topGap: CGFloat = 6
    static let padding: CGFloat = 8
    static let spacing: CGFloat = 6
    /// One item: a picture box of 80 × 50 and a name line under it.
    static let item = CGSize(width: 88, height: 74)
    static let picture = CGSize(width: 80, height: 50)
    static let grip = CGSize(width: 112, height: 22)
    static let minScale: CGFloat = 0.6
    static let maxVisible = 9

    static func collapsed(usable: CGRect) -> (panel: CGRect, body: CGRect) {
        let body = CGRect(x: (usable.midX - grip.width / 2).rounded(), y: usable.maxY - topGap - grip.height,
                          width: grip.width, height: grip.height)
        return (body.insetBy(dx: -margin, dy: -margin), body)
    }

    /// Items shrink (down to `minScale`) to fit the usable width; past that, or past `maxVisible`, a window of
    /// items centred on the current layout is shown.
    static func expanded(usable: CGRect, count: Int, current: Int?) -> Expanded {
        let count = max(0, count)
        let available = max(0, usable.width - 2 * (margin + 8))
        func width(_ n: Int, _ s: CGFloat) -> CGFloat {
            CGFloat(n) * item.width * s + CGFloat(max(0, n - 1)) * spacing + 2 * padding
        }
        let wanted = min(count, maxVisible)
        var scale: CGFloat = 1
        if wanted > 0, width(wanted, 1) > available {
            let room = available - 2 * padding - CGFloat(wanted - 1) * spacing
            scale = max(minScale, room / (CGFloat(wanted) * item.width))
        }
        var visible = wanted
        while visible > 1 && width(visible, scale) > available { visible -= 1 }
        let first: Int
        if visible < count, let current {
            first = min(max(0, current - visible / 2), count - visible)
        } else {
            first = 0
        }
        let bodyWidth = visible > 0 ? width(visible, scale) : grip.width
        let bodyHeight = item.height * scale + 2 * padding
        let body = CGRect(x: (usable.midX - bodyWidth / 2).rounded(), y: usable.maxY - topGap - bodyHeight,
                          width: bodyWidth, height: bodyHeight)
        let items = (0..<visible).map { offset in
            Item(index: first + offset,
                 frame: CGRect(x: body.minX + padding + CGFloat(offset) * (item.width * scale + spacing),
                               y: body.minY + padding, width: item.width * scale, height: item.height * scale))
        }
        return Expanded(panel: body.insetBy(dx: -margin, dy: -margin), body: body, items: items, scale: scale)
    }

    /// The item under `p`, if any (gaps between items count as none).
    static func item(at p: CGPoint, in expanded: Expanded) -> Int? {
        expanded.items.first { $0.frame.contains(p) }?.index
    }

    /// Whether the cursor is in the strip: the expanded body, or the collapsed grip's body. Entering the grip
    /// expands the strip; leaving the expanded body collapses it.
    static func inside(_ p: CGPoint, expanded: Bool, usable: CGRect, count: Int, current: Int?) -> Bool {
        expanded ? self.expanded(usable: usable, count: count, current: current).body.contains(p)
                 : collapsed(usable: usable).body.contains(p)
    }

    /// Zone picking is suspended only inside the expanded strip. The collapsed grip never blocks zones that
    /// touch the top edge: picking there goes on as if the grip were not drawn.
    static func suspendsPicking(_ p: CGPoint, expanded: Bool, usable: CGRect, count: Int, current: Int?) -> Bool {
        expanded && inside(p, expanded: true, usable: usable, count: count, current: current)
    }
}

/// Hover-to-switch on the strip: an item must be hovered for `dwell` seconds to switch to it. Moving between
/// items takes effect after `hysteresis` (no flicker on shared edges; nothing fires meanwhile). The current
/// layout never fires, and after a switch the same item does not fire again until the cursor leaves it.
struct ZoneStripDwell {
    enum Output: Equatable {
        case idle
        case progress(item: Int, fraction: Double)
        case switchTo(Int)
    }

    static let dwell = 0.35
    static let hysteresis = 0.10

    private(set) var hovered: Int?
    private var pending: (item: Int?, since: Double)?
    private var hoverStart = 0.0
    private var blocked: Int?

    mutating func update(item: Int?, now: Double, current: Int?) -> Output {
        if item == hovered {
            pending = nil
        } else if hovered == nil {
            accept(item, now)
        } else {
            if pending == nil || pending?.item != item { pending = (item, now) }
            if let pending, now - pending.since >= Self.hysteresis { accept(pending.item, now) }
        }
        guard pending == nil, let hovered, hovered != current, hovered != blocked else { return .idle }
        let fraction = (now - hoverStart) / Self.dwell
        if fraction >= 1 {
            blocked = hovered
            return .switchTo(hovered)
        }
        return .progress(item: hovered, fraction: max(0, fraction))
    }

    /// Leaving the strip or releasing the button cancels any dwell.
    mutating func reset() {
        hovered = nil
        pending = nil
        blocked = nil
    }

    private mutating func accept(_ item: Int?, _ now: Double) {
        if item != blocked { blocked = nil }
        hovered = item
        hoverStart = now
        pending = nil
    }
}

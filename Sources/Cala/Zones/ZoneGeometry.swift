import Foundation
import CoreGraphics

enum ZoneGeometry {
    static func usableRect(frame: CGRect, visibleFrame: CGRect, barHeight: CGFloat, barReserves: Bool) -> CGRect {
        guard barReserves else { return visibleFrame }
        let bottom = min(visibleFrame.maxY, max(visibleFrame.minY, frame.minY + barHeight))
        return CGRect(x: visibleFrame.minX, y: bottom, width: visibleFrame.width, height: visibleFrame.maxY - bottom)
    }

    static func frame(for r: ZoneRect, in usable: CGRect) -> CGRect {
        let edges = edges(for: r, in: usable)
        return CGRect(x: edges.minX, y: edges.minY,
                      width: edges.maxX - edges.minX, height: edges.maxY - edges.minY)
    }

    // Transform each endpoint directly so adjacent zones use the same coordinate for their shared edge.
    static func edges(for r: ZoneRect, in usable: CGRect) -> (minX: CGFloat, maxX: CGFloat, minY: CGFloat, maxY: CGFloat) {
        (usable.minX + r.x * usable.width, usable.minX + r.maxX * usable.width,
         usable.minY + (1 - r.maxY) * usable.height, usable.minY + (1 - r.y) * usable.height)
    }

    static func fraction(for f: CGRect, in usable: CGRect) -> ZoneRect {
        guard usable.width > 0, usable.height > 0 else { return ZoneRect(x: 0, y: 0, w: 0, h: 0) }
        return ZoneRect(x: (f.minX - usable.minX) / usable.width, y: (usable.maxY - f.maxY) / usable.height,
                        w: f.width / usable.width, h: f.height / usable.height)
    }

    static func applyGap(_ f: CGRect, gap: CGFloat, usable: CGRect, minSize: CGFloat = 40) -> CGRect {
        let gap = max(0, gap)
        // Screen edges get the full gap. Interior edges get half, so adjacent zones share one gap.
        func inset(_ edge: CGFloat, _ boundary: CGFloat) -> CGFloat {
            abs(edge - boundary) < 0.5 ? gap : gap / 2
        }
        func insets(_ a: CGFloat, _ b: CGFloat, length: CGFloat) -> (CGFloat, CGFloat) {
            // Reduce both insets proportionally when there is too little room for the minimum.
            let scale = a + b > 0 ? min(1, max(0, length - max(0, minSize)) / (a + b)) : 0
            return (a * scale, b * scale)
        }
        let (left, right) = insets(inset(f.minX, usable.minX), inset(f.maxX, usable.maxX), length: f.width)
        let (bottom, top) = insets(inset(f.minY, usable.minY), inset(f.maxY, usable.maxY), length: f.height)
        return CGRect(x: f.minX + left, y: f.minY + bottom, width: f.width - left - right, height: f.height - bottom - top)
    }

    static func axRect(fromAppKit r: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    static func appKitRect(fromAX r: CGRect, primaryHeight: CGFloat) -> CGRect {
        axRect(fromAppKit: r, primaryHeight: primaryHeight)
    }

    static func appKitPoint(fromCG p: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: p.x, y: primaryHeight - p.y)
    }

    static func cgPoint(fromAppKit p: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        appKitPoint(fromCG: p, primaryHeight: primaryHeight)
    }

    static func screenIndex(containing p: CGPoint, frames: [CGRect]) -> Int? {
        if let index = frames.firstIndex(where: { $0.contains(p) }) { return index }
        func distance(to frame: CGRect) -> CGFloat {
            let dx = max(frame.minX - p.x, p.x - frame.maxX, 0)
            let dy = max(frame.minY - p.y, p.y - frame.maxY, 0)
            return dx * dx + dy * dy
        }
        return frames.indices.min { distance(to: frames[$0]) < distance(to: frames[$1]) }
    }

    static func clamp(_ r: ZoneRect, minW: Double, minH: Double) -> ZoneRect {
        let w = min(1, max(0, minW, r.w))
        let h = min(1, max(0, minH, r.h))
        return ZoneRect(x: min(max(0, r.x), 1 - w), y: min(max(0, r.y), 1 - h), w: w, h: h)
    }
}

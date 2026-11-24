import Foundation

enum ZoneSnapping {
    enum Axis { case x, y }

    struct Guide: Equatable {
        var axis: Axis
        var position: Double
    }

    struct Edges: OptionSet {
        let rawValue: Int
        static let left = Edges(rawValue: 1 << 0)
        static let right = Edges(rawValue: 1 << 1)
        static let top = Edges(rawValue: 1 << 2)
        static let bottom = Edges(rawValue: 1 << 3)
    }

    static func candidates(others: [ZoneRect], grid: Bool) -> (xs: [Double], ys: [Double]) {
        let guides = grid ? (0...12).map { Double($0) / 12 } : [0, 0.5, 1]
        func sorted(_ values: [Double]) -> [Double] {
            Set(guides + values.filter { $0 >= 0 && $0 <= 1 }).sorted()
        }
        return (sorted(others.flatMap { [$0.x, $0.maxX] }), sorted(others.flatMap { [$0.y, $0.maxY] }))
    }

    static func snap(_ value: Double, to candidates: [Double], threshold: Double) -> Double? {
        guard threshold >= 0 else { return nil }
        return candidates.filter { value >= $0 - threshold && value <= $0 + threshold }
            .min { abs($0 - value) < abs($1 - value) }
    }

    static func move(_ r: ZoneRect, by d: (dx: Double, dy: Double), others: [ZoneRect], grid: Bool,
                     snapping: Bool, threshold: (x: Double, y: Double)) -> (ZoneRect, [Guide]) {
        let limits = snapping ? candidates(others: others, grid: grid) : (xs: [], ys: [])
        let size = ZoneGeometry.clamp(r, minW: 0, minH: 0)
        let (x, gx) = moveAxis(r.x + d.dx, length: size.w, to: limits.xs, threshold: threshold.x)
        let (y, gy) = moveAxis(r.y + d.dy, length: size.h, to: limits.ys, threshold: threshold.y)
        return (ZoneRect(x: x, y: y, w: size.w, h: size.h), guides(x: gx, y: gy))
    }

    private static func moveAxis(_ start: Double, length: Double, to candidates: [Double],
                                 threshold: Double) -> (Double, Double?) {
        let end = start + length
        let leading = snap(start, to: candidates.filter { $0 <= 1 - length }, threshold: threshold)
        let trailing = snap(end, to: candidates.filter { $0 >= length }, threshold: threshold)
        if let leading, trailing.map({ abs(leading - start) <= abs($0 - end) }) ?? true {
            return (leading, leading)
        }
        if let trailing { return (trailing - length, trailing) }
        return (min(max(0, start), 1 - length), nil)
    }

    // Use the drag delta so grabbing anywhere in the handle's hit band preserves the pointer offset.
    static func resize(_ r: ZoneRect, edges: Edges, by d: (dx: Double, dy: Double),
                       others: [ZoneRect], grid: Bool, snapping: Bool,
                       threshold: (x: Double, y: Double), minSize: (w: Double, h: Double)) -> (ZoneRect, [Guide]) {
        let x = edges.contains(.left) ? r.x : r.maxX
        let y = edges.contains(.top) ? r.y : r.maxY
        return resize(r, edges: edges, to: (x + d.dx, y + d.dy), others: others,
                      grid: grid, snapping: snapping, threshold: threshold, minSize: minSize)
    }

    // A resize handle supplies at most one edge per axis. The opposite edge stays anchored.
    static func resize(_ r: ZoneRect, edges: Edges, to p: (x: Double, y: Double), others: [ZoneRect], grid: Bool,
                       snapping: Bool, threshold: (x: Double, y: Double),
                       minSize: (w: Double, h: Double)) -> (ZoneRect, [Guide]) {
        let limits = snapping ? candidates(others: others, grid: grid) : (xs: [], ys: [])
        let rect = ZoneGeometry.clamp(r, minW: 0, minH: 0)
        let x: (origin: Double, length: Double, guide: Double?)
        let y: (origin: Double, length: Double, guide: Double?)
        if edges.contains(.left) || edges.contains(.right) {
            let leading = edges.contains(.left)
            x = dragAxis(from: leading ? rect.maxX : rect.x, to: p.x, leading: leading,
                         minSize: minSize.w, candidates: limits.xs, threshold: threshold.x)
        } else {
            x = (rect.x, rect.w, nil)
        }
        if edges.contains(.top) || edges.contains(.bottom) {
            let leading = edges.contains(.top)
            y = dragAxis(from: leading ? rect.maxY : rect.y, to: p.y, leading: leading,
                         minSize: minSize.h, candidates: limits.ys, threshold: threshold.y)
        } else {
            y = (rect.y, rect.h, nil)
        }
        return (ZoneRect(x: x.origin, y: y.origin, w: x.length, h: y.length), guides(x: x.guide, y: y.guide))
    }

    static func draw(from a: (x: Double, y: Double), to b: (x: Double, y: Double), others: [ZoneRect], grid: Bool,
                     snapping: Bool, threshold: (x: Double, y: Double),
                     minSize: (w: Double, h: Double)) -> (ZoneRect, [Guide]) {
        let limits = snapping ? candidates(others: others, grid: grid) : (xs: [], ys: [])
        let x = drawAxis(from: a.x, to: b.x, minSize: minSize.w, candidates: limits.xs, threshold: threshold.x)
        let y = drawAxis(from: a.y, to: b.y, minSize: minSize.h, candidates: limits.ys, threshold: threshold.y)
        let rect = ZoneRect(x: x.origin, y: y.origin, w: x.length, h: y.length)
        return (rect, guides(x: x.anchorGuide, y: y.anchorGuide) + guides(x: x.endGuide, y: y.endGuide))
    }

    private static func drawAxis(from start: Double, to end: Double, minSize: Double, candidates: [Double],
                                 threshold: Double) -> (origin: Double, length: Double, anchorGuide: Double?, endGuide: Double?) {
        let leading = end < start
        let minSize = min(max(0, minSize), 1)
        let range = leading ? minSize...1 : 0...(1 - minSize)
        let guide = snap(start, to: candidates.filter(range.contains), threshold: threshold)
        let result = dragAxis(from: guide ?? start, to: end, leading: leading, minSize: minSize,
                              candidates: candidates, threshold: threshold)
        return (result.origin, result.length, guide, result.guide == guide ? nil : result.guide)
    }

    private static func dragAxis(from start: Double, to end: Double, leading: Bool, minSize: Double,
                                 candidates: [Double], threshold: Double) -> (origin: Double, length: Double, guide: Double?) {
        let minSize = min(max(0, minSize), 1)
        let anchor = leading ? min(max(minSize, start), 1) : min(max(0, start), 1 - minSize)
        let lower = leading ? 0 : anchor + minSize
        let upper = leading ? anchor - minSize : 1
        let roundoff = Double.ulpOfOne
        let guide = snap(end, to: candidates.filter { $0 >= lower - roundoff && $0 <= upper + roundoff }, threshold: threshold)
        let edge = min(max(lower, guide ?? end), upper)
        return (min(anchor, edge), abs(edge - anchor), guide)
    }

    private static func guides(x: Double?, y: Double?) -> [Guide] {
        [x.map { Guide(axis: .x, position: $0) }, y.map { Guide(axis: .y, position: $0) }].compactMap { $0 }
    }
}

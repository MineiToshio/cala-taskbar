import Foundation

enum ZoneSnapping {
    enum Axis { case x, y }

    struct Guide: Equatable {
        /// `edge`: an edge lines up with something; `center`: the zone's centre is on the screen's centre line;
        /// `equalSize`: the zone is as wide (x) or tall (y) as another zone, and the guide marks the edge that did it.
        enum Kind { case edge, center, equalSize }
        var axis: Axis
        var position: Double
        var kind: Kind = .edge
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
        let (x, gx) = moveAxis(r.x + d.dx, length: size.w, to: limits.xs, centre: snapping, threshold: threshold.x)
        let (y, gy) = moveAxis(r.y + d.dy, length: size.h, to: limits.ys, centre: snapping, threshold: threshold.y)
        return (ZoneRect(x: x, y: y, w: size.w, h: size.h),
                [gx.map { Guide(axis: .x, position: $0.0, kind: $0.1) }, gy.map { Guide(axis: .y, position: $0.0, kind: $0.1) }]
                    .compactMap { $0 })
    }

    /// The nearest of: (with `centre`) the zone's centre on the screen's centre line, the leading edge on a
    /// candidate, or the trailing edge on one. Ties keep that order.
    private static func moveAxis(_ start: Double, length: Double, to candidates: [Double], centre: Bool,
                                 threshold: Double) -> (Double, (Double, Guide.Kind)?) {
        let end = start + length
        var options: [(origin: Double, distance: Double, guide: Double, kind: Guide.Kind)] = []
        // Centre first: when a centred zone's edges also meet a line, the centre guide says more.
        if centre, length < 1, abs(start + length / 2 - 0.5) <= threshold {
            options.append((0.5 - length / 2, abs(start + length / 2 - 0.5), 0.5, .center))
        }
        if let leading = snap(start, to: candidates.filter { $0 <= 1 - length }, threshold: threshold) {
            options.append((leading, abs(leading - start), leading, .edge))
        }
        if let trailing = snap(end, to: candidates.filter { $0 >= length }, threshold: threshold) {
            options.append((trailing - length, abs(trailing - end), trailing, .edge))
        }
        if let best = options.enumerated().min(by: { a, b in
            a.element.distance < b.element.distance || (a.element.distance == b.element.distance && a.offset < b.offset)
        })?.element {
            return (best.origin, (best.guide, best.kind))
        }
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
        let lengths = snapping ? (ws: others.map(\.w), hs: others.map(\.h)) : (ws: [], hs: [])
        let rect = ZoneGeometry.clamp(r, minW: 0, minH: 0)
        let x: (origin: Double, length: Double, guide: Guide?)
        let y: (origin: Double, length: Double, guide: Guide?)
        if edges.contains(.left) || edges.contains(.right) {
            let leading = edges.contains(.left)
            x = dragAxis(.x, from: leading ? rect.maxX : rect.x, to: p.x, leading: leading,
                         minSize: minSize.w, candidates: limits.xs, lengths: lengths.ws, threshold: threshold.x)
        } else {
            x = (rect.x, rect.w, nil)
        }
        if edges.contains(.top) || edges.contains(.bottom) {
            let leading = edges.contains(.top)
            y = dragAxis(.y, from: leading ? rect.maxY : rect.y, to: p.y, leading: leading,
                         minSize: minSize.h, candidates: limits.ys, lengths: lengths.hs, threshold: threshold.y)
        } else {
            y = (rect.y, rect.h, nil)
        }
        return (ZoneRect(x: x.origin, y: y.origin, w: x.length, h: y.length), [x.guide, y.guide].compactMap { $0 })
    }

    static func draw(from a: (x: Double, y: Double), to b: (x: Double, y: Double), others: [ZoneRect], grid: Bool,
                     snapping: Bool, threshold: (x: Double, y: Double),
                     minSize: (w: Double, h: Double)) -> (ZoneRect, [Guide]) {
        let limits = snapping ? candidates(others: others, grid: grid) : (xs: [], ys: [])
        let lengths = snapping ? (ws: others.map(\.w), hs: others.map(\.h)) : (ws: [], hs: [])
        let x = drawAxis(.x, from: a.x, to: b.x, minSize: minSize.w, candidates: limits.xs, lengths: lengths.ws,
                         threshold: threshold.x)
        let y = drawAxis(.y, from: a.y, to: b.y, minSize: minSize.h, candidates: limits.ys, lengths: lengths.hs,
                         threshold: threshold.y)
        let rect = ZoneRect(x: x.origin, y: y.origin, w: x.length, h: y.length)
        return (rect, guides(x: x.anchorGuide, y: y.anchorGuide) + [x.endGuide, y.endGuide].compactMap { $0 })
    }

    private static func drawAxis(_ axis: Axis, from start: Double, to end: Double, minSize: Double, candidates: [Double],
                                 lengths: [Double], threshold: Double)
        -> (origin: Double, length: Double, anchorGuide: Double?, endGuide: Guide?) {
        let leading = end < start
        let minSize = min(max(0, minSize), 1)
        let range = leading ? minSize...1 : 0...(1 - minSize)
        let guide = snap(start, to: candidates.filter(range.contains), threshold: threshold)
        let result = dragAxis(axis, from: guide ?? start, to: end, leading: leading, minSize: minSize,
                              candidates: candidates, lengths: lengths, threshold: threshold)
        let repeated = result.guide.map { $0.kind == .edge && $0.position == guide } ?? false
        return (result.origin, result.length, guide, repeated ? nil : result.guide)
    }

    /// Moves one edge from its anchor towards `end`: it snaps to the nearest candidate line or, with `lengths`, to
    /// the position that makes the zone exactly as long as another zone (an `equalSize` guide). Ties go to the line.
    private static func dragAxis(_ axis: Axis, from start: Double, to end: Double, leading: Bool, minSize: Double,
                                 candidates: [Double], lengths: [Double], threshold: Double)
        -> (origin: Double, length: Double, guide: Guide?) {
        let minSize = min(max(0, minSize), 1)
        let anchor = leading ? min(max(minSize, start), 1) : min(max(0, start), 1 - minSize)
        let lower = leading ? 0 : anchor + minSize
        let upper = leading ? anchor - minSize : 1
        let roundoff = Double.ulpOfOne
        let line = snap(end, to: candidates.filter { $0 >= lower - roundoff && $0 <= upper + roundoff }, threshold: threshold)
        let sized = snap(end, to: lengths.map { leading ? anchor - $0 : anchor + $0 }
                            .filter { $0 >= lower - roundoff && $0 <= upper + roundoff }, threshold: threshold)
        var guide: Guide?
        if let line, sized.map({ abs(line - end) <= abs($0 - end) }) ?? true {
            guide = Guide(axis: axis, position: line)
        } else if let sized {
            guide = Guide(axis: axis, position: sized, kind: .equalSize)
        }
        let edge = min(max(lower, guide?.position ?? end), upper)
        return (min(anchor, edge), abs(edge - anchor), guide)
    }

    private static func guides(x: Double?, y: Double?) -> [Guide] {
        [x.map { Guide(axis: .x, position: $0) }, y.map { Guide(axis: .y, position: $0) }].compactMap { $0 }
    }
}

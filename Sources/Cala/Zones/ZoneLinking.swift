import Foundation
import CoreGraphics

/// The editor's **Linked** mode: zones that share an edge stay joined, and a moved zone never lands on another.
/// Zones are stored without gaps (the gap is applied when snapping a window), so "shared" means equal coordinates
/// within `tolerance`. Pure, so the rules are checked without AppKit.
enum ZoneLinking {
    /// Two edges closer than this (a fraction of the usable size; about 1 pt on a 1920-pt-wide screen) are one edge.
    static let tolerance = 0.0005

    struct LinkedEdge: Equatable {
        var index: Int
        /// The zone's right (x) or bottom (y) edge; otherwise its left or top edge.
        var isMax: Bool
    }

    private static func span(_ r: ZoneRect, vertical: Bool) -> (Double, Double) { vertical ? (r.y, r.maxY) : (r.x, r.maxX) }
    private static func position(_ r: ZoneRect, horizontal: Bool, isMax: Bool) -> Double {
        horizontal ? (isMax ? r.maxX : r.x) : (isMax ? r.maxY : r.y)
    }

    /// The edges that move with zone `index`'s `edge` (one of left, right, top, bottom): every zone edge at the same
    /// coordinate that is connected to it through spans that overlap (touching at a corner is not enough). So in
    /// three columns the divider moves both columns; in a 2 × 2 grid only the row you drag; and a zone that spans
    /// two stacked neighbours drags the whole divider. The dragged edge itself is always first.
    static func linkedEdges(_ zones: [ZoneRect], index: Int, edge: ZoneSnapping.Edges) -> [LinkedEdge] {
        guard zones.indices.contains(index) else { return [] }
        let horizontal = edge == .left || edge == .right
        let isMax = edge == .right || edge == .bottom
        let p = position(zones[index], horizontal: horizontal, isMax: isMax)
        var segments: [LinkedEdge] = []
        for (j, zone) in zones.enumerated() {
            for side in [false, true] where abs(position(zone, horizontal: horizontal, isMax: side) - p) <= tolerance {
                segments.append(LinkedEdge(index: j, isMax: side))
            }
        }
        let start = LinkedEdge(index: index, isMax: isMax)
        var result = [start]
        var frontier = [start]
        while let current = frontier.popLast() {
            let a = span(zones[current.index], vertical: horizontal)
            for segment in segments where !result.contains(segment) {
                let b = span(zones[segment.index], vertical: horizontal)
                if min(a.1, b.1) - max(a.0, b.0) > tolerance {
                    result.append(segment)
                    frontier.append(segment)
                }
            }
        }
        return result
    }

    /// A linked resize. `proposed` is the dragged zone after normal snapping; each dragged edge's new coordinate is
    /// applied to every linked edge, stopping where any zone involved would get smaller than the minimum. Returns
    /// the new rect of every zone that changed.
    static func resize(_ zones: [ZoneRect], index: Int, edges: ZoneSnapping.Edges, proposed: ZoneRect,
                       minSize: (w: Double, h: Double)) -> [Int: ZoneRect] {
        guard zones.indices.contains(index) else { return [:] }
        var result = zones
        for edge in [ZoneSnapping.Edges.left, .right, .top, .bottom] where edges.contains(edge) {
            let horizontal = edge == .left || edge == .right
            let isMax = edge == .right || edge == .bottom
            let minimum = horizontal ? minSize.w : minSize.h
            let linked = linkedEdges(zones, index: index, edge: edge)
            var q = position(proposed, horizontal: horizontal, isMax: isMax)
            var lower = 0.0, upper = 1.0
            for item in linked {
                let zone = zones[item.index]
                let (start, end) = horizontal ? (zone.x, zone.maxX) : (zone.y, zone.maxY)
                // A zone whose far edge moves keeps at least the minimum from its near edge, and the other way round.
                if item.isMax { lower = max(lower, start + minimum) } else { upper = min(upper, end - minimum) }
            }
            guard lower <= upper else { continue }
            q = min(max(q, lower), upper)
            for item in linked {
                var zone = result[item.index]
                let original = zones[item.index]
                if horizontal {
                    if item.isMax { zone.w = q - original.x } else { zone.x = q; zone.w = original.maxX - q }
                } else {
                    if item.isMax { zone.h = q - original.y } else { zone.y = q; zone.h = original.maxY - q }
                }
                result[item.index] = zone
            }
        }
        var changed: [Int: ZoneRect] = [:]
        for i in zones.indices where result[i] != zones[i] { changed[i] = result[i] }
        return changed
    }

    /// Covering more than `slack` on both axes; zones that only share an edge do not overlap.
    static func overlaps(_ a: ZoneRect, _ b: ZoneRect, slack: Double = tolerance) -> Bool {
        min(a.maxX, b.maxX) - max(a.x, b.x) > slack && min(a.maxY, b.maxY) - max(a.y, b.y) > slack
    }

    /// A linked move: the zone goes as far towards `proposed` as it can without covering another zone, first
    /// horizontally then vertically, so it slides along a neighbour instead of stopping dead. Zones it already
    /// overlapped (a layout made in Free mode) do not block it.
    static func move(_ zones: [ZoneRect], index: Int, to proposed: ZoneRect) -> ZoneRect {
        guard zones.indices.contains(index) else { return proposed }
        let start = zones[index]
        let blockers = zones.indices.filter { $0 != index && !overlaps(zones[$0], start) }.map { zones[$0] }
        // Exact here, so a zone slides right up to its neighbour's edge and shares it.
        func free(_ r: ZoneRect) -> Bool { !blockers.contains { overlaps($0, r, slack: 1e-9) } }
        if free(proposed) { return proposed }
        func furthest(from a: ZoneRect, to b: ZoneRect) -> ZoneRect {
            func at(_ t: Double) -> ZoneRect {
                ZoneRect(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t, w: a.w, h: a.h)
            }
            if free(b) { return b }
            var low = 0.0, high = 1.0
            for _ in 0..<40 {
                let mid = (low + high) / 2
                if free(at(mid)) { low = mid } else { high = mid }
            }
            return at(low)
        }
        let horizontal = furthest(from: start, to: ZoneRect(x: proposed.x, y: start.y, w: start.w, h: start.h))
        return furthest(from: horizontal, to: ZoneRect(x: horizontal.x, y: proposed.y, w: start.w, h: start.h))
    }

    /// Zones in the same row as `index` (same top and height) or column (same left and width) get equal sizes:
    /// the row keeps its outer edges and the gaps between its zones, and the zones' total length is shared out
    /// evenly, in left-to-right (top-to-bottom) order. Returns the changed rects; empty if the zone is alone.
    static func equalized(_ zones: [ZoneRect], index: Int, horizontal: Bool) -> [Int: ZoneRect] {
        guard zones.indices.contains(index) else { return [:] }
        let reference = zones[index]
        let members = zones.indices.filter { i in
            let z = zones[i]
            return horizontal ? abs(z.y - reference.y) <= tolerance && abs(z.h - reference.h) <= tolerance
                : abs(z.x - reference.x) <= tolerance && abs(z.w - reference.w) <= tolerance
        }.sorted { horizontal ? zones[$0].x < zones[$1].x : zones[$0].y < zones[$1].y }
        guard members.count > 1 else { return [:] }
        let total = members.map { horizontal ? zones[$0].w : zones[$0].h }.reduce(0, +)
        let share = total / Double(members.count)
        var cursor = horizontal ? zones[members[0]].x : zones[members[0]].y
        var changed: [Int: ZoneRect] = [:]
        for (rank, i) in members.enumerated() {
            if rank > 0 {
                let previous = zones[members[rank - 1]]
                let gap = horizontal ? zones[i].x - previous.maxX : zones[i].y - previous.maxY
                cursor += max(0, gap)
            }
            var zone = zones[i]
            if horizontal { zone.x = cursor; zone.w = share } else { zone.y = cursor; zone.h = share }
            cursor += share
            if zone != zones[i] { changed[i] = zone }
        }
        return changed
    }

    /// The zone moved so its centre is on the screen's centre line (x: horizontally, y: vertically).
    static func centered(_ r: ZoneRect, horizontally: Bool) -> ZoneRect {
        var zone = r
        if horizontally { zone.x = min(max(0, 0.5 - r.w / 2), 1 - r.w) } else { zone.y = min(max(0, 0.5 - r.h / 2), 1 - r.h) }
        return zone
    }
}

/// Sizes shown on the editor's zones, in the monitor's points (the "looks like" resolution macOS and Settings show,
/// e.g. 3840 × 1080). Edges are rounded first, so zones that share an edge add up to the screen exactly.
enum ZoneMeasure {
    static func size(_ r: ZoneRect, in usable: CGSize) -> (w: Int, h: Int) {
        let w = Double(usable.width), h = Double(usable.height)
        return (Int((r.maxX * w).rounded()) - Int((r.x * w).rounded()), Int((r.maxY * h).rounded()) - Int((r.y * h).rounded()))
    }

    /// The zone with an exact size typed by the user (points), keeping its centre where possible and staying on the
    /// screen; at least `minSize`.
    static func resized(_ r: ZoneRect, to size: (w: Double, h: Double), in usable: CGSize,
                        minSize: (w: Double, h: Double)) -> ZoneRect {
        guard usable.width > 0, usable.height > 0 else { return r }
        let w = min(1, max(minSize.w, size.w / Double(usable.width)))
        let h = min(1, max(minSize.h, size.h / Double(usable.height)))
        let cx = r.x + r.w / 2, cy = r.y + r.h / 2
        return ZoneRect(x: min(max(0, cx - w / 2), 1 - w), y: min(max(0, cy - h / 2), 1 - h), w: w, h: h)
    }
}

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

/// The Linked model ("grid" in FancyZones' terms): the zones tile the usable area, with no overlaps and no holes.
/// Edits that keep that true: dragging a divider (`ZoneLinking.resize`), swapping two zones, splitting one zone in
/// two and merging zones whose union is a rectangle. The Free model's "add" lives here too: the largest empty gap.
enum ZoneTiling {
    private static let slack = ZoneLinking.tolerance

    /// Whether the rects tile the screen: each inside it, no two overlapping, and together covering all of it.
    static func tiles(_ zones: [ZoneRect]) -> Bool {
        guard !zones.isEmpty else { return false }
        for zone in zones where zone.x < -slack || zone.y < -slack || zone.maxX > 1 + slack || zone.maxY > 1 + slack
            || zone.w <= slack || zone.h <= slack {
            return false
        }
        for i in zones.indices {
            for j in zones.indices where j > i && ZoneLinking.overlaps(zones[i], zones[j]) { return false }
        }
        // Inside the screen and not overlapping, so they cover it exactly when their areas add up to it.
        return abs(zones.map(\.area).reduce(0, +) - 1) <= 4 * slack
    }

    /// Edges of the zone that lie on the screen's border. In Linked mode they are not draggable (a hole would open).
    static func borderEdges(_ r: ZoneRect) -> ZoneSnapping.Edges {
        var edges: ZoneSnapping.Edges = []
        if r.x <= slack { edges.insert(.left) }
        if r.maxX >= 1 - slack { edges.insert(.right) }
        if r.y <= slack { edges.insert(.top) }
        if r.maxY >= 1 - slack { edges.insert(.bottom) }
        return edges
    }

    /// Splitting along the longer side: a vertical divider (left and right halves) when the zone is wider than tall
    /// on screen. `aspect` is the usable area's width / height.
    static func splitsVertically(_ r: ZoneRect, aspect: Double) -> Bool { r.w * aspect >= r.h }

    /// The zone cut in two at `position` (a screen fraction on the cut axis; the midpoint when nil), as the
    /// left/top part then the right/bottom one. Nil when either part would be smaller than the minimum.
    static func split(_ r: ZoneRect, vertically: Bool, at position: Double? = nil,
                      minSize: (w: Double, h: Double)) -> (ZoneRect, ZoneRect)? {
        if vertically {
            let cut = position ?? (r.x + r.w / 2)
            guard cut - r.x >= minSize.w - 1e-9, r.maxX - cut >= minSize.w - 1e-9 else { return nil }
            return (ZoneRect(x: r.x, y: r.y, w: cut - r.x, h: r.h), ZoneRect(x: cut, y: r.y, w: r.maxX - cut, h: r.h))
        }
        let cut = position ?? (r.y + r.h / 2)
        guard cut - r.y >= minSize.h - 1e-9, r.maxY - cut >= minSize.h - 1e-9 else { return nil }
        return (ZoneRect(x: r.x, y: r.y, w: r.w, h: cut - r.y), ZoneRect(x: r.x, y: cut, w: r.w, h: r.maxY - cut))
    }

    /// The rectangle that merging these zones makes, or nil when they are fewer than two, overlap each other, leave
    /// holes in their bounding box, or another zone reaches into it.
    static func mergedRect(_ zones: [ZoneRect], indices: Set<Int>) -> ZoneRect? {
        let chosen = indices.filter(zones.indices.contains).sorted()
        guard chosen.count >= 2 else { return nil }
        let parts = chosen.map { zones[$0] }
        let x = parts.map(\.x).min()!, y = parts.map(\.y).min()!
        let box = ZoneRect(x: x, y: y, w: parts.map(\.maxX).max()! - x, h: parts.map(\.maxY).max()! - y)
        for i in parts.indices { for j in parts.indices where j > i && ZoneLinking.overlaps(parts[i], parts[j]) { return nil } }
        guard abs(parts.map(\.area).reduce(0, +) - box.area) <= 4 * slack else { return nil }
        for i in zones.indices where !indices.contains(i) && ZoneLinking.overlaps(zones[i], box) { return nil }
        return box
    }

    /// Deleting a zone in Linked mode hands its space to a neighbour that shares a whole side with it (so the result
    /// is still a rectangle): the smallest such neighbour, then the first. Nil when there is none.
    static func deletionMerge(_ zones: [ZoneRect], index: Int) -> (neighbour: Int, rect: ZoneRect)? {
        guard zones.indices.contains(index) else { return nil }
        let candidates = zones.indices.filter { $0 != index }.compactMap { j -> (Int, ZoneRect)? in
            mergedRect(zones, indices: [index, j]).map { (j, $0) }
        }
        guard let best = candidates.min(by: { a, b in
            zones[a.0].area < zones[b.0].area - 1e-12 || (abs(zones[a.0].area - zones[b.0].area) <= 1e-12 && a.0 < b.0)
        }) else { return nil }
        return (best.0, best.1)
    }

    /// The largest empty rectangle on the screen (corners on the screen's or zones' edges), or nil if none is
    /// at least `minSize`.
    static func largestGap(_ zones: [ZoneRect], minSize: (w: Double, h: Double)) -> ZoneRect? {
        let xs = Array(Set([0, 1] + zones.flatMap { [$0.x, $0.maxX] }.map { min(max($0, 0), 1) })).sorted()
        let ys = Array(Set([0, 1] + zones.flatMap { [$0.y, $0.maxY] }.map { min(max($0, 0), 1) })).sorted()
        var best: ZoneRect?
        for (a, x0) in xs.enumerated() {
            for x1 in xs[(a + 1)...] where x1 - x0 >= minSize.w - 1e-9 {
                for (c, y0) in ys.enumerated() {
                    for y1 in ys[(c + 1)...] where y1 - y0 >= minSize.h - 1e-9 {
                        let r = ZoneRect(x: x0, y: y0, w: x1 - x0, h: y1 - y0)
                        if r.area > (best?.area ?? 0) + 1e-12, !zones.contains(where: { ZoneLinking.overlaps($0, r, slack: 1e-9) }) {
                            best = r
                        }
                    }
                }
            }
        }
        return best
    }

    /// Free mode's "Add zone": a third of the width and half the height, centred in the largest empty gap (shrunk
    /// to fit it); with no gap, cascaded a twenty-fourth down and right from `last` (the newest zone).
    static func freeZoneRect(_ zones: [ZoneRect], last: ZoneRect?, minSize: (w: Double, h: Double)) -> ZoneRect {
        let size = (w: 1.0 / 3, h: 0.5)
        if let gap = largestGap(zones, minSize: minSize) {
            let w = min(size.w, gap.w), h = min(size.h, gap.h)
            return ZoneRect(x: gap.x + (gap.w - w) / 2, y: gap.y + (gap.h - h) / 2, w: w, h: h)
        }
        guard let last else { return ZoneEditing.newZoneRect(existing: zones) }
        let step = 1.0 / 24
        var x = last.x + step, y = last.y + step
        if x + size.w > 1 + 1e-9 { x = 0 }
        if y + size.h > 1 + 1e-9 { y = 0 }
        return ZoneRect(x: x, y: y, w: size.w, h: size.h)
    }
}

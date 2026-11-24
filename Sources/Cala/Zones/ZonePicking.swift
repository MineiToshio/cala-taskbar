import Foundation
import CoreGraphics

enum ZonePicking {
    struct Target: Equatable {
        var frame: CGRect
        var chosen: Set<UUID>
        var soft: Set<UUID>
    }

    static func zonesUnder(_ p: CGPoint, zones: [Zone], usable: CGRect) -> [Zone] {
        zones.filter {
            let edges = ZoneGeometry.edges(for: $0.rect, in: usable)
            return p.x >= edges.minX && p.x < edges.maxX && p.y >= edges.minY && p.y < edges.maxY
        }
    }

    static func chosen(_ p: CGPoint, zones: [Zone], usable: CGRect) -> Zone? {
        winner(in: zonesUnder(p, zones: zones, usable: usable))
    }

    struct EditorHit {
        var zone: Zone
        var edges: ZoneSnapping.Edges
    }

    struct EditorHandle {
        static let side: CGFloat = 8
        static let hitRadius: CGFloat = 6
        let center: CGPoint
        let edges: ZoneSnapping.Edges
    }

    static func editorHandles(in frame: CGRect) -> [EditorHandle] {
        let positions: [(CGFloat, CGFloat, ZoneSnapping.Edges)] = [
            (frame.minX, frame.maxY, [.left, .top]),
            (frame.midX, frame.maxY, .top),
            (frame.maxX, frame.maxY, [.right, .top]),
            (frame.minX, frame.midY, .left),
            (frame.maxX, frame.midY, .right),
            (frame.minX, frame.minY, [.left, .bottom]),
            (frame.midX, frame.minY, .bottom),
            (frame.maxX, frame.minY, [.right, .bottom])
        ]
        return positions.map { x, y, edges in
            EditorHandle(center: CGPoint(x: x, y: y), edges: edges)
        }
    }

    static func editorHit(at point: CGPoint, zones: [Zone], usable: CGRect, selectedID: UUID? = nil) -> EditorHit? {
        if let selectedID, let selected = zones.first(where: { $0.id == selectedID }) {
            let handles = editorHandles(in: ZoneGeometry.frame(for: selected.rect, in: usable))
            let nearby = handles.filter {
                abs(point.x - $0.center.x) <= EditorHandle.hitRadius && abs(point.y - $0.center.y) <= EditorHandle.hitRadius
            }
            if let closest = nearby.min(by: {
                hypot(point.x - $0.center.x, point.y - $0.center.y) < hypot(point.x - $1.center.x, point.y - $1.center.y)
            }) {
                return EditorHit(zone: selected, edges: closest.edges)
            }
        }
        // Preserve the regular picker at shared edges. Include exposed right and bottom
        // boundaries so handles centered on those edges can still be grabbed.
        let zone = chosen(point, zones: zones, usable: usable) ?? winner(in: zones.filter {
            let edges = ZoneGeometry.edges(for: $0.rect, in: usable)
            return (edges.minX...edges.maxX).contains(point.x) && (edges.minY...edges.maxY).contains(point.y)
        })
        guard let zone else { return nil }
        let frame = ZoneGeometry.frame(for: zone.rect, in: usable)
        let x = min(point.x - frame.minX, frame.maxX - point.x)
        let y = min(point.y - frame.minY, frame.maxY - point.y)
        let horizontal: ZoneSnapping.Edges = point.x <= frame.midX ? .left : .right
        let vertical: ZoneSnapping.Edges = point.y >= frame.midY ? .top : .bottom
        if x <= 12 && y <= 12 { return EditorHit(zone: zone, edges: horizontal.union(vertical)) }
        var edges: ZoneSnapping.Edges = []
        if x <= 8 { edges.insert(horizontal) }
        if y <= 8 { edges.insert(vertical) }
        return EditorHit(zone: zone, edges: edges)
    }

    private static func winner(in hits: [Zone]) -> Zone? {
        guard let smallest = hits.map(\.rect.area).min() else { return nil }
        // File order breaks ties when older data lacks a creation sequence.
        return hits.reversed().filter { abs($0.rect.area - smallest) < 0.000001 }.max { $0.seq < $1.seq }
    }

    static func span(anchor: Zone, current: Zone, zones: [Zone]) -> (rect: ZoneRect, members: Set<UUID>) {
        span(anchor: anchor, current: [current], zones: zones)
    }

    static func span(anchor: Zone, current: [Zone], zones: [Zone]) -> (rect: ZoneRect, members: Set<UUID>) {
        let endpoints = [anchor] + current
        let ids = Set(endpoints.map(\.id))
        guard ids.count > 1 else { return (anchor.rect, [anchor.id]) }

        let x = endpoints.map(\.rect.x).min() ?? anchor.rect.x
        let y = endpoints.map(\.rect.y).min() ?? anchor.rect.y
        let maxX = endpoints.map(\.rect.maxX).max() ?? anchor.rect.maxX
        let maxY = endpoints.map(\.rect.maxY).max() ?? anchor.rect.maxY
        let tolerance = 0.002
        let contained = zones.filter {
            $0.rect.x >= x - tolerance && $0.rect.y >= y - tolerance
                && $0.rect.maxX <= maxX + tolerance && $0.rect.maxY <= maxY + tolerance
        }
        let candidates = contained + current
        var reached = Set([anchor.id])
        var frontier = [anchor]
        while !ids.isSubset(of: reached), let zone = frontier.popLast() {
            for next in candidates where !reached.contains(next.id) && touches(zone.rect, next.rect) {
                reached.insert(next.id)
                frontier.append(next)
            }
        }
        guard ids.isSubset(of: reached) else {
            let fallback = current.last ?? anchor
            return (fallback.rect, [fallback.id])
        }
        return (ZoneRect(x: x, y: y, w: maxX - x, h: maxY - y), ids.union(contained.map(\.id)))
    }

    private static func touches(_ a: ZoneRect, _ b: ZoneRect) -> Bool {
        let x = min(a.maxX, b.maxX) - max(a.x, b.x)
        let y = min(a.maxY, b.maxY) - max(a.y, b.y)
        let roundoff = 4 * Double.ulpOfOne
        // Overlap or a shared edge connects two zones. A shared corner alone does not.
        return x >= -roundoff && y >= -roundoff && (x > roundoff || y > roundoff)
    }

    static func target(point: CGPoint, zones: [Zone], usable: CGRect, gap: CGFloat, spanAnchor: UUID?) -> Target? {
        let hits = zonesUnder(point, zones: zones, usable: usable)
        guard let current = winner(in: hits) else { return nil }
        if let anchor = zones.first(where: { $0.id == spanAnchor }) {
            let selection = span(anchor: anchor, current: current, zones: zones)
            if selection.members.count > 1 {
                let frame = ZoneGeometry.frame(for: selection.rect, in: usable)
                return Target(frame: ZoneGeometry.applyGap(frame, gap: gap, usable: usable),
                              chosen: selection.members, soft: selection.members.union(hits.map(\.id)))
            }
        }
        let frame = ZoneGeometry.frame(for: current.rect, in: usable)
        return Target(frame: ZoneGeometry.applyGap(frame, gap: gap, usable: usable),
                      chosen: [current.id], soft: Set(hits.map(\.id)).subtracting([current.id]))
    }
}

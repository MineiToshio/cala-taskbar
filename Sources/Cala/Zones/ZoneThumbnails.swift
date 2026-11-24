import Foundation
import CoreGraphics

/// Geometry of a layout's small picture: the screen's shape with each zone drawn inside it. Shared by the editor's
/// gallery, Settings → Zones and the menu-bar icon's layout menus (drawn by `ZoneThumbnailRenderer`).
enum ZoneThumbnails {
    /// The largest size with the screen's shape (width / height) that fits the box. Each side is at least 1 pt.
    static func size(aspect: Double, fitting box: CGSize) -> CGSize {
        guard aspect.isFinite, aspect > 0, box.width > 0, box.height > 0 else { return CGSize(width: 1, height: 1) }
        let width = min(Double(box.width), Double(box.height) * aspect)
        return CGSize(width: max(1, width.rounded()), height: max(1, (width / aspect).rounded()))
    }

    /// Zone frames inside a picture of `size`, origin at the top-left (y grows down, like a flipped view).
    /// The outer `inset` keeps zones off the picture's border and `gap` separates neighbours, so two zones sharing
    /// an edge read as two. Edges land on the pixel grid of `scale`; a zone is never thinner than one pixel.
    static func frames(for zones: [ZoneRect], size: CGSize, inset: Double, gap: Double, scale: Double = 2) -> [CGRect] {
        let scale = scale > 0 && scale.isFinite ? scale : 1
        let width = max(0, Double(size.width) - 2 * inset)
        let height = max(0, Double(size.height) - 2 * inset)
        let pixel = 1 / scale
        func align(_ value: Double) -> Double { (value * scale).rounded() / scale }
        return zones.map { zone in
            var minX = align(inset + zone.x * width + gap / 2)
            var maxX = align(inset + zone.maxX * width - gap / 2)
            var minY = align(inset + zone.y * height + gap / 2)
            var maxY = align(inset + zone.maxY * height - gap / 2)
            if maxX - minX < pixel { maxX = minX + pixel }
            if maxY - minY < pixel { maxY = minY + pixel }
            minX = max(0, minX); minY = max(0, minY)
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
    }

    /// Indices in painting order: larger zones first, so a smaller zone on top of a bigger one stays visible
    /// (the same "smallest wins" rule the picker uses). Equal areas keep file order.
    static func paintingOrder(_ zones: [ZoneRect]) -> [Int] {
        zones.indices.sorted { a, b in
            if abs(zones[a].area - zones[b].area) > 0.000001 { return zones[a].area > zones[b].area }
            return a < b
        }
    }
}

/// Editor helpers that need no AppKit.
enum ZoneEditing {
    /// Where "Add zone" puts a new zone: a third of the width and half the height, centred, on the 12-grid.
    /// If that spot is taken by a zone with the same frame, it steps one twelfth down and right (wrapping).
    static func newZoneRect(existing: [ZoneRect]) -> ZoneRect {
        let step = 1.0 / 12
        var candidate = ZoneRect(x: 4 * step, y: 3 * step, w: 4 * step, h: 6 * step)
        for _ in 0..<12 {
            let taken = existing.contains { zone in
                abs(zone.x - candidate.x) < 0.001 && abs(zone.y - candidate.y) < 0.001
                    && abs(zone.w - candidate.w) < 0.001 && abs(zone.h - candidate.h) < 0.001
            }
            guard taken else { return candidate }
            candidate.x += step
            candidate.y += step
            if candidate.maxX > 1.0001 || candidate.maxY > 1.0001 { candidate.x = 0; candidate.y = 0 }
        }
        return candidate
    }

    /// `base`, or `base 2`, `base 3`... whichever no other layout uses (ignoring case and surrounding spaces).
    static func uniqueName(_ base: String, existing: [String]) -> String {
        let taken = Set(existing.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        var number = 2
        while taken.contains("\(base) \(number)".lowercased()) { number += 1 }
        return "\(base) \(number)"
    }
}

/// Names monitors so two of them can always be told apart. A monitor keeps its own name when that name is unique;
/// monitors that share a name (two identical models, or several reported as "(AirPlay)") or have none are named
/// by where they sit instead: left / middle / right, or top / bottom, else "Display N" in screen order.
enum ZoneMonitorNames {
    struct Monitor {
        var name: String
        /// AppKit coordinates (y grows up).
        var frame: CGRect
    }

    static func labels(_ monitors: [Monitor], localize: (String, String) -> String) -> [String] {
        let names = monitors.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
        // macOS itself numbers same-named screens ("(AirPlay) (1)", "(AirPlay) (2)"), which says nothing about
        // which one is which: compare names without that number.
        let bases = names.map(baseName)
        let counts = Dictionary(bases.map { ($0, 1) }, uniquingKeysWith: +)
        let positions = positionNames(monitors.map(\.frame), localize: localize)
        return monitors.indices.map { index in
            let name = names[index]
            if !bases[index].isEmpty, counts[bases[index]] == 1 { return name }
            return positions[index]
        }
    }

    /// Lowercased name without a trailing " (2)"-style number.
    static func baseName(_ name: String) -> String {
        var base = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if base.hasSuffix(")"), let open = base.lastIndex(of: "(") {
            let digits = base[base.index(after: open)..<base.index(before: base.endIndex)]
            if !digits.isEmpty, digits.allSatisfy(\.isNumber) {
                base = String(base[..<open]).trimmingCharacters(in: .whitespaces)
            }
        }
        return base
    }

    private static func positionNames(_ frames: [CGRect], localize: (String, String) -> String) -> [String] {
        func numbered() -> [String] {
            frames.indices.map { localize("Display \($0 + 1)", "Pantalla \($0 + 1)") }
        }
        guard frames.count > 1, frames.count <= 3 else { return numbered() }
        func overlap(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> Bool { min(b, d) - max(a, c) > 1 }
        let pairs = frames.indices.flatMap { a in frames.indices.filter { $0 > a }.map { (a, $0) } }
        let sideBySide = pairs.allSatisfy { !overlap(frames[$0].minX, frames[$0].maxX, frames[$1].minX, frames[$1].maxX) }
        let stacked = pairs.allSatisfy { !overlap(frames[$0].minY, frames[$0].maxY, frames[$1].minY, frames[$1].maxY) }
        if sideBySide {
            let order = frames.indices.sorted { frames[$0].minX < frames[$1].minX }
            let words = frames.count == 2
                ? [localize("Left display", "Pantalla izquierda"), localize("Right display", "Pantalla derecha")]
                : [localize("Left display", "Pantalla izquierda"), localize("Middle display", "Pantalla central"),
                   localize("Right display", "Pantalla derecha")]
            var result = numbered()
            for (rank, index) in order.enumerated() { result[index] = words[rank] }
            return result
        }
        if stacked, frames.count == 2 {
            let top = frames[0].minY > frames[1].minY ? 0 : 1
            var result = numbered()
            result[top] = localize("Top display", "Pantalla superior")
            result[1 - top] = localize("Bottom display", "Pantalla inferior")
            return result
        }
        return numbered()
    }
}

import Foundation

enum ZoneTemplates {
    static let ids = ["two-columns", "three-columns", "grid-2x2", "main-side", "side-main", "two-rows",
                      "main-two-stacked", "wide-center"]

    static func name(_ id: String) -> String {
        switch id {
        case "two-columns": return "Two columns"
        case "three-columns": return "Three columns"
        case "grid-2x2": return "2 × 2 grid"
        case "main-side": return "Main + side"
        case "side-main": return "Side + main"
        case "two-rows": return "Two rows"
        case "main-two-stacked": return "Main + two stacked"
        case "wide-center": return "Wide center"
        default: return id
        }
    }

    static func zones(_ id: String) -> [ZoneRect] {
        func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> ZoneRect {
            ZoneRect(x: x, y: y, w: w, h: h)
        }
        switch id {
        case "two-columns": return [rect(0, 0, 0.5, 1), rect(0.5, 0, 0.5, 1)]
        case "three-columns": return [rect(0, 0, 1.0 / 3, 1), rect(1.0 / 3, 0, 1.0 / 3, 1), rect(2.0 / 3, 0, 1.0 / 3, 1)]
        case "grid-2x2": return [rect(0, 0, 0.5, 0.5), rect(0.5, 0, 0.5, 0.5),
                                rect(0, 0.5, 0.5, 0.5), rect(0.5, 0.5, 0.5, 0.5)]
        case "main-side": return [rect(0, 0, 2.0 / 3, 1), rect(2.0 / 3, 0, 1.0 / 3, 1)]
        case "side-main": return [rect(0, 0, 1.0 / 3, 1), rect(1.0 / 3, 0, 2.0 / 3, 1)]
        case "two-rows": return [rect(0, 0, 1, 0.5), rect(0, 0.5, 1, 0.5)]
        case "main-two-stacked": return [rect(0, 0, 0.5, 1), rect(0.5, 0, 0.5, 0.5), rect(0.5, 0.5, 0.5, 0.5)]
        case "wide-center": return [rect(0, 0, 0.25, 1), rect(0.25, 0, 0.5, 1), rect(0.75, 0, 0.25, 1)]
        default: return []
        }
    }

    static func makeLayout(_ id: String, name: String) -> ZoneLayout {
        let zones = zones(id).enumerated().map { Zone(rect: $0.element, seq: $0.offset) }
        return ZoneLayout(name: name, zones: zones, nextSeq: zones.count, template: id)
    }

    static func seedState(names: (String) -> String = name) -> ZonesState {
        let layouts = ids.map { makeLayout($0, name: names($0)) }
        return ZonesState(layouts: layouts, defaultLayout: layouts.first?.id)
    }
}

import Foundation

enum ZoneTemplates {
    static let ids = ["two-columns", "three-columns", "grid-2x2", "main-side", "side-main", "two-rows",
                      "main-two-stacked", "wide-center"]

    static func name(_ id: String) -> String { name(id, localizedWith: { english, _ in english }) }

    static func name(_ id: String, localizedWith localize: (String, String) -> String) -> String {
        switch id {
        case "two-columns": return localize("Two columns", "Dos columnas")
        case "three-columns": return localize("Three columns", "Tres columnas")
        case "grid-2x2": return localize("2 × 2 grid", "Cuadrícula 2 × 2")
        case "main-side": return localize("Main + side", "Principal + lateral")
        case "side-main": return localize("Side + main", "Lateral + principal")
        case "two-rows": return localize("Two rows", "Dos filas")
        case "main-two-stacked": return localize("Main + two stacked", "Principal + dos apiladas")
        case "wide-center": return localize("Wide center", "Centro ancho")
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

    /// Built-in layouts no layout in the state comes from (the user deleted them), in template order.
    static func missing(in state: ZonesState) -> [String] {
        let present = Set(state.layouts.compactMap(\.template))
        return ids.filter { !present.contains($0) }
    }

    /// Whether a layout made from a built-in no longer has the built-in's zones (so "Restore original" applies).
    static func isModified(_ layout: ZoneLayout) -> Bool {
        guard let template = layout.template, ids.contains(template) else { return false }
        return layout.zones.map(\.rect) != zones(template)
    }

    /// The layout with its built-in zones back; its id, name and per-monitor use stay.
    static func restored(_ layout: ZoneLayout) -> ZoneLayout {
        guard let template = layout.template, ids.contains(template) else { return layout }
        var copy = layout
        copy.zones = zones(template).enumerated().map { Zone(rect: $0.element, seq: $0.offset) }
        copy.nextSeq = copy.zones.count
        copy.mode = .linked   // every built-in tiles the screen
        return copy
    }

    static func seedState(names: (String) -> String = name) -> ZonesState {
        let layouts = ids.map { makeLayout($0, name: names($0)) }
        return ZonesState(layouts: layouts, defaultLayout: layouts.first?.id)
    }
}

import Foundation

struct ZoneRect: Codable, Equatable {
    // Fractions of the usable screen, measured from its top-left corner.
    var x, y, w, h: Double

    var maxX: Double { x + w }
    var maxY: Double { y + h }
    var area: Double { w * h }
    var isFinite: Bool { x.isFinite && y.isFinite && w.isFinite && h.isFinite }
}

struct Zone: Codable, Equatable, Identifiable {
    var id: UUID
    var rect: ZoneRect
    var seq: Int

    init(id: UUID = UUID(), rect: ZoneRect, seq: Int = 0) {
        self.id = id
        self.rect = rect
        self.seq = seq
    }

    private enum CodingKeys: String, CodingKey { case id, rect, seq }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        id = try fields.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        rect = try fields.decode(ZoneRect.self, forKey: .rect)
        seq = try fields.decodeIfPresent(Int.self, forKey: .seq) ?? 0
    }
}

struct ZoneLayout: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var zones: [Zone]
    var nextSeq: Int
    var template: String?
    var isTemplate: Bool { template != nil }

    init(id: UUID = UUID(), name: String, zones: [Zone] = [], nextSeq: Int = 0, template: String? = nil) {
        self.id = id
        self.name = name
        self.zones = zones
        self.nextSeq = nextSeq
        self.template = template
    }

    private enum CodingKeys: String, CodingKey { case id, name, zones, nextSeq, template }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        id = try fields.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try fields.decode(String.self, forKey: .name)
        zones = try fields.decodeIfPresent([Zone].self, forKey: .zones) ?? []
        nextSeq = try fields.decodeIfPresent(Int.self, forKey: .nextSeq) ?? 0
        template = try fields.decodeIfPresent(String.self, forKey: .template)
    }

    @discardableResult
    mutating func addZone(_ rect: ZoneRect) -> UUID {
        repairCreationOrder()
        let zone = Zone(rect: rect, seq: nextSeq)
        zones.append(zone)
        nextSeq += 1
        return zone.id
    }

    mutating func repairCreationOrder() {
        let last = zones.map(\.seq).max() ?? -1
        if nextSeq == Int.max || last >= Int.max - 1 {
            resetCreationOrder()
        } else {
            nextSeq = max(nextSeq, last + 1, 0)
        }
    }

    private mutating func resetCreationOrder() {
        let oldestFirst = zones.indices.sorted {
            if zones[$0].seq == zones[$1].seq { return $0 < $1 }
            return zones[$0].seq < zones[$1].seq
        }
        for (seq, index) in oldestFirst.enumerated() { zones[index].seq = seq }
        nextSeq = zones.count
    }
}

enum ZoneActivation: String, Codable { case rightClick, shift, both }

struct ZonesState: Codable, Equatable {
    static let off = "off"

    var version: Int
    var layouts: [ZoneLayout]
    var defaultLayout: UUID?
    var activeByDisplay: [String: String]

    init(version: Int = 1, layouts: [ZoneLayout], defaultLayout: UUID? = nil,
         activeByDisplay: [String: String] = [:]) {
        self.version = version
        self.layouts = layouts
        self.defaultLayout = defaultLayout
        self.activeByDisplay = activeByDisplay
    }

    private enum CodingKeys: String, CodingKey { case version, layouts, defaultLayout, activeByDisplay }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        version = try fields.decodeIfPresent(Int.self, forKey: .version) ?? 1
        layouts = try fields.decodeIfPresent([ZoneLayout].self, forKey: .layouts) ?? []
        defaultLayout = try fields.decodeIfPresent(UUID.self, forKey: .defaultLayout)
        activeByDisplay = try fields.decodeIfPresent([String: String].self, forKey: .activeByDisplay) ?? [:]
    }

    func repaired(names: (String) -> String = ZoneTemplates.name) -> ZonesState {
        var state = self
        var layoutIDs = Set<UUID>()
        state.layouts = layouts.compactMap { layout in
            guard layoutIDs.insert(layout.id).inserted else { return nil }
            var layout = layout
            var zoneIDs = Set<UUID>()
            layout.zones = layout.zones.compactMap { zone in
                guard zone.rect.isFinite, zoneIDs.insert(zone.id).inserted else { return nil }
                var zone = zone
                zone.rect = ZoneGeometry.clamp(zone.rect, minW: 0.05, minH: 0.05)
                return zone
            }
            layout.repairCreationOrder()
            return layout
        }
        if state.layouts.isEmpty {
            state.layouts = ZoneTemplates.seedState(names: names).layouts
            layoutIDs = Set(state.layouts.map(\.id))
        }
        if state.defaultLayout.map(layoutIDs.contains) != true {
            state.defaultLayout = state.layouts.first?.id
        }
        state.activeByDisplay = activeByDisplay.compactMapValues { value in
            if value == Self.off { return value }
            guard let id = UUID(uuidString: value), layoutIDs.contains(id) else { return nil }
            return id.uuidString
        }
        return state
    }

    func layout(forDisplay key: String) -> ZoneLayout? {
        let assignment = activeByDisplay[key]
        if assignment == Self.off { return nil }
        let id = assignment.flatMap(UUID.init(uuidString:))
        return layouts.first { $0.id == id } ?? layouts.first { $0.id == defaultLayout } ?? layouts.first
    }

    @discardableResult
    mutating func duplicate(_ id: UUID, name: String) -> UUID {
        guard let source = layouts.first(where: { $0.id == id }) else { return id }
        var copy = source
        copy.id = UUID()
        copy.name = name
        copy.zones = copy.zones.map { Zone(rect: $0.rect, seq: $0.seq) }
        layouts.append(copy)
        return copy.id
    }

    @discardableResult
    mutating func delete(_ id: UUID) -> Bool {
        guard layouts.count > 1, let index = layouts.firstIndex(where: { $0.id == id }) else { return false }
        layouts.remove(at: index)
        if defaultLayout == id { defaultLayout = layouts.first?.id }
        activeByDisplay = activeByDisplay.filter { UUID(uuidString: $0.value) != id }
        return true
    }
}

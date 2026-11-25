import Foundation

struct ZoneRect: Codable, Equatable {
    // Fractions of the usable screen, measured from its top-left corner.
    var x, y, w, h: Double

    var maxX: Double { x + w }
    var maxY: Double { y + h }
    var area: Double { w * h }
    var isFinite: Bool { x.isFinite && y.isFinite && w.isFinite && h.isFinite }
}

/// Legacy or seeded entries must get the same IDs when the file is read again before its first write.
func zoneStorageID(kind: UInt8, layout: Int, zone: Int = 0, attempt: Int = 0) -> UUID {
    let a = UInt32(truncatingIfNeeded: layout).bigEndian
    let b = UInt32(truncatingIfNeeded: zone).bigEndian
    return withUnsafeBytes(of: a) { a in
        withUnsafeBytes(of: b) { b in
            UUID(uuid: (0xCA, 0x1A, 0x5A, kind, a[0], a[1], 0x80 | UInt8(truncatingIfNeeded: attempt >> 24), UInt8(truncatingIfNeeded: attempt >> 16),
                        0x80 | UInt8(truncatingIfNeeded: attempt >> 8), UInt8(truncatingIfNeeded: attempt),
                        a[2], a[3], b[0], b[1], b[2], b[3]))
        }
    }
}

/// Reserve explicit IDs before repairing any missing entries so a fallback never claims their identity.
private func restoreStorageIDs<Entry>(_ entries: inout [Entry], missing: WritableKeyPath<Entry, Bool>,
                                      id: WritableKeyPath<Entry, UUID>, candidate: (Int, Int) -> UUID) {
    var reserved = Set(entries.lazy.filter { !$0[keyPath: missing] }.map { $0[keyPath: id] })
    for index in entries.indices where entries[index][keyPath: missing] {
        var attempt = 0
        while true {
            let replacement = candidate(index, attempt)
            if reserved.insert(replacement).inserted {
                entries[index][keyPath: id] = replacement
                entries[index][keyPath: missing] = false
                break
            }
            attempt += 1
        }
    }
}

struct Zone: Codable, Equatable, Identifiable {
    var id: UUID
    fileprivate var missingStorageID = false
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
        let storedID = try fields.decodeIfPresent(UUID.self, forKey: .id)
        id = storedID ?? zoneStorageID(kind: 2, layout: 0)
        missingStorageID = storedID == nil
        rect = try fields.decode(ZoneRect.self, forKey: .rect)
        seq = try fields.decodeIfPresent(Int.self, forKey: .seq) ?? 0
    }
}

/// How a layout is edited. `linked`: the zones tile the usable area (no overlaps, no holes) and are changed by
/// dragging dividers, splitting and merging. `free`: rectangles anywhere, overlaps allowed.
enum ZoneLayoutMode: String, Codable {
    case linked, free

    /// Linked when the zones tile the screen, otherwise Free.
    static func inferred(from zones: [Zone]) -> ZoneLayoutMode {
        ZoneTiling.tiles(zones.map(\.rect)) ? .linked : .free
    }
}

struct ZoneLayout: Codable, Equatable, Identifiable {
    var id: UUID
    fileprivate var missingStorageID = false
    var name: String
    var isNameCustomized: Bool?
    var zones: [Zone]
    var nextSeq: Int
    var template: String?
    var mode: ZoneLayoutMode
    var isTemplate: Bool { template != nil }

    /// Without a `mode`, it is inferred from the zones (see `ZoneLayoutMode.inferred`).
    init(id: UUID = UUID(), name: String, zones: [Zone] = [], nextSeq: Int = 0, template: String? = nil,
         mode: ZoneLayoutMode? = nil, isNameCustomized: Bool? = nil) {
        self.id = id
        self.name = name
        self.isNameCustomized = isNameCustomized
        self.zones = zones
        self.nextSeq = nextSeq
        self.template = template
        self.mode = mode ?? .inferred(from: zones)
    }

    private enum CodingKeys: String, CodingKey { case id, name, zones, nextSeq, template, mode, isNameCustomized }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        let storedID = try fields.decodeIfPresent(UUID.self, forKey: .id)
        id = storedID ?? zoneStorageID(kind: 1, layout: 0)
        missingStorageID = storedID == nil
        name = try fields.decode(String.self, forKey: .name)
        isNameCustomized = try? fields.decodeIfPresent(Bool.self, forKey: .isNameCustomized)
        var decodedZones = try fields.decodeIfPresent([Zone].self, forKey: .zones) ?? []
        let layoutIndex = decoder.codingPath.last?.intValue ?? 0
        restoreStorageIDs(&decodedZones, missing: \.missingStorageID, id: \.id) { index, attempt in
            zoneStorageID(kind: 2, layout: layoutIndex, zone: index, attempt: attempt)
        }
        zones = decodedZones
        nextSeq = try fields.decodeIfPresent(Int.self, forKey: .nextSeq) ?? 0
        template = try fields.decodeIfPresent(String.self, forKey: .template)
        // Older files have no mode, and an unknown value must not cost the whole file: infer it then.
        mode = (try? fields.decodeIfPresent(String.self, forKey: .mode)).flatMap { $0 }
            .flatMap(ZoneLayoutMode.init(rawValue:)) ?? .inferred(from: zones)
    }

    mutating func rename(to name: String) {
        self.name = name
        isNameCustomized = true
    }

    @discardableResult
    mutating func addZone(_ rect: ZoneRect) -> UUID {
        repairCreationOrder()
        let zone = Zone(rect: rect, seq: nextSeq)
        zones.append(zone)
        nextSeq += 1
        // An added rectangle always overlaps a tiling, so the layout becomes Free (Linked layouts split instead).
        if mode == .linked && !ZoneTiling.tiles(zones.map(\.rect)) { mode = .free }
        return zone.id
    }

    /// Cuts a zone in two (see `ZoneTiling.split`); the new part follows it in the list. Returns its id, or nil
    /// when the parts would be too small.
    @discardableResult
    mutating func split(_ id: UUID, vertically: Bool, at position: Double? = nil,
                        minSize: (w: Double, h: Double)) -> UUID? {
        guard let index = zones.firstIndex(where: { $0.id == id }),
              let (first, second) = ZoneTiling.split(zones[index].rect, vertically: vertically, at: position,
                                                      minSize: minSize) else { return nil }
        repairCreationOrder()
        zones[index].rect = first
        let part = Zone(rect: second, seq: nextSeq)
        nextSeq += 1
        zones.insert(part, at: index + 1)
        return part.id
    }

    /// Merges zones whose union is a rectangle into the first of them in the list. Returns its id.
    @discardableResult
    mutating func merge(_ ids: Set<UUID>) -> UUID? {
        let indices = Set(zones.indices.filter { ids.contains(zones[$0].id) })
        guard let rect = ZoneTiling.mergedRect(zones.map(\.rect), indices: indices), let keep = indices.min() else { return nil }
        let kept = zones[keep].id
        zones[keep].rect = rect
        zones.removeAll { ids.contains($0.id) && $0.id != kept }
        return kept
    }

    /// Linked delete: the zone's space goes to a neighbour (see `ZoneTiling.deletionMerge`). Returns that neighbour.
    @discardableResult
    mutating func removeByMerging(_ id: UUID) -> UUID? {
        guard let index = zones.firstIndex(where: { $0.id == id }),
              let (neighbour, rect) = ZoneTiling.deletionMerge(zones.map(\.rect), index: index) else { return nil }
        let kept = zones[neighbour].id
        zones[neighbour].rect = rect
        zones.remove(at: index)
        return kept
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
        var decodedLayouts = try fields.decodeIfPresent([ZoneLayout].self, forKey: .layouts) ?? []
        restoreStorageIDs(&decodedLayouts, missing: \.missingStorageID, id: \.id) { index, attempt in
            zoneStorageID(kind: 1, layout: index, attempt: attempt)
        }
        layouts = decodedLayouts
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
            // A Linked layout must tile; one that no longer does (edited by hand) is edited as Free.
            if layout.mode == .linked && !ZoneTiling.tiles(layout.zones.map(\.rect)) { layout.mode = .free }
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
        copy.rename(to: name)
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

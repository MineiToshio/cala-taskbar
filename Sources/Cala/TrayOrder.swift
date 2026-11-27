import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Where a tray item lives: visible in the bar, in the overflow panel, or hidden.
enum TrayPlace: String, CaseIterable, Identifiable {
    case bar, more, hidden
    var id: String { rawValue }

    var menuDestinations: [TrayPlace] {
        switch self {
        case .bar: return [.more, .hidden]
        case .more: return [.bar, .hidden]
        case .hidden: return []
        }
    }
}

struct TrayItemGroup {
    let place: TrayPlace
    var items: [String]
    var rows: [TrayListRow] {
        [.heading(place)] + (items.isEmpty ? [.empty(place)] : items.map(TrayListRow.item))
    }
}

enum TrayListRow: Hashable {
    case heading(TrayPlace)
    case item(String)
    case empty(TrayPlace)

    var itemID: String? {
        if case let .item(id) = self { return id }
        return nil
    }
}

/// Translate SwiftUI's destination gap in the original list to a gap in one group.
func trayMoveTarget(in rows: [TrayListRow], source: Int, destination: Int) -> (place: TrayPlace, index: Int)? {
    guard rows.indices.contains(source), rows[source].itemID != nil,
          (0...rows.count).contains(destination), case let .heading(firstPlace) = rows.first else { return nil }
    var place = firstPlace
    var index = 0
    for row in rows.prefix(destination) {
        switch row {
        case let .heading(nextPlace):
            place = nextPlace
            index = 0
        case .item:
            index += 1
        case .empty:
            break
        }
    }
    return (place, index)
}

/// The insertion index is a gap in the destination group, measured before removing the source.
func movingTrayItem(_ id: String, to place: TrayPlace, at insertionIndex: Int, in groups: [TrayItemGroup],
                    savedLayout: [String: String], savedOrder: [String]) -> (layout: [String: String], order: [String])? {
    guard let source = groups.firstIndex(where: { $0.items.contains(id) }),
          let sourceIndex = groups[source].items.firstIndex(of: id),
          let destination = groups.firstIndex(where: { $0.place == place }),
          (0...groups[destination].items.count).contains(insertionIndex) else { return nil }

    let index = source == destination && sourceIndex < insertionIndex ? insertionIndex - 1 : insertionIndex
    guard source != destination || sourceIndex != index else { return nil }
    var updated = groups
    updated[source].items.remove(at: sourceIndex)
    updated[destination].items.insert(id, at: index)
    var layout = savedLayout
    if source != destination { layout[id] = place.rawValue }
    return (layout, mergingTrayOrder(savedOrder, with: updated.flatMap(\.items)))
}

/// Reorder the selected slots, keeping saved entries for items outside that selection.
func mergingTrayOrder(_ savedOrder: [String], with visibleOrder: [String]) -> [String] {
    let visibleIDs = Set(visibleOrder)
    var remaining = visibleOrder.makeIterator()
    var merged = savedOrder.compactMap { id in
        visibleIDs.contains(id) ? remaining.next() : id
    }
    merged.append(contentsOf: remaining)
    return merged
}

struct TrayBarDrag {
    let id: String
    private let peers: [(id: String, crossing: CGFloat, width: CGFloat)]
    private let firstCenter: CGFloat

    init?(id: String, order: [String], frames: [String: CGRect]) {
        guard let source = order.firstIndex(of: id), let frame = frames[id], !frame.isEmpty else { return nil }
        self.id = id
        // Measure once, before the cells slide. Peers on the right lose the dragged cell's width
        // when its slot moves past them, so compare the dragged edge to the peer's midpoint.
        peers = order.enumerated().compactMap { index, peer in
            guard peer != id, let bounds = frames[peer], !bounds.isEmpty else { return nil }
            return (peer, bounds.midX + (index < source ? frame.width / 2 : -frame.width / 2), bounds.width)
        }
        firstCenter = frame.midX - peers.prefix { $0.crossing < frame.midX }.reduce(0) { $0 + $1.width }
    }

    func order(at centerX: CGFloat) -> [String] {
        var order = peers.map(\.id)
        let index = peers.firstIndex { centerX < $0.crossing } ?? order.count
        order.insert(id, at: index)
        return order
    }

    func restingCenter(in order: [String]) -> CGFloat {
        let index = order.firstIndex(of: id) ?? 0
        return firstCenter + peers.prefix(index).reduce(0) { $0 + $1.width }
    }
}

func savingTrayBarOrder(_ savedOrder: [String], configuredOrder: [String],
                        currentBarOrder: [String], dragOrder: [String]) -> [String] {
    let currentIDs = Set(currentBarOrder)
    let reordered = dragOrder.filter(currentIDs.contains)
    let participantIDs = Set(reordered)
    guard reordered != currentBarOrder.filter(participantIDs.contains) else { return savedOrder }
    // Materialize defaults before moving bar slots so inferred More and Hidden order stays in place too.
    let completeOrder = mergingTrayOrder(savedOrder, with: configuredOrder)
    return mergingTrayOrder(completeOrder, with: reordered)
}

/// Restore defaults for known items while keeping preferences from other Cala versions.
func resettingTrayItems(_ knownIDs: Set<String>, layout: [String: String], order: [String])
    -> (layout: [String: String], order: [String]) {
    (layout.filter { !knownIDs.contains($0.key) }, order.filter { !knownIDs.contains($0) })
}

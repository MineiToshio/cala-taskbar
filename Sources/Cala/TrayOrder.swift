/// Where a tray item lives: visible in the bar, in the overflow panel, or hidden.
enum TrayPlace: String, CaseIterable, Identifiable {
    case bar, more, hidden
    var id: String { rawValue }
}

struct TrayItemGroup: Identifiable {
    let place: TrayPlace
    var items: [String]
    var id: TrayPlace { place }
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

/// Reorder the slots represented in Settings, keeping saved entries for items this version cannot display.
func mergingTrayOrder(_ savedOrder: [String], with visibleOrder: [String]) -> [String] {
    let visibleIDs = Set(visibleOrder)
    var remaining = visibleOrder.makeIterator()
    var merged = savedOrder.compactMap { id in
        visibleIDs.contains(id) ? remaining.next() : id
    }
    merged.append(contentsOf: remaining)
    return merged
}

/// Restore defaults for known items while keeping preferences from other Cala versions.
func resettingTrayItems(_ knownIDs: Set<String>, layout: [String: String], order: [String])
    -> (layout: [String: String], order: [String]) {
    (layout.filter { !knownIDs.contains($0.key) }, order.filter { !knownIDs.contains($0) })
}

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

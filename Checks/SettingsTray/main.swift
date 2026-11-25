func expect(_ name: String, _ actual: [String], _ expected: [String]) {
    guard actual == expected else { fatalError("FAIL \(name): \(actual) != \(expected)") }
    print("PASS \(name)")
}

expect("Moving Wi-Fi preserves the relative positions of unknown saved IDs",
       mergingTrayOrder(["future-first", "wifi", "future-middle", "volume", "future-last"], with: ["volume", "wifi"]),
       ["future-first", "volume", "future-middle", "wifi", "future-last"])

expect("New visible items are saved without dropping unknown entries",
       mergingTrayOrder(["wifi", "future", "volume"], with: ["disk", "volume", "wifi"]),
       ["disk", "future", "volume", "wifi"])

let reset = resettingTrayItems(["disk", "wifi"], layout: ["wifi": "hidden", "disk": "bar", "future-a": "more",
                                                       "future-b": "future-placement", "layout-only": "hidden"],
                               order: ["future-b", "disk", "future-a", "wifi", "order-only"])
guard reset.layout == ["future-a": "more", "future-b": "future-placement", "layout-only": "hidden"] else {
    fatalError("FAIL resetting tray items should only clear known placements")
}
expect("Resetting known items preserves unknown placements and their saved order",
       reset.order, ["future-b", "future-a", "order-only"])

let groups = [TrayItemGroup(place: .bar, items: ["wifi", "volume", "disk"]),
              TrayItemGroup(place: .more, items: ["keyboard"]),
              TrayItemGroup(place: .hidden, items: [])]
let savedOrder = ["future-first", "wifi", "volume", "future-middle", "disk", "keyboard", "future-last"]
let savedLayout = ["keyboard": "more", "future-first": "future-placement"]

func expectMove(_ name: String, item: String, to place: TrayPlace, at index: Int,
                order: [String], layout: [String: String]) {
    guard let result = movingTrayItem(item, to: place, at: index, in: groups,
                                     savedLayout: savedLayout, savedOrder: savedOrder),
          result.layout == layout else { fatalError("FAIL \(name): unexpected placement") }
    expect(name, result.order, order)
}

expectMove("Drops can insert at index zero of another group", item: "wifi", to: .more, at: 0,
           order: ["future-first", "volume", "disk", "future-middle", "wifi", "keyboard", "future-last"],
           layout: ["wifi": "more", "keyboard": "more", "future-first": "future-placement"])
expectMove("Drops can insert into an empty group", item: "volume", to: .hidden, at: 0,
           order: ["future-first", "wifi", "disk", "future-middle", "keyboard", "volume", "future-last"],
           layout: ["volume": "hidden", "keyboard": "more", "future-first": "future-placement"])
expectMove("Moving the sole item out of a group changes its placement even if the order stays the same",
           item: "keyboard", to: .bar, at: 3, order: savedOrder,
           layout: ["keyboard": "bar", "future-first": "future-placement"])
expectMove("Within a group, the insertion index accounts for removing the dragged row",
           item: "wifi", to: .bar, at: 2,
           order: ["future-first", "volume", "wifi", "future-middle", "disk", "keyboard", "future-last"],
           layout: savedLayout)

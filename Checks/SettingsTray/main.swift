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

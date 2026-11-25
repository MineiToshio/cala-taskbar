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

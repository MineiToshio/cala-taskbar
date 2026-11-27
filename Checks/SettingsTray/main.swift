import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

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
let rows = groups.flatMap(\.rows)
guard rows == [.heading(.bar), .item("wifi"), .item("volume"), .item("disk"),
               .heading(.more), .item("keyboard"), .heading(.hidden), .empty(.hidden)] else {
    fatalError("FAIL native list rows include headers and a placeholder only for the empty group")
}

func expectTarget(_ name: String, source: Int, destination: Int, place: TrayPlace, index: Int) {
    guard let target = trayMoveTarget(in: rows, source: source, destination: destination),
          target.place == place, target.index == index else { fatalError("FAIL \(name): unexpected destination") }
    print("PASS \(name)")
}

expectTarget("Native drop below a group header targets its first slot",
             source: 1, destination: 5, place: .more, index: 0)
expectTarget("Native drop above the first header targets the first slot in the bar",
             source: 5, destination: 0, place: .bar, index: 0)
expectTarget("Native drop below an empty group's header targets its first slot",
             source: 2, destination: 7, place: .hidden, index: 0)
expectTarget("Native drop below the empty placeholder targets the same slot",
             source: 2, destination: 8, place: .hidden, index: 0)
expectTarget("Native drop before the next header targets the end of the preceding group",
             source: 5, destination: 4, place: .bar, index: 3)
expectTarget("Native upward move uses the insertion gap ahead of the target item",
             source: 3, destination: 1, place: .bar, index: 0)
expectTarget("Native downward move reports the gap before removing the source",
             source: 1, destination: 3, place: .bar, index: 2)

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

expect("Bar menu offers More and Hide", TrayPlace.bar.menuDestinations.map(\.rawValue), ["more", "hidden"])
expect("More menu offers bar and Hide", TrayPlace.more.menuDestinations.map(\.rawValue), ["bar", "hidden"])
expect("Hidden items have no placement menu", TrayPlace.hidden.menuDestinations.map(\.rawValue), [])

let frames = [
    "wifi": CGRect(x: 100, y: 0, width: 30, height: 48),
    "usage": CGRect(x: 130, y: 0, width: 64, height: 48),
    "disk": CGRect(x: 194, y: 0, width: 26, height: 48),
    "more-button": CGRect(x: 70, y: 0, width: 30, height: 48),
    "app": CGRect(x: 0, y: 0, width: 46, height: 48),
]
let barOrder = ["wifi", "usage", "unavailable", "disk"]
guard let drag = TrayBarDrag(id: "usage", order: barOrder, frames: frames),
      TrayBarDrag(id: "unavailable", order: barOrder, frames: frames) == nil,
      TrayBarDrag(id: "more-button", order: barOrder, frames: frames) == nil else {
    fatalError("FAIL only visible, configurable bar items can start a tray drag")
}
expect("Dragging starts from the visible bar order", drag.order(at: 162), ["wifi", "usage", "disk"])
expect("A wide tray icon slides left after crossing its neighbor", drag.order(at: 146), ["usage", "wifi", "disk"])
expect("A wide tray icon slides right after crossing its neighbor", drag.order(at: 176), ["wifi", "disk", "usage"])
expect("Reversing the drag restores the original order", drag.order(at: 162), ["wifi", "usage", "disk"])
expect("Moving over the app or More area only changes order within the bar tray",
       drag.order(at: 10), ["usage", "wifi", "disk"])
guard drag.restingCenter(in: drag.order(at: 146)) == 132,
      drag.restingCenter(in: drag.order(at: 176)) == 188 else {
    fatalError("FAIL the lifted icon should settle in the new slot with mixed cell widths")
}
print("PASS Lifted icon settles in its new slot with mixed cell widths")

let complete = ["more-a", "wifi", "hidden", "usage", "unavailable", "more-b", "disk"]
expect("Saving a drag preserves More, Hidden, unavailable and unknown slots",
       savingTrayBarOrder(complete + ["future"], configuredOrder: complete,
                          currentBarOrder: ["wifi", "usage", "disk"], dragOrder: drag.order(at: 176)),
       ["more-a", "wifi", "hidden", "disk", "unavailable", "more-b", "usage", "future"])
expect("Saving the first drag materializes the inferred tray order before reordering",
       savingTrayBarOrder([], configuredOrder: complete,
                          currentBarOrder: ["wifi", "usage", "disk"], dragOrder: drag.order(at: 176)),
       ["more-a", "wifi", "hidden", "disk", "unavailable", "more-b", "usage"])

let beforeDiskDisappears = ["wifi", "disk", "volume"]
let diskDrag = TrayBarDrag(id: "wifi", order: beforeDiskDisappears, frames: [
    "wifi": CGRect(x: 100, y: 0, width: 30, height: 48),
    "disk": CGRect(x: 130, y: 0, width: 30, height: 48),
    "volume": CGRect(x: 160, y: 0, width: 30, height: 48),
])!
expect("Disk keeps its saved middle slot when Wi-Fi is dragged to the end and Disk disappears",
       savingTrayBarOrder(beforeDiskDisappears, configuredOrder: beforeDiskDisappears,
                          currentBarOrder: ["wifi", "volume"], dragOrder: diskDrag.order(at: 180)),
       ["volume", "disk", "wifi"])

import Foundation

let primary = MenuBarGeometry.Screen(
    frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
    menuBarHeight: 38,
    unobscuredTopAreas: [
        CGRect(x: 0, y: 944, width: 690, height: 38),
        CGRect(x: 822, y: 944, width: 690, height: 38),
    ]
)
let left = MenuBarGeometry.Screen(
    frame: CGRect(x: -3840, y: -98, width: 3840, height: 1080),
    menuBarHeight: 24,
    unobscuredTopAreas: []
)
let above = MenuBarGeometry.Screen(
    frame: CGRect(x: 0, y: 982, width: 1920, height: 1080),
    menuBarHeight: 0,
    unobscuredTopAreas: []
)
let below = MenuBarGeometry.Screen(
    frame: CGRect(x: 0, y: -1080, width: 1920, height: 1080),
    menuBarHeight: 24,
    unobscuredTopAreas: []
)
let geometry = MenuBarGeometry(screens: [primary, left, above, below], fallbackHeight: 24)

let cases: [(point: CGPoint, visible: Bool, name: String)] = [
    (CGPoint(x: -309, y: 3), true, "Shottr on the left display"),
    (CGPoint(x: -346, y: 3), true, "Karabiner on the left display"),
    (CGPoint(x: -309, y: -1), false, "just above the left display"),
    (CGPoint(x: -309, y: 23), true, "last point of the left menu bar"),
    (CGPoint(x: -309, y: 24), false, "bottom edge of the left menu bar excluded"),
    (CGPoint(x: -309, y: 40), false, "below the 24-point left menu bar"),
    (CGPoint(x: -5000, y: 3), false, "hidden to the left of all displays"),
    (CGPoint(x: 200, y: 3), true, "left of the notch"),
    (CGPoint(x: 1200, y: 3), true, "primary menu bar"),
    (CGPoint(x: 1200, y: 37), true, "right of the notch in the taller menu bar"),
    (CGPoint(x: 756, y: 3), false, "under the notch"),
    (CGPoint(x: 1200, y: 500), false, "primary display below its menu bar"),
    (CGPoint(x: 1200, y: -1077), true, "auto-hidden menu bar on display above the primary"),
    (CGPoint(x: 1200, y: -1056), false, "below the fallback menu bar height"),
    (CGPoint(x: 1700, y: 3), false, "in the upper display’s horizontal range but outside its menu bar"),
    (CGPoint(x: 1200, y: 981), false, "just above the lower display"),
    (CGPoint(x: 1200, y: 985), true, "menu bar on display below the primary"),
    (CGPoint(x: -3840, y: 0), true, "left and top edges included"),
    (CGPoint(x: 1512, y: 3), false, "right edge excluded"),
]

var failures = 0
for test in cases {
    if geometry.contains(test.point) != test.visible {
        print("FAIL \(test.name)")
        failures += 1
    }
}
if failures > 0 { exit(1) }
print("PASS menu bar geometry (\(cases.count) cases)")

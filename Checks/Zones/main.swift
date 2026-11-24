import Foundation
import CoreGraphics

var failures = 0
var passes = 0

func expect(_ id: String, _ ok: Bool, _ note: @autoclosure () -> String = "") {
    if ok {
        passes += 1
        print("PASS \(id)")
    } else {
        failures += 1
        print("FAIL \(id) \(note())")
    }
}

func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> ZoneRect {
    ZoneRect(x: x, y: y, w: w, h: h)
}

func near(_ a: ZoneRect, _ b: ZoneRect) -> Bool {
    zip([a.x, a.y, a.w, a.h], [b.x, b.y, b.w, b.h]).allSatisfy { abs($0 - $1) < 1e-9 }
}

func near(_ a: CGRect, _ b: CGRect) -> Bool {
    zip([a.minX, a.minY, a.width, a.height], [b.minX, b.minY, b.width, b.height])
        .allSatisfy { abs($0 - $1) < 0.5 }
}

// MARK: Geometry

let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)
let above = CGRect(x: 0, y: 900, width: 1920, height: 1080)
let left = CGRect(x: -2560, y: -300, width: 2560, height: 1440)
let below = CGRect(x: 0, y: -1920, width: 1080, height: 1920)
let right = CGRect(x: 1440, y: 70, width: 3840, height: 2160)
let visiblePrimary = CGRect(x: 0, y: 0, width: 1440, height: 875)
let barVisible = CGRect(x: 0, y: 0, width: 1920, height: 1055)
let cases: [(String, CGRect, Int, Int, CGRect)] = [
    ("1440×900, menu", visiblePrimary, 0, 875, CGRect(x: 360, y: 437.5, width: 720, height: 218.75)),
    ("1920×1080, bar and menu", CGRect(x: 0, y: 48, width: 1920, height: 1007), 0, 1055,
     CGRect(x: 480, y: 551.5, width: 960, height: 251.75)),
    ("2560×1440, left display with Dock", CGRect(x: -2480, y: -300, width: 2480, height: 1440), -2480, 1140,
     CGRect(x: -1860, y: 420, width: 1240, height: 360)),
    ("3840×2160, right display", right, 1440, 2230, CGRect(x: 2400, y: 1150, width: 1920, height: 540)),
    ("1080×1920, portrait below", below, 0, 0, CGRect(x: 270, y: -960, width: 540, height: 480)),
    ("1920×1080, display above", above, 0, 1980, CGRect(x: 480, y: 1440, width: 960, height: 270)),
    ("3024×1964, notch", CGRect(x: 0, y: 0, width: 3024, height: 1926), 0, 1926,
     CGRect(x: 756, y: 963, width: 1512, height: 481.5))
]
let sample = rect(0.25, 0.25, 0.5, 0.25)
for (name, usable, x, maxY, expected) in cases {
    let frame = ZoneGeometry.frame(for: sample, in: usable)
    let fraction = ZoneGeometry.fraction(for: frame, in: usable)
    let ax = ZoneGeometry.axRect(fromAppKit: usable, primaryHeight: primary.height)
    let point = ZoneGeometry.appKitPoint(fromCG: ax.origin, primaryHeight: primary.height)
    expect("Geometry \(name)", near(frame, expected) && near(fraction, sample))
    expect("AX/CG \(name)", ax.origin == CGPoint(x: x, y: 900 - maxY)
           && ZoneGeometry.appKitRect(fromAX: ax, primaryHeight: primary.height) == usable
           && point == CGPoint(x: x, y: maxY)
           && ZoneGeometry.cgPoint(fromAppKit: point, primaryHeight: primary.height) == ax.origin)
}

let barScreen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
expect("Usable frame reserves the visible bar only",
       ZoneGeometry.usableRect(frame: barScreen, visibleFrame: barVisible, barHeight: 48, barReserves: true) == cases[1].1
       && ZoneGeometry.usableRect(frame: barScreen, visibleFrame: barVisible, barHeight: 48, barReserves: false) == barVisible)
let dockVisible = CGRect(x: -2480, y: -230, width: 2480, height: 1370)
expect("Bar strip does not subtract space already excluded by the Dock",
       ZoneGeometry.usableRect(frame: left, visibleFrame: dockVisible, barHeight: 48, barReserves: true) == dockVisible)
expect("Screen lookup is half-open and falls back to nearest",
       ZoneGeometry.screenIndex(containing: CGPoint(x: 0, y: 50), frames: [left, primary]) == 1
       && ZoneGeometry.screenIndex(containing: CGPoint(x: 3800, y: 0), frames: [primary, right]) == 1
       && ZoneGeometry.screenIndex(containing: .zero, frames: []) == nil)

let leftBelowPortrait = CGRect(x: -1037.5, y: -1832.25, width: 1011.5, height: 1779.75)
let portraitZone = rect(0.125, 0.375, 0.625, 0.5)
let portraitFrame = ZoneGeometry.frame(for: portraitZone, in: leftBelowPortrait)
let portraitAX = ZoneGeometry.axRect(fromAppKit: portraitFrame, primaryHeight: primary.height)
expect("Window rect on a portrait display left and below the primary retains both offsets",
       near(portraitAX, CGRect(x: -911.0625, y: 1619.90625, width: 632.1875, height: 889.875))
       && ZoneGeometry.appKitRect(fromAX: portraitAX, primaryHeight: primary.height) == portraitFrame
       && near(ZoneGeometry.fraction(for: portraitFrame, in: leftBelowPortrait), portraitZone))
expect("Vertical screen seams go to the display whose minimum edge contains the point",
       ZoneGeometry.screenIndex(containing: CGPoint(x: 30, y: 0), frames: [below, primary]) == 1
       && ZoneGeometry.screenIndex(containing: CGPoint(x: 30, y: 900), frames: [primary, above]) == 1)

let usable = CGRect(x: 0, y: 0, width: 1000, height: 800)
let columns = ZoneTemplates.zones("two-columns").enumerated().map { Zone(rect: $0.element, seq: $0.offset) }
let a = ZoneGeometry.frame(for: columns[0].rect, in: usable)
let b = ZoneGeometry.frame(for: columns[1].rect, in: usable)
let gapA = ZoneGeometry.applyGap(a, gap: 8, usable: usable)
let gapB = ZoneGeometry.applyGap(b, gap: 8, usable: usable)
expect("Gap uses full screen margins and half insets on interior edges",
       gapA == CGRect(x: 8, y: 8, width: 488, height: 784) && gapB.minX - gapA.maxX == 8 && gapB.maxX == 992)
let small = CGRect(x: 0, y: 0, width: 46, height: 38)
let gappedSmall = ZoneGeometry.applyGap(small, gap: 12, usable: usable)
expect("Gap shrinks proportionally to preserve available size",
       gappedSmall == CGRect(x: 4, y: 0, width: 40, height: 38) && ZoneGeometry.applyGap(a, gap: 0, usable: usable) == a)

// MARK: Picking and spanning

let large = Zone(rect: rect(0, 0, 1, 1), seq: 10)
let older = Zone(rect: rect(0.2, 0.2, 0.4, 0.4), seq: 4)
let newer = Zone(rect: rect(0.3, 0.3, 0.4, 0.4), seq: 5)
let nestedPoint = CGPoint(x: 400, y: 450)
expect("Smallest overlapping area wins", ZonePicking.chosen(nestedPoint, zones: [older, large], usable: usable) == older)
let target = ZonePicking.target(point: nestedPoint, zones: [large, newer, older], usable: usable, gap: 8, spanAnchor: nil)
expect("Equal area picks latest and returns other hits for soft tint", target?.chosen == [newer.id] && target?.soft == [large.id, older.id])
expect("Visual gaps still pick the raw zone",
       ZonePicking.chosen(CGPoint(x: 499, y: 400), zones: columns, usable: usable) == columns[0])
expect("Outside all zones returns nil",
       ZonePicking.target(point: CGPoint(x: -1, y: 0), zones: columns, usable: usable, gap: 8, spanAnchor: nil) == nil)
let across = ZonePicking.span(anchor: columns[0], current: columns[1], zones: columns)
expect("Two columns span the full width", across.rect == large.rect && across.members == Set(columns.map(\.id)))
let quarters = ZoneTemplates.zones("grid-2x2").enumerated().map { Zone(rect: $0.element, seq: $0.offset) }
let diagonal = ZonePicking.span(anchor: quarters[0], current: quarters[3], zones: quarters)
let same = ZonePicking.span(anchor: quarters[0], current: quarters[0], zones: quarters)
let top = ZonePicking.span(anchor: quarters[0], current: [quarters[1]], zones: quarters + [large])
expect("Diagonal includes four quarters; spans exclude zones outside the bound",
       diagonal.rect == large.rect && diagonal.members == Set(quarters.map(\.id))
       && same.rect == quarters[0].rect && same.members == [quarters[0].id]
       && top.rect == rect(0, 0, 1, 0.5) && top.members == [quarters[0].id, quarters[1].id])
let union = ZonePicking.target(point: CGPoint(x: 700, y: 400), zones: columns, usable: usable, gap: 8, spanAnchor: columns[0].id)
expect("Span applies the gap once", union?.frame == CGRect(x: 8, y: 8, width: 984, height: 784))

expect("Picking includes minimum edges and excludes maximum edges on both axes",
       ZonePicking.zonesUnder(CGPoint(x: 0, y: 0), zones: columns, usable: usable) == [columns[0]]
       && ZonePicking.zonesUnder(CGPoint(x: 500, y: 400), zones: quarters, usable: usable) == [quarters[1]]
       && ZonePicking.zonesUnder(CGPoint(x: 500.0.nextDown, y: 400.0.nextDown), zones: quarters, usable: usable) == [quarters[2]]
       && ZonePicking.zonesUnder(CGPoint(x: 1000, y: 800), zones: columns, usable: usable).isEmpty)
let fractionalLeft = Zone(rect: rect(0.1, 0, 0.2, 1), seq: 1)
let fractionalRight = Zone(rect: rect(fractionalLeft.rect.maxX, 0, 0.2, 1), seq: 2)
let joinX = fractionalRight.rect.x * usable.width
expect("Fractional shared edge has no floating-point crack",
       ZonePicking.zonesUnder(CGPoint(x: joinX.nextDown, y: 400), zones: [fractionalLeft, fractionalRight], usable: usable) == [fractionalLeft]
       && ZonePicking.zonesUnder(CGPoint(x: joinX, y: 400), zones: [fractionalLeft, fractionalRight], usable: usable) == [fractionalRight])
let epsilonTie = Zone(rect: rect(0.2, 0.2, 0.400002, 0.4), seq: 12)
let largerOutsideEpsilon = Zone(rect: rect(0.2, 0.2, 0.400004, 0.4), seq: 13)
let closeHits = [older, epsilonTie, largerOutsideEpsilon]
expect("Area ties compare with the true minimum without chaining epsilon across candidates",
       ZonePicking.chosen(nestedPoint, zones: closeHits, usable: usable) == epsilonTie
       && ZonePicking.chosen(nestedPoint, zones: closeHits.reversed(), usable: usable) == epsilonTie
       && ZonePicking.target(point: nestedPoint, zones: closeHits, usable: usable, gap: 0, spanAnchor: nil)?.soft
           == [older.id, largerOutsideEpsilon.id])

let islands = [Zone(rect: rect(0, 0, 0.25, 1)), Zone(rect: rect(0.75, 0, 0.25, 1))]
let bridge = Zone(rect: rect(0.25, 0, 0.5, 1))
let acrossVoid = ZonePicking.span(anchor: islands[0], current: islands[1], zones: islands)
let acrossBridge = ZonePicking.span(anchor: islands[0], current: islands[1], zones: islands + [bridge])
expect("Disconnected zones fall back to the current zone; a bridge enables the span",
       acrossVoid.rect == islands[1].rect && acrossVoid.members == [islands[1].id]
       && acrossBridge.rect == large.rect && acrossBridge.members == Set((islands + [bridge]).map(\.id)))
let cornerOnly = ZonePicking.span(anchor: quarters[0], current: quarters[3], zones: [quarters[0], quarters[3]])
expect("Corner-only contact does not connect zones", cornerOnly.members == [quarters[3].id])
let overlapping = Zone(rect: rect(0.2, 0.125, 0.4, 0.75), seq: 1)
let overlappingTarget = ZonePicking.target(point: CGPoint(x: 550, y: 400), zones: [islands[0], overlapping, large],
                                           usable: usable, gap: 8, spanAnchor: islands[0].id)
expect("Overlapping zones can span; the bounding rect gets one gap and retains other cursor hits",
       overlappingTarget.map { near($0.frame, CGRect(x: 8, y: 8, width: 588, height: 784)) } == true
       && overlappingTarget?.chosen == [islands[0].id, overlapping.id]
       && overlappingTarget?.soft == [islands[0].id, overlapping.id, large.id])
let nestedSpan = ZonePicking.span(anchor: large, current: large, zones: [older, large])
expect("Spanning the same zone keeps its exact rect and excludes nested zones",
       nestedSpan.rect == large.rect && nestedSpan.members == [large.id])
expect("Releasing outside all zones during a span has no drop target",
       ZonePicking.target(point: CGPoint(x: 500, y: 400), zones: islands, usable: usable, gap: 8, spanAnchor: islands[0].id) == nil)

// MARK: Editor snapping

let editable = rect(0.15, 0.15, 0.2, 0.2)
let other = rect(0.4, 0.25, 0.2, 0.2)
let threshold = (x: 0.01, y: 0.01)
let minimum = (w: 0.08, h: 0.1)
let editArea = CGRect(x: 20, y: 30, width: 1000, height: 800)
let whole = Zone(rect: rect(0, 0, 1, 1), seq: 2)
let smaller = Zone(rect: editable, seq: 1)
let smallFrame = ZoneGeometry.frame(for: editable, in: editArea)
func editorHit(_ x: CGFloat, _ y: CGFloat) -> ZonePicking.EditorHit? {
    ZonePicking.editorHit(at: CGPoint(x: x, y: y), zones: [whole, smaller], usable: editArea)
}
let editorHandles: [(CGFloat, CGFloat, ZoneSnapping.Edges)] = [
    (smallFrame.minX + 10, smallFrame.maxY - 10, [.left, .top]),
    (smallFrame.midX, smallFrame.maxY - 8, .top),
    (smallFrame.maxX - 10, smallFrame.maxY - 10, [.right, .top]),
    (smallFrame.minX + 8, smallFrame.midY, .left),
    (smallFrame.maxX - 8, smallFrame.midY, .right),
    (smallFrame.minX + 10, smallFrame.minY + 10, [.left, .bottom]),
    (smallFrame.midX, smallFrame.minY + 8, .bottom),
    (smallFrame.maxX - 10, smallFrame.minY + 10, [.right, .bottom])
]
expect("Editor picks the smallest overlapping zone at all eight handles",
       editorHandles.allSatisfy { x, y, edges in
           let hit = editorHit(x, y)
           return hit?.zone.id == smaller.id && hit?.edges == edges
       })
let bodyHit = editorHit(smallFrame.minX + 9, smallFrame.midY)
expect("Editor body moves the smallest zone outside its edge band",
       bodyHit?.zone.id == smaller.id && bodyHit?.edges.isEmpty == true)
expect("Editor hits the exposed lower right corner and ignores excluded space",
       editorHit(editArea.maxX, editArea.minY)?.edges == [.right, .bottom]
       && editorHit(editArea.maxX + 1, editArea.midY) == nil)
let crossing = Zone(rect: rect(0.32, 0.21, 0.08, 0.08), seq: 3)
let overlapZones = [whole, smaller, crossing]
let visibleGrip = CGPoint(x: smallFrame.maxX + 6, y: smallFrame.midY)
let beyondGrip = CGPoint(x: smallFrame.maxX + 7, y: smallFrame.midY)
expect("Selected handle beats the zone underneath its outer half, within six points only",
       ZonePicking.editorHit(at: visibleGrip, zones: overlapZones, usable: editArea)?.zone.id == crossing.id
       && ZonePicking.editorHit(at: visibleGrip, zones: overlapZones, usable: editArea, selectedID: smaller.id)?.edges == .right
       && ZonePicking.editorHit(at: visibleGrip, zones: overlapZones, usable: editArea, selectedID: smaller.id)?.zone.id == smaller.id
       && ZonePicking.editorHit(at: beyondGrip, zones: overlapZones, usable: editArea, selectedID: smaller.id)?.zone.id == crossing.id)
let offCanvasGrip = CGPoint(x: editArea.minX - 5, y: editArea.maxY + 5)
expect("Selected screen-corner handle works from its part outside the usable area",
       ZonePicking.editorHit(at: offCanvasGrip, zones: [whole], usable: editArea, selectedID: whole.id)?.edges == [.left, .top]
       && ZonePicking.editorHit(at: offCanvasGrip, zones: [whole], usable: editArea) == nil)
let (offsetResize, _) = ZoneSnapping.resize(editable, edges: [.left, .bottom], by: (0.02, 0.04), others: [],
    grid: false, snapping: false, threshold: threshold, minSize: minimum)
expect("Handle-band resize applies pointer delta from the original edge",
       near(offsetResize, rect(0.17, 0.15, 0.18, 0.24)))

let (moved, moveGuides) = ZoneSnapping.move(editable, by: (0.044, 0.346), others: [other],
                                          grid: false, snapping: true, threshold: threshold)
expect("Move snaps trailing zone edge and leading edge to screen center",
       near(moved, rect(0.2, 0.5, 0.2, 0.2)) && moveGuides == [.init(axis: .x, position: 0.4), .init(axis: .y, position: 0.5)])
let (edge, edgeGuides) = ZoneSnapping.move(editable, by: (-0.145, 0.645), others: [],
                                          grid: false, snapping: true, threshold: threshold)
expect("Move snaps to outside screen edges",
       near(edge, rect(0, 0.8, 0.2, 0.2)) && edgeGuides == [.init(axis: .x, position: 0), .init(axis: .y, position: 1)])
let (option, optionGuides) = ZoneSnapping.move(editable, by: (0.044, 0.346), others: [other],
                                              grid: true, snapping: false, threshold: threshold)
expect("Option disables all snapping and guides", near(option, rect(0.194, 0.496, 0.2, 0.2)) && optionGuides.isEmpty)
let (grid, gridGuides) = ZoneSnapping.move(editable, by: (0.097, 0.18), others: [],
                                          grid: true, snapping: true, threshold: threshold)
expect("12-division grid snaps at 3/12 and 4/12",
       near(grid, rect(3.0 / 12, 4.0 / 12, 0.2, 0.2)) && gridGuides.count == 2
       && ZoneSnapping.snap(0.47, to: [0.5], threshold: 0.01) == nil)
let (clamped, clampGuides) = ZoneSnapping.move(editable, by: (-2, 2), others: [],
                                               grid: true, snapping: false, threshold: threshold)
expect("Move stays on screen even with Option", near(clamped, rect(0, 0.8, 0.2, 0.2)) && clampGuides.isEmpty)
let (resized, resizeGuides) = ZoneSnapping.resize(editable, edges: [.right, .bottom], to: (0.396, 0.503),
                                                 others: [other], grid: false, snapping: true,
                                                 threshold: threshold, minSize: minimum)
expect("Corner resize snaps both axes with opposite edges anchored",
       near(resized, rect(0.15, 0.15, 0.25, 0.35))
       && resizeGuides == [.init(axis: .x, position: 0.4), .init(axis: .y, position: 0.5)])
let (limited, limitedGuides) = ZoneSnapping.resize(editable, edges: [.left, .bottom], to: (0.6, 1.1),
                                                   others: [], grid: false, snapping: true,
                                                   threshold: threshold, minSize: minimum)
expect("Resize enforces minimum size and screen bounds without false guides",
       near(limited, rect(0.27, 0.15, 0.08, 0.85)) && limitedGuides.isEmpty)
let (drawn, drawGuides) = ZoneSnapping.draw(from: (0.799, 0.75), to: (-0.5, 0.249), others: [],
                                           grid: true, snapping: true, threshold: threshold, minSize: minimum)
expect("Reverse draw normalizes, clamps, and reports snap guides",
       near(drawn, rect(0, 0.25, 0.799, 0.5)) && drawGuides == [.init(axis: .y, position: 0.75), .init(axis: .y, position: 0.25)])
let (shortDraw, _) = ZoneSnapping.draw(from: (0.99, 0.99), to: (1, 1), others: [], grid: false, snapping: false,
                                       threshold: threshold, minSize: minimum)
expect("Draw enforces minimum size at screen edges", near(shortDraw, rect(0.92, 0.9, 0.08, 0.1)))

expect("Nearest snap wins independent of candidate order, including at the threshold",
       ZoneSnapping.snap(0.497, to: [0.49, 0.5], threshold: 0.01) == 0.5
       && ZoneSnapping.snap(0.497, to: [0.5, 0.49], threshold: 0.01) == 0.5
       && ZoneSnapping.snap(0.51, to: [0.5], threshold: 0.01) == 0.5
       && ZoneSnapping.snap(0.51.nextUp, to: [0.5], threshold: 0.01) == nil)
let (nearestMove, nearestMoveGuides) = ZoneSnapping.move(editable, by: (0, 0),
    others: [rect(0.144, 0.8, 0.208, 0.1)], grid: false, snapping: true, threshold: threshold)
expect("Move chooses the closer trailing-edge guide over the leading-edge candidate",
       near(nearestMove, rect(0.152, 0.15, 0.2, 0.2)) && nearestMoveGuides == [.init(axis: .x, position: 0.352)])
let gridPositions = ZoneSnapping.candidates(others: [], grid: true).xs
expect("Grid uses twelve divisions with exact endpoints and snaps near each line",
       gridPositions == (0...12).map { Double($0) / 12 }
       && gridPositions.allSatisfy { ZoneSnapping.snap($0 + ($0 == 1 ? -0.001 : 0.001), to: gridPositions, threshold: 0.002) == $0 }
       && ZoneSnapping.snap(11.5 / 12, to: gridPositions, threshold: 0.01) == nil)

let resizeCases: [(String, ZoneSnapping.Edges, ZoneRect)] = [
    ("left", .left, rect(0, 0.15, 0.35, 0.2)),
    ("top", .top, rect(0.15, 0, 0.2, 0.35)),
    ("right", .right, rect(0.15, 0.15, 0.85, 0.2)),
    ("bottom", .bottom, rect(0.15, 0.15, 0.2, 0.85)),
    ("top-left", [.top, .left], rect(0, 0, 0.35, 0.35)),
    ("top-right", [.top, .right], rect(0.15, 0, 0.85, 0.35)),
    ("bottom-left", [.bottom, .left], rect(0, 0.15, 0.35, 0.85)),
    ("bottom-right", [.bottom, .right], rect(0.15, 0.15, 0.85, 0.85))
]
for (name, edges, expected) in resizeCases {
    let point = (edges.contains(.left) ? -2.0 : 2.0, edges.contains(.top) ? -2.0 : 2.0)
    let (result, guides) = ZoneSnapping.resize(editable, edges: edges, to: point, others: [other],
        grid: true, snapping: false, threshold: threshold, minSize: minimum)
    expect("Resize \(name) clamps to screen and anchors the opposite edge with Option",
           near(result, expected) && guides.isEmpty && result.maxX <= 1 && result.maxY <= 1)
}
let (oldNarrow, _) = ZoneSnapping.resize(rect(0.25, 0.25, 0.05, 0.05), edges: .left, to: (0, 0),
    others: [], grid: false, snapping: false, threshold: threshold, minSize: minimum)
expect("Resizing a narrow stored zone anchors its original opposite edge and preserves the untouched axis",
       near(oldNarrow, rect(0, 0.25, 0.3, 0.05)))
let (minimumGuide, minGuides) = ZoneSnapping.resize(rect(0.2, 0.2, 0.2, 0.2), edges: .right, to: (0.3, 0),
    others: [rect(0.3, 0, 0.2, 0.2)], grid: false, snapping: true, threshold: threshold, minSize: (0.1, 0.1))
expect("Resize accepts a guide exactly one minimum width from the anchor",
       near(minimumGuide, rect(0.2, 0.2, 0.1, 0.2)) && minGuides == [.init(axis: .x, position: 0.3)])

// MARK: Templates, repair and restore

let seeded = ZoneTemplates.seedState()
let newGrid = ZoneTemplates.makeLayout("grid-2x2", name: "Cuadrícula")
expect("Template names share one English and Spanish table",
       ZoneTemplates.ids.allSatisfy { ZoneTemplates.name($0) != ZoneTemplates.name($0, localizedWith: { _, spanish in spanish }) }
       && ZoneTemplates.name("grid-2x2", localizedWith: { _, spanish in spanish }) == "Cuadrícula 2 × 2")
expect("A new template layout gets independent IDs, a localized name and complete creation order",
       newGrid.name == "Cuadrícula" && newGrid.template == "grid-2x2" && newGrid.nextSeq == 4
       && newGrid.zones.map(\.rect) == ZoneTemplates.zones("grid-2x2")
       && newGrid.zones.map(\.seq) == [0, 1, 2, 3]
       && Set(newGrid.zones.map(\.id)).isDisjoint(with: seeded.layouts.flatMap { $0.zones.map(\.id) }))
expect("All eight editable templates seed once within 0…1",
       Set(ZoneTemplates.ids).count == 8 && seeded.layouts.map(\.template) == ZoneTemplates.ids.map(Optional.some)
       && seeded.defaultLayout == seeded.layouts.first?.id && seeded.layouts.allSatisfy { layout in
           layout.isTemplate && !layout.zones.isEmpty && layout.zones.allSatisfy {
               $0.rect.isFinite && $0.rect.x >= 0 && $0.rect.y >= 0 && $0.rect.maxX <= 1 && $0.rect.maxY <= 1
               && $0.rect.area > 0
           }
       })
expect("Seed state repair is idempotent", seeded.repaired() == seeded)
let overflow = Zone(rect: rect(-1, 0.99, 0, 4), seq: 12)
let invalid = Zone(rect: rect(.nan, 0, 1, 1), seq: 13)
let damaged = ZoneLayout(name: "Damaged", zones: [overflow, overflow, invalid])
let repaired = ZonesState(layouts: [damaged, damaged], defaultLayout: UUID(),
                          activeByDisplay: ["gone": UUID().uuidString, "off": ZonesState.off]).repaired()
expect("Repair clamps, drops nonfinite zones, deduplicates and clears dangling assignments",
       repaired.layouts.count == 1 && repaired.layouts[0].zones.count == 1
       && repaired.layouts[0].zones[0].rect == rect(0, 0, 0.05, 1) && repaired.layouts[0].nextSeq == 13
       && repaired.defaultLayout == damaged.id && repaired.activeByDisplay == ["off": ZonesState.off]
       && repaired.repaired() == repaired && ZonesState(layouts: []).repaired().layouts.count == 8)

let inverted = ZoneGeometry.clamp(rect(1.5, -0.5, -0.25, -1), minW: 0.05, minH: 0.1)
expect("Negative stored dimensions repair to the minimum within the screen",
       inverted == rect(0.95, 0, 0.05, 0.1) && inverted.area > 0)
var exhausted = ZoneLayout(name: "Sequence overflow", zones: [
    Zone(rect: older.rect, seq: Int.max), Zone(rect: older.rect, seq: Int.max)
], nextSeq: Int.max)
let appended = exhausted.addZone(older.rect)
expect("Creation sequence overflow preserves file order and allows a newest equal-area zone",
       exhausted.zones.map(\.seq) == [0, 1, 2] && exhausted.nextSeq == 3
       && ZonePicking.chosen(nestedPoint, zones: exhausted.zones, usable: usable)?.id == appended)

let original = CGRect(x: 100, y: 70, width: 300, height: 200)
let snapped = CGRect(x: 200, y: 40, width: 600, height: 800)
expect("Restore respects the 2 pt tolerance and keeps the horizontal grab point",
       ZoneRestore.isStillSnapped(current: snapped.offsetBy(dx: 2, dy: -2), snapped: snapped)
       && !ZoneRestore.isStillSnapped(current: snapped.offsetBy(dx: 2.1, dy: 0), snapped: snapped)
       && ZoneRestore.restoredFrame(current: snapped, originalSize: original.size, cursorX: 350)
           == CGRect(x: 275, y: 40, width: 300, height: 200))
let window = ZoneRestore.WindowKey(pid: 42, windowID: 24)
var records = ZoneRestore.Records()
records.recordSnap(window, originalFrameAX: original, snappedFrameAX: a)
records.recordSnap(window, originalFrameAX: a, snappedFrameAX: snapped)
let restored = records.restoreOnDrag(window, current: snapped, cursorX: 350)
expect("Re-snap keeps the original size and restore consumes the record",
       restored?.size == original.size && records.restoreOnDrag(window, current: snapped, cursorX: 350) == nil)
records.recordSnap(window, originalFrameAX: original, snappedFrameAX: snapped)
expect("Manual window resize clears the record",
       records.restoreOnDrag(window, current: snapped.insetBy(dx: 4, dy: 4), cursorX: 350) == nil
       && records.restoreOnDrag(window, current: snapped, cursorX: 350) == nil)
records.recordSnap(window, originalFrameAX: original, snappedFrameAX: snapped)
let translated = snapped.offsetBy(dx: -7, dy: 12)
let liveRestore = records.restoreOnDrag(window, current: translated, cursorX: 343, initialFrameAX: snapped)
expect("A confirmed drag restores the original size at the translated frame and keeps the grab point",
       liveRestore == CGRect(x: 268, y: 52, width: 300, height: 200))
records.recordSnap(window, originalFrameAX: original, snappedFrameAX: snapped)
expect("A drag that began after a manual move clears the old snap record",
       records.restoreOnDrag(window, current: snapped, cursorX: 350, initialFrameAX: translated) == nil
       && records.restoreOnDrag(window, current: snapped, cursorX: 350) == nil)

// MARK: Drag gesture state machine

do {
    let p = CGPoint(x: 100, y: 100)
    var m = ZoneDragMachine()
    expect("Activation: unknown config falls back to both",
           ZoneActivation(config: "nonsense") == .both && ZoneActivation(config: "shift") == .shift)
    expect("Activation: right-click and Shift permissions per mode",
           ZoneActivation.rightClick.allowsRightClick && !ZoneActivation.rightClick.allowsShift
               && ZoneActivation.shift.allowsShift && !ZoneActivation.shift.allowsRightClick
               && ZoneActivation.both.allowsShift && ZoneActivation.both.allowsRightClick)

    expect("Right click with no press passes through", !m.rightDown() && !m.rightUp())
    let g1 = m.leftDown(at: p, shift: false, command: false)
    expect("Left down asks the worker to probe a new generation", g1 == 1 && m.phase == .pressed)
    expect("Dragging while pressed asks for a move check", m.leftDragged(to: p, shift: false, command: false))
    expect("Right click before the drag is confirmed passes (text selection, sliders)", !m.rightDown() && !m.rightUp())
    expect("A stale generation never confirms", !m.confirmDrag(generation: 99) && m.phase == .pressed)
    expect("Worker confirmation starts the drag", m.confirmDrag(generation: 1) && m.phase == .dragging && !m.zonesMode)
    expect("Dragging while dragging needs no move check", !m.leftDragged(to: p, shift: false, command: false))
    expect("First right click is swallowed and turns zones mode on", m.rightDown() && m.zonesMode)
    expect("Its matching right up is swallowed too", m.rightUp())
    expect("A later right up without a swallowed down passes", !m.rightUp())
    expect("Second right click is swallowed and turns zones mode off", m.rightDown() && !m.zonesMode && m.rightUp())
    _ = m.rightDown(); _ = m.rightUp()
    let r1 = m.leftUp(at: CGPoint(x: 5, y: 6), shift: false, command: true)
    expect("Release in zones mode reports a snap with the final point and ⌘",
           r1 == ZoneDragMachine.Release(generation: 1, point: CGPoint(x: 5, y: 6), zonesMode: true, command: true)
               && m.phase == .idle && !m.zonesMode)

    _ = m.leftDown(at: p, shift: false, command: false)
    _ = m.confirmDrag(generation: m.generation)
    _ = m.rightDown()
    _ = m.rightDown()
    let r2 = m.leftUp(at: p, shift: false, command: false)
    expect("Release after the second right click does not snap", r2?.zonesMode == false)
    expect("Swallowed right up survives the left release (no orphan up)", m.rightUp())

    _ = m.leftDown(at: p, shift: false, command: false)
    let r3 = m.leftUp(at: p, shift: false, command: false)
    expect("Release before the drag was confirmed reports nothing", r3 == nil && !m.confirmDrag(generation: m.generation))

    m.activation = .shift
    _ = m.leftDown(at: p, shift: false, command: false)
    _ = m.confirmDrag(generation: m.generation)
    expect("Shift mode: right click passes through", !m.rightDown() && !m.rightUp())
    _ = m.leftDragged(to: p, shift: true, command: false)
    expect("Shift mode: on while Shift is held", m.zonesMode)
    _ = m.leftDragged(to: p, shift: false, command: false)
    expect("Shift mode: off when Shift is released", !m.zonesMode)
    _ = m.leftDragged(to: p, shift: true, command: false)
    expect("Shift mode: release with Shift held snaps", m.leftUp(at: p, shift: true, command: false)?.zonesMode == true)

    m.activation = .rightClick
    _ = m.leftDown(at: p, shift: true, command: false)
    _ = m.confirmDrag(generation: m.generation)
    expect("Right-click mode: Shift alone does nothing", !m.zonesMode)
    m.cancel(resetButtons: true)

    m.activation = .both
    _ = m.leftDown(at: p, shift: true, command: false)
    _ = m.confirmDrag(generation: m.generation)
    expect("Both: Shift held at confirmation turns zones mode on", m.zonesMode)
    _ = m.rightDown(); _ = m.rightUp()
    _ = m.leftDragged(to: p, shift: false, command: false)
    expect("Both: the right-click toggle holds after Shift is released", m.zonesMode)

    _ = m.rightDown()
    m.cancel(resetButtons: false)
    expect("Cancel goes idle, keeps the pending swallowed right up", m.phase == .idle && !m.zonesMode && m.rightUp())
    _ = m.leftDown(at: p, shift: false, command: false)
    _ = m.confirmDrag(generation: m.generation)
    _ = m.rightDown()
    m.cancel(resetButtons: true)
    expect("Cancel after a tap timeout forgets the pending right up", !m.rightUp())

    m.ignoring = true
    expect("Editor open: presses are ignored", m.leftDown(at: p, shift: false, command: false) == nil && m.phase == .idle)
    m.ignoring = false
    let g = m.leftDown(at: p, shift: false, command: false)!
    m.ignoring = true
    expect("Editor opening mid-press cancels and blocks confirmation", !m.confirmDrag(generation: g) && m.phase == .idle)
    m.ignoring = false

    // Review fixes: right-button pairing, reject, release after cancel.
    m = ZoneDragMachine()
    _ = m.leftDown(at: p, shift: false, command: false)
    _ = m.confirmDrag(generation: m.generation)
    expect("Pairing: swallowed right down", m.rightDown())
    _ = m.leftUp(at: p, shift: false, command: false)
    expect("Pairing: a stale pending up is cleared by the next unswallowed right down (its up was lost upstream)",
           !m.rightDown() && !m.rightUp())

    _ = m.leftDown(at: p, shift: false, command: false)
    expect("Pairing: right down before confirmation passes", !m.rightDown())
    _ = m.confirmDrag(generation: m.generation)
    expect("Pairing: its up after confirmation passes too", !m.rightUp())

    _ = m.rightDown()
    m.activation = .shift
    expect("Pairing: activation changed between a swallowed down and its up still swallows the up", m.rightUp())
    m.activation = .both
    m.cancel(resetButtons: true)

    _ = m.leftDown(at: p, shift: false, command: false)
    _ = m.confirmDrag(generation: m.generation)
    _ = m.rightDown()
    m.ignoring = true
    expect("Pairing: the editor opening mid-drag keeps the pending up swallowed", m.phase == .idle && m.rightUp())
    m.ignoring = false

    let gr = m.leftDown(at: p, shift: false, command: false)!
    _ = m.confirmDrag(generation: gr)
    _ = m.rightDown()
    expect("Reject: a stale generation is ignored", !m.reject(generation: gr &+ 1) && m.phase == .dragging)
    expect("Reject: drops the drag without a snap", m.reject(generation: gr) && m.phase == .idle && !m.zonesMode)
    expect("Reject: the swallowed right down still gets its up swallowed", m.rightUp())
    expect("Reject: no release is reported afterwards", m.leftUp(at: p, shift: false, command: false) == nil)

    _ = m.leftDown(at: p, shift: false, command: false)
    _ = m.confirmDrag(generation: m.generation)
    _ = m.rightDown(); _ = m.rightUp()
    m.cancel(resetButtons: false)
    let rc = m.leftUp(at: p, shift: false, command: false)
    expect("Cancel mid-drag still reports the release, without zones mode (drag-out restore can finish)",
           rc != nil && rc?.zonesMode == false)

    let usableAK = CGRect(x: 0, y: 70, width: 1440, height: 805)
    expect("Clamp: a drop in the menu bar picks the top edge of the usable area",
           ZoneWindowFit.clampPoint(CGPoint(x: 300, y: 890), into: usableAK) == CGPoint(x: 300, y: 874.5))
    expect("Clamp: a drop on the bar strip or Dock picks the bottom edge",
           ZoneWindowFit.clampPoint(CGPoint(x: 1500, y: 10), into: usableAK) == CGPoint(x: 1439.5, y: 70))
    expect("Clamp: a point inside is unchanged",
           ZoneWindowFit.clampPoint(CGPoint(x: 10, y: 100), into: usableAK) == CGPoint(x: 10, y: 100))

    var a = ZoneSpanAnchor()
    let z1 = UUID(), z2 = UUID()
    expect("Span: no anchor without ⌘", a.update(command: false, screen: 0, single: z1) == nil)
    expect("Span: ⌘ anchors the zone chosen then", a.update(command: true, screen: 0, single: z1) == z1)
    expect("Span: the anchor stays while ⌘ is held", a.update(command: true, screen: 0, single: z2) == z1)
    expect("Span: the anchor waits for a zone when ⌘ went down outside",
           { var b = ZoneSpanAnchor(); return b.update(command: true, screen: 0, single: nil) == nil
               && b.update(command: true, screen: 0, single: z2) == z2 }())
    expect("Span: another screen re-anchors", a.update(command: true, screen: 1, single: z2) == z2)
    expect("Span: releasing ⌘ clears it", a.update(command: false, screen: 1, single: z1) == nil)

    let start = CGRect(x: 100, y: 100, width: 800, height: 600)
    expect("Drag detection: a 3 pt move with the same size is a window move",
           ZoneWindowFit.isMove(from: start, to: start.offsetBy(dx: 3, dy: 0)))
    expect("Drag detection: under 3 pt is not",
           !ZoneWindowFit.isMove(from: start, to: start.offsetBy(dx: 2, dy: 1)))
    expect("Drag detection: a left-edge resize (origin and size change) is not",
           !ZoneWindowFit.isMove(from: start, to: CGRect(x: 60, y: 100, width: 840, height: 600)))

    let usableAX = CGRect(x: 0, y: 25, width: 1440, height: 875)
    let zoneAX = CGRect(x: 720, y: 25, width: 720, height: 875)
    expect("Fit: a window bigger than the zone starts at the zone's corner, kept inside the screen",
           near(ZoneWindowFit.place(size: CGSize(width: 900, height: 500), in: zoneAX, usable: usableAX, centered: false),
                CGRect(x: 540, y: 25, width: 900, height: 500)))
    expect("Fit: a non-resizable window is centred in the zone",
           near(ZoneWindowFit.place(size: CGSize(width: 400, height: 300), in: zoneAX, usable: usableAX, centered: true),
                CGRect(x: 880, y: 312.5, width: 400, height: 300)))
    expect("Fit: a window taller than the screen keeps its top visible",
           ZoneWindowFit.place(size: CGSize(width: 400, height: 2000), in: zoneAX, usable: usableAX, centered: true).minY == 25)
    expect("Fit: app rounding within 2 pt is accepted",
           ZoneWindowFit.matches(CGRect(x: 720, y: 25, width: 718.5, height: 874), zoneAX)
               && !ZoneWindowFit.matches(CGRect(x: 720, y: 25, width: 700, height: 875), zoneAX))
}

// MARK: Store and displays

func checkStore() throws {
    let data = try JSONEncoder().encode(seeded)
    let roundTrip = try JSONDecoder().decode(ZonesState.self, from: data)
    expect("JSON round-trip retains all model fields", roundTrip == seeded)

    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cala-zones-\(UUID())", isDirectory: true)
    let url = root.appendingPathComponent("zones.json")
    let fm = FileManager.default
    defer { try? fm.removeItem(at: root) }
    let store = try ZonesStore(fileURL: url, templateName: { "Localized \($0)" })
    let firstReload = try ZonesStore(fileURL: url)
    expect("First start writes all eight templates with supplied names",
           store.state == firstReload.state && store.state.layouts.count == 8
           && store.state.layouts[0].name == "Localized two-columns")
    let editorURL = root.appendingPathComponent("editor-zones.json")
    let editorStore = try ZonesStore(fileURL: editorURL)
    let editorBase = editorStore.state
    let beforeDraft = try Data(contentsOf: editorURL)
    var editorDraft = editorBase
    let newID = editorDraft.duplicate(editorBase.layouts[0].id, name: "Editor copy")
    editorDraft.activeByDisplay["editor-monitor"] = newID.uuidString
    let beforeSave = try Data(contentsOf: editorURL)
    expect("Editor draft edits leave store state and disk untouched before Save",
           beforeSave == beforeDraft && editorStore.state == editorBase)
    try editorStore.saveEditorDraft(editorDraft, basedOn: editorBase)
    let savedEditor = try ZonesStore(fileURL: editorURL)
    expect("Editor save writes the layout and display assignment together",
           savedEditor.state == editorDraft && savedEditor.layout(forDisplay: "editor-monitor")?.id == newID)
    let deletedLayoutID = editorBase.layouts[0].id
    let editedLayoutID = editorBase.layouts[1].id
    let externallyEditedID = editorBase.layouts[2].id
    let externallyDeletedID = editorBase.layouts[3].id
    try editorStore.setActiveLayout(deletedLayoutID, forDisplay: "externally-reassigned")
    try editorStore.setActiveLayout(deletedLayoutID, forDisplay: "deleted-layout")
    try editorStore.setActiveLayout(externallyEditedID, forDisplay: "editor-cleared")
    let mergeBase = editorStore.state
    var mergeDraft = mergeBase
    mergeDraft.layouts[1].name = "Editor rename"
    mergeDraft.layouts[1].addZone(rect(0.2, 0.2, 0.1, 0.1))
    let editorNew = ZoneLayout(name: "Editor addition")
    mergeDraft.layouts.append(editorNew)
    mergeDraft.delete(deletedLayoutID)
    mergeDraft.activeByDisplay["editor-monitor"] = editedLayoutID.uuidString
    mergeDraft.activeByDisplay.removeValue(forKey: "editor-cleared")

    var external = mergeBase.layouts[2]
    external.name = "External rename"
    try editorStore.save(external)
    var sameLayout = mergeBase.layouts[1]
    sameLayout.name = "Conflicting external rename"
    try editorStore.save(sameLayout)
    let externalNew = ZoneLayout(name: "External addition")
    try editorStore.save(externalNew)
    try editorStore.delete(externallyDeletedID)
    try editorStore.setDefaultLayout(externallyEditedID)
    try editorStore.setActiveLayout(externallyEditedID, forDisplay: "externally-reassigned")
    try editorStore.setActiveLayout(externallyEditedID, forDisplay: "editor-monitor")
    try editorStore.setActiveLayout(nil, forDisplay: "external-off")
    try editorStore.saveEditorDraft(mergeDraft, basedOn: mergeBase)

    let merged = try ZonesStore(fileURL: editorURL).state
    expect("Editor save merges layout edits, additions and removals against the live state",
           merged.layouts.first { $0.id == editedLayoutID } == mergeDraft.layouts.first { $0.id == editedLayoutID }
           && merged.layouts.contains(external) && merged.layouts.contains(externalNew) && merged.layouts.contains(editorNew)
           && merged.layouts.allSatisfy { $0.id != deletedLayoutID && $0.id != externallyDeletedID })
    expect("Editor save preserves external assignments except where the editor changed them",
           merged.defaultLayout == externallyEditedID
           && merged.activeByDisplay["externally-reassigned"] == externallyEditedID.uuidString
           && merged.activeByDisplay["editor-monitor"] == editedLayoutID.uuidString
           && merged.activeByDisplay["external-off"] == ZonesState.off
           && merged.activeByDisplay["editor-cleared"] == nil && merged.activeByDisplay["deleted-layout"] == nil)
    try editorStore.saveEditorDraft(mergeBase, basedOn: mergeBase)
    expect("An unchanged editor draft preserves the live state", editorStore.state == merged)
    let leftDisplay = ZoneDisplayKeys.Display(id: 200, frame: left, key: "display-uuid")
    let rightDisplay = ZoneDisplayKeys.Display(id: 100, frame: right, key: "display-uuid")
    let keys = ZoneDisplayKeys.keys(for: [rightDisplay, leftDisplay])
    expect("Duplicate UUIDs follow display arrangement independent of input order",
           keys == [200: "display-uuid", 100: "display-uuid#2"]
           && keys == ZoneDisplayKeys.keys(for: [leftDisplay, rightDisplay]))
    let lowerDisplay = ZoneDisplayKeys.Display(id: 400, frame: below, key: "stacked")
    let upperDisplay = ZoneDisplayKeys.Display(id: 300, frame: above, key: "stacked")
    let upperSameOrigin = ZoneDisplayKeys.Display(id: 200, frame: above, key: "stacked")
    let stackedKeys = ZoneDisplayKeys.keys(for: [upperDisplay, lowerDisplay, upperSameOrigin])
    expect("Duplicate UUIDs use vertical position, then display ID at identical origins",
           stackedKeys == [400: "stacked", 200: "stacked#2", 300: "stacked#3"]
           && stackedKeys == ZoneDisplayKeys.keys(for: [upperSameOrigin, lowerDisplay, upperDisplay]))
    let unplugged = ZoneDisplayKeys.Display(id: 9, frame: leftBelowPortrait, key: "unique-uuid")
    let replugged = ZoneDisplayKeys.Display(id: 90, frame: right, key: unplugged.key)
    expect("A unique display UUID survives reconnect with a new ID and placement",
           ZoneDisplayKeys.keys(for: [unplugged])[9] == unplugged.key
           && ZoneDisplayKeys.keys(for: [upperDisplay, replugged])[90] == unplugged.key)

    let second = store.state.layouts[1].id
    let didAssign = try store.setActiveLayout(second, forDisplay: "display-uuid#2")
    let didDisable = try store.setActiveLayout(nil, forDisplay: "off")
    let connected = ZoneDisplayKeys.keys(for: [leftDisplay])
    let reopened = try ZonesStore(fileURL: url)
    expect("New monitor gets default; disconnected monitor keeps its layout; off survives reload",
           didAssign && didDisable && connected[100] == nil && reopened.state.activeByDisplay.count == 2
           && reopened.layout(forDisplay: keys[100]!)?.id == second
           && reopened.layout(forDisplay: "new")?.id == store.state.defaultLayout
           && reopened.layout(forDisplay: "off") == nil
           && reopened.state.activeByDisplay["new"] == nil)

    let duplicate = try reopened.duplicate(second, name: "Copy")
    let copied = reopened.state.layouts.last!
    let originalZones = reopened.layout(forDisplay: "display-uuid#2")!.zones
    var draft = copied
    draft.name = "Renamed"
    draft.addZone(rect(0.1, 0.1, 0.2, 0.2))
    try reopened.save(draft)
    let changedDefault = try reopened.setDefaultLayout(draft.id)
    let deleted = try reopened.delete(second)
    try reopened.useDefaultLayout(forDisplay: "off")
    let afterEdit = try ZonesStore(fileURL: url)
    expect("CRUD preserves creation order and deleted assignments use the default",
           duplicate == copied.id && copied.zones.map(\.seq) == originalZones.map(\.seq)
           && Set(copied.zones.map(\.id)).isDisjoint(with: originalZones.map(\.id))
           && changedDefault && deleted && afterEdit.layout(forDisplay: "display-uuid#2") == draft
           && afterEdit.layout(forDisplay: "off") == draft)
    var last = ZonesState(layouts: [draft], defaultLayout: draft.id)
    expect("Final layout cannot be deleted", !last.delete(draft.id))
    let deletedDefault = try afterEdit.delete(draft.id)
    expect("Deleting the default chooses the first remaining layout",
           deletedDefault && afterEdit.state.defaultLayout == afterEdit.state.layouts.first?.id)

    let future = """
    {"version":7,"futureRoot":true,"activeByDisplay":{"disconnected":"off"},
     "layouts":[{"name":"Future","template":"new-template","futureLayout":{},
                 "zones":[{"futureZone":42,"rect":{"x":0.2,"y":0.4,"w":0.3,"h":0.5,"futureRect":[]}}]},
                {"name":"Blank","zones":null}]}
    """
    let futureState = try JSONDecoder().decode(ZonesState.self, from: Data(future.utf8)).repaired()
    expect("JSON ignores unknown fields at every level and defaults missing optional values",
           futureState.version == 7 && futureState.defaultLayout == futureState.layouts.first?.id
           && futureState.layouts.first?.template == "new-template" && futureState.layouts.first?.zones.first?.rect == rect(0.2, 0.4, 0.3, 0.5)
           && futureState.layouts.last?.zones.isEmpty == true && futureState.layout(forDisplay: "disconnected") == nil)
    let incomplete = Data(#"{"layouts":[{"name":"Incomplete","zones":[{"rect":{"x":0,"y":0,"h":1}}]}]}"#.utf8)
    let incompleteURL = root.appendingPathComponent("incomplete.json")
    try incomplete.write(to: incompleteURL)
    let incompleteStore = try ZonesStore(fileURL: incompleteURL)
    let incompleteBackup = try Data(contentsOf: incompleteURL.appendingPathExtension("bad"))
    expect("Missing required geometry backs up valid JSON before reseeding",
           incompleteBackup == incomplete && incompleteStore.state.layouts.count == ZoneTemplates.ids.count)

    let old = """
    {"layouts":[{"name":"Older","zones":[{"rect":{"x":0,"y":0,"w":0.5,"h":1}},
                                         {"rect":{"x":0,"y":0,"w":0.5,"h":1}}]}]}
    """
    try Data(old.utf8).write(to: url)
    let legacy = try ZonesStore(fileURL: url)
    let oldLayout = legacy.state.layouts[0]
    expect("Older JSON defaults missing fields and preserves tie order",
           legacy.state.version == 1 && legacy.state.defaultLayout == oldLayout.id
           && !oldLayout.isTemplate && oldLayout.nextSeq == 1 && legacy.state.activeByDisplay.isEmpty
           && ZonePicking.chosen(CGPoint(x: 50, y: 50), zones: oldLayout.zones, usable: usable) == oldLayout.zones.last)

    let broken = Data("invalid JSON".utf8)
    try broken.write(to: url)
    let recovered = try ZonesStore(fileURL: url)
    let backup = url.appendingPathExtension("bad")
    let backupData = try Data(contentsOf: backup)
    let reloaded = try ZonesStore(fileURL: url)
    expect("Corrupt JSON is preserved as .bad before seeding", backupData == broken && reloaded.state == recovered.state)

    try broken.write(to: url)
    try fm.removeItem(at: backup)
    try fm.createSymbolicLink(at: backup, withDestinationURL: root.appendingPathComponent("missing"))
    let locked = try ZonesStore(fileURL: url)
    var saveDisabled = false
    do {
        try locked.save(draft)
    } catch ZonesStore.SaveError.recoveryFailed {
        saveDisabled = true
    }
    let protectedData = try Data(contentsOf: url)
    expect("Failed backup disables writes and preserves the existing file",
           locked.recoveryError != nil && saveDisabled && protectedData == broken && locked.state.layouts.count == 8)
}

do {
    try checkStore()
} catch {
    expect("Store persistence", false, "\(error)")
}

print("\(passes) PASS, \(failures) FAIL")
exit(failures == 0 ? 0 : 1)

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

// MARK: Thumbnails, monitor names and editor helpers

let wide = ZoneThumbnails.size(aspect: 3840.0 / 1080, fitting: CGSize(width: 112, height: 70))
let laptop = ZoneThumbnails.size(aspect: 1512.0 / 982, fitting: CGSize(width: 112, height: 70))
let portrait = ZoneThumbnails.size(aspect: 1080.0 / 1920, fitting: CGSize(width: 112, height: 70))
expect("Thumbnail keeps the screen's shape inside its box",
       wide == CGSize(width: 112, height: 32) && laptop == CGSize(width: 108, height: 70)
       && portrait == CGSize(width: 39, height: 70)
       && ZoneThumbnails.size(aspect: .nan, fitting: CGSize(width: 10, height: 10)) == CGSize(width: 1, height: 1))
let thumbColumns = ZoneThumbnails.frames(for: ZoneTemplates.zones("two-columns"), size: CGSize(width: 100, height: 50),
                                         inset: 2, gap: 2, scale: 2)
expect("Thumbnail zones sit inside the inset with a gap between neighbours",
       thumbColumns.count == 2 && thumbColumns[0] == CGRect(x: 3, y: 3, width: 46, height: 44)
       && thumbColumns[1] == CGRect(x: 51, y: 3, width: 46, height: 44)
       && thumbColumns[1].minX - thumbColumns[0].maxX == 2
       && ZoneThumbnails.frames(for: ZoneTemplates.zones("two-columns"), size: CGSize(width: 100, height: 50),
                                inset: 2, gap: 4, scale: 2)[1].minX
          - ZoneThumbnails.frames(for: ZoneTemplates.zones("two-columns"), size: CGSize(width: 100, height: 50),
                                  inset: 2, gap: 4, scale: 2)[0].maxX == 4)
let thumbThirds = ZoneThumbnails.frames(for: ZoneTemplates.zones("three-columns"), size: CGSize(width: 101, height: 31),
                                        inset: 1.5, gap: 1.5, scale: 2)
expect("Thumbnail edges land on the pixel grid and tiny zones stay one pixel wide",
       thumbThirds.allSatisfy { [$0.minX, $0.maxX, $0.minY, $0.maxY].allSatisfy { ($0 * 2).rounded() == $0 * 2 } }
       && ZoneThumbnails.frames(for: [rect(0.5, 0.5, 0.001, 0.001)], size: CGSize(width: 40, height: 20),
                                inset: 0, gap: 2, scale: 2)[0].size == CGSize(width: 0.5, height: 0.5))
expect("Thumbnails paint larger zones first so overlapping small ones stay visible",
       ZoneThumbnails.paintingOrder([rect(0.4, 0.4, 0.2, 0.2), rect(0, 0, 1, 1), rect(0, 0, 0.5, 1), rect(0.5, 0, 0.5, 1)])
       == [1, 2, 3, 0])

func english(_ en: String, _ es: String) -> String { en }
func spanish(_ en: String, _ es: String) -> String { es }
let numberedLeft = ZoneMonitorNames.Monitor(name: "(AirPlay) (2)", frame: CGRect(x: -3840, y: -98, width: 3840, height: 1080))
let numberedMain = ZoneMonitorNames.Monitor(name: "(AirPlay) (1)", frame: CGRect(x: 0, y: 0, width: 1512, height: 982))
expect("Names macOS only told apart with a number are named by position",
       ZoneMonitorNames.labels([numberedMain, numberedLeft], localize: english) == ["Right display", "Left display"]
       && ZoneMonitorNames.baseName(" Dell U2720Q (12) ") == "dell u2720q" && ZoneMonitorNames.baseName("Studio (Pro)") == "studio (pro)")
let airplayLeft = ZoneMonitorNames.Monitor(name: " (AirPlay)", frame: CGRect(x: -3840, y: -98, width: 3840, height: 1080))
let airplayMain = ZoneMonitorNames.Monitor(name: "(AirPlay) ", frame: CGRect(x: 0, y: 0, width: 1512, height: 982))
expect("Monitors sharing a name are named by position",
       ZoneMonitorNames.labels([airplayMain, airplayLeft], localize: english) == ["Right display", "Left display"]
       && ZoneMonitorNames.labels([airplayMain, airplayLeft], localize: spanish) == ["Pantalla derecha", "Pantalla izquierda"])
expect("A unique monitor name is kept; three side by side get left, middle and right",
       ZoneMonitorNames.labels([.init(name: "Studio Display", frame: primary), airplayLeft], localize: english)
       == ["Studio Display", " (AirPlay)".trimmingCharacters(in: .whitespaces)]
       && ZoneMonitorNames.labels([.init(name: "Dell", frame: primary), .init(name: "Dell", frame: left),
                                   .init(name: "", frame: right)], localize: english)
       == ["Middle display", "Left display", "Right display"])
expect("Stacked monitors are top and bottom; other arrangements are numbered",
       ZoneMonitorNames.labels([.init(name: "", frame: primary), .init(name: "", frame: above)], localize: english)
       == ["Bottom display", "Top display"]
       && ZoneMonitorNames.labels([.init(name: "", frame: primary), .init(name: "", frame: CGRect(x: 1000, y: 800, width: 1920, height: 1080))],
                                  localize: english) == ["Display 1", "Display 2"]
       && ZoneMonitorNames.labels([.init(name: "", frame: primary)], localize: english) == ["Display 1"])

let firstNew = ZoneEditing.newZoneRect(existing: [])
let secondNew = ZoneEditing.newZoneRect(existing: [firstNew])
expect("Add zone places a centred grid-aligned zone and steps when that spot is taken",
       near(firstNew, rect(4.0 / 12, 3.0 / 12, 4.0 / 12, 6.0 / 12))
       && near(secondNew, rect(5.0 / 12, 4.0 / 12, 4.0 / 12, 6.0 / 12))
       && near(ZoneEditing.newZoneRect(existing: [firstNew, secondNew, rect(6.0 / 12, 5.0 / 12, 4.0 / 12, 6.0 / 12),
                                                  rect(7.0 / 12, 6.0 / 12, 4.0 / 12, 6.0 / 12)]), rect(0, 0, 4.0 / 12, 6.0 / 12)))
expect("New layout names never repeat",
       ZoneEditing.uniqueName("My layout", existing: ["Two columns"]) == "My layout"
       && ZoneEditing.uniqueName("My layout", existing: [" my layout ", "My layout 2"]) == "My layout 3")

var trimmedSeed = ZoneTemplates.seedState()
trimmedSeed.layouts.removeAll { $0.template == "wide-center" || $0.template == "two-rows" }
var editedCenter = ZoneTemplates.makeLayout("wide-center", name: "Mine")
editedCenter.addZone(rect(0.1, 0.1, 0.2, 0.2))
let restoredCenter = ZoneTemplates.restored(editedCenter)
expect("Deleted built-ins can be added back; an edited built-in can be restored keeping its id and name",
       ZoneTemplates.missing(in: trimmedSeed) == ["two-rows", "wide-center"]
       && ZoneTemplates.missing(in: ZoneTemplates.seedState()).isEmpty
       && ZoneTemplates.isModified(editedCenter) && !ZoneTemplates.isModified(restoredCenter)
       && restoredCenter.id == editedCenter.id && restoredCenter.name == "Mine"
       && restoredCenter.zones.map(\.rect) == ZoneTemplates.zones("wide-center") && restoredCenter.nextSeq == 3
       && !ZoneTemplates.isModified(ZoneLayout(name: "Blank")))

// MARK: Linked editing, centre and equal-size snapping, measures

let thirdsL = ZoneTemplates.zones("three-columns")
let gridL = ZoneTemplates.zones("grid-2x2")
let stackedL = ZoneTemplates.zones("main-two-stacked")
expect("A shared divider links both columns; float noise still counts as shared",
       ZoneLinking.linkedEdges(thirdsL, index: 0, edge: .right) == [.init(index: 0, isMax: true), .init(index: 1, isMax: false)]
       && ZoneLinking.linkedEdges([rect(0, 0, 0.3333331, 1), rect(0.3333336, 0, 0.6666664, 1)], index: 1, edge: .left).count == 2
       && ZoneLinking.linkedEdges(thirdsL, index: 0, edge: .left) == [.init(index: 0, isMax: false)])
expect("In a 2 × 2 grid only the dragged row's divider moves; a tall zone drags the whole divider",
       Set(ZoneLinking.linkedEdges(gridL, index: 0, edge: .right).map(\.index)) == [0, 1]
       && Set(ZoneLinking.linkedEdges(stackedL, index: 1, edge: .left).map(\.index)) == [0, 1, 2]
       && Set(ZoneLinking.linkedEdges(gridL, index: 0, edge: .bottom).map(\.index)) == [0, 2])
let linkedGrow = ZoneLinking.resize(thirdsL, index: 0, edges: .right, proposed: rect(0, 0, 0.5, 1), minSize: (0.05, 0.05))
expect("Linked resize grows one zone and shrinks its neighbour, nothing overlaps",
       linkedGrow.count == 2 && near(linkedGrow[0]!, rect(0, 0, 0.5, 1)) && near(linkedGrow[1]!, rect(0.5, 0, 1.0 / 6, 1))
       && abs(linkedGrow[0]!.maxX - linkedGrow[1]!.x) < 1e-12)
let linkedStop = ZoneLinking.resize(thirdsL, index: 0, edges: .right, proposed: rect(0, 0, 0.95, 1), minSize: (0.1, 0.1))
expect("Linked resize stops where the neighbour reaches the minimum size",
       near(linkedStop[0]!, rect(0, 0, 2.0 / 3 - 0.1, 1)) && abs(linkedStop[1]!.w - 0.1) < 1e-12
       && linkedStop[2] == nil)
let linkedDivider = ZoneLinking.resize(stackedL, index: 2, edges: [.left, .top], proposed: rect(0.4, 0.6, 0.6, 0.4),
                                       minSize: (0.05, 0.05))
expect("A corner drag moves both linked dividers: three zones follow the vertical one, two the horizontal one",
       near(linkedDivider[0]!, rect(0, 0, 0.4, 1)) && near(linkedDivider[1]!, rect(0.4, 0, 0.6, 0.6))
       && near(linkedDivider[2]!, rect(0.4, 0.6, 0.6, 0.4)))
expect("A screen-edge resize has no neighbours; an unlinked zone stays put",
       ZoneLinking.resize(thirdsL, index: 0, edges: .left, proposed: rect(0.1, 0, 1.0 / 3 - 0.1, 1), minSize: (0.05, 0.05)).keys.sorted() == [0])

let centreWide = ZoneTemplates.zones("wide-center")
let equalRow = ZoneLinking.equalized(centreWide, index: 0, horizontal: true)
expect("Equal widths shares the row evenly and keeps its outer edges; a lone zone is left alone",
       equalRow.count == 3 && near(equalRow[1]!, rect(1.0 / 3, 0, 1.0 / 3, 1)) && near(equalRow[2]!, rect(2.0 / 3, 0, 1.0 / 3, 1))
       && ZoneLinking.equalized(centreWide, index: 0, horizontal: false).isEmpty
       && near(ZoneLinking.equalized([rect(0, 0, 0.2, 1), rect(0.3, 0, 0.6, 1)], index: 1, horizontal: true)[1]!,
               rect(0.5, 0, 0.4, 1)))
expect("Centre actions put the zone's centre on the screen's centre line",
       near(ZoneLinking.centered(rect(0.1, 0.2, 0.3, 0.4), horizontally: true), rect(0.35, 0.2, 0.3, 0.4))
       && near(ZoneLinking.centered(rect(0.1, 0.2, 0.3, 0.4), horizontally: false), rect(0.1, 0.3, 0.3, 0.4)))

let (centredMove, centreGuides) = ZoneSnapping.move(rect(0.1, 0.1, 0.3, 0.3), by: (0.247, 0.0), others: [], grid: false,
                                                     snapping: true, threshold: (0.01, 0.01))
expect("Moving snaps the zone's centre to the screen's centre with a centre guide",
       near(centredMove, rect(0.35, 0.1, 0.3, 0.3)) && centreGuides == [.init(axis: .x, position: 0.5, kind: .center)]
       && ZoneSnapping.move(rect(0.1, 0.1, 0.3, 0.3), by: (0.247, 0.0), others: [], grid: false, snapping: false,
                            threshold: (0.01, 0.01)).1.isEmpty)
expect("A centred zone whose edges also meet grid lines shows the centre guide",
       ZoneSnapping.move(rect(0.25, 0.1, 0.5, 0.3), by: (0.003, 0), others: [], grid: true, snapping: true,
                         threshold: (0.01, 0.01)).1.first == .init(axis: .x, position: 0.5, kind: .center))
let (equalWidth, equalGuides) = ZoneSnapping.resize(rect(0.5, 0, 0.3, 1), edges: .right, by: (dx: -0.054, dy: 0),
                                                    others: [rect(0, 0, 0.243, 1)], grid: false, snapping: true,
                                                    threshold: (0.01, 0.01), minSize: (0.05, 0.05))
expect("Resizing snaps to another zone's width and marks it as equal size",
       abs(equalWidth.w - 0.243) < 1e-12 && equalGuides == [.init(axis: .x, position: 0.743, kind: .equalSize)])
let (drawnEqual, drawnGuides) = ZoneSnapping.draw(from: (0.6, 0.2), to: (0.893, 0.62), others: [rect(0, 0, 0.3, 0.3)],
                                                  grid: false, snapping: true, threshold: (0.01, 0.01), minSize: (0.05, 0.05))
expect("Drawing snaps to another zone's size too",
       abs(drawnEqual.w - 0.3) < 1e-12
       && drawnGuides.contains { $0.axis == .x && $0.kind == .equalSize && abs($0.position - 0.9) < 1e-12 })

expect("Sizes in points add up across a shared edge and follow the monitor",
       ZoneMeasure.size(rect(0, 0, 0.25, 1), in: CGSize(width: 3840, height: 1050)) == (960, 1050)
       && ZoneMeasure.size(rect(1.0 / 3, 0, 1.0 / 3, 1), in: CGSize(width: 1000, height: 10)).w
          + ZoneMeasure.size(rect(0, 0, 1.0 / 3, 1), in: CGSize(width: 1000, height: 10)).w
          + ZoneMeasure.size(rect(2.0 / 3, 0, 1.0 / 3, 1), in: CGSize(width: 1000, height: 10)).w == 1000)
expect("A typed size keeps the centre, stays on screen and respects the minimum",
       near(ZoneMeasure.resized(rect(0.4, 0.4, 0.2, 0.2), to: (960, 525), in: CGSize(width: 3840, height: 1050), minSize: (0.05, 0.05)),
            rect(0.375, 0.25, 0.25, 0.5))
       && near(ZoneMeasure.resized(rect(0.9, 0, 0.1, 0.1), to: (1920, 10), in: CGSize(width: 3840, height: 1050), minSize: (0.05, 0.05)),
               rect(0.5, 0.025, 0.5, 0.05)))

// MARK: Linked tiling (split, merge, delete-as-merge, dividers, swap) and Free placement

let minT = (w: 0.05, h: 0.05)
expect("Every built-in tiles; overlaps, holes and an empty layout do not",
       ZoneTemplates.ids.allSatisfy { ZoneTiling.tiles(ZoneTemplates.zones($0)) }
       && !ZoneTiling.tiles([rect(0, 0, 0.6, 1), rect(0.5, 0, 0.5, 1)]) && !ZoneTiling.tiles([rect(0, 0, 0.5, 1)])
       && !ZoneTiling.tiles([]) && ZoneTiling.tiles([rect(0, 0, 0.3333331, 1), rect(0.3333336, 0, 0.6666664, 1)]))
expect("Mode is inferred from geometry: built-ins Linked, overlapping or blank Free; a stored mode wins",
       ZoneTemplates.seedState().layouts.allSatisfy { $0.mode == .linked }
       && ZoneLayout(name: "Overlap", zones: [Zone(rect: rect(0, 0, 0.7, 1)), Zone(rect: rect(0.3, 0, 0.7, 1))]).mode == .free
       && ZoneLayout(name: "Blank").mode == .free
       && (try? JSONDecoder().decode(ZoneLayout.self, from: Data(#"{"name":"Old","zones":[{"rect":{"x":0,"y":0,"w":0.5,"h":1}},{"rect":{"x":0.5,"y":0,"w":0.5,"h":1}}]}"#.utf8)))?.mode == .linked
       && (try? JSONDecoder().decode(ZoneLayout.self, from: Data(#"{"name":"Odd","mode":"spiral","zones":[]}"#.utf8)))?.mode == .free
       && (try? JSONDecoder().decode(ZoneLayout.self, from: Data(#"{"name":"Kept","mode":"free","zones":[{"rect":{"x":0,"y":0,"w":1,"h":1}}]}"#.utf8)))?.mode == .free)
var brokenLinked = ZoneTemplates.makeLayout("two-columns", name: "Hand-edited")
brokenLinked.zones[0].rect = rect(0, 0, 0.7, 1)
expect("A stored Linked layout that no longer tiles is repaired to Free; adding a rectangle makes a layout Free",
       ZonesState(layouts: [brokenLinked]).repaired().layouts[0].mode == .free
       && { var l = ZoneTemplates.makeLayout("two-rows", name: "x"); l.addZone(rect(0.1, 0.1, 0.2, 0.2)); return l.mode == .free }())

var splitLayout = ZoneTemplates.makeLayout("two-columns", name: "Split")
let splitFirst = splitLayout.zones[0].id
let splitNew = splitLayout.split(splitFirst, vertically: false, minSize: minT)
expect("Split cuts a zone in two at its midpoint, the new part follows it, and the layout still tiles",
       splitNew != nil && splitLayout.zones.count == 3 && splitLayout.zones[1].id == splitNew
       && near(splitLayout.zones[0].rect, rect(0, 0, 0.5, 0.5)) && near(splitLayout.zones[1].rect, rect(0, 0.5, 0.5, 0.5))
       && ZoneTiling.tiles(splitLayout.zones.map(\.rect)) && splitLayout.zones[1].seq == 2 && splitLayout.mode == .linked)
expect("Split follows the longer side on screen, cuts where asked, and refuses parts below the minimum",
       ZoneTiling.splitsVertically(rect(0, 0, 0.5, 1), aspect: 3840.0 / 1050) && !ZoneTiling.splitsVertically(rect(0, 0, 0.5, 1), aspect: 1)
       && near(ZoneTiling.split(rect(0, 0, 0.5, 1), vertically: true, at: 0.2, minSize: minT)!.1, rect(0.2, 0, 0.3, 1))
       && ZoneTiling.split(rect(0, 0, 0.08, 1), vertically: true, minSize: minT) == nil)

let quarters4 = ZoneTemplates.zones("grid-2x2")
expect("Merge needs the union to be a rectangle: a row merges, a diagonal pair or a single zone does not",
       near(ZoneTiling.mergedRect(quarters4, indices: [0, 1])!, rect(0, 0, 1, 0.5))
       && ZoneTiling.mergedRect(quarters4, indices: [0, 3]) == nil && ZoneTiling.mergedRect(quarters4, indices: [0]) == nil
       && near(ZoneTiling.mergedRect(quarters4, indices: [0, 1, 2, 3])!, rect(0, 0, 1, 1))
       && ZoneTiling.mergedRect([rect(0, 0, 0.5, 1), rect(0.5, 0, 0.5, 0.5), rect(0.5, 0.5, 0.5, 0.5)], indices: [0, 1]) == nil)
var mergeLayout = ZoneTemplates.makeLayout("grid-2x2", name: "Merge")
let mergeIDs = Set([mergeLayout.zones[2].id, mergeLayout.zones[3].id])
let mergedKept = mergeLayout.merge(mergeIDs)
expect("Merging keeps the first zone, removes the others and still tiles",
       mergedKept == mergeLayout.zones.last?.id && mergeLayout.zones.count == 3
       && near(mergeLayout.zones[2].rect, rect(0, 0.5, 1, 0.5)) && ZoneTiling.tiles(mergeLayout.zones.map(\.rect))
       && { var l = ZoneTemplates.makeLayout("grid-2x2", name: "x"); return l.merge([l.zones[0].id, l.zones[3].id]) == nil && l.zones.count == 4 }())
var deleteLayout = ZoneTemplates.makeLayout("main-two-stacked", name: "Delete")
let stackedTop = deleteLayout.zones[1].id
let absorbedBy = deleteLayout.removeByMerging(stackedTop)
var lonely = ZoneLayout(name: "Lonely", zones: [Zone(rect: rect(0, 0, 1, 1))])
var pinwheel = ZoneLayout(name: "Pinwheel", zones: [rect(0, 0, 0.6, 0.4), rect(0.6, 0, 0.4, 0.6), rect(0.4, 0.6, 0.6, 0.4),
                                                    rect(0, 0.4, 0.4, 0.6), rect(0.4, 0.4, 0.2, 0.2)].map { Zone(rect: $0) })
expect("Linked delete gives the space to a neighbour sharing a whole side; none when no side is shared",
       absorbedBy == deleteLayout.zones[1].id && near(deleteLayout.zones[1].rect, rect(0.5, 0, 0.5, 1))
       && ZoneTiling.tiles(deleteLayout.zones.map(\.rect))
       && lonely.removeByMerging(lonely.zones[0].id) == nil && pinwheel.mode == .linked
       && pinwheel.removeByMerging(pinwheel.zones[4].id) == nil && pinwheel.zones.count == 5)
expect("Linked delete prefers the smallest neighbour",
       ZoneTiling.deletionMerge([rect(0, 0, 0.2, 1), rect(0.2, 0, 0.3, 1), rect(0.5, 0, 0.5, 1)], index: 1)?.neighbour == 0)

let dividerTiles = ZoneLinking.resize(ZoneTemplates.zones("main-two-stacked"), index: 1, edges: [.left, .bottom],
                                      proposed: rect(0.3, 0, 0.7, 0.7), minSize: minT)
var afterDivider = ZoneTemplates.zones("main-two-stacked")
for (i, r) in dividerTiles { afterDivider[i] = r }
var swapped = ZoneTemplates.zones("wide-center")
swapped.swapAt(0, 2)
expect("Divider drags and swaps keep a tiling; border edges are reported so they are not dragged",
       ZoneTiling.tiles(afterDivider) && ZoneTiling.tiles(swapped.enumerated().map { i, _ in ZoneTemplates.zones("wide-center")[[2, 1, 0][i]] })
       && ZoneTiling.borderEdges(rect(0, 0, 0.5, 1)) == [.left, .top, .bottom] && ZoneTiling.borderEdges(rect(0.2, 0.2, 0.5, 0.5)).isEmpty)

expect("Free add goes into the largest empty gap, shrunk to fit",
       near(ZoneTiling.freeZoneRect([rect(0, 0, 0.5, 1)], last: rect(0, 0, 0.5, 1), minSize: minT), rect(0.5 + 1.0 / 12, 0.25, 1.0 / 3, 0.5))
       && near(ZoneTiling.freeZoneRect([rect(0, 0, 0.8, 1)], last: nil, minSize: minT), rect(0.8, 0.25, 0.2, 0.5))
       && near(ZoneTiling.largestGap([rect(0, 0, 1, 0.3), rect(0, 0.3, 0.4, 0.7)], minSize: minT)!, rect(0.4, 0.3, 0.6, 0.7))
       && near(ZoneTiling.freeZoneRect([], last: nil, minSize: minT), rect(1.0 / 3, 0.25, 1.0 / 3, 0.5)))
expect("With no gap, Free add cascades from the newest zone and wraps at the screen's edge",
       near(ZoneTiling.freeZoneRect(ZoneTemplates.zones("two-columns"), last: rect(0.5, 0, 0.5, 1), minSize: minT),
            rect(0.5 + 1.0 / 24, 1.0 / 24, 1.0 / 3, 0.5))
       && near(ZoneTiling.freeZoneRect(ZoneTemplates.zones("two-columns"), last: rect(0.7, 0.6, 0.3, 0.4), minSize: minT),
               rect(0, 0, 1.0 / 3, 0.5)))

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

// MARK: Drag candidates

do {
    let id: CGWindowID = 20_529
    let ids = ZoneDragCandidate.windowIDArray(id)
    expect("Window bounds lookup passes the raw CGWindowID to Core Graphics",
           CFArrayGetCount(ids) == 1 && UInt(bitPattern: CFArrayGetValueAtIndex(ids, 0)) == UInt(id))
}

do {
    let p = CGPoint(x: 140, y: 110)
    var machine = ZoneDragMachine()
    let released = machine.leftDown(at: p, shift: false, command: false)!
    _ = machine.leftDragged(to: p, shift: false, command: false)
    expect("Mouse-up clears a pending drag and rejects late adoption or AppKit validation",
           machine.leftUp(at: p, shift: false, command: false) == nil && machine.phase == .idle
               && !machine.confirmDrag(generation: released) && !machine.endPending(generation: released))

    let timedOut = machine.leftDown(at: p, shift: true, command: false)!
    expect("A pending timeout affects only its own press",
           !machine.endPending(generation: released) && machine.isPending(generation: timedOut))
    expect("A pending drag times out even without mouse-up and leaves right-click alone",
           machine.endPending(generation: timedOut) && machine.phase == .idle && !machine.zonesMode
               && !machine.confirmDrag(generation: timedOut) && !machine.rightDown() && !machine.rightUp())

    let next = machine.leftDown(at: p, shift: false, command: false)!
    expect("The next drag can activate zones and a timeout cannot cancel a confirmed drag",
           machine.confirmDrag(generation: next) && !machine.endPending(generation: next)
               && machine.rightDown() && machine.rightUp()
               && machine.leftUp(at: p, shift: false, command: false)?.zonesMode == true)
    machine.endSnapRelease(generation: timedOut)
    expect("Completion of a stale detached lookup leaves the current release alone", machine.snapReleaseGeneration == next)
    machine.endSnapRelease(generation: next)
    expect("Completion of the detached lookup clears its release", machine.snapReleaseGeneration == nil)
}

do {
    let frame = CGRect(x: 100, y: 100, width: 880, height: 640)
    let press = CGPoint(x: 140, y: 110)
    let point = CGPoint(x: 165, y: 130)
    let settings = ZoneDragCandidate.Window(key: .init(pid: getpid(), windowID: 10), frame: frame)
    let candidate = ZoneDragCandidate(original: settings, point: press)
    var machine = ZoneDragMachine()
    let generation = machine.leftDown(at: press, shift: false, command: false)!
    let check = machine.leftDragged(to: point, shift: false, command: false)
    expect("Cala Settings: a stationary window leaves the right click alone",
           check && !candidate.originalMoved(to: frame) && !machine.rightDown())
    expect("Cala Settings: CG movement leaves the press pending until AppKit validation confirms it",
           candidate.originalMoved(to: frame.offsetBy(dx: 25, dy: 20)) && !machine.zonesMode && !machine.rightDown()
               && machine.confirmDrag(generation: generation))
    expect("Cala Settings: right-click activates zones and the release requests a snap",
           machine.rightDown() && machine.rightUp()
               && machine.leftUp(at: point, shift: false, command: false)?.zonesMode == true)

    let stale = machine.leftDown(at: press, shift: false, command: false)!
    _ = machine.leftUp(at: point, shift: false, command: false)
    let current = machine.leftDown(at: press, shift: true, command: false)!
    expect("Cala Settings: delayed AppKit validation cannot confirm a newer press",
           !machine.confirmDrag(generation: stale) && !machine.zonesMode && !machine.rightDown()
               && machine.confirmDrag(generation: current) && machine.zonesMode)
}

do {
    let browserPID: pid_t = 99
    let original = ZoneDragCandidate.Window(key: .init(pid: browserPID, windowID: 10),
                                            frame: CGRect(x: 100, y: 100, width: 900, height: 700))
    let press = CGPoint(x: 160, y: 112)
    let first = CGPoint(x: 200, y: 160)
    let second = CGPoint(x: 240, y: 190)
    let frame = CGRect(x: 170, y: 150, width: 800, height: 600)
    func window(_ id: CGWindowID, _ frame: CGRect, pid: pid_t = browserPID) -> ZoneDragCandidate.Window {
        ZoneDragCandidate.Window(key: .init(pid: pid, windowID: id), frame: frame)
    }

    expect("Tab detach: scans require a press in the tab band near the top edge, in any app (Chrome, Brave, ...)",
           ZoneDragCandidate.mayDetachTab(at: press, in: original.frame)
               && ZoneDragCandidate.mayDetachTab(at: CGPoint(x: 160, y: 190), in: original.frame)
               && !ZoneDragCandidate.mayDetachTab(at: CGPoint(x: 160, y: 220), in: original.frame))
    let ordinary = ZoneDragCandidate(original: original, point: press)
    expect("Tab detach: an ordinary content drag never requests a full scan",
           !ordinary.shouldRecheck(at: first, time: 10))

    var machine = ZoneDragMachine()
    let generation = machine.leftDown(at: press, shift: false, command: false)!
    var candidate = ZoneDragCandidate(original: original, point: press, initialTabWindowIDs: [10, 11])
    let check = machine.leftDragged(to: first, shift: false, command: false)
    let popup = frame.offsetBy(dx: 0, dy: -120)
    let visible = [original, window(11, frame), window(12, frame, pid: 80), window(13, frame),
                   window(14, frame), window(15, frame), window(16, frame), window(17, popup)]
    expect("Tab detach: the original stays put and a new ID alone does not confirm a drag",
           check && !candidate.originalMoved(to: original.frame)
               && candidate.shouldRecheck(at: first, time: 10)
               && candidate.recheck(windows: visible, at: first, time: 10) == nil && !machine.rightDown())

    expect("Tab detach: fallback scans are rate limited and require cursor motion",
           !candidate.shouldRecheck(at: second, time: 10.01)
               && !candidate.shouldRecheck(at: first, time: 10.05)
               && candidate.shouldRecheck(at: second, time: 10.05))
    let moved = frame.offsetBy(dx: 40, dy: 30)
    let resized = CGRect(x: moved.minX, y: moved.minY, width: moved.width + 50, height: moved.height)
    let next = [original, window(11, moved), window(12, moved, pid: 80), window(13, frame),
                window(14, resized), window(15, frame.offsetBy(dx: -40, dy: 30)), window(16, moved),
                window(17, popup.offsetBy(dx: 40, dy: 30))]
    _ = machine.leftDragged(to: second, shift: false, command: false)
    let adopted = candidate.recheck(windows: next, at: second, time: 10.05)
    expect("Tab detach: a unique tab-like window is adopted over a popup tracking the pointer outside its tab band",
           adopted?.key == window(16, moved).key && adopted?.frame == moved)
    expect("Tab detach: adoption confirms the same press and the right-click snap survives to release",
           adopted != nil && machine.confirmDrag(generation: generation)
               && machine.rightDown() && machine.rightUp()
               && machine.leftUp(at: second, shift: false, command: false)
                   == ZoneDragMachine.Release(generation: generation, point: second, zonesMode: true, command: false))
    expect("Tab detach: AX lookup stays current after release and a new press cancels it",
           machine.snapReleaseGeneration == generation
               && machine.leftDown(at: second, shift: false, command: false) != generation
               && machine.snapReleaseGeneration == nil)

    let third = CGPoint(x: 280, y: 220)
    let last = moved.offsetBy(dx: 40, dy: 30)
    for reversed in [false, true] {
        var ambiguous = ZoneDragCandidate(original: original, point: press, initialTabWindowIDs: [10])
        let generation = machine.leftDown(at: press, shift: true, command: false)!
        let pair = [window(18, frame), window(19, frame.offsetBy(dx: 10, dy: 4))]
        let moving = [window(18, moved), window(19, moved.offsetBy(dx: 10, dy: 4))]
        _ = ambiguous.recheck(windows: pair, at: first, time: 20)
        _ = machine.leftDragged(to: second, shift: true, command: false)
        let matches = reversed ? Array(moving.reversed()) : moving
        let unresolved = ambiguous.recheck(windows: matches, at: second, time: 20.05)
        expect("Tab detach: two tab-like candidates stay pending (reversed: \(reversed))",
               unresolved == nil && machine.phase == .pressed && !machine.zonesMode && !machine.rightDown())
        let remaining = ambiguous.recheck(windows: [window(19, last.offsetBy(dx: 10, dy: 4))],
                                          at: third, time: 20.10)
        expect("Tab detach: the remaining candidate keeps its history (reversed: \(reversed))",
               remaining?.key == window(19, last).key && machine.confirmDrag(generation: generation))
        _ = machine.leftUp(at: third, shift: true, command: false)
        machine.cancel(resetButtons: true)
        expect("Tab detach: cancelling clears the released gesture (reversed: \(reversed))",
               machine.snapReleaseGeneration == nil)
    }
}

// MARK: Layout strip

do {
    let usable = CGRect(x: 0, y: 0, width: 1512, height: 944)
    let grip = ZoneStripGeometry.collapsed(usable: usable)
    expect("Strip: the grip sits at the top centre of the usable area, below its top edge",
           abs(grip.body.midX - usable.midX) <= 0.5 && grip.body.maxY == usable.maxY - ZoneStripGeometry.topGap
               && grip.panel == grip.body.insetBy(dx: -16, dy: -16))
    let eight = ZoneStripGeometry.expanded(usable: usable, count: 8, current: 2)
    expect("Strip: eight layouts fit at full size, centred, in order",
           eight.scale == 1 && eight.items.map(\.index) == Array(0..<8) && abs(eight.body.midX - usable.midX) <= 0.5
               && eight.body.maxY == usable.maxY - ZoneStripGeometry.topGap)
    expect("Strip: items do not overlap and stay inside the body",
           zip(eight.items, eight.items.dropFirst()).allSatisfy { $0.frame.maxX < $1.frame.minX }
               && eight.items.allSatisfy { eight.body.contains($0.frame) })
    let medium = ZoneStripGeometry.expanded(usable: CGRect(x: 0, y: 0, width: 600, height: 900), count: 8, current: 0)
    expect("Strip: a medium display shrinks items so all eight still fit",
           medium.items.count == 8 && medium.scale < 1 && medium.scale >= ZoneStripGeometry.minScale && medium.body.width <= 600)
    let narrow = CGRect(x: -1080, y: 0, width: 400, height: 1920)
    let shrunk = ZoneStripGeometry.expanded(usable: narrow, count: 8, current: 7)
    expect("Strip: a narrow display shrinks items, then shows a window around the current layout",
           shrunk.scale == ZoneStripGeometry.minScale && shrunk.items.count < 8 && shrunk.items.last?.index == 7
               && shrunk.body.minX >= narrow.minX && shrunk.body.maxX <= narrow.maxX)
    let many = ZoneStripGeometry.expanded(usable: CGRect(x: 0, y: 0, width: 5120, height: 1440), count: 20, current: 0)
    expect("Strip: at most nine items are visible", many.items.count == 9 && many.items.first?.index == 0)
    let first = eight.items[0].frame
    expect("Strip: item hit-testing, gaps between items hit nothing",
           ZoneStripGeometry.item(at: CGPoint(x: first.midX, y: first.midY), in: eight) == 0
               && ZoneStripGeometry.item(at: CGPoint(x: first.maxX + 3, y: first.midY), in: eight) == nil)
    let inMargin = CGPoint(x: eight.body.midX, y: eight.body.minY - 8)
    expect("Strip: the transparent 16 pt margin is not part of the hit area",
           eight.panel.contains(inMargin)
               && !ZoneStripGeometry.inside(inMargin, expanded: true, usable: usable, count: 8, current: 2))
    let pill = ZoneStripGeometry.pillSize(textWidth: 150, usableWidth: usable.width)
    let pillRect = ZoneStripGeometry.collapsed(usable: usable, pill: pill).body
    expect("Strip: the pill fits its picture, text and chevron, legibly tall",
           pill.width == 12 + 26 + 8 + 150 + 8 + 10 + 12 && pill.height >= 24 && abs(pillRect.midX - usable.midX) <= 0.5)
    expect("Strip: a long name never makes the pill wider than the display",
           ZoneStripGeometry.pillSize(textWidth: 5000, usableWidth: 800).width <= 800 - 2 * 16)
    expect("Strip: the collapsed hit area is the pill itself",
           ZoneStripGeometry.inside(CGPoint(x: pillRect.minX + 2, y: pillRect.midY), expanded: false, usable: usable,
                                    count: 8, current: 2, pill: pill)
               && !ZoneStripGeometry.inside(CGPoint(x: pillRect.minX - 2, y: pillRect.midY), expanded: false, usable: usable,
                                            count: 8, current: 2, pill: pill))
    let onGrip = CGPoint(x: grip.body.midX, y: grip.body.midY)
    expect("Strip: the collapsed grip never suspends zone picking (top-edge zones stay reachable)",
           ZoneStripGeometry.inside(onGrip, expanded: false, usable: usable, count: 8, current: 2)
               && !ZoneStripGeometry.suspendsPicking(onGrip, expanded: false, usable: usable, count: 8, current: 2))
    expect("Strip: inside the expanded strip picking is suspended, outside it is not",
           ZoneStripGeometry.suspendsPicking(CGPoint(x: first.midX, y: first.midY), expanded: true, usable: usable, count: 8, current: 2)
               && !ZoneStripGeometry.suspendsPicking(CGPoint(x: 700, y: 400), expanded: true, usable: usable, count: 8, current: 2))

    var d = ZoneStripDwell()
    expect("Dwell: entering an item starts its progress at once", d.update(item: 3, now: 0, current: 0) == .progress(item: 3, fraction: 0))
    expect("Dwell: progress grows with time", d.update(item: 3, now: 0.175, current: 0) == .progress(item: 3, fraction: 0.5))
    expect("Dwell: switches after 350 ms", d.update(item: 3, now: 0.36, current: 0) == .switchTo(3))
    expect("Dwell: does not fire again while the cursor stays on that item", d.update(item: 3, now: 1.0, current: 0) == .idle)
    d.reset()
    expect("Dwell: the current layout never fires", d.update(item: 0, now: 0, current: 0) == .idle
               && d.update(item: 0, now: 1, current: 0) == .idle)
    d.reset()
    _ = d.update(item: 1, now: 0, current: 0)
    expect("Dwell: moving to another item waits the hysteresis, nothing fires meanwhile",
           d.update(item: 2, now: 0.30, current: 0) == .idle && d.update(item: 2, now: 0.36, current: 0) == .idle
               && d.hovered == 1)
    expect("Dwell: after the hysteresis the new item starts from zero",
           d.update(item: 2, now: 0.41, current: 0) == .progress(item: 2, fraction: 0) && d.hovered == 2)
    expect("Dwell: a brief crossing back keeps the hovered item", d.update(item: 1, now: 0.45, current: 0) == .idle
               && d.update(item: 2, now: 0.48, current: 0) == .progress(item: 2, fraction: (0.48 - 0.41) / 0.35))
    d.reset()
    _ = d.update(item: 4, now: 0, current: 0)
    _ = d.update(item: 4, now: 0.4, current: 0)
    _ = d.update(item: nil, now: 0.5, current: 4)
    _ = d.update(item: nil, now: 0.65, current: 4)
    _ = d.update(item: 5, now: 0.70, current: 4)
    expect("Dwell: leaving the item that fired re-arms it",
           d.update(item: 5, now: 0.80, current: 4) == .progress(item: 5, fraction: (0.80 - 0.70) / 0.35))
    d.reset()
    _ = d.update(item: 6, now: 0, current: 0)
    d.reset()
    expect("Dwell: leaving the strip (reset) cancels the dwell", d.hovered == nil && d.update(item: nil, now: 1, current: 0) == .idle)
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

    for (label, input, count) in [("missing IDs", Data(old.utf8), 1),
                                  ("an empty layout list", Data(#"{"layouts":[]}"#.utf8), 8)] {
        let path = root.appendingPathComponent("repair-\(count).json")
        try input.write(to: path)
        let readOnly = try ZonesStore(fileURL: path, readOnly: true)
        let edit = try ZonesStore(fileURL: path)
        let diskBeforeEdit = try Data(contentsOf: path)
        expect("Reopening \(label) preserves repaired layout and zone IDs without writing", readOnly.state == edit.state && diskBeforeEdit == input)
        let layoutID = readOnly.state.layouts[0].id
        let selected = try edit.setActiveLayout(layoutID, forDisplay: "external-display")
        expect("Settings can select the repaired ID after reopening \(label)", selected && edit.layout(forDisplay: "external-display")?.id == layoutID)
        var renamed = readOnly.state
        renamed.layouts[0].name = "Renamed"
        let mergeTarget = try ZonesStore(fileURL: path)
        try mergeTarget.saveEditorDraft(renamed, basedOn: readOnly.state)
        expect("An editor rename with \(label) preserves count and a newer assignment",
               mergeTarget.state.layouts.count == count && mergeTarget.state.layouts[0].name == "Renamed"
               && mergeTarget.layout(forDisplay: "external-display")?.id == layoutID)
    }

    let localizedTemplate = ZoneTemplates.makeLayout("two-columns", name: "Dos columnas")
    var personalized = localizedTemplate
    personalized.name = "Workspace"
    expect("Default template names follow the display language and custom names stay intact",
           ZoneTemplates.displayName(localizedTemplate, localizedWith: { english, _ in english }) == "Two columns"
           && ZoneTemplates.displayName(personalized, localizedWith: { _, spanish in spanish }) == "Workspace")

    // The explicit IDs were assigned on a previous load, then moved to another index in the JSON.
    let explicitLayout = zoneStorageID(kind: 1, layout: 0)
    let explicitZone = zoneStorageID(kind: 2, layout: 0, zone: 0)
    let mixed = """
    {"defaultLayout":"\(explicitLayout)","activeByDisplay":{"kept":"\(explicitLayout)"},
     "layouts":[{"name":"Missing ID","zones":[{"rect":{"x":0,"y":0,"w":0.5,"h":1}},
                  {"id":"\(explicitZone)","rect":{"x":0.5,"y":0,"w":0.5,"h":1}}]},
                {"id":"\(explicitLayout)","name":"Explicit ID"}]}
    """
    let mixedURL = root.appendingPathComponent("mixed.json")
    try Data(mixed.utf8).write(to: mixedURL)
    let mixedPreview = try ZonesStore(fileURL: mixedURL, readOnly: true)
    let mixedEditable = try ZonesStore(fileURL: mixedURL)
    let mixedLayouts = mixedEditable.state.layouts
    expect("Explicit layout IDs and assignments survive a collision with an earlier missing ID",
           mixedLayouts.count == 2 && mixedLayouts[0].id != explicitLayout && mixedLayouts[1].id == explicitLayout
           && mixedEditable.layout(forDisplay: "kept")?.name == "Explicit ID")
    let mixedZones = mixedLayouts[0].zones
    expect("Explicit zone IDs survive a collision with an earlier missing ID",
           mixedZones.count == 2 && mixedZones[0].id != explicitZone && mixedZones[1].id == explicitZone
           && mixedZones[0].rect.x == 0 && mixedZones[1].rect.x == 0.5)
    expect("Mixed repaired IDs are stable before the first write", mixedPreview.state == mixedEditable.state)
    let assignedMixed = try mixedEditable.setActiveLayout(mixedLayouts[0].id, forDisplay: "new")
    let roundTripped = try ZonesStore(fileURL: mixedURL, readOnly: true)
    expect("Saving and reopening mixed IDs preserves every layout and zone",
           assignedMixed && roundTripped.state == mixedEditable.state
           && roundTripped.state.layouts.count == 2 && roundTripped.state.layouts[0].zones.count == 2)

    var customSpanish = ZoneTemplates.makeLayout("two-columns", name: "Dos columnas")
    customSpanish.rename(to: "Dos columnas")
    let renamedTemplate = try JSONDecoder().decode(ZoneLayout.self, from: JSONEncoder().encode(customSpanish))
    expect("Explicitly renaming a template to its Spanish label survives reload and English display",
           renamedTemplate.isNameCustomized == true
           && ZoneTemplates.displayName(renamedTemplate, localizedWith: { english, _ in english }) == "Dos columnas")

    let broken = Data("invalid JSON".utf8)
    try broken.write(to: url)
    let recovered = try ZonesStore(fileURL: url)
    let backup = url.appendingPathExtension("bad")
    let backupData = try Data(contentsOf: backup)
    let reloaded = try ZonesStore(fileURL: url)
    expect("Corrupt JSON is preserved as .bad before seeding", backupData == broken && reloaded.state == recovered.state)

    let directoryBackupURL = root.appendingPathComponent("directory-backup.json")
    try broken.write(to: directoryBackupURL)
    let directoryBackup = directoryBackupURL.appendingPathExtension("bad")
    try fm.createDirectory(at: directoryBackup, withIntermediateDirectories: false)
    let prior = directoryBackup.appendingPathComponent("previous-backup.json")
    try Data("keep this".utf8).write(to: prior)
    let dangling = directoryBackupURL.appendingPathExtension("bad.1")
    let missingTarget = root.appendingPathComponent("missing").path
    try fm.createSymbolicLink(atPath: dangling.path, withDestinationPath: missingTarget)
    let recoveredAgain = try ZonesStore(fileURL: directoryBackupURL)
    let preservedPrior = try Data(contentsOf: prior)
    let preservedLink = try fm.destinationOfSymbolicLink(atPath: dangling.path)
    let freshBackup = try Data(contentsOf: directoryBackupURL.appendingPathExtension("bad.2"))
    expect("Recovery skips existing files, directories and dangling links without deleting any backup",
           recoveredAgain.recoveryError == nil && preservedPrior == Data("keep this".utf8)
           && preservedLink == missingTarget && freshBackup == broken)

}

do {
    try checkStore()
} catch {
    expect("Store persistence", false, "\(error)")
}

print("\(passes) PASS, \(failures) FAIL")
exit(failures == 0 ? 0 : 1)

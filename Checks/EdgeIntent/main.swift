import Foundation

var failures = 0
func check(_ ok: Bool, _ name: String) {
    if !ok { failures += 1; print("FAIL \(name)") }
}

let c = EdgeIntent.Config()
let screen = EdgeIntent.Rect(x: 0, y: 0, w: 1000, h: 800)
let poll = 0.03
let moveStep = 0.008

func input(_ t: Double, x: Double = 500, y: Double = 0, hard: Bool = true, buttons: Int = 0,
           drag: Bool = false, targets: Bool = false, press: Double? = nil) -> EdgeIntent.Input {
    .init(now: t, x: x, y: y, screen: screen, hardEdge: hard, buttons: buttons,
          dragSession: drag, dropTargets: targets, lastPressAt: press)
}

/// Polls every 30 ms from `from` while `t < to`; returns the first time `reveal` was true, if any.
func polls(_ s: inout EdgeIntent.State, from: Double, to: Double, _ make: (Double) -> EdgeIntent.Input) -> Double? {
    var t = from
    while t < to - 1e-9 {
        if EdgeIntent.reveal(&s, make(t), c) { return t }
        t += poll
    }
    return nil
}

func move(_ s: inout EdgeIntent.State, _ t: Double, dx: Double, dy: Double, x: Double = 500, y: Double = 0,
          hard: Bool = true, buttons: Int = 0) {
    EdgeIntent.noteMove(&s, .init(t: t, x: x, y: y, dx: dx, dyDown: dy), screen: screen, hardEdge: hard, buttons: buttons, c)
}

/// Interleaves 8 ms moves with 30 ms polls from 0 while `t < to`; returns the first reveal time.
func pushing(_ s: inout EdgeIntent.State, to: Double, dx: Double, dy: Double, hard: Bool = true) -> Double? {
    var nextPoll = 0.0, nextMove = 0.0
    while min(nextPoll, nextMove) < to - 1e-9 {
        if nextMove <= nextPoll {
            move(&s, nextMove, dx: dx, dy: dy, hard: hard); nextMove += moveStep
        } else {
            if EdgeIntent.reveal(&s, input(nextPoll, hard: hard), c) { return nextPoll }
            nextPoll += poll
        }
    }
    return nil
}

// Graze: touch the edge for up to 0.12 s and leave: never reveals.
do {
    var s = EdgeIntent.State()
    check(polls(&s, from: 0, to: 0.12, { input($0) }) == nil, "graze in band")
    check(polls(&s, from: 0.12, to: 1.0, { input($0, y: 40) }) == nil, "graze then leave")
}
// Resting 0.2 s then leaving: no.
do {
    var s = EdgeIntent.State()
    check(polls(&s, from: 0, to: 0.2, { input($0) }) == nil, "rest 0.2 s")
    check(polls(&s, from: 0.2, to: 1.0, { input($0, y: 30) }) == nil, "rest 0.2 s then leave")
}
// Dwell: still pointer reveals at 0.25 s, not before.
do {
    var s = EdgeIntent.State()
    _ = EdgeIntent.reveal(&s, input(0), c)
    check(!EdgeIntent.reveal(&s, input(0.24, hard: false), c), "dwell false at 0.24")
    check(EdgeIntent.reveal(&s, input(0.26, hard: false), c), "dwell true at 0.26")
}
// ±1.5 pt jitter around the spot where the pointer landed still counts as resting (tolerance is from the anchor).
do {
    var s = EdgeIntent.State()
    let jitter: (Double) -> Double = { t in
        let n = Int((t / poll).rounded()); return n == 0 ? 500 : (n % 2 == 0 ? 501.5 : 498.5)
    }
    let r = polls(&s, from: 0, to: 0.5, { input($0, x: jitter($0), hard: false) })
    check(r != nil && r! >= 0.25 && r! < 0.3, "jitter still reveals")
}
// A 3 pt move at 0.20 restarts the dwell: nothing until 0.45.
do {
    var s = EdgeIntent.State()
    let r = polls(&s, from: 0, to: 1.0, { input($0, x: $0 >= 0.2 - 1e-9 ? 503 : 500, hard: false) })
    check(r != nil && r! >= 0.45 - 1e-9, "3 pt move restarts dwell")
}
// Push: straight down against a hard edge reveals by 0.12 s, before the dwell.
do {
    var s = EdgeIntent.State()
    let r = pushing(&s, to: 0.5, dx: 0, dy: 3)
    check(r != nil && r! <= 0.12 + 1e-9 && r! < c.dwell, "push reveals by 0.12")
}
// A push at an angle (dx 3, dy 1 = 72 degrees) never counts.
do {
    var s = EdgeIntent.State()
    _ = pushing(&s, to: 0.2, dx: 3, dy: 1)
    check(!EdgeIntent.pushSatisfied(s, 0.2, c), "angled push not satisfied")
    // and x moves 3 pt per event, so the dwell keeps restarting too
    var s2 = EdgeIntent.State(); var x = 500.0; var t = 0.0; var revealed = false
    while t < 1.0 { move(&s2, t, dx: 3, dy: 1, x: x); if EdgeIntent.reveal(&s2, input(t, x: x), c) { revealed = true }; x += 3; t += moveStep }
    check(!revealed, "angled push never reveals")
}
// A slightly slanted push drifts sideways (moving the dwell anchor) and still opens; a 30 degree one never does.
func slanted(_ degrees: Double, to: Double) -> (first: Double?, pushEver: Bool) {
    var s = EdgeIntent.State()
    let dy = 4.0, dx = dy * tan(degrees * .pi / 180)
    var x = 500.0, nextPoll = 0.0, nextMove = 0.0, pushEver = false
    while min(nextPoll, nextMove) < to - 1e-9 {
        if nextMove <= nextPoll {
            move(&s, nextMove, dx: dx, dy: dy, x: x); x += dx; nextMove += moveStep
        } else {
            if EdgeIntent.pushSatisfied(s, nextPoll, c) { pushEver = true }
            if EdgeIntent.reveal(&s, input(nextPoll, x: x), c) { return (nextPoll, pushEver) }
            nextPoll += poll
        }
    }
    return (nil, pushEver)
}
do {
    for deg in [7.0, 14.0, 20.0] {
        let r = slanted(deg, to: 0.4)
        check(r.first != nil && r.first! <= 0.15 + 1e-9, "\(Int(deg)) degree push opens by 0.15")
    }
    let steep = slanted(30, to: 1.0)
    check(steep.first == nil && !steep.pushEver, "30 degree push never opens")
}
// A 150 ms gap restarts the push.
do {
    var s = EdgeIntent.State()
    var t = 0.0
    while t < 0.06 { move(&s, t, dx: 0, dy: 3); t += moveStep }
    t += 0.15
    move(&s, t, dx: 0, dy: 3); move(&s, t + moveStep, dx: 0, dy: 3)
    check(!EdgeIntent.pushSatisfied(s, t + moveStep, c), "push gap 150 ms not satisfied")
    check(s.pushStart == t, "push gap restarts start")
}
// Overshoot: two big flicks then leave: never.
do {
    var s = EdgeIntent.State()
    _ = EdgeIntent.reveal(&s, input(0), c)
    move(&s, 0.0, dx: 0, dy: 40); move(&s, 0.008, dx: 0, dy: 40)
    check(s.pushDown == 12, "per-event cap")
    check(!EdgeIntent.reveal(&s, input(0.03), c), "overshoot in band")
    check(polls(&s, from: 0.06, to: 1.0, { input($0, y: 50) }) == nil, "overshoot then leave")
}
// Soft edge (another display below): push is ignored, only the dwell reveals.
do {
    var s = EdgeIntent.State()
    let r = pushing(&s, to: 0.5, dx: 0, dy: 3, hard: false)
    check(r != nil && r! >= c.dwell, "soft edge only dwell")
}
// isHardBottom.
do {
    let below = EdgeIntent.Rect(x: 0, y: -800, w: 1000, h: 800)
    let side = EdgeIntent.Rect(x: 1000, y: 0, w: 1000, h: 800)
    let partial = EdgeIntent.Rect(x: 600, y: -600, w: 800, h: 600)
    check(!EdgeIntent.isHardBottom(screen: screen, others: [below], x: 500), "stacked is soft")
    check(EdgeIntent.isHardBottom(screen: screen, others: [side], x: 500), "side by side is hard")
    check(EdgeIntent.isHardBottom(screen: screen, others: [], x: 500), "single screen is hard")
    check(EdgeIntent.isHardBottom(screen: screen, others: [partial], x: 300), "partial overlap: outside is hard")
    check(!EdgeIntent.isHardBottom(screen: screen, others: [partial], x: 700), "partial overlap: inside is soft")
    check(EdgeIntent.isHardBottom(screen: screen, others: [partial], x: 1400), "partial overlap: right edge exclusive")
}
// Fast horizontal sweep along the edge for 2 s: never.
do {
    var s = EdgeIntent.State()
    check(polls(&s, from: 0, to: 2.0, { input($0, x: 20 * ($0 / poll).rounded()) }) == nil, "fast horizontal never")
}
// Button held 2 s: never; released in band: still never; leave and come back: reveals after the dwell.
do {
    var s = EdgeIntent.State()
    check(polls(&s, from: 0, to: 2.0, { input($0, buttons: 1) }) == nil, "button held never")
    check(polls(&s, from: 2.0, to: 3.0, { input($0) }) == nil, "released in band still never")
    check(polls(&s, from: 3.0, to: 3.1, { input($0, y: 20) }) == nil, "left band")
    let r = polls(&s, from: 3.1, to: 4.0, { input($0) })
    check(r != nil && r! >= 3.1 + c.dwell - 1e-9, "re-enter reveals after dwell")
}
// A click at the edge (press after entering the band): never until leaving and coming back.
do {
    var s = EdgeIntent.State()
    _ = EdgeIntent.reveal(&s, input(0), c)
    check(polls(&s, from: 0.03, to: 2.0, { input($0, press: 0.02) }) == nil, "click at edge never")
    _ = EdgeIntent.reveal(&s, input(2.0, y: 30, press: 0.02), c)
    let r = polls(&s, from: 2.03, to: 3.0, { input($0, press: 0.02) })
    check(r != nil && r! >= 2.03 + c.dwell - 1e-9, "click at edge re-arms after leave")
    // a press before entering the band does not disarm
    var s2 = EdgeIntent.State()
    check(polls(&s2, from: 1.0, to: 2.0, { input($0, press: 0.5) }) != nil, "earlier press does not disarm")
}
// Drag: without drop targets never; with them after the drag dwell.
do {
    var s = EdgeIntent.State()
    check(polls(&s, from: 0, to: 2.0, { input($0, buttons: 1, drag: true, targets: false) }) == nil, "drag without targets never")
    var s2 = EdgeIntent.State()
    _ = EdgeIntent.reveal(&s2, input(0, buttons: 1, drag: true, targets: true), c)
    check(!EdgeIntent.reveal(&s2, input(0.5, buttons: 1, drag: true, targets: true), c), "drag false at 0.5")
    check(EdgeIntent.reveal(&s2, input(0.61, buttons: 1, drag: true, targets: true), c), "drag true at 0.61")
}
// A bar that is out without the edge revealing it (launch, rebuild, auto-hide just turned on) gets the normal delay.
do {
    let fresh = EdgeIntent.State()
    check(EdgeIntent.hideDelay(fresh, c) == 0.5, "fresh bar normal delay")
    check(!PanelPolicy.barShouldHide(autoHide: true, barHidden: false, pointerNearBar: false, panelPinsBar: false,
                                     secondsSinceInside: 0.13, delay: EdgeIntent.hideDelay(fresh, c)), "fresh bar does not flash away")
}
// Quick hide for a bar the edge revealed but never used.
do {
    var s = EdgeIntent.State()
    EdgeIntent.didShow(&s, now: 10)
    let d = EdgeIntent.hideDelay(s, c)
    check(d == 0.12, "unengaged hide delay")
    check(PanelPolicy.barShouldHide(autoHide: true, barHidden: false, pointerNearBar: false, panelPinsBar: false, secondsSinceInside: 0.13, delay: d), "quick hide at 0.13")
    check(!PanelPolicy.barShouldHide(autoHide: true, barHidden: false, pointerNearBar: false, panelPinsBar: false, secondsSinceInside: 0.10, delay: d), "no quick hide at 0.10")
    EdgeIntent.noteInside(&s, dt: 0.15, c)
    check(!s.engaged, "0.15 s inside not engaged")
    EdgeIntent.noteInside(&s, dt: 0.15, c)
    check(s.engaged && EdgeIntent.hideDelay(s, c) == 0.5, "0.3 s inside engaged")
    var p = EdgeIntent.State(); EdgeIntent.didShow(&p, now: 0)
    p.engaged = true // a press on the bar
    check(EdgeIntent.hideDelay(p, c) == 0.5, "press engages")
    EdgeIntent.didHide(&s)
    check(!s.engaged && s.inside == 0 && s.anchorT == nil && s.revealedAt == nil, "didHide resets")
    check(EdgeIntent.hideDelay(s, c) == 0.5, "hidden-then-reset bar gets the normal delay")
    EdgeIntent.didShow(&p, now: 1)
    check(!p.engaged && p.revealedAt == 1, "didShow resets engagement")
}
// A pinned bar never hides, even with the quick delay, and pinning engages it.
do {
    check(!PanelPolicy.barShouldHide(autoHide: true, barHidden: false, pointerNearBar: false, panelPinsBar: true, secondsSinceInside: 99, delay: c.quickHide), "pinned never hides")
    var s = EdgeIntent.State(); EdgeIntent.didShow(&s, now: 0)
    if PanelPolicy.keepsBarVisible(panelOpen: true, panelBarIsThisBar: true) { s.engaged = true } // as BarController.tick
    check(EdgeIntent.hideDelay(s, c) == 0.5, "pinned engages")
}
// Leaving the screen's x range (or the band) resets disarmed.
do {
    var s = EdgeIntent.State()
    _ = EdgeIntent.reveal(&s, input(0, buttons: 1), c)
    check(s.disarmed, "button disarms")
    check(!EdgeIntent.reveal(&s, input(0.03, x: 1200), c), "out of x range")
    check(!s.disarmed && s.anchorT == nil, "out of range resets disarmed")
    check(!EdgeIntent.reveal(&s, input(0.06, y: -5), c), "below the screen is not in band")
    var b = EdgeIntent.State()
    _ = EdgeIntent.reveal(&b, input(0, y: 1), c)
    check(EdgeIntent.reveal(&b, input(0.26, y: 2), c), "band covers minY + 2")
    check(!EdgeIntent.reveal(&b, input(0.29, y: 2.5), c) && b.anchorT == nil, "minY + 2.5 is out of band")
}

if failures > 0 { print("\(failures) edge intent check(s) failed"); exit(1) }
print("edge intent checks passed")

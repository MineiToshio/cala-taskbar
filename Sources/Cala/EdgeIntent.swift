import Foundation

/// Whether the pointer at the bottom screen edge means "show me the auto-hidden bar". Pure on purpose: no AppKit, so
/// `scripts/check-edge-intent.sh` can run it. Touching the edge is not enough: the pointer has to rest there (dwell)
/// or keep pushing down against a hard edge (push). A held button, a click there or a fast horizontal sweep never
/// reveals. Once shown, a bar the pointer never really used (engaged) hides quickly; a used one waits the usual delay.
///
/// Times are seconds of `ProcessInfo.processInfo.systemUptime`, the same clock as `NSEvent.timestamp`.
/// Coordinates are screen points with a bottom-left origin (y grows upward), like `NSScreen.frame`.
enum EdgeIntent {
    struct Rect: Equatable {
        var minX, minY, maxX, maxY: Double
        init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
            self.minX = minX; self.minY = minY; self.maxX = maxX; self.maxY = maxY
        }
        init(x: Double, y: Double, w: Double, h: Double) { self.init(minX: x, minY: y, maxX: x + w, maxY: y + h) }
    }

    struct Config {
        /// The pointer is in the edge band iff 0 <= y - screen.minY <= band. 2 pt: at the edge mouseLocation.y can
        /// read minY or minY + 1.
        var band = 2.0
        /// Horizontal drift (pt) that still counts as resting at the same spot.
        var anchorTolerance = 2.0
        /// Resting this long at the edge reveals.
        var dwell = 0.25
        /// Pushing down against a hard edge for this long reveals (before the dwell).
        var pushTime = 0.10
        /// A pause longer than this between moves starts the push over.
        var pushMaxGap = 0.10
        /// A push must point mostly down: its angle from vertical stays under this (degrees).
        var pushMaxAngle = 25.0
        /// Minimum downward travel (pt, after the per-event cap) a push needs.
        var pushMinDown = 8.0
        /// One event counts at most this much downward travel, so a single flick cannot make a push.
        var pushStepCap = 6.0
        /// Hide delay for a bar the edge revealed but the pointer never used.
        var quickHide = 0.12
        /// Hide delay for a bar the pointer used.
        var hideDelay = 0.5
        /// Seconds over the bar after which it counts as used.
        var engageTime = 0.3
        /// Dwell while dragging something the bar could take.
        var dragDwell = 0.6
    }

    struct State {
        var anchorX = 0.0
        var anchorT: TimeInterval?
        /// Set by a held button or a click in the band; cleared only by leaving the band.
        var disarmed = false
        var pushStart: TimeInterval?
        var pushLast: TimeInterval?
        var pushDown = 0.0
        var pushAlong = 0.0
        var revealedAt: TimeInterval?
        /// Seconds the pointer spent over the shown bar.
        var inside: TimeInterval = 0
        var engaged = false
    }

    struct Input {
        var now: TimeInterval
        var x: Double
        var y: Double
        var screen: Rect
        /// No other display continues below this point of the bottom edge, so the cursor stops there.
        var hardEdge: Bool
        /// `NSEvent.pressedMouseButtons`.
        var buttons: Int
        var dragSession: Bool
        var dropTargets: Bool
        var lastPressAt: TimeInterval?
    }

    /// One mouse-moved event. `dyDown` is the raw device delta, positive downward; it keeps coming while the cursor
    /// is clamped at the edge, which is what makes a push measurable.
    struct Move {
        var t: TimeInterval
        var x: Double
        var y: Double
        var dx: Double
        var dyDown: Double
    }

    static func inBand(x: Double, y: Double, _ screen: Rect, _ c: Config) -> Bool {
        x >= screen.minX && x < screen.maxX && y >= screen.minY && y - screen.minY <= c.band
    }

    /// Called every poll for a hidden bar. True means reveal now.
    static func reveal(_ s: inout State, _ i: Input, _ c: Config) -> Bool {
        guard inBand(x: i.x, y: i.y, i.screen, c) else {
            resetReveal(&s)
            return false
        }
        if s.anchorT == nil { anchor(&s, i.x, i.now) }
        if i.buttons != 0 {
            if i.dragSession && i.dropTargets { return dwelled(&s, i, c.dragDwell, c) }
            s.disarmed = true
            return false
        }
        if let press = i.lastPressAt, let since = s.anchorT, press >= since { s.disarmed = true }
        if s.disarmed { return false }
        return dwelled(&s, i, c.dwell, c) || (i.hardEdge && pushSatisfied(s, i.now, c))
    }

    /// Called for each mouse-moved event over a hidden bar's screen.
    static func noteMove(_ s: inout State, _ m: Move, screen: Rect, hardEdge: Bool, buttons: Int, _ c: Config) {
        guard inBand(x: m.x, y: m.y, screen, c), hardEdge, buttons == 0 else {
            clearPush(&s)
            return
        }
        let continuing = s.pushStart != nil && s.pushLast.map { m.t - $0 <= c.pushMaxGap } == true
        if !continuing {
            clearPush(&s)
            s.pushStart = m.t
        }
        s.pushDown += min(max(m.dyDown, 0), c.pushStepCap)
        s.pushAlong += abs(m.dx)
        s.pushLast = m.t
        if atan2(s.pushAlong, s.pushDown) * 180 / .pi > c.pushMaxAngle {
            clearPush(&s)
            s.pushStart = m.t
            s.pushLast = m.t
        }
    }

    static func pushSatisfied(_ s: State, _ now: TimeInterval, _ c: Config) -> Bool {
        guard let start = s.pushStart, let last = s.pushLast else { return false }
        return now - last <= c.pushMaxGap && last - start >= c.pushTime && s.pushDown >= c.pushMinDown
    }

    /// Time the pointer spends over the shown bar; enough of it makes the bar "used".
    static func noteInside(_ s: inout State, dt: TimeInterval, _ c: Config) {
        s.inside += max(dt, 0)
        if s.inside >= c.engageTime { s.engaged = true }
    }

    /// Quick only for a bar the edge revealed and nobody used; a bar shown at launch, after a rebuild or because
    /// auto-hide was just turned on gets the normal delay.
    static func hideDelay(_ s: State, _ c: Config) -> TimeInterval {
        s.revealedAt != nil && !s.engaged ? c.quickHide : c.hideDelay
    }

    static func didShow(_ s: inout State, now: TimeInterval) {
        resetReveal(&s)
        s.revealedAt = now
        s.inside = 0
        s.engaged = false
    }

    static func didHide(_ s: inout State) { s = State() }

    /// The bottom edge at `x` stops the cursor unless another display sits right below it there.
    static func isHardBottom(screen: Rect, others: [Rect], x: Double) -> Bool {
        !others.contains { abs($0.maxY - screen.minY) <= 1 && $0.minX <= x && x < $0.maxX }
    }

    private static func dwelled(_ s: inout State, _ i: Input, _ dwell: TimeInterval, _ c: Config) -> Bool {
        if abs(i.x - s.anchorX) > c.anchorTolerance { anchor(&s, i.x, i.now) }
        guard let since = s.anchorT else { return false }
        return i.now - since >= dwell
    }

    /// Moving the dwell anchor leaves the push alone: a push drifts sideways a little, and noteMove already rejects
    /// pushes that are too slanted or paused; leaving the band clears it (resetReveal).
    private static func anchor(_ s: inout State, _ x: Double, _ t: TimeInterval) {
        s.anchorX = x
        s.anchorT = t
    }

    private static func clearPush(_ s: inout State) {
        s.pushStart = nil; s.pushLast = nil; s.pushDown = 0; s.pushAlong = 0
    }

    private static func resetReveal(_ s: inout State) {
        s.anchorX = 0; s.anchorT = nil; s.disarmed = false
        clearPush(&s)
    }
}

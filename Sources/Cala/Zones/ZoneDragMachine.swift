import Foundation
import CoreGraphics

extension ZoneActivation {
    /// Unknown config values fall back to `both`, so Shift always works.
    init(config: String) { self = ZoneActivation(rawValue: config) ?? .both }
    var allowsRightClick: Bool { self != .shift }
    var allowsShift: Bool { self != .rightClick }
}

/// The drag-tap state machine. Pure and O(1) per event: the tap callback runs it under a lock.
/// Points are CG global coordinates (top-left origin), exactly as the mouse events carry them.
///
///     idle --leftDown--> pressed(gen)                     [worker: window under the point]
///     pressed --confirmDrag(gen)--> dragging              [worker saw an eligible window move]
///     dragging --rightDown--> SWALLOW, toggle right-click mode (its rightUp is swallowed too)
///     dragging --Shift in the event flags--> Shift mode while held
///     dragging --reject(gen)--> idle                     [worker: the moving window cannot be placed]
///     any --leftUp--> idle (the leftUp always passes; the release of a confirmed drag is reported,
///                           even after a cancel, so a drag-out restore can still finish on mouse-up)
///     any --cancel--> idle
struct ZoneDragMachine {
    enum Phase: Equatable { case idle, pressed, dragging }

    struct Release: Equatable {
        var generation: UInt64
        var point: CGPoint
        var zonesMode: Bool
        var command: Bool
    }

    private(set) var phase: Phase = .idle
    private(set) var generation: UInt64 = 0
    private(set) var rightToggle = false
    private(set) var shift = false
    private(set) var command = false
    private(set) var point: CGPoint = .zero
    /// The right button's down was swallowed, so its up must be swallowed too (no orphan up for the app).
    private(set) var swallowRightUp = false
    /// The current press was confirmed as a window drag (survives cancel, cleared by reject and the next press).
    private(set) var confirmed = false
    /// A detached window can still snap while this release is current.
    private(set) var snapReleaseGeneration: UInt64?
    var activation: ZoneActivation = .both
    /// True while drags must be ignored (the zones editor is open).
    var ignoring = false {
        didSet { if ignoring { cancel(resetButtons: false) } }
    }

    var zonesMode: Bool {
        phase == .dragging && ((activation.allowsRightClick && rightToggle) || (activation.allowsShift && shift))
    }

    init(generation: UInt64 = 0) { self.generation = generation }

    /// Returns the generation the worker must probe, or nil when the press is ignored.
    mutating func leftDown(at p: CGPoint, shift: Bool, command: Bool) -> UInt64? {
        generation &+= 1
        rightToggle = false
        confirmed = false
        snapReleaseGeneration = nil
        self.shift = shift
        self.command = command
        point = p
        guard !ignoring else { phase = .idle; return nil }
        phase = .pressed
        return generation
    }

    /// Returns true when the worker should look for a moving window.
    mutating func leftDragged(to p: CGPoint, shift: Bool, command: Bool) -> Bool {
        point = p
        self.shift = shift
        self.command = command
        return phase == .pressed
    }

    /// The leftUp itself always reaches the system. A confirmed drag reports its release.
    mutating func leftUp(at p: CGPoint, shift: Bool, command: Bool) -> Release? {
        point = p
        self.shift = shift
        self.command = command
        defer { phase = .idle; rightToggle = false; confirmed = false }
        guard confirmed else { return nil }
        let snap = zonesMode
        snapReleaseGeneration = snap ? generation : nil
        return Release(generation: generation, point: p, zonesMode: snap, command: command)
    }

    /// Returns true when the event must be swallowed during a confirmed window drag.
    mutating func rightDown() -> Bool {
        guard phase == .dragging, activation.allowsRightClick else {
            // This down reaches the app, so its up must too. A pending flag here is stale: its up was lost
            // upstream (remappers, a Bluetooth drop, two mice) and would otherwise eat this click's up.
            swallowRightUp = false
            return false
        }
        rightToggle.toggle()
        swallowRightUp = true
        return true
    }

    mutating func rightUp() -> Bool {
        defer { swallowRightUp = false }
        return swallowRightUp
    }

    /// A worker result for an older press never promotes a newer one.
    mutating func confirmDrag(generation gen: UInt64) -> Bool {
        guard isPending(generation: gen) else { return false }
        phase = .dragging
        confirmed = true
        return true
    }

    func isPending(generation gen: UInt64) -> Bool {
        phase == .pressed && generation == gen
    }

    /// Ends an unfinished probe (including tab adoption or AppKit validation), even if mouse-up was missed.
    mutating func endPending(generation gen: UInt64) -> Bool {
        guard isPending(generation: gen) else { return false }
        phase = .idle
        return true
    }

    mutating func endSnapRelease(generation gen: UInt64) {
        if snapReleaseGeneration == gen { snapReleaseGeneration = nil }
    }

    /// The worker could not resolve or place the confirmed window: back to idle without a snap. A swallowed
    /// right down keeps its pending up, so the app still never sees an orphan up.
    mutating func reject(generation gen: UInt64) -> Bool {
        guard generation == gen, confirmed else { return false }
        phase = .idle
        rightToggle = false
        confirmed = false
        return true
    }

    /// Back to idle. `resetButtons` also forgets a pending swallowed rightUp (used after the tap was
    /// disabled, when that up may have been missed and would otherwise eat a later one).
    mutating func cancel(resetButtons: Bool) {
        phase = .idle
        rightToggle = false
        snapReleaseGeneration = nil
        if resetButtons { swallowRightUp = false }
    }
}

/// Window observations used by the worker while the tap is still in the pressed phase.
struct ZoneDragCandidate {
    struct Window {
        let key: ZoneRestore.WindowKey
        let frame: CGRect
    }

    static func windowIDArray(_ id: CGWindowID) -> CFArray {
        // Core Graphics reads the array slots as raw CGWindowIDs, so use no object callbacks.
        var value = UnsafeRawPointer(bitPattern: UInt(id))
        return CFArrayCreate(nil, &value, 1, nil)
    }

    private static let recheckInterval: TimeInterval = 0.04
    private static let cursorSlack: CGFloat = 20
    private static let tabBandHeight: CGFloat = 64
    private static let tabDetachBundles: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "org.chromium.Chromium",
    ]

    let original: Window
    private let initialTabWindowIDs: Set<CGWindowID>?
    private var lastPoint: CGPoint
    private var nextCheck: TimeInterval = 0
    private var previous: [CGWindowID: CGRect] = [:]

    init(original: Window, point: CGPoint, initialTabWindowIDs: Set<CGWindowID>? = nil) {
        self.original = original
        self.initialTabWindowIDs = initialTabWindowIDs
        self.lastPoint = point
    }

    /// Estimate the tab strip without querying AX during a drag. Look up the app only inside this band.
    static func mayDetachTab(at point: CGPoint, in frame: CGRect, bundleID: @autoclosure () -> String) -> Bool {
        tabBand(of: frame).contains(point) && tabDetachBundles.contains(bundleID())
    }

    private static func tabBand(of frame: CGRect) -> CGRect {
        CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: min(tabBandHeight, frame.height))
    }

    func originalMoved(to frame: CGRect?) -> Bool {
        frame.map { ZoneWindowFit.isMove(from: original.frame, to: $0) } ?? false
    }

    /// Take at most one full window-list sample every 40 ms, and only on cursor movement.
    func shouldRecheck(at point: CGPoint, time: TimeInterval) -> Bool {
        initialTabWindowIDs != nil && time >= nextCheck && hypot(point.x - lastPoint.x, point.y - lastPoint.y) >= 3
    }

    /// Adopt only a unique new window whose tab band follows the cursor at a stable size.
    mutating func recheck(windows: [Window], at point: CGPoint, time: TimeInterval) -> Window? {
        guard let initialTabWindowIDs else { return nil }
        let dx = point.x - lastPoint.x
        let dy = point.y - lastPoint.y
        let tolerance = min(Self.cursorSlack, max(4, hypot(dx, dy) / 2))
        lastPoint = point
        nextCheck = time + Self.recheckInterval
        var observed: [CGWindowID: CGRect] = [:]
        var matches: [Window] = []
        for window in windows {
            let id = window.key.windowID
            let frame = window.frame
            guard window.key.pid == original.key.pid, id != original.key.windowID, !initialTabWindowIDs.contains(id),
                  Self.tabBand(of: frame).insetBy(dx: -Self.cursorSlack, dy: -Self.cursorSlack).contains(point)
            else { continue }
            observed[id] = frame
            guard let before = previous[id], ZoneWindowFit.isMove(from: before, to: frame) else { continue }
            let moveX = frame.minX - before.minX
            let moveY = frame.minY - before.minY
            if moveX * dx + moveY * dy > 0, hypot(moveX - dx, moveY - dy) <= tolerance {
                matches.append(window)
            }
        }
        previous = observed
        return matches.count == 1 ? matches.first : nil
    }
}

/// ⌘ span anchor: the zone chosen when ⌘ went down (or the first chosen afterwards), cleared when ⌘ is
/// released or the pointer moves to another screen.
struct ZoneSpanAnchor {
    private(set) var anchor: UUID?
    private var screen: Int?

    mutating func update(command: Bool, screen: Int?, single: UUID?) -> UUID? {
        if !command || screen != self.screen { anchor = nil }
        self.screen = screen
        if command, anchor == nil { anchor = single }
        return anchor
    }

    mutating func reset() { anchor = nil; screen = nil }
}

enum ZoneWindowFit {
    /// A drag counts as a window MOVE when the origin moved at least 3 pt and the size did not change
    /// (a size change is a resize, including left/top-edge resizes that also move the origin).
    static func isMove(from start: CGRect, to now: CGRect) -> Bool {
        hypot(now.minX - start.minX, now.minY - start.minY) >= 3
            && abs(now.width - start.width) < 1 && abs(now.height - start.height) < 1
    }

    /// Where a window of `size` goes when it cannot take the zone's size exactly: at the zone's minimum
    /// corner (top-left in AX space) when it is bigger than the zone (app minimum size), centred in the
    /// zone when `centered` and it fits (not resizable), then kept inside `usable` as far as it fits.
    static func place(size: CGSize, in target: CGRect, usable: CGRect, centered: Bool) -> CGRect {
        func axis(_ length: CGFloat, _ zoneMin: CGFloat, _ zoneLength: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
            let start = centered && length <= zoneLength ? zoneMin + (zoneLength - length) / 2 : zoneMin
            // Too big for the usable area: keep its leading edge visible.
            return length >= hi - lo ? lo : min(max(start, lo), hi - length)
        }
        return CGRect(x: axis(size.width, target.minX, target.width, usable.minX, usable.maxX),
                      y: axis(size.height, target.minY, target.height, usable.minY, usable.maxY),
                      width: size.width, height: size.height)
    }

    /// True when the app took the requested frame, allowing its own rounding (terminal cells and the like).
    static func matches(_ actual: CGRect, _ wanted: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(actual.minX - wanted.minX) <= tolerance && abs(actual.minY - wanted.minY) <= tolerance
            && abs(actual.width - wanted.width) <= tolerance && abs(actual.height - wanted.height) <= tolerance
    }
}

extension ZoneWindowFit {
    /// Drops in the menu bar, Cala's bar strip or the Dock land on the nearest zone: the picking point is clamped
    /// into the usable area (half-open on the far edges, like zone hit-testing).
    static func clampPoint(_ p: CGPoint, into usable: CGRect) -> CGPoint {
        guard usable.width > 0, usable.height > 0 else { return p }
        return CGPoint(x: min(max(p.x, usable.minX), usable.maxX - 0.5),
                       y: min(max(p.y, usable.minY), usable.maxY - 0.5))
    }
}

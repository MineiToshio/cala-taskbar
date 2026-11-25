import AppKit
import ApplicationServices
import os

/// Active mouse-only event tap for the zones drag gestures, on its own thread and run loop so main-thread
/// stalls can never delay system mouse input.
///
/// Callback rules (an active tap sits in the path of every click on the Mac):
/// - O(1): it runs `ZoneDragMachine` under an unfair lock and hands work off with `async`. No AX, no
///   CGWindowList, no logging, no file I/O.
/// - Only a right click during a confirmed window drag (and its matching up) is swallowed.
///   Every other event is returned unmodified; unknown types pass through.
/// - Disabled by timeout or user input: re-enabled at once and the gesture is cancelled, so a missed
///   leftMouseUp can never leave zones mode stuck.
final class ZoneDragTap: @unchecked Sendable {
    struct Snapshot {
        var generation: UInt64
        var zonesMode: Bool
        var point: CGPoint
        var command: Bool
    }

    private struct State {
        var machine = ZoneDragMachine()
        var checkPending = false
        var syncPending = false
        /// The installed port, read by the callback to re-enable itself.
        var port: CFMachPort?
    }

    private final class LoopBox: @unchecked Sendable { var loop: CFRunLoop? }

    /// Mouse buttons only: left down/up/dragged, right down/up (0x5E). No keyboard events.
    static let mask: CGEventMask = [CGEventType.leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp]
        .reduce(0) { $0 | (1 << $1.rawValue) }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    // Set before install, read on the tap thread. Each must only dispatch.
    private let onPress: (UInt64, CGPoint) -> Void
    private let onMoveCheck: (UInt64) -> Void
    private let onSync: () -> Void
    private let onRelease: (ZoneDragMachine.Release) -> Void
    private let onDisabled: (CGEventType) -> Void

    // Only touched on the main thread.
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private var runLoop: CFRunLoop?
    private var finished: DispatchSemaphore?

    init(onPress: @escaping (UInt64, CGPoint) -> Void, onMoveCheck: @escaping (UInt64) -> Void,
         onSync: @escaping () -> Void, onRelease: @escaping (ZoneDragMachine.Release) -> Void,
         onDisabled: @escaping (CGEventType) -> Void) {
        self.onPress = onPress
        self.onMoveCheck = onMoveCheck
        self.onSync = onSync
        self.onRelease = onRelease
        self.onDisabled = onDisabled
    }

    var isInstalled: Bool { port != nil }

    /// AppKit can track Cala's own window drags in a nested event-tracking run loop.
    static func performOnMainDuringDrag(_ block: @escaping () -> Void) {
        let loop = CFRunLoopGetMain()
        let modes = [RunLoop.Mode.common.rawValue, RunLoop.Mode.eventTracking.rawValue] as CFArray
        CFRunLoopPerformBlock(loop, modes, block)
        CFRunLoopWakeUp(loop)
    }

    // MARK: Main thread

    /// Creates the tap and its thread. Returns false when the system refuses an active tap (no Accessibility).
    func install() -> Bool {
        precondition(Thread.isMainThread)
        guard port == nil else { return true }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: Self.mask, callback: zoneTapCallback, userInfo: refcon)
        else { return false }
        guard let source = CFMachPortCreateRunLoopSource(nil, port, 0) else {
            CFMachPortInvalidate(port)
            return false
        }
        state.withLockUnchecked { $0 = State(machine: Self.fresh(from: $0.machine), port: port) }
        let ready = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let box = LoopBox()
        // The thread keeps `self` alive until its run loop returns, so the callback's unretained refcon stays valid.
        let thread = Thread { [self] in
            let loop = CFRunLoopGetCurrent()
            box.loop = loop
            CFRunLoopAddSource(loop, source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            ready.signal()
            // Returns once uninstall() stops it (or the invalidated port leaves it without sources).
            CFRunLoopRun()
            withExtendedLifetime(self) {}
            finished.signal()
        }
        thread.name = "Cala.zones.tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        guard ready.wait(timeout: .now() + 2) == .success, let loop = box.loop else {
            // The thread never started: tear the port down; its run loop then has no source and returns at once.
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
            state.withLockUnchecked { $0.port = nil }
            return false
        }
        self.port = port
        self.source = source
        self.runLoop = loop
        self.finished = finished
        return true
    }

    /// Disables and invalidates the tap, stops its run loop and waits (briefly) for the thread to exit.
    func uninstall() {
        precondition(Thread.isMainThread)
        guard let port else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        if let runLoop, let source { CFRunLoopRemoveSource(runLoop, source, .commonModes) }
        CFMachPortInvalidate(port)
        if let runLoop {
            CFRunLoopStop(runLoop)
            CFRunLoopWakeUp(runLoop)
        }
        if finished?.wait(timeout: .now() + 1) == .timedOut { log("zones: tap thread did not stop within 1 s") }
        self.port = nil
        self.source = nil
        self.runLoop = nil
        self.finished = nil
        state.withLockUnchecked { $0 = State(machine: Self.fresh(from: $0.machine), port: nil) }
    }

    enum Health { case ok, reenabled, broken }

    /// Re-enables a tap the system disabled (cancelling the gesture: the caller must hide the overlay);
    /// `broken` when it is gone for good (invalid port, permission revoked).
    func ensureEnabled() -> Health {
        guard let port, CFMachPortIsValid(port) else { return .broken }
        guard !CGEvent.tapIsEnabled(tap: port) else { return .ok }
        cancel(resetButtons: true)
        CGEvent.tapEnable(tap: port, enable: true)
        return CGEvent.tapIsEnabled(tap: port) ? .reenabled : .broken
    }

    // MARK: Any thread

    func setActivation(_ activation: ZoneActivation) {
        state.withLockUnchecked { $0.machine.activation = activation }
    }

    func setIgnoring(_ ignoring: Bool) {
        state.withLockUnchecked { $0.machine.ignoring = ignoring }
    }

    func cancel(resetButtons: Bool) {
        state.withLockUnchecked { $0.machine.cancel(resetButtons: resetButtons) }
    }

    /// Promotes the press to a window drag if it is still the current one. Called by the worker.
    func confirmDrag(generation: UInt64) -> Bool {
        let (confirmed, sync) = state.withLockUnchecked { s -> (Bool, Bool) in
            guard s.machine.confirmDrag(generation: generation) else { return (false, false) }
            // Shift may already be held: let main show the overlay without waiting for the next event.
            let sync = !s.syncPending
            s.syncPending = true
            return (true, sync)
        }
        if sync { onSync() }
        return confirmed
    }

    /// The worker could not resolve the confirmed window: drop the drag and let main hide any overlay.
    func rejectDrag(generation: UInt64) {
        let sync = state.withLockUnchecked { s -> Bool in
            guard s.machine.reject(generation: generation), !s.syncPending else { return false }
            s.syncPending = true
            return true
        }
        if sync { onSync() }
    }

    /// Worker side of the coalesced move check: clears the pending flag and says whether the press is still current.
    func beginMoveCheck(generation: UInt64) -> (current: Bool, point: CGPoint) {
        state.withLockUnchecked { s in
            s.checkPending = false
            return (s.machine.phase == .pressed && s.machine.generation == generation, s.machine.point)
        }
    }

    func isDragging(generation: UInt64) -> Bool {
        state.withLockUnchecked { $0.machine.generation == generation && $0.machine.phase == .dragging }
    }

    /// Main side of the coalesced overlay update.
    func takeSnapshot() -> Snapshot {
        state.withLockUnchecked { s in
            s.syncPending = false
            return Snapshot(generation: s.machine.generation, zonesMode: s.machine.zonesMode,
                            point: s.machine.point, command: s.machine.command)
        }
    }

    // MARK: Tap thread

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            let port = state.withLockUnchecked { s -> CFMachPort? in
                s.machine.cancel(resetButtons: true)
                s.checkPending = false
                return s.port
            }
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            onDisabled(type)
        case .leftMouseDown:
            let flags = event.flags, p = event.location
            let gen = state.withLockUnchecked {
                $0.machine.leftDown(at: p, shift: flags.contains(.maskShift), command: flags.contains(.maskCommand))
            }
            if let gen { onPress(gen, p) }
        case .leftMouseDragged:
            let flags = event.flags, p = event.location
            let (check, sync, gen) = state.withLockUnchecked { s -> (Bool, Bool, UInt64) in
                let wasMode = s.machine.zonesMode
                var check = s.machine.leftDragged(to: p, shift: flags.contains(.maskShift),
                                                  command: flags.contains(.maskCommand))
                if check { check = !s.checkPending; s.checkPending = true }
                let sync = (s.machine.zonesMode || wasMode) && !s.syncPending
                if sync { s.syncPending = true }
                return (check, sync, s.machine.generation)
            }
            if check { onMoveCheck(gen) }
            if sync { onSync() }
        case .leftMouseUp:
            let flags = event.flags, p = event.location
            let release = state.withLockUnchecked {
                $0.machine.leftUp(at: p, shift: flags.contains(.maskShift), command: flags.contains(.maskCommand))
            }
            if let release { onRelease(release) }
        case .rightMouseDown:
            let (swallow, sync) = state.withLockUnchecked { s -> (Bool, Bool) in
                guard s.machine.rightDown() else { return (false, false) }
                let sync = !s.syncPending
                s.syncPending = true
                return (true, sync)
            }
            if sync { onSync() }
            if swallow { return nil }
        case .rightMouseUp:
            if state.withLockUnchecked({ $0.machine.rightUp() }) { return nil }
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    /// A fresh state that keeps the configuration (activation, editor gate).
    private static func fresh(from old: ZoneDragMachine) -> ZoneDragMachine {
        var machine = ZoneDragMachine()
        machine.activation = old.activation
        machine.ignoring = old.ignoring
        return machine
    }
}

private func zoneTapCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent,
                             _ refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<ZoneDragTap>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
}

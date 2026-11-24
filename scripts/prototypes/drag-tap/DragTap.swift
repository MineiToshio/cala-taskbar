// DragTap.swift — feasibility prototype for Cala "Zones" (NOT part of the app target).
//
// What it does
//   While the user drags a window of ANOTHER app with the left button, a right click
//   toggles "zones mode" and is swallowed (never reaches the app under the cursor).
//   Holding Shift during the drag is logged as the alternative gesture.
//
// How to run
//   ./build.sh                                   # builds build/DragTapProbe.app (ad-hoc, fixed DR)
//   open build/DragTapProbe.app --args --probe   # permissions report only, then exits
//   open build/DragTapProbe.app                  # live prototype, exits by itself after 60 s
//   tail -f /tmp/drag-tap-probe.log              # everything is logged here (and to stdout)
//   Optional args: --log <path>  --seconds <n> (max 60)
//
// What it logs
//   permissions (AXIsProcessTrusted, CGPreflightListen/PostEventAccess), whether an active
//   (.defaultTap) and a listen-only tap could be created, "DRAG START pid=… win=…" once a
//   foreign window actually moves, "ZONES MODE ON/OFF" on each swallowed right click,
//   "SHIFT held during drag", "SNAP would happen" on release in zones mode, tap re-enables.
//
// Design rules shown here
//   * The tap callback is O(1): it only reads/writes a small locked state struct and
//     hands work to a serial queue. No AX / CGWindowList calls inside the callback.
//   * Only rightMouseDown/Up are ever swallowed, and only while a foreign window drag is
//     confirmed. Every other event is returned unmodified. Anything unexpected passes through.
//   * kCGEventTapDisabledByTimeout / ByUserInput → re-enable the tap immediately.

import AppKit
import ApplicationServices
import os

// MARK: - Arguments and logging

let args = CommandLine.arguments
func argValue(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
let probeOnly = args.contains("--probe")
let logPath = argValue("--log") ?? "/tmp/drag-tap-probe.log"
let lifetime = min(Double(argValue("--seconds") ?? "60") ?? 60, 60)   // hard cap: 60 s
let myPID = getpid()

let logLock = NSLock()
func log(_ s: String) {
    let line = "\(String(format: "%.3f", ProcessInfo.processInfo.systemUptime)) \(s)\n"
    logLock.lock(); defer { logLock.unlock() }
    FileHandle.standardOutput.write(line.data(using: .utf8)!)
    if let h = FileHandle(forWritingAtPath: logPath) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
    } else {
        FileManager.default.createFile(atPath: logPath, contents: line.data(using: .utf8))
    }
}

// MARK: - Shared state (touched by the tap thread and the worker queue)

enum Phase { case idle, pressed, draggingWindow }

struct DragState {
    var phase: Phase = .idle
    var zonesMode = false
    var swallowedRightDown = false   // swallow the matching rightMouseUp too
    var shiftLogged = false
    var generation = 0               // bumps on every leftMouseDown; stale worker results are dropped
}
let state = OSAllocatedUnfairLock(initialState: DragState())

// Worker-only data (only touched on `worker`, so no lock needed).
let worker = DispatchQueue(label: "drag-tap.worker", qos: .userInteractive)
var candidate: (gen: Int, windowID: CGWindowID, pid: pid_t, bounds: CGRect)?
var dragCheckPending = false

// MARK: - Window lookup via CGWindowList (no permission needed for bounds/pid/number)

/// Topmost normal (layer 0) on-screen window containing `p` (global, top-left origin).
func windowUnder(_ p: CGPoint) -> (CGWindowID, pid_t, CGRect)? {
    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return nil }
    for w in list {   // front-to-back order
        guard let layer = w[kCGWindowLayer as String] as? Int,
              let num = w[kCGWindowNumber as String] as? CGWindowID,
              let pid = w[kCGWindowOwnerPID as String] as? pid_t,
              let bd = w[kCGWindowBounds as String] as? NSDictionary,
              let r = CGRect(dictionaryRepresentation: bd) else { continue }
        if r.contains(p) {
            // The first hit is what the click lands on. If it is not a normal window
            // (menu, panel, Dock, overlay…) we do not treat the press as a window drag.
            return layer == 0 ? (num, pid, r) : nil
        }
    }
    return nil
}

func bounds(of id: CGWindowID) -> CGRect? {
    guard let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]],
          let bd = list.first?[kCGWindowBounds as String] as? NSDictionary else { return nil }
    return CGRect(dictionaryRepresentation: bd)
}

// MARK: - Worker side (off the tap)

func workerMouseDown(at p: CGPoint, gen: Int) {
    candidate = nil
    guard let (id, pid, r) = windowUnder(p), pid != myPID else { return }
    candidate = (gen, id, pid, r)
}

/// Called (coalesced) while leftMouseDragged events arrive. A drag counts as a WINDOW MOVE
/// only if the window's origin moved ≥ 3 pt and its size did not change (size change = resize).
func workerCheckDrag(gen: Int, shift: Bool) {
    dragCheckPending = false
    guard let c = candidate, c.gen == gen, let now = bounds(of: c.windowID) else { return }
    let moved = hypot(now.minX - c.bounds.minX, now.minY - c.bounds.minY) >= 3
    let sameSize = abs(now.width - c.bounds.width) < 1 && abs(now.height - c.bounds.height) < 1
    guard moved && sameSize else { return }
    let started = state.withLock { s -> Bool in
        guard s.generation == gen, s.phase == .pressed else { return false }
        s.phase = .draggingWindow
        return true
    }
    if started { log("DRAG START pid=\(c.pid) win=\(c.windowID) from=\(c.bounds.origin) now=\(now.origin)") }
}

// MARK: - The tap callback: O(1), fail-safe

var tapPort: CFMachPort?

let callback: CGEventTapCallBack = { _, type, event, _ in
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        if let port = tapPort { CGEvent.tapEnable(tap: port, enable: true) }
        log("TAP re-enabled after \(type == .tapDisabledByTimeout ? "timeout" : "user input")")
        return Unmanaged.passUnretained(event)

    case .leftMouseDown:
        let p = event.location
        let gen = state.withLock { s -> Int in
            s = DragState(generation: s.generation + 1); s.phase = .pressed; return s.generation
        }
        worker.async { workerMouseDown(at: p, gen: gen) }

    case .leftMouseDragged:
        let shift = event.flags.contains(.maskShift)   // modifiers ride on mouse events: no keyboard mask needed
        let (phase, gen, logShift) = state.withLock { s -> (Phase, Int, Bool) in
            let l = s.phase == .draggingWindow && shift && !s.shiftLogged
            if l { s.shiftLogged = true }
            return (s.phase, s.generation, l)
        }
        if logShift { log("SHIFT held during drag (alternative gesture)") }
        if phase == .pressed {
            worker.async {   // coalesce: at most one pending check
                guard !dragCheckPending else { return }
                dragCheckPending = true
                worker.async { workerCheckDrag(gen: gen, shift: shift) }
            }
        }

    case .leftMouseUp:
        let s = state.withLock { s -> DragState in let old = s; s.phase = .idle; s.zonesMode = false; return old }
        if s.phase == .draggingWindow { log(s.zonesMode ? "DRAG END → SNAP would happen (zones mode ON)" : "DRAG END (no zones)") }

    case .rightMouseDown:
        let (swallow, on) = state.withLock { s -> (Bool, Bool) in
            guard s.phase == .draggingWindow else { return (false, false) }
            s.zonesMode.toggle(); s.swallowedRightDown = true
            return (true, s.zonesMode)
        }
        if swallow { log("ZONES MODE \(on ? "ON" : "OFF") (right click swallowed)"); return nil }

    case .rightMouseUp:
        let swallow = state.withLock { s -> Bool in
            let w = s.swallowedRightDown; s.swallowedRightDown = false; return w
        }
        if swallow { return nil }   // never leave an orphan rightMouseUp for the app

    default:
        break   // anything unexpected: pass through untouched
    }
    return Unmanaged.passUnretained(event)
}

// MARK: - Permissions probe

func mask(_ types: [CGEventType]) -> CGEventMask { types.reduce(0) { $0 | (1 << $1.rawValue) } }
let mouseMask = mask([.leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp])
let keyMask = mask([.keyDown, .flagsChanged])

func tryTap(_ options: CGEventTapOptions, _ m: CGEventMask) -> CFMachPort? {
    CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: options,
                      eventsOfInterest: m, callback: { _, _, e, _ in Unmanaged.passUnretained(e) }, userInfo: nil)
}

func probe() {
    log("PROBE pid=\(myPID) exe=\(Bundle.main.executablePath ?? "?") bundle=\(Bundle.main.bundleIdentifier ?? "none")")
    log("AXIsProcessTrusted=\(AXIsProcessTrusted())")
    log("CGPreflightListenEventAccess=\(CGPreflightListenEventAccess())")
    log("CGPreflightPostEventAccess=\(CGPreflightPostEventAccess())")
    for (name, opt, m) in [("active  mouse", CGEventTapOptions.defaultTap, mouseMask),
                           ("listen  mouse", .listenOnly, mouseMask),
                           ("active  keys ", .defaultTap, keyMask),
                           ("listen  keys ", .listenOnly, keyMask)] {
        let port = tryTap(opt, m)
        log("tapCreate \(name): \(port == nil ? "nil (FAILED)" : "OK")")
        if let port { CFMachPortInvalidate(port) }
    }
    // Cost of the calls the worker makes (they must stay out of the tap callback): median of 20 runs.
    var here = CGEvent(source: nil)?.location ?? .zero   // global, top-left origin (same space as tap events)
    if windowUnder(here) == nil,   // cursor not over a window: sample the centre of the frontmost normal window
       let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
       let w = list.first(where: { ($0[kCGWindowLayer as String] as? Int) == 0 }),
       let bd = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: bd) {
        here = CGPoint(x: r.midX, y: r.midY)
    }
    func median(_ f: () -> Void) -> String {
        let xs = (0..<20).map { _ -> Double in
            let t = DispatchTime.now().uptimeNanoseconds; f()
            return Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6
        }.sorted()
        return String(format: "median %.2f ms, max %.2f ms", xs[10], xs[19])
    }
    let hit = windowUnder(here)
    log("window under cursor \(here): \(hit.map { "id=\($0.0) pid=\($0.1) \($0.2)" } ?? "none (not a layer-0 window)")")
    log("cost windowUnder (full on-screen list): \(median { _ = windowUnder(here) })")
    if let id = hit?.0 { log("cost bounds(of:) single window: \(median { _ = bounds(of: id) })") }
    if AXIsProcessTrusted() {
        let sys = AXUIElementCreateSystemWide()
        let axCost = median {
            var el: AXUIElement?
            _ = AXUIElementCopyElementAtPosition(sys, Float(here.x), Float(here.y), &el)
        }
        log("cost AXUIElementCopyElementAtPosition: \(axCost)")
    }
}

// MARK: - Main

log("---- start args=\(args.dropFirst().joined(separator: " "))")
probe()
if probeOnly { log("---- probe done"); exit(0) }

guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                   eventsOfInterest: mouseMask, callback: callback, userInfo: nil) else {
    log("ACTIVE TAP FAILED: grant Accessibility to \(Bundle.main.bundlePath) and relaunch. Exiting.")
    exit(2)
}
tapPort = port

// Dedicated thread with its own run loop: the tap never waits behind main-thread UI work.
let tapThread = Thread {
    let src = CFMachPortCreateRunLoopSource(nil, port, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
    CGEvent.tapEnable(tap: port, enable: true)
    log("TAP running on dedicated thread; drag another app's window and right-click. Auto-exit in \(Int(lifetime)) s")
    CFRunLoopRun()
}
tapThread.qualityOfService = .userInteractive
tapThread.start()

func shutdown(_ why: String) {
    CGEvent.tapEnable(tap: port, enable: false)
    CFMachPortInvalidate(port)
    log("---- exit (\(why))")
    exit(0)
}
signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
let sigs = [SIGINT, SIGTERM].map { sig -> DispatchSourceSignal in
    let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    s.setEventHandler { shutdown("signal \(sig)") }
    s.resume(); return s
}
DispatchQueue.main.asyncAfter(deadline: .now() + lifetime) { shutdown("timeout \(Int(lifetime)) s") }
withExtendedLifetime(sigs) { dispatchMain() }

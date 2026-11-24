import AppKit
import ApplicationServices

/// The zones worker: every CGWindowList and AX call of the drag pipeline runs here, on one serial queue,
/// never on the tap thread and never on main. All stored state is only touched on `queue`.
/// Frames are AX/CG global coordinates (top-left origin of the primary screen, y down).
final class ZoneWindowMover: @unchecked Sendable {
    private struct Candidate {
        var generation: UInt64
        var windowID: CGWindowID
        var pid: pid_t
        var start: CGRect
        var decided = false   // confirmed or rejected: checked once per press
    }

    private struct Drag {
        var key: ZoneRestore.WindowKey
        var window: AXUIElement
        var app: AXUIElement
        var resizable: Bool
        /// The frame to restore later: the frame at drag start, or the restored size when it was dragged out of a zone.
        var original: CGRect
        var restoredSize: CGSize?
    }

    /// Apps whose windows are never zones targets (system UI, Stage Manager, security prompts).
    private static let deniedBundles: Set<String> = [
        "com.apple.dock", "com.apple.SystemUIServer", "com.apple.controlcenter", "com.apple.notificationcenterui",
        "com.apple.loginwindow", "com.apple.SecurityAgent", "com.apple.CoreServicesUIAgent", "com.apple.Spotlight",
        "com.apple.WindowManager", "com.apple.screencaptureui",
    ]

    private let queue = DispatchQueue(label: "Cala.zones.worker", qos: .userInteractive)
    private let cancellation = ModuleCancellation()
    private let ownPID = getpid()
    private weak var tap: ZoneDragTap?
    private var candidate: Candidate?
    private var drags: [UInt64: Drag] = [:]
    private var records = ZoneRestore.Records()

    func attach(_ tap: ZoneDragTap) { self.tap = tap }

    /// Stops all queued work; the stored state is dropped on the queue.
    func stop() {
        cancellation.cancel()
        queue.async { [self] in
            candidate = nil
            drags.removeAll()
            records = ZoneRestore.Records()
        }
    }

    // MARK: Requests (any thread)

    func press(generation: UInt64, at point: CGPoint) {
        queue.async { [self] in
            guard !cancellation.isCancelled else { return }
            candidate = nil
            guard let (id, pid, frame) = Self.windowUnder(point), pid != ownPID else { return }
            candidate = Candidate(generation: generation, windowID: id, pid: pid, start: frame)
        }
    }

    func checkMove(generation: UInt64) {
        queue.async { [self] in
            guard !cancellation.isCancelled, let tap else { return }
            let (current, point) = tap.beginMoveCheck(generation: generation)
            guard current, var c = candidate, c.generation == generation, !c.decided,
                  let now = Self.bounds(of: c.windowID), ZoneWindowFit.isMove(from: c.start, to: now) else { return }
            // Confirm on the CG move alone, before any AX call: until the tap knows about the drag, a
            // right-click would reach the app (a context menu mid-drag). AX resolution follows right away.
            c.decided = true
            candidate = c
            guard tap.confirmDrag(generation: generation) else { return }
            guard let drag = resolve(c, frame: now) else {
                // Not a window zones may place: end the gesture without a snap. A swallowed right down
                // keeps its pending up swallowed (the machine only drops the drag).
                tap.rejectDrag(generation: generation)
                return
            }
            drags = drags.filter { $0.key + 8 > generation }
            drags[generation] = restoreIfSnapped(drag, start: c.start, now: now, cursorX: point.x)
        }
    }

    /// After the mouse-up of a confirmed drag: snap into `target` (zones mode) or finish a restore.
    func finish(generation: UInt64, cursorX: CGFloat, target: CGRect?, usable: CGRect?) {
        queue.async { [self] in
            guard !cancellation.isCancelled, let drag = drags.removeValue(forKey: generation) else { return }
            if let target, let usable {
                // Let the app and the window server finish their own drag first.
                queue.asyncAfter(deadline: .now() + 0.04) { [self] in
                    guard !cancellation.isCancelled else { return }
                    snap(drag, into: target, usable: usable)
                }
            } else if let size = drag.restoredSize {
                finishRestore(drag, size: size, cursorX: cursorX)
            }
        }
    }

    // MARK: Window lookup (worker)

    /// Topmost on-screen window under `p`, if it is a normal (layer 0) window. Menus, the Dock, Cala's bar and
    /// panels are higher layers: a press on them is never a window drag.
    private static func windowUnder(_ p: CGPoint) -> (CGWindowID, pid_t, CGRect)? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        for info in list {
            guard let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds), frame.contains(p) else { continue }
            // Fully transparent windows (invisible overlays some apps keep on screen) never receive the click.
            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha == 0 { continue }
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t else { return nil }
            return (id, pid, frame)
        }
        return nil
    }

    private static func bounds(of id: CGWindowID) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]],
              let bounds = list.first?[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: bounds)
    }

    /// The AX window behind a moving CG window, if zones may place it.
    private func resolve(_ c: Candidate, frame: CGRect) -> Drag? {
        let bundle = NSRunningApplication(processIdentifier: c.pid)?.bundleIdentifier ?? ""
        if Self.deniedBundles.contains(bundle) { return nil }
        let app = AXUIElementCreateApplication(c.pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let windows = WindowService.attr(app, kAXWindowsAttribute) as? [AXUIElement] else {
            log("zones: ignoring drag, no AX windows for \(bundle.isEmpty ? "pid \(c.pid)" : bundle)")
            return nil
        }
        var match = windows.first { element in
            var id: CGWindowID = 0
            return _AXUIElementGetWindow(element, &id) == .success && id == c.windowID
        }
        if match == nil {
            // Fallback: the window whose AX frame is closest to the CG frame (it is moving, so allow some slack).
            let scored = windows.compactMap { w in WindowService.frame(w).map { (w, hypot($0.minX - frame.minX, $0.minY - frame.minY)) } }
            match = scored.filter { $0.1 < 40 }.min { $0.1 < $1.1 }?.0
        }
        guard let window = match else {
            log("zones: ignoring drag, window \(c.windowID) of \(bundle) not found via AX")
            return nil
        }
        let role = WindowService.attr(window, kAXRoleAttribute) as? String
        let subrole = WindowService.attr(window, kAXSubroleAttribute) as? String
        // Sheets and system dialogs are never moved; app dialogs (AXDialog) are.
        guard role == kAXWindowRole as String,
              ![kAXSystemDialogSubrole as String, "AXSheet", kAXUnknownSubrole as String].contains(subrole ?? "") else {
            log("zones: ignoring drag of \(bundle) (role \(role ?? "-"), subrole \(subrole ?? "-"))")
            return nil
        }
        if WindowService.isFullScreen(window) { return nil }
        guard Self.settable(window, kAXPositionAttribute) else {
            log("zones: ignoring drag of \(bundle), position not settable")
            return nil
        }
        let resizable = Self.settable(window, kAXSizeAttribute)
        let key = ZoneRestore.WindowKey(pid: c.pid, windowID: c.windowID)
        return Drag(key: key, window: window, app: app, resizable: resizable, original: c.start, restoredSize: nil)
    }

    // MARK: Restore on drag out (worker)

    /// A window still in the zone it was snapped to gets its original size back as soon as it is dragged,
    /// keeping the grab point under the cursor. If the app refuses mid-drag, `finishRestore` retries on mouse-up.
    private func restoreIfSnapped(_ drag: Drag, start: CGRect, now: CGRect, cursorX: CGFloat) -> Drag {
        guard let restored = records.restoreOnDrag(drag.key, current: now, cursorX: cursorX, initialFrameAX: start)
        else { return drag }
        var drag = drag
        drag.original = restored
        guard drag.resizable else { return drag }
        drag.restoredSize = restored.size
        Self.setSize(drag.window, restored.size)
        Self.setPosition(drag.window, restored.origin)
        log("zones: restored size \(Int(restored.width))×\(Int(restored.height)) on drag out")
        return drag
    }

    private func finishRestore(_ drag: Drag, size: CGSize, cursorX: CGFloat) {
        guard let frame = WindowService.frame(drag.window),
              abs(frame.width - size.width) > 2 || abs(frame.height - size.height) > 2 else { return }
        let restored = ZoneRestore.restoredFrame(current: frame, originalSize: size, cursorX: cursorX)
        Self.setSize(drag.window, restored.size)
        Self.setPosition(drag.window, restored.origin)
        log("zones: restored size on mouse-up (the app refused it during the drag)")
    }

    // MARK: Snapping (worker)

    private func snap(_ drag: Drag, into target: CGRect, usable: CGRect) {
        let window = drag.window
        // Chromium/Electron animate and fight AX frame changes while enhanced UI is on; switch it off around the move.
        let enhanced = WindowService.attr(drag.app, "AXEnhancedUserInterface") as? Bool == true
        if enhanced { AXUIElementSetAttributeValue(drag.app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
        defer {
            if enhanced { AXUIElementSetAttributeValue(drag.app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) }
        }
        guard let before = WindowService.frame(window) else {
            log("zones: snap skipped, the window is gone")
            return
        }
        if drag.resizable {
            // Size, position, size: an app may clamp the size to the display the window is on before the move.
            let sized = Self.setSize(window, target.size)
            Self.setPosition(window, target.origin)
            Self.setSize(window, target.size)
            if !sized { log("zones: app refused size (pid \(drag.key.pid))") }
            if let got = WindowService.frame(window), !ZoneWindowFit.matches(got, target) {
                // Bigger than the zone (minimum size): start at the zone's corner, inside the screen. Smaller or
                // rounded (terminal cells): accept the size and keep the zone's corner.
                let placed = ZoneWindowFit.place(size: got.size, in: target, usable: usable, centered: false)
                if abs(placed.minX - got.minX) > 1 || abs(placed.minY - got.minY) > 1 {
                    Self.setPosition(window, placed.origin)
                }
            }
        } else {
            let placed = ZoneWindowFit.place(size: before.size, in: target, usable: usable, centered: true)
            Self.setPosition(window, placed.origin)
        }
        guard let after = WindowService.frame(window) else { return }
        records.recordSnap(drag.key, originalFrameAX: drag.original, snappedFrameAX: after)
        log("zones: snapped pid=\(drag.key.pid) frame=\(Self.describe(after)) target=\(Self.describe(target))"
            + (drag.resizable ? "" : " (not resizable, centred)"))
    }

    // MARK: AX helpers

    private static func settable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success && settable.boolValue
    }

    @discardableResult
    private static func setSize(_ element: AXUIElement, _ size: CGSize) -> Bool {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value) == .success
    }

    @discardableResult
    private static func setPosition(_ element: AXUIElement, _ point: CGPoint) -> Bool {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return false }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value) == .success
    }

    private static func describe(_ r: CGRect) -> String {
        "(\(Int(r.minX.rounded())),\(Int(r.minY.rounded())) \(Int(r.width.rounded()))×\(Int(r.height.rounded())))"
    }
}

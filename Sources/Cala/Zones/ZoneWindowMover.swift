import AppKit
import ApplicationServices

/// The zones worker: every CGWindowList and AX call of the drag pipeline runs here, on one serial queue,
/// never on the tap thread and never on main. AppKit window operations run on main; drag state lives on `queue`.
/// Frames are AX/CG global coordinates (top-left origin of the primary screen, y down).
final class ZoneWindowMover: @unchecked Sendable {
    private struct Drag {
        var key: ZoneRestore.WindowKey
        var window: AXUIElement
        var app: AXUIElement
        var resizable: Bool
        /// The frame to restore later: the frame at drag start, or the restored size when it was dragged out of a zone.
        var original: CGRect
        var restoredSize: CGSize?
    }

    private struct AppKitDrag {
        var key: ZoneRestore.WindowKey
        var original: CGRect
        var restoredSize: CGSize?
    }

    private enum Target {
        case accessibility(Drag)
        case appKit(AppKitDrag)
        case detached(ZoneDragCandidate.Window)
    }

    private enum Resolution {
        case missing, ineligible, resolved(Drag)
    }

    private static let settleDelay: TimeInterval = 0.04
    private static let detachedLookupLimit: TimeInterval = 0.5

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
    private var candidate: (generation: UInt64, probe: ZoneDragCandidate)?
    private var drags: [UInt64: Target] = [:]
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
            let windows = Self.onScreenWindows()
            guard let window = Self.windowUnder(point, in: windows) else { return }
            var initialTabWindowIDs: Set<CGWindowID>?
            if window.key.pid != ownPID,
               ZoneDragCandidate.mayDetachTab(at: point, in: window.frame) {
                initialTabWindowIDs = Set(windows.compactMap { info -> CGWindowID? in
                    guard (info[kCGWindowOwnerPID as String] as? pid_t) == window.key.pid else { return nil }
                    return info[kCGWindowNumber as String] as? CGWindowID
                })
            }
            candidate = (generation, ZoneDragCandidate(original: window, point: point,
                                                       initialTabWindowIDs: initialTabWindowIDs))
        }
    }

    func discardProbe(generation: UInt64) {
        queue.async { [self] in
            if candidate?.generation == generation { candidate = nil }
        }
    }

    func checkMove(generation: UInt64) {
        queue.async { [self] in
            guard !cancellation.isCancelled, let tap else { return }
            let (current, point) = tap.beginMoveCheck(generation: generation)
            guard current, var c = candidate, c.generation == generation else { return }
            let window = c.probe.original
            let now = Self.bounds(of: window.key.windowID)
            let detached: ZoneDragCandidate.Window?
            if let now, c.probe.originalMoved(to: now) {
                if window.key.pid == ownPID {
                    candidate = nil
                    confirmAppKitDrag(window, generation: generation, current: now, cursorX: point.x, tap: tap)
                    return
                }
                detached = nil
            } else {
                let time = ProcessInfo.processInfo.systemUptime
                guard c.probe.shouldRecheck(at: point, time: time) else { return }
                let windows = Self.onScreenWindows().compactMap { info -> ZoneDragCandidate.Window? in
                    guard (info[kCGWindowOwnerPID as String] as? pid_t) == window.key.pid else { return nil }
                    return Self.normalWindow(info)
                }
                detached = c.probe.recheck(windows: windows, at: point, time: time)
                candidate = c
                guard detached != nil else { return }
            }
            // Confirm external drags on the CG move, before any AX call: until the tap knows about the drag, a
            // right-click would reach the app (a context menu mid-drag).
            candidate = nil
            guard tap.confirmDrag(generation: generation) else {
                log("zones: drag detected, zones not shown (press ended before confirmation)")
                return
            }
            drags = drags.filter { $0.key + 8 > generation }
            if let detached {
                // Chromium can publish the AX window only after the tab has finished detaching.
                drags[generation] = .detached(detached)
                return
            }
            guard let now else { return }
            guard case .resolved(let drag) = resolve(window, frame: now) else {
                // Not a window zones may place: end the gesture without a snap. A swallowed right down
                // keeps its pending up swallowed (the machine only drops the drag).
                tap.rejectDrag(generation: generation)
                return
            }
            drags[generation] = .accessibility(restoreIfSnapped(drag, start: window.frame, now: now, cursorX: point.x))
        }
    }

    /// After the mouse-up of a confirmed drag: snap into `target` (zones mode) or finish a restore.
    func finish(generation: UInt64, cursorX: CGFloat, target: CGRect?, usable: CGRect?) {
        queue.async { [self] in
            guard !cancellation.isCancelled else { return }
            guard let moving = drags.removeValue(forKey: generation) else {
                tap?.endSnapRelease(generation: generation)
                return
            }
            if let target, let usable {
                // Let the app and the window server finish their own drag first.
                let released = DispatchTime.now()
                queue.asyncAfter(deadline: released + Self.settleDelay) { [self] in
                    guard !cancellation.isCancelled else { return }
                    switch moving {
                    case .accessibility(let drag):
                        tap?.endSnapRelease(generation: generation)
                        snap(drag, into: target, usable: usable)
                    case .appKit(let drag):
                        tap?.endSnapRelease(generation: generation)
                        DispatchQueue.main.async { [self] in snapAppKit(drag, into: target, usable: usable) }
                    case .detached(let window):
                        snapDetached(window, generation: generation, into: target, usable: usable,
                                     deadline: released + Self.detachedLookupLimit)
                    }
                }
            } else {
                tap?.endSnapRelease(generation: generation)
                switch moving {
                case .accessibility(let drag):
                    if let size = drag.restoredSize { finishRestore(drag, size: size, cursorX: cursorX) }
                case .appKit(let drag):
                    if let size = drag.restoredSize {
                        DispatchQueue.main.async { [self] in finishAppKitRestore(drag, size: size, cursorX: cursorX) }
                    }
                case .detached:
                    break
                }
            }
        }
    }

    // MARK: Window lookup (worker)

    private static func onScreenWindows() -> [[String: Any]] {
        CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
    }

    /// A higher-layer surface (menu, Dock or panel) above a normal window blocks the press.
    private static func windowUnder(_ p: CGPoint, in windows: [[String: Any]]) -> ZoneDragCandidate.Window? {
        for info in windows {
            guard let frame = visibleFrame(info), frame.contains(p) else { continue }
            return normalWindow(info)
        }
        return nil
    }

    private static func normalWindow(_ info: [String: Any]) -> ZoneDragCandidate.Window? {
        guard (info[kCGWindowLayer as String] as? Int) == 0, let frame = visibleFrame(info),
              let id = info[kCGWindowNumber as String] as? CGWindowID,
              let pid = info[kCGWindowOwnerPID as String] as? pid_t else { return nil }
        return ZoneDragCandidate.Window(key: .init(pid: pid, windowID: id), frame: frame)
    }

    private static func visibleFrame(_ info: [String: Any]) -> CGRect? {
        if let alpha = info[kCGWindowAlpha as String] as? Double, alpha == 0 { return nil }
        guard let bounds = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: bounds)
    }

    private static func bounds(of id: CGWindowID) -> CGRect? {
        guard let list = CGWindowListCreateDescriptionFromArray(ZoneDragCandidate.windowIDArray(id)) as? [[String: Any]],
              let info = list.first, (info[kCGWindowNumber as String] as? CGWindowID) == id,
              let bounds = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: bounds)
    }

    /// The AX window behind a moving CG window, if zones may place it.
    private func resolve(_ candidate: ZoneDragCandidate.Window, frame: CGRect?, reportMissing: Bool = true) -> Resolution {
        let key = candidate.key
        let bundle = Self.bundleID(for: key.pid)
        if Self.deniedBundles.contains(bundle) {
            log("zones: ignoring drag of \(bundle), system UI window")
            return .ineligible
        }
        let app = AXUIElementCreateApplication(key.pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let windows = WindowService.attr(app, kAXWindowsAttribute) as? [AXUIElement] else {
            if reportMissing { log("zones: ignoring drag, no AX windows for \(bundle.isEmpty ? "pid \(key.pid)" : bundle)") }
            return .missing
        }
        var match = windows.first { element in
            var id: CGWindowID = 0
            return _AXUIElementGetWindow(element, &id) == .success && id == key.windowID
        }
        if match == nil, let frame {
            // Fallback: the window whose AX frame is closest to the CG frame (it is moving, so allow some slack).
            let scored = windows.compactMap { w in WindowService.frame(w).map { (w, hypot($0.minX - frame.minX, $0.minY - frame.minY)) } }
            match = scored.filter { $0.1 < 40 }.min { $0.1 < $1.1 }?.0
        }
        guard let window = match else {
            if reportMissing { log("zones: ignoring drag, window \(key.windowID) of \(bundle) not found via AX") }
            return .missing
        }
        let role = WindowService.attr(window, kAXRoleAttribute) as? String
        let subrole = WindowService.attr(window, kAXSubroleAttribute) as? String
        // Sheets and system dialogs are never moved; app dialogs (AXDialog) are.
        guard role == kAXWindowRole as String,
              ![kAXSystemDialogSubrole as String, "AXSheet", kAXUnknownSubrole as String].contains(subrole ?? "") else {
            log("zones: ignoring drag of \(bundle) (role \(role ?? "-"), subrole \(subrole ?? "-"))")
            return .ineligible
        }
        if WindowService.isFullScreen(window) {
            log("zones: ignoring drag of \(bundle), full-screen window")
            return .ineligible
        }
        guard Self.settable(window, kAXPositionAttribute) else {
            log("zones: ignoring drag of \(bundle), position not settable")
            return .ineligible
        }
        let resizable = Self.settable(window, kAXSizeAttribute)
        return .resolved(Drag(key: key, window: window, app: app, resizable: resizable,
                              original: candidate.frame, restoredSize: nil))
    }

    private static func bundleID(for pid: pid_t) -> String {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
    }

    // MARK: Cala windows

    private func confirmAppKitDrag(_ window: ZoneDragCandidate.Window, generation: UInt64, current: CGRect,
                                   cursorX: CGFloat, tap: ZoneDragTap) {
        ZoneDragTap.performOnMainDuringDrag { [self] in
            guard !cancellation.isCancelled else { return }
            guard appKitWindow(window.key.windowID) != nil else {
                tap.endPending(generation: generation)
                log("zones: drag detected, zones not shown (Cala window \(window.key.windowID) is ineligible in AppKit)")
                return
            }
            queue.async { [self] in
                guard !cancellation.isCancelled else { return }
                guard tap.confirmDrag(generation: generation) else {
                    log("zones: drag detected, zones not shown (press ended during AppKit validation)")
                    return
                }
                drags = drags.filter { $0.key + 8 > generation }
                let restored = records.restoreOnDrag(window.key, current: current, cursorX: cursorX,
                                                     initialFrameAX: window.frame)
                drags[generation] = .appKit(AppKitDrag(key: window.key, original: restored ?? window.frame,
                                                      restoredSize: restored?.size))
                if let restored {
                    ZoneDragTap.performOnMainDuringDrag { [self] in
                        guard tap.isDragging(generation: generation),
                              let (local, height) = appKitWindow(window.key.windowID) else { return }
                        local.setFrame(ZoneGeometry.appKitRect(fromAX: restored, primaryHeight: height), display: true)
                    }
                }
            }
        }
    }

    /// Eligibility and frame changes must run on main.
    private func appKitWindow(_ id: CGWindowID) -> (NSWindow, CGFloat)? {
        guard !cancellation.isCancelled, !ZonesModule.editorOpen, let height = NSScreen.screens.first?.frame.height,
              let window = NSApp.window(withWindowNumber: Int(id)), window.isVisible, window.level == .normal,
              window.styleMask.contains(.titled), !window.styleMask.contains(.fullScreen), !(window is NSPanel),
              window.isMovable, !window.ignoresMouseEvents, !window.isSheet, window.attachedSheet == nil else { return nil }
        return (window, height)
    }

    private func snapAppKit(_ drag: AppKitDrag, into target: CGRect, usable: CGRect) {
        guard let (window, height) = appKitWindow(drag.key.windowID) else { return }
        let resizable = window.styleMask.contains(.resizable)
        var size = window.frame.size
        if resizable {
            // setFrame can bypass the size limits normally enforced during a user resize.
            let contentMin = window.frameRect(forContentRect: CGRect(origin: .zero, size: window.contentMinSize)).size
            let contentMax = window.frameRect(forContentRect: CGRect(origin: .zero, size: window.contentMaxSize)).size
            size = CGSize(width: max(window.minSize.width, contentMin.width,
                                     min(target.width, window.maxSize.width, contentMax.width)),
                          height: max(window.minSize.height, contentMin.height,
                                      min(target.height, window.maxSize.height, contentMax.height)))
        }
        let placed = ZoneWindowFit.place(size: size, in: target, usable: usable, centered: !resizable)
        window.setFrame(ZoneGeometry.appKitRect(fromAX: placed, primaryHeight: height), display: true)
        let after = ZoneGeometry.axRect(fromAppKit: window.frame, primaryHeight: height)
        queue.async { [self] in
            guard !cancellation.isCancelled else { return }
            records.recordSnap(drag.key, originalFrameAX: drag.original, snappedFrameAX: after)
            log("zones: snapped pid=\(drag.key.pid) frame=\(Self.describe(after)) target=\(Self.describe(target)) via AppKit")
        }
    }

    private func finishAppKitRestore(_ drag: AppKitDrag, size: CGSize, cursorX: CGFloat) {
        guard let (window, height) = appKitWindow(drag.key.windowID),
              abs(window.frame.width - size.width) > 2 || abs(window.frame.height - size.height) > 2 else { return }
        let frame = ZoneGeometry.axRect(fromAppKit: window.frame, primaryHeight: height)
        let restored = ZoneRestore.restoredFrame(current: frame, originalSize: size, cursorX: cursorX)
        window.setFrame(ZoneGeometry.appKitRect(fromAX: restored, primaryHeight: height), display: true)
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

    private func snapDetached(_ window: ZoneDragCandidate.Window, generation: UInt64, into target: CGRect,
                              usable: CGRect, deadline: DispatchTime) {
        guard !cancellation.isCancelled, let tap, tap.isCurrentSnapRelease(generation: generation) else { return }
        guard DispatchTime.now() < deadline else {
            tap.endSnapRelease(generation: generation)
            log("zones: detached window \(window.key.windowID) not found via AX before lookup expired")
            return
        }
        // Match only the adopted ID. The source browser window can still overlap its frame.
        switch resolve(window, frame: nil, reportMissing: false) {
        case .resolved(let drag):
            defer { tap.endSnapRelease(generation: generation) }
            guard !cancellation.isCancelled, tap.isCurrentSnapRelease(generation: generation),
                  DispatchTime.now() < deadline else { return }
            snap(drag, into: target, usable: usable) {
                !self.cancellation.isCancelled && tap.isCurrentSnapRelease(generation: generation)
            }
        case .missing:
            queue.asyncAfter(deadline: min(deadline, .now() + Self.settleDelay)) { [self] in
                snapDetached(window, generation: generation, into: target, usable: usable, deadline: deadline)
            }
        case .ineligible:
            tap.endSnapRelease(generation: generation)
        }
    }

    private func snap(_ drag: Drag, into target: CGRect, usable: CGRect, canPlace: () -> Bool = { true }) {
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
        guard canPlace() else { return }
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

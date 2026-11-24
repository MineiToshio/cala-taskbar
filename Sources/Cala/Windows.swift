import AppKit
import ApplicationServices
import ScreenCaptureKit

private enum AXWindowLookup {
    typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    static let handle = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY)
    static let getWindow: GetWindow? = {
        guard let handle, let symbol = dlsym(handle, "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(symbol, to: GetWindow.self)
    }()
}

func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError {
    guard let getWindow = AXWindowLookup.getWindow else { return .notImplemented }
    return getWindow(element, id)
}

struct WinRef: Identifiable {
    let id: CGWindowID
    let title: String
    let minimized: Bool
    let ax: AXUIElement?
    let pid: pid_t
}

private let logQueue = DispatchQueue(label: "Cala.log")

func log(_ s: String) {
    let line = "\(Date()) \(s)\n"
    logQueue.async {
        let fm = FileManager.default
        let dir = AppPaths.supportDirectory
        let f = dir.appendingPathComponent("debug.log")
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = Data(line.utf8)
            let size = (try? fm.attributesOfItem(atPath: f.path)[.size] as? NSNumber)?.intValue ?? 0
            if size > 1_000_000 {
                let backup = dir.appendingPathComponent("debug.log.1")
                if fm.fileExists(atPath: backup.path) { try fm.removeItem(at: backup) }
                try fm.moveItem(at: f, to: backup)
            }
            if fm.fileExists(atPath: f.path) {
                let h = try FileHandle(forWritingTo: f)
                defer { try? h.close() }
                try h.seekToEnd()
                try h.write(contentsOf: data)
            } else {
                try data.write(to: f, options: .atomic)
            }
        } catch { /* Logging must not interrupt window actions. */ }
    }
}

func bringFront(_ app: NSRunningApplication) {
    let el = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetAttributeValue(el, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    app.activate(options: [.activateAllWindows])
}

func newWindow(pid: pid_t, run: ModuleCancellation) {
    guard !run.isCancelled, let app = NSRunningApplication(processIdentifier: pid) else { return }
    bringFront(app)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
        guard !run.isCancelled, !app.isTerminated else { return }
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: 45, keyDown: down)
            e?.flags = .maskCommand
            e?.postToPid(pid)
        }
    }
}

func axAttr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
    return v
}

enum WindowService {
    static func cgWindows(for pid: pid_t) -> [WinRef] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { d in
            guard (d[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (d[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let num = (d[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let b = d[kCGWindowBounds as String] as? [String: CGFloat],
                  (b["Width"] ?? 0) >= 100, (b["Height"] ?? 0) >= 60 else { return nil }
            let title = d[kCGWindowName as String] as? String ?? ""
            if title.isEmpty { return nil } // untitled off-screen entries are ghosts of closed windows
            let onscreen = (d[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
            return WinRef(id: num, title: title, minimized: !onscreen, ax: nil, pid: pid)
        }
    }

    static func focusedWindow(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        guard let w = attr(app, kAXFocusedWindowAttribute) else { return nil }
        return (w as! AXUIElement)
    }

    static func frame(_ w: AXUIElement) -> CGRect? {
        guard let p = attr(w, kAXPositionAttribute), let s = attr(w, kAXSizeAttribute) else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &pt), AXValueGetValue(s as! AXValue, .cgSize, &sz) else { return nil }
        return CGRect(origin: pt, size: sz)
    }

    static func isFullScreen(_ w: AXUIElement) -> Bool {
        (attr(w, "AXFullScreen") as? Bool) ?? false
    }

    static func setHeight(_ w: AXUIElement, _ h: CGFloat, width: CGFloat) {
        var sz = CGSize(width: width, height: h)
        if let v = AXValueCreate(.cgSize, &sz) { AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, v) }
    }

    static func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v
    }

    static func windows(for pid: pid_t, run: ModuleCancellation? = nil) -> [WinRef] {
        guard run?.isCancelled != true else { return [] }
        let app = AXUIElementCreateApplication(pid)
        guard let arr = attr(app, kAXWindowsAttribute) as? [AXUIElement] else { return cgWindows(for: pid) }
        // For Cala itself only its real windows count (not the bar's own panels).
        let own = pid == ProcessInfo.processInfo.processIdentifier ? Set(TaskbarModel.ownWindows().map { CGWindowID($0.windowNumber) }) : nil
        var ax: [WinRef] = []
        for w in arr {
            guard run?.isCancelled != true else { return [] }
            var id: CGWindowID = 0
            guard _AXUIElementGetWindow(w, &id) == .success, id != 0 else { continue }
            if let own, !own.contains(id) { continue }
            let sub = attr(w, kAXSubroleAttribute) as? String
            if sub == "AXUnknown" || sub == "AXSystemDialog" { continue }
            let title = attr(w, kAXTitleAttribute) as? String ?? ""
            let min = (attr(w, kAXMinimizedAttribute) as? Bool) ?? false
            ax.append(WinRef(id: id, title: title, minimized: min, ax: w, pid: pid))
        }
        if !ax.isEmpty { return ax }
        // AX sees nothing: windows of a hidden app are still real, otherwise they are ghosts of closed windows.
        return NSRunningApplication(processIdentifier: pid)?.isHidden == true ? cgWindows(for: pid) : []
    }

    /// "New ..." entries read from the app's File menu (menu bar item #3).
    static func newItems(pid: pid_t) -> [(title: String, el: AXUIElement)] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.6)
        guard let bar = attr(app, kAXMenuBarAttribute) else { return [] }
        guard let tops = attr(bar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement], tops.count > 2 else { return [] }
        guard let menus = attr(tops[2], kAXChildrenAttribute) as? [AXUIElement], let menu = menus.first,
              let items = attr(menu, kAXChildrenAttribute) as? [AXUIElement] else { return [] }
        var out: [(String, AXUIElement)] = []
        for it in items {
            guard let title = attr(it, kAXTitleAttribute) as? String, !title.isEmpty else { continue }
            let low = title.lowercased()
            guard low.hasPrefix("new") || low.hasPrefix("nuev") else { continue }
            if (attr(it, kAXEnabledAttribute) as? Bool) == false { continue }
            if let kids = attr(it, kAXChildrenAttribute) as? [AXUIElement], !kids.isEmpty { continue }
            out.append((title, it))
            if out.count >= 4 { break }
        }
        return out
    }

    static func press(_ el: AXUIElement, pid: pid_t, run: ModuleCancellation) {
        guard !run.isCancelled, let app = NSRunningApplication(processIdentifier: pid) else { return }
        bringFront(app)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard !run.isCancelled, !app.isTerminated else { return }
            AXUIElementPerformAction(el, kAXPressAction as CFString)
        }
    }

    /// Window rect in AppKit (bottom-left origin) screen coordinates.
    static func appKitFrame(_ ax: AXUIElement) -> NSRect? {
        var pos = CGPoint.zero, size = CGSize.zero
        guard let pv = attr(ax, kAXPositionAttribute), let sv = attr(ax, kAXSizeAttribute),
              AXValueGetValue(pv as! AXValue, .cgPoint, &pos), AXValueGetValue(sv as! AXValue, .cgSize, &size),
              size.width > 0, let h = NSScreen.screens.first?.frame.height else { return nil }
        return NSRect(x: pos.x, y: h - pos.y - size.height, width: size.width, height: size.height)
    }

    static func raise(_ w: WinRef) {
        guard let ax = w.ax else {
            if let app = NSRunningApplication(processIdentifier: w.pid) {
                bringFront(app)
                if let url = app.bundleURL { NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) }
            }
            return
        }
        AXUIElementSetAttributeValue(ax, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        if let app = NSRunningApplication(processIdentifier: w.pid) { bringFront(app) }
        AXUIElementPerformAction(ax, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(ax, kAXMainAttribute as CFString, kCFBooleanTrue)
    }

    private static func closeTarget(_ w: WinRef, run: ModuleCancellation) -> WinRef? {
        guard let current = windows(for: w.pid, run: run).first(where: { $0.id == w.id }),
              let ax = current.ax, !current.minimized,
              (attr(ax, kAXMinimizedAttribute) as? Bool) == false,
              let children = attr(ax, kAXChildrenAttribute) as? [AXUIElement],
              !children.contains(where: { (attr($0, kAXRoleAttribute) as? String) == kAXSheetRole }),
              (attr(ax, "AXSheets") as? [AXUIElement] ?? []).isEmpty else { return nil }
        return current
    }

    static func close(_ w: WinRef, run: ModuleCancellation) {
        guard !run.isCancelled else { return }
        var err: AXError = .cannotComplete
        if let ax = w.ax, let btn = attr(ax, kAXCloseButtonAttribute), !run.isCancelled {
            err = AXUIElementPerformAction(btn as! AXUIElement, kAXPressAction as CFString)
        }
        log("close id=\(w.id) pid=\(w.pid) ax=\(w.ax != nil) press=\(err.rawValue)")
        // Some apps ignore the close button press: only send Cmd+W to the same, focused window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard !run.isCancelled, let target = closeTarget(w, run: run) else { return }
            raise(target)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                guard !run.isCancelled, closeTarget(w, run: run) != nil,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == w.pid,
                      let focused = focusedWindow(pid: w.pid) else { return }
                var id: CGWindowID = 0
                guard _AXUIElementGetWindow(focused, &id) == .success, id == w.id else { return }
                log("close fallback Cmd+W id=\(w.id)")
                let src = CGEventSource(stateID: .hidSystemState)
                for down in [true, false] {
                    let e = CGEvent(keyboardEventSource: src, virtualKey: 13, keyDown: down)
                    e?.flags = .maskCommand
                    e?.postToPid(w.pid)
                }
            }
        }
    }

    /// Takes a thumbnail first (macOS stops drawing video layers once minimizing starts), then minimizes.
    static func minimize(_ w: WinRef, run: ModuleCancellation) {
        guard !run.isCancelled, let ax = w.ax else { return }
        Task { @MainActor in
            guard !run.isCancelled else { return }
            let windows = await ThumbCache.shared.scWindows(ids: [w.id])
            await ThumbCache.shared.capture(windows, shouldCapture: { _ in !run.isCancelled })
            guard !run.isCancelled else { return }
            AXUIElementSetAttributeValue(ax, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
        }
    }

    static func snapshot(_ ids: [CGWindowID]) async {
        let ws = await ThumbCache.shared.scWindows(ids: ids)
        await ThumbCache.shared.capture(ws)
    }

    /// Click on a running app's icon: toggle like the Windows taskbar.
    @discardableResult
    static func toggle(pid: pid_t, run: ModuleCancellation) -> Bool {
        guard !run.isCancelled, let app = NSRunningApplication(processIdentifier: pid) else { return false }
        let wins = windows(for: pid, run: run)
        log("click \(app.localizedName ?? "?") windows=\(wins.count) trusted=\(AXIsProcessTrusted())")
        if wins.isEmpty || wins.allSatisfy({ $0.ax == nil }) {
            bringFront(app)
            if let url = app.bundleURL {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
            return true
        }
        if app.isActive, let visible = wins.first(where: { !$0.minimized }) {
            if wins.filter({ !$0.minimized }).count == 1 { minimize(visible, run: run) } else { bringFront(app) }
        } else if let first = wins.first(where: { !$0.minimized }) ?? wins.first {
            raise(first)
        }
        return false
    }
}

final class ThumbCache {
    static let shared = ThumbCache()

    @MainActor private final class State {
        var images: [CGWindowID: NSImage] = [:]
        var stamps: [CGWindowID: Date] = [:]
        var access: [CGWindowID: UInt64] = [:]
        var clock: UInt64 = 0

        func touch(_ id: CGWindowID) {
            clock &+= 1
            access[id] = clock
        }

        func prune() {
            if let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] {
                let live = Set(list.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
                for id in Array(images.keys) where !live.contains(id) { remove(id) }
            }
            while images.count > 100, let oldest = access.min(by: { $0.value < $1.value })?.key { remove(oldest) }
        }

        private func remove(_ id: CGWindowID) {
            images[id] = nil; stamps[id] = nil; access[id] = nil
        }
    }

    @MainActor private static let state = State()

    // Keep synchronous snapshot reads source-compatible for AppKit callers, including AX callbacks.
    private func onMain<T>(_ body: @MainActor (State) -> T) -> T {
        if Thread.isMainThread { return MainActor.assumeIsolated { body(Self.state) } }
        return DispatchQueue.main.sync { MainActor.assumeIsolated { body(Self.state) } }
    }

    var images: [CGWindowID: NSImage] { onMain { $0.prune(); return $0.images } }
    var stamps: [CGWindowID: Date] { onMain { $0.prune(); return $0.stamps } }

    func capture(ids: [CGWindowID]) async -> [CGWindowID: NSImage] {
        let windows = await scWindows(ids: ids)
        await capture(windows)
        return images
    }

    func cached(_ id: CGWindowID) -> NSImage? {
        onMain { state in
            state.prune()
            guard let image = state.images[id] else { return nil }
            state.touch(id)
            return image
        }
    }

    /// SCWindow handles for the given ids (enumerating them is the expensive part, so callers reuse them).
    func scWindows(ids: [CGWindowID]) async -> [SCWindow] {
        guard !Task.isCancelled, CGPreflightScreenCaptureAccess(), !ids.isEmpty,
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
              !Task.isCancelled else { return [] }
        return content.windows.filter { ids.contains($0.windowID) && $0.frame.width > 1 }
    }

    /// Captures already-resolved windows; the main-thread predicate is rechecked before publishing each image.
    func capture(_ windows: [SCWindow], width: CGFloat = 720,
                 shouldCapture: @escaping @MainActor (CGWindowID) -> Bool = { _ in true }) async {
        for w in windows {
            guard !Task.isCancelled else { break }
            guard w.frame.width > 1, await MainActor.run(body: { shouldCapture(w.windowID) }) else { continue }
            let cfg = SCStreamConfiguration()
            let scale = width / w.frame.width
            cfg.width = max(1, Int(w.frame.width * scale))
            cfg.height = max(1, Int(w.frame.height * scale))
            cfg.showsCursor = false
            if let img = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: w), configuration: cfg) {
                guard !Task.isCancelled else { break }
                await MainActor.run {
                    guard !Task.isCancelled, shouldCapture(w.windowID) else { return }
                    let state = Self.state
                    state.images[w.windowID] = NSImage(cgImage: img, size: .zero)
                    state.stamps[w.windowID] = Date()
                    state.touch(w.windowID)
                    state.prune()
                }
            }
        }
        onMain { $0.prune() }
    }
}


/// Takes a thumbnail the moment a window is minimized (by any means: yellow button, Cmd+M, the bar, show desktop),
/// so minimized windows keep a recent preview. Nothing runs periodically: it is purely event-driven.
final class MinimizeWatcher {
    static let shared = MinimizeWatcher()
    private let registrationQueue = DispatchQueue(label: "local.cala.thumbnails.ax", qos: .utility)
    private var observers: [pid_t: AXObserver] = [:]
    private var registering: [pid_t: UUID] = [:]
    private var unsupported = Set<pid_t>()
    private var workspaceObservers: [NSObjectProtocol] = []
    private var mouseMonitor: Any?
    private var run: ModuleCancellation?
    private var captures: [CGWindowID: Task<Void, Never>] = [:]

    func start() {
        guard run == nil else { return }
        let run = ModuleCancellation()
        self.run = run
        let nc = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let self, self.run === run,
                  let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self.watch(app)
        })
        workspaceObservers.append(nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let self, self.run === run,
                  let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self.unwatch(app.processIdentifier)
        })
        // Pressing the yellow button: capture right then, before the click completes and minimizing starts.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            guard let self, self.run === run, AXIsProcessTrusted() else { return }
            let p = NSEvent.mouseLocation
            guard let h = NSScreen.screens.first?.frame.height else { return }
            var el: AXUIElement?
            let system = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(system, 0.25)
            guard AXUIElementCopyElementAtPosition(system, Float(p.x), Float(h - p.y), &el) == .success, let el else { return }
            AXUIElementSetMessagingTimeout(el, 0.25)
            guard (WindowService.attr(el, kAXSubroleAttribute) as? String) == "AXMinimizeButton",
                  let win = WindowService.attr(el, kAXWindowAttribute) else { return }
            let window = win as! AXUIElement
            AXUIElementSetMessagingTimeout(window, 0.25)
            var id: CGWindowID = 0
            guard _AXUIElementGetWindow(window, &id) == .success, id != 0 else { return }
            self.capture(id)
        }
        sync()
    }

    func stop() {
        run?.cancel()
        run = nil
        registering.removeAll()
        unsupported.removeAll()
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        workspaceObservers.removeAll()
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        for pid in Array(observers.keys) { unwatch(pid) }
        captures.values.forEach { $0.cancel() }
        captures.removeAll()
    }

    private func unwatch(_ pid: pid_t) {
        registering[pid] = nil
        unsupported.remove(pid)
        guard let observer = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    private func capture(_ id: CGWindowID, onMinimize: Bool = false) {
        guard let run, captures[id] == nil else { return }
        captures[id] = Task { @MainActor [weak self] in
            let windows = await ThumbCache.shared.scWindows(ids: [id])
            guard !Task.isCancelled else { return }
            await ThumbCache.shared.capture(windows)
            guard let self, self.run === run else { return }
            self.captures[id] = nil
            if onMinimize {
                log("minimized window \(id): thumbnail \(ThumbCache.shared.cached(id) != nil ? "saved" : "NOT captured")")
            }
        }
    }

    /// Watches every regular app (also retried later, in case Accessibility was granted after launch).
    func sync() {
        guard run != nil, AXIsProcessTrusted() else { return }
        for a in NSWorkspace.shared.runningApplications where a.activationPolicy == .regular { watch(a) }
    }

    private func watch(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard let run, observers[pid] == nil, registering[pid] == nil, !unsupported.contains(pid),
              pid != ProcessInfo.processInfo.processIdentifier, AXIsProcessTrusted() else { return }
        let request = UUID()
        registering[pid] = request
        registrationQueue.async { [weak self] in
            guard let self, !run.isCancelled else { return }
            let started = DispatchTime.now()
            let (observer, result) = self.registerObserver(pid: pid)
            #if DEBUG
            let milliseconds = (DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
            if result == .notificationUnsupported || result == .notImplemented || milliseconds >= 50 {
                log("thumbnails: AX registration pid=\(pid) result=\(result.rawValue) duration=\(milliseconds)ms")
            }
            #endif
            DispatchQueue.main.async {
                guard self.run === run, self.registering[pid] == request else { return }
                self.registering[pid] = nil
                guard !app.isTerminated else { return }
                if let observer {
                    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
                    self.observers[pid] = observer
                } else if result == .notificationUnsupported || result == .notImplemented {
                    self.unsupported.insert(pid)
                }
            }
        }
    }

    private func registerObserver(pid: pid_t) -> (AXObserver?, AXError) {
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, _, context in
            guard let context else { return }
            let watcher = Unmanaged<MinimizeWatcher>.fromOpaque(context).takeUnretainedValue()
            var id: CGWindowID = 0
            guard _AXUIElementGetWindow(element, &id) == .success, id != 0 else { return }
            // Already captured just before minimizing (mouse-down, Cmd+M, the bar)? Keep that one: it is better.
            if let t = ThumbCache.shared.stamps[id], Date().timeIntervalSince(t) < 5 { return }
            watcher.capture(id, onMinimize: true)
        }
        let created = AXObserverCreate(pid, callback, &observer)
        guard created == .success, let observer else { return (nil, created) }
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.25)
        let result = AXObserverAddNotification(observer, element, kAXWindowMiniaturizedNotification as CFString,
                                               Unmanaged.passUnretained(self).toOpaque())
        return (result == .success ? observer : nil, result)
    }
}

import SwiftUI
import AppKit

// MARK: - UI

final class SwitcherModel: ObservableObject {
    @Published var windows: [WinRef] = []
    @Published var images: [CGWindowID: NSImage] = [:]
    @Published var selected = 0
    var icons: [pid_t: NSImage] = [:]
    var onPick: ((Int) -> Void)?
}

struct SwitcherCard: View {
    @Environment(\.themeAccent) private var accent
    let w: WinRef
    let image: NSImage?
    let icon: NSImage?
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let icon { Image(nsImage: icon).resizable().frame(width: 18, height: 18) }
                Text(w.title.isEmpty ? tx("Untitled", "Sin título") : w.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(width: 196)
            ZStack {
                if let image { Image(nsImage: image).resizable().scaledToFit().opacity(w.minimized ? 0.55 : 1) }
                else if let icon { Image(nsImage: icon).resizable().frame(width: 36, height: 36).opacity(0.45) }
            }
            .frame(width: 196, height: 122)
            .background(Color.black.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 11).fill(selected ? accent.opacity(0.25) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(accent, lineWidth: selected ? 2.5 : 0))
        .contentShape(Rectangle())
    }
}

struct SwitcherView: View {
    @ObservedObject var sm: SwitcherModel
    var body: some View {
        let cols = Array(repeating: GridItem(.fixed(214), spacing: 8), count: min(max(sm.windows.count, 1), 5))
        LazyVGrid(columns: cols, spacing: 8) {
            ForEach(Array(sm.windows.enumerated()), id: \.offset) { i, w in
                SwitcherCard(w: w, image: sm.images[w.id], icon: sm.icons[w.pid], selected: i == sm.selected)
                    .onTapGesture { sm.onPick?(i) }
            }
        }
        .padding(14)
        .themedPanel(radius: 18)
        .fixedSize()
    }
}

// MARK: - Controller + key interception

/// Window switcher (Option+Tab, optionally Cmd+Tab): one card per WINDOW, not per app.
final class WindowSwitcher {
    static let shared = WindowSwitcher()
    let sm = SwitcherModel()
    private let panel: NSPanel
    private let host: NSHostingView<SwitcherView>
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var swallowedKeys = Set<Int64>()
    private var generation = UUID()
    private var collecting = false
    private var pendingMove = 0
    private var pendingCommit = false
    private var collectionInFlight = false
    private var queuedBegin: Bool?
    private(set) var active = false
    private var trigger: CGEventFlags = .maskAlternate

    private init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        host = NSHostingView(rootView: SwitcherView(sm: sm))
        panel.contentView = host
        sm.onPick = { [weak self] i in self?.sm.selected = i; self?.commit() }
    }

    /// Creates the event tap once the needed permissions exist; cheap to call repeatedly.
    func ensureTap() {
        if let t = tap {
            if CFMachPortIsValid(t) {
                if !CGEvent.tapIsEnabled(tap: t) {
                    // keyUps missed while disabled would leave stale entries that eat later keyUps.
                    swallowedKeys.removeAll()
                    CGEvent.tapEnable(tap: t, enable: true)
                }
                if CGEvent.tapIsEnabled(tap: t) { return }
            }
            cancel()
            if let source = tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
            CFMachPortInvalidate(t)
            tapSource = nil; tap = nil
            swallowedKeys.removeAll()
        }
        guard AXIsProcessTrusted() else { return }
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let cb: CGEventTapCallBack = { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                let switcher = WindowSwitcher.shared
                if switcher.active { switcher.cancel() }
                switcher.ensureTap()
                return Unmanaged.passUnretained(event)
            }
            return WindowSwitcher.shared.handle(type, event) ? nil : Unmanaged.passUnretained(event)
        }
        guard let t = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: cb, userInfo: nil) else {
            log("switcher: event tap could not be created (permissions?)"); return
        }
        tap = t
        tapSource = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
        log("switcher: event tap active")
    }

    /// Marks the Cmd+M events re-posted by `repostCmdM` so the tap never intercepts them again.
    private static let repostMarker: Int64 = 0x4D54_434D

    /// Returns true when the event must be swallowed.
    fileprivate func handle(_ type: CGEventType, _ e: CGEvent) -> Bool {
        if e.getIntegerValueField(.eventSourceUserData) == Self.repostMarker { return false }
        let key = e.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyUp { return swallowedKeys.remove(key) != nil }
        let repeating = e.getIntegerValueField(.keyboardEventAutorepeat) != 0
        // Repeats of a swallowed press stay swallowed, even after its modifier is released.
        if type == .keyDown, repeating, swallowedKeys.contains(key) { return true }
        let swallow = decide(type, e, key)
        // A fresh press that reaches the app owns its keyUp, even if an older swallowed keyUp was lost.
        if type == .keyDown, !swallow, !repeating { swallowedKeys.remove(key) }
        return swallow
    }

    private func decide(_ type: CGEventType, _ e: CGEvent, _ key: Int64) -> Bool {
        let cfg = ConfigStore.shared.config
        guard cfg.switcherEnabled else { if active { cancel() }; return false }
        // Cmd+M: swallow it and minimize off the callback (snapshot first: video layers vanish once minimizing starts).
        // If the window turns out not to be minimizable, the original Cmd+M is re-posted to the app instead.
        // Repeats never start an interception: the app already received that press.
        if type == .keyDown, !active, key == 46, e.getIntegerValueField(.keyboardEventAutorepeat) == 0,
           e.flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift]) == .maskCommand,
           let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           pid != ProcessInfo.processInfo.processIdentifier {
            swallowedKeys.insert(key)
            DispatchQueue.global(qos: .userInitiated).async { Self.minimizeFocusedWindow(pid: pid) }
            return true
        }
        let flags = e.flags
        switch type {
        case .keyDown:
            if active {
                // Only navigation with the trigger modifier still held belongs to the switcher; after its
                // release (commit pending while the list is collected) every key reaches the app.
                guard !pendingCommit, flags.contains(trigger), [48, 53, 36, 123, 124, 125, 126].contains(key) else { return false }
                if e.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return true }
                swallowedKeys.insert(key)
                let token = generation
                DispatchQueue.main.async {
                    guard self.active, self.generation == token else { return }
                    switch key {
                    case 48: self.move(flags.contains(.maskShift) ? -1 : 1)
                    case 53: self.cancel()
                    case 36: self.commit()
                    case 123, 126: self.move(-1)
                    case 124, 125: self.move(1)
                    default: break
                    }
                }
                return true
            }
            guard key == 48, e.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return false }
            let mods = flags.intersection([.maskCommand, .maskAlternate, .maskControl])
            if mods == .maskAlternate || (cfg.switcherReplaceCmdTab && mods == .maskCommand) {
                trigger = mods
                active = true; collecting = true
                pendingMove = 0; pendingCommit = false
                generation = UUID()
                let token = generation
                swallowedKeys.insert(key)
                DispatchQueue.main.async {
                    guard self.active, self.generation == token else { return }
                    // A canceled collection still running: start this one when it lands (one in flight).
                    if self.collectionInFlight { self.queuedBegin = flags.contains(.maskShift) }
                    else { self.begin(backwards: flags.contains(.maskShift)) }
                }
                return true
            }
            return false
        case .flagsChanged:
            if active && !pendingCommit && !flags.contains(trigger) {
                pendingCommit = true
                let token = generation
                DispatchQueue.main.async { if self.generation == token { self.commit() } }
            }
            return false
        default:
            return false
        }
    }

    /// Runs on a background queue. Until the minimize is issued, a failed or timed-out check hands the key back to
    /// the app (re-posted Cmd+M, the native behavior). Once issued, nothing is re-posted, whatever the result
    /// (a timeout is unknown, not failed), so one Cmd+M never acts twice.
    private static func minimizeFocusedWindow(pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let value = WindowService.attr(app, kAXFocusedWindowAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return repostCmdM(pid) }
        let window = value as! AXUIElement
        AXUIElementSetMessagingTimeout(window, 0.25)
        guard (WindowService.attr(window, "AXFullScreen") as? Bool) == false,
              let value = WindowService.attr(window, kAXMinimizeButtonAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return repostCmdM(pid) }
        let button = value as! AXUIElement
        AXUIElementSetMessagingTimeout(button, 0.25)
        guard (WindowService.attr(button, kAXEnabledAttribute) as? Bool) == true else { return repostCmdM(pid) }
        var id: CGWindowID = 0
        if _AXUIElementGetWindow(window, &id) == .success, id != 0 {
            WindowService.minimize(WinRef(id: id, title: "", minimized: false, ax: window, pid: pid))
        } else {
            _ = AXUIElementPerformAction(button, kAXPressAction as CFString)
        }
    }

    private static func repostCmdM(_ pid: pid_t) {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: 46, keyDown: down)
            e?.flags = .maskCommand
            e?.setIntegerValueField(.eventSourceUserData, value: repostMarker)
            e?.postToPid(pid)
        }
    }

    private func begin(backwards: Bool) {
        let token = generation
        let pids = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map(\.processIdentifier)
        collectionInFlight = true
        DispatchQueue.global(qos: .userInitiated).async {
            let list = Self.collect(pids: pids)
            DispatchQueue.main.async {
                self.collectionInFlight = false
                if let back = self.queuedBegin {
                    self.queuedBegin = nil
                    if self.active, self.collecting { self.begin(backwards: back) }
                    return
                }
                guard self.active, self.generation == token else { return }
                self.collecting = false
                guard !list.isEmpty else { self.cancel(); return }
                log("switcher: open with \(list.count) windows")
                self.sm.windows = list
                self.sm.selected = list.count > 1 ? (backwards ? list.count - 1 : 1) : 0
                self.move(self.pendingMove)
                self.sm.images = list.reduce(into: [:]) { if let i = ThumbCache.shared.cached($1.id) { $0[$1.id] = i } }
                self.sm.icons = Dictionary(list.map { $0.pid }.reduce(into: Set<pid_t>()) { $0.insert($1) }.compactMap { pid in
                    NSRunningApplication(processIdentifier: pid)?.icon.map { (pid, $0) } }, uniquingKeysWith: { a, _ in a })
                if self.pendingCommit { self.commit(); return }
                self.show()
                let ids = list.filter { !$0.minimized }.map(\.id)
                Task {
                    let all = await ThumbCache.shared.capture(ids: ids)
                    await MainActor.run {
                        if self.active, self.generation == token { self.sm.images.merge(all) { $1 } }
                    }
                }
            }
        }
    }

    private func move(_ d: Int) {
        if collecting { pendingMove += d; return }
        let n = sm.windows.count
        guard n > 0 else { return }
        sm.selected = (sm.selected + d % n + n) % n
    }

    private func commit() {
        guard active else { return }
        if collecting { pendingCommit = true; return }
        active = false
        panel.orderOut(nil)
        log("switcher: pick #\(sm.selected)")
        if sm.windows.indices.contains(sm.selected) { WindowService.raise(sm.windows[sm.selected]) }
    }

    private func cancel() {
        generation = UUID()
        collecting = false
        queuedBegin = nil
        active = false
        panel.orderOut(nil)
    }

    private func show() {
        host.layoutSubtreeIfNeeded()
        let s = host.fittingSize
        let m = NSEvent.mouseLocation
        guard let sc = NSScreen.screens.first(where: { $0.frame.contains(m) }) ?? NSScreen.main ?? NSScreen.screens.first else { cancel(); return }
        let f = sc.frame
        panel.setFrame(NSRect(x: f.midX - s.width / 2, y: f.midY - s.height / 2, width: s.width, height: s.height), display: true)
        panel.orderFrontRegardless()
    }

    /// Windows in most-recently-used order (on-screen z-order), then minimized / other ones.
    private static func collect(pids: [pid_t]) -> [WinRef] {
        let me = ProcessInfo.processInfo.processIdentifier
        var cache: [pid_t: [WinRef]] = [:]
        func wins(_ pid: pid_t) -> [WinRef] {
            if let c = cache[pid] { return c }
            let w = WindowService.windows(for: pid); cache[pid] = w; return w
        }
        var out: [WinRef] = []
        var seen = Set<CGWindowID>()
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for d in info {
            guard (d[kCGWindowLayer as String] as? Int) == 0,
                  let pid = d[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let num = d[kCGWindowNumber as String] as? CGWindowID,
                  !seen.contains(num), let w = wins(pid).first(where: { $0.id == num }) else { continue }
            out.append(w); seen.insert(num)
        }
        for pid in pids where pid != me {
            for w in wins(pid) where !seen.contains(w.id) { out.append(w); seen.insert(w.id) }
        }
        return Array(out.prefix(20))
    }
}

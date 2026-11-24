import SwiftUI
import AppKit

// MARK: - UI

final class SwitcherModel: ObservableObject {
    /// Everything collected; `windows` is what the current search shows.
    @Published var all: [WinRef] = []
    @Published var windows: [WinRef] = []
    @Published var query = ""
    /// Once true, letters (including W/Q/M) go to the search instead of acting on the selection.
    @Published var searching = false
    @Published var images: [CGWindowID: NSImage] = [:]
    @Published var selected = 0
    var icons: [pid_t: NSImage] = [:]
    var onPick: ((Int) -> Void)?

    func refilter(keeping id: CGWindowID? = nil) {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        windows = q.isEmpty ? all : all.filter {
            $0.title.lowercased().contains(q) || (appNames[$0.pid]?.lowercased().contains(q) ?? false)
        }
        if let id, let i = windows.firstIndex(where: { $0.id == id }) { selected = i }
        else { selected = 0 }
    }
    var appNames: [pid_t: String] = [:]
}

struct SwitcherCard: View {
    @Environment(\.themeAccent) private var accent
    let w: WinRef
    let image: NSImage?
    let icon: NSImage?
    let selected: Bool
    var width: CGFloat = SwitcherLayout.maxCardWidth

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let icon { Image(nsImage: icon).resizable().frame(width: 18, height: 18) }
                Text(w.title.isEmpty ? tx("Untitled", "Sin título") : w.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(width: width)
            ZStack {
                if let image { Image(nsImage: image).resizable().scaledToFit().opacity(w.minimized ? 0.55 : 1) }
                else if let icon { Image(nsImage: icon).resizable().frame(width: 36, height: 36).opacity(0.45) }
            }
            .frame(width: width, height: width * SwitcherLayout.aspect)
            .background(Color.black.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 11).fill(selected ? accent.opacity(0.25) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(accent, lineWidth: selected ? 2.5 : 0))
        .contentShape(Rectangle())
    }
}

/// Card sizing: big previews, shrunk only as far as needed to keep the grid inside the screen.
enum SwitcherLayout {
    static let maxCardWidth: CGFloat = 360
    static let aspect: CGFloat = 0.625
    static let chrome: CGFloat = 16 + 6 + 18   // card padding + header spacing + header height
    static let footer: CGFloat = 34
    static let gap: CGFloat = 8

    static func layout(count n: Int, screen: CGSize) -> (cols: Int, width: CGFloat) {
        let count = max(n, 1)
        let availW = screen.width * 0.92 - 28, availH = screen.height * 0.85 - 28 - footer
        var best: (cols: Int, width: CGFloat) = (1, 120)
        for cols in 1...min(count, 6) {
            let rows = (count + cols - 1) / cols
            let byW = (availW - CGFloat(cols - 1) * gap) / CGFloat(cols) - 16
            let byH = (availH - CGFloat(rows - 1) * gap) / CGFloat(rows) - chrome - 16 + 16
            let w = min(maxCardWidth, byW, byH / aspect)
            if w > best.width || (w == best.width && cols > best.cols) { best = (cols, w) }
        }
        return best
    }
}

struct SwitcherView: View {
    @ObservedObject var sm: SwitcherModel
    var body: some View {
        let size = (NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main)?.frame.size ?? CGSize(width: 1440, height: 900)
        let lay = SwitcherLayout.layout(count: sm.windows.count, screen: size)
        let cols = Array(repeating: GridItem(.fixed(lay.width + 16), spacing: SwitcherLayout.gap), count: lay.cols)
        LazyVGrid(columns: cols, spacing: SwitcherLayout.gap) {
            ForEach(Array(sm.windows.enumerated()), id: \.offset) { i, w in
                SwitcherCard(w: w, image: sm.images[w.id], icon: sm.icons[w.pid], selected: i == sm.selected, width: lay.width)
                    .onTapGesture { sm.onPick?(i) }
            }
        }
        .padding(14)
        .padding(.bottom, SwitcherLayout.footer)
        .overlay(alignment: .bottom) { SwitcherFooter(sm: sm).padding(.bottom, 10).padding(.horizontal, 14) }
        .themedPanel(radius: 18)
        .fixedSize()
    }
}

struct SwitcherFooter: View {
    @ObservedObject var sm: SwitcherModel
    var body: some View {
        HStack(spacing: 8) {
            if sm.searching || !sm.query.isEmpty {
                Image(systemName: "magnifyingglass").font(.system(size: 11))
                Text(sm.query.isEmpty ? tx("Type to search…", "Escribe para buscar…") : sm.query).font(.system(size: 12, weight: .medium))
                if sm.windows.isEmpty { Text(tx("No matches", "Sin resultados")).font(.system(size: 11)).opacity(0.6) }
            } else {
                Text(tx("W close · Q quit app · M minimize/restore · type to search", "W cerrar · Q salir de la app · M minimizar/restaurar · escribe para buscar"))
                    .font(.system(size: 11)).opacity(0.6)
            }
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .center)
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
                guard !pendingCommit, flags.contains(trigger) else { return false }
                let nav = [48, 53, 36, 123, 124, 125, 126].contains(key)
                // Typed characters (letters, digits, space) and Backspace belong to the switcher too.
                let typed: String? = nav || key == 51 ? nil : NSEvent(cgEvent: e)?.charactersIgnoringModifiers?.lowercased()
                let isTyped = typed.map { $0.count == 1 && ($0.first!.isLetter || $0.first!.isNumber || $0 == " " || $0 == "/") } ?? false
                guard nav || key == 51 || isTyped else { return false }
                if e.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return true }
                swallowedKeys.insert(key)
                let token = generation
                if key == 51 || isTyped {
                    let ch = typed
                    DispatchQueue.main.async {
                        guard self.active, self.generation == token else { return }
                        if key == 51 { self.backspace() } else if let ch { self.type(ch) }
                    }
                    return true
                }
                DispatchQueue.main.async {
                    guard self.active, self.generation == token else { return }
                    switch key {
                    case 48: self.move(flags.contains(.maskShift) ? -1 : 1)
                    case 53: if self.sm.query.isEmpty && !self.sm.searching { self.cancel() } else { self.clearSearch() }
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
                self.sm.query = ""; self.sm.searching = false
                self.sm.all = list
                self.sm.windows = list
                self.sm.selected = list.count > 1 ? (backwards ? list.count - 1 : 1) : 0
                self.move(self.pendingMove)
                self.sm.images = list.reduce(into: [:]) { if let i = ThumbCache.shared.cached($1.id) { $0[$1.id] = i } }
                self.sm.appNames = Dictionary(list.map { $0.pid }.reduce(into: Set<pid_t>()) { $0.insert($1) }.compactMap { pid in
                    NSRunningApplication(processIdentifier: pid)?.localizedName.map { (pid, $0) } }, uniquingKeysWith: { a, _ in a })
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

    // MARK: search and window actions

    private func type(_ ch: String) {
        if ch == "/" { if sm.query.isEmpty { sm.searching = true; resizeSoon() }; return }
        if !sm.searching && sm.query.isEmpty, let cmd = ["w": Action.close, "q": .quit, "m": .minimize][ch] {
            perform(cmd); return
        }
        sm.searching = true
        sm.query += ch
        sm.refilter()
        resizeSoon()
    }

    private func backspace() {
        guard !sm.query.isEmpty else { return }
        sm.query.removeLast()
        if sm.query.isEmpty { sm.searching = false }
        sm.refilter()
        resizeSoon()
    }

    private func clearSearch() {
        sm.query = ""; sm.searching = false
        sm.refilter()
        resizeSoon()
    }

    private enum Action { case close, quit, minimize }

    private func perform(_ a: Action) {
        guard sm.windows.indices.contains(sm.selected) else { return }
        let w = sm.windows[sm.selected]
        switch a {
        case .close:
            DispatchQueue.global(qos: .userInitiated).async { WindowService.close(w) }
            remove { $0.id == w.id }
        case .quit:
            NSRunningApplication(processIdentifier: w.pid)?.terminate()
            remove { $0.pid == w.pid }
        case .minimize:
            guard let ax = w.ax else { return }
            let flipped = WinRef(id: w.id, title: w.title, minimized: !w.minimized, ax: ax, pid: w.pid)
            if w.minimized {
                AXUIElementSetAttributeValue(ax, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            } else {
                WindowService.minimize(w)
            }
            if let i = sm.all.firstIndex(where: { $0.id == w.id }) { sm.all[i] = flipped }
            if let i = sm.windows.firstIndex(where: { $0.id == w.id }) { sm.windows[i] = flipped }
        }
    }

    /// Drops windows from the list right away; the selection stays on the next card.
    private func remove(_ gone: (WinRef) -> Bool) {
        let at = sm.selected
        sm.all.removeAll(where: gone)
        sm.windows.removeAll(where: gone)
        if sm.windows.isEmpty && sm.query.isEmpty { cancel(); return }
        sm.selected = min(at, max(sm.windows.count - 1, 0))
        resizeSoon()
    }

    private func resizeSoon() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.active else { return }
            self.show()
        }
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

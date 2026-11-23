import AppKit
import Combine
import IOKit.ps

struct AppItem: Identifiable, Equatable {
    let id: String
    let name: String
    let icon: NSImage
    let url: URL?
    let pid: pid_t?
    let pinned: Bool

    static func == (a: AppItem, b: AppItem) -> Bool { a.id == b.id && a.pid == b.pid && a.pinned == b.pinned }
}

final class TaskbarModel: ObservableObject {
    @Published var items: [AppItem] = []
    @Published var frontPID: pid_t = 0
    @Published var hovered: AppItem?
    @Published var startHover = false
    @Published var deskHover = false
    @Published var badges: [String: String] = [:]
    @Published var usage: [UsageState] = []
    @Published var trayHover: String?
    /// Running apps that currently have no windows (shown with a dot instead of the bar).
    @Published var windowless: Set<pid_t> = []
    /// Icon being dragged, the screen it is on and its ghost's center x (bar coordinates).
    @Published var dragID: String?
    @Published var dragScreen = ""
    @Published var dragX: CGFloat = 0
    /// Items whose app is opening (see LaunchFeedback): their icon pulses until a window appears.
    @Published var launching: Set<String> = []
    @Published var batt: (pct: Int, charging: Bool, isCharging: Bool)?
    @Published var disk: DiskInfo?
    @Published var wifiOn = true
    @Published var wifiConnected = true
    @Published var volume: Float = 0.5
    @Published var muted = false
    @Published var btOn = false
    @Published var wifiSignal: Double = 1
    @Published var userPhoto: NSImage?
    private var photoLoaded = false
    @Published var hasBright = false
    @Published var kbCode = ""
    var frames: [String: CGRect] = [:]
    private var lastOwnCount = 0
    var hoverSince = Date()
    let store: ConfigStore
    private var bag = Set<AnyCancellable>()

    init(store: ConfigStore) {
        self.store = store
        let nc = NSWorkspace.shared.notificationCenter
        [NSWorkspace.didLaunchApplicationNotification,
         NSWorkspace.didTerminateApplicationNotification,
         NSWorkspace.didActivateApplicationNotification].forEach { name in
            nc.publisher(for: name).receive(on: DispatchQueue.main).sink { [weak self] _ in self?.rebuild() }.store(in: &bag)
        }
        store.$config.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.rebuild() }.store(in: &bag)
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
            NotificationCenter.default.publisher(for: name).receive(on: DispatchQueue.main).sink { [weak self] _ in
                // After the close/minimize has actually happened.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self?.rebuild() }
            }.store(in: &bag)
        }
        UsageService.shared.$providers.receive(on: DispatchQueue.main).sink { [weak self] in self?.usage = $0 }.store(in: &bag)
        rebuild()
        watchPower()
        disk = DiskInfo.read()
    }

    /// Event-driven: macOS calls back the moment the power source (plug / unplug) or charge state changes,
    /// so there is no polling and no CPU cost while nothing happens.
    private func watchPower() {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        guard let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let m = Unmanaged<TaskbarModel>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { m.batt = SystemTray.battery() }
        }, ctx)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        batt = SystemTray.battery()
    }

    private func key(_ a: NSRunningApplication) -> String {
        a.bundleIdentifier ?? a.bundleURL?.path ?? "pid\(a.processIdentifier)"
    }

    /// Cala's own windows (Settings, Report a problem, Free up space). The bar's panels and flyouts are NSPanels and
    /// are not counted: only real, titled windows.
    static func ownWindows() -> [NSWindow] {
        NSApp.windows.filter { !($0 is NSPanel) && $0.styleMask.contains(.titled) && ($0.isVisible || $0.isMiniaturized) }
    }

    func rebuild() {
        frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        let me = ProcessInfo.processInfo.processIdentifier
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != me }
        var byKey: [String: NSRunningApplication] = [:]
        for a in running { byKey[key(a)] = a }

        var out: [AppItem] = []
        var used = Set<String>()
        for bid in store.config.pinned {
            if let r = byKey[bid] {
                out.append(item(r, pinned: true)); used.insert(bid)
            } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
                let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
                out.append(AppItem(id: bid, name: name, icon: NSWorkspace.shared.icon(forFile: url.path),
                                   url: url, pid: nil, pinned: true))
            }
        }
        let rest = running.filter { !used.contains(key($0)) }
            .sorted { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }
        for a in rest { out.append(item(a, pinned: false)) }
        // While one of Cala's own windows is open, show Cala on the bar so it is never forgotten behind other windows.
        let ownCount = Self.ownWindows().count
        if ownCount != lastOwnCount { lastOwnCount = ownCount; log("bar: Cala windows open = \(ownCount)") }
        if ownCount > 0 {
            out.append(AppItem(id: Bundle.main.bundleIdentifier ?? "local.cala", name: "Cala", icon: NSApp.applicationIconImage,
                               url: Bundle.main.bundleURL, pid: me, pinned: false))
        }
        let order = store.config.order
        if !order.isEmpty {
            let idx = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            out = out.enumerated().sorted {
                let a = idx[$0.element.id] ?? Int.max, b = idx[$1.element.id] ?? Int.max
                return a != b ? a < b : $0.offset < $1.offset
            }.map(\.element)
        }
        if out != items { items = out }
    }

    private func item(_ a: NSRunningApplication, pinned: Bool) -> AppItem {
        AppItem(id: key(a), name: a.localizedName ?? "App",
                icon: a.icon ?? NSImage(named: NSImage.applicationIconName) ?? NSImage(),
                url: a.bundleURL, pid: a.processIdentifier, pinned: pinned)
    }

    func refreshTray() {
        let battery = SystemTray.battery()
        if batt?.pct != battery?.pct || batt?.charging != battery?.charging || batt?.isCharging != battery?.isCharging { batt = battery }
        let diskNow = DiskInfo.read()
        if disk != diskNow { disk = diskNow }
        let wifi = SystemTray.wifiOn() ?? true
        if wifiOn != wifi { wifiOn = wifi }
        let connected = SystemTray.wifiConnected()
        if wifiConnected != connected { wifiConnected = connected }
        let vol = SystemTray.volume() ?? volume
        if volume != vol { volume = vol }
        let mute = SystemTray.muted()
        if muted != mute { muted = mute }
        let bluetooth = Bluetooth.on
        if btOn != bluetooth { btOn = bluetooth }
        let signal = SystemTray.signal(SystemTray.rssi())
        if wifiSignal != signal { wifiSignal = signal }
        if !photoLoaded { photoLoaded = true; DispatchQueue.global().async { let i = Users.photo(NSUserName()); DispatchQueue.main.async { if self.userPhoto != i { self.userPhoto = i } } } }
        let bright = Brightness.get() != nil
        if hasBright != bright { hasBright = bright }
        let code = Keyboard.current()?.code ?? ""
        if kbCode != code { kbCode = code }
    }

    func badge(for item: AppItem) -> String? {
        if let b = badges[item.name] { return b }
        if let p = item.url?.path, let b = badges["path:" + p] { return b }
        return nil
    }

    /// Returns true when the click opens something (launch or reopen) rather than raising/minimizing a window.
    @discardableResult
    func click(_ item: AppItem) -> Bool {
        if let pid = item.pid {
            return WindowService.toggle(pid: pid)
        } else if let url = item.url {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            return true
        }
        return false
    }

    /// Moves an icon to the position of another one (drag reorder).
    func move(_ id: String, to target: String) {
        var ids = items.map(\.id)
        guard id != target, let from = ids.firstIndex(of: id), let to = ids.firstIndex(of: target) else { return }
        ids.insert(ids.remove(at: from), at: to)
        var c = store.config
        c.order = ids
        store.config = c
    }

    func togglePin(_ item: AppItem) {
        var c = store.config
        if let i = c.pinned.firstIndex(of: item.id) { c.pinned.remove(at: i) } else { c.pinned.append(item.id) }
        store.config = c
    }
}

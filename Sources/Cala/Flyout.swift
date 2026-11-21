import SwiftUI
import AppKit
import Combine
import CoreWLAN
import IOKit.ps

let trayBT = "__t_bt", trayBright = "__t_bright", trayUser = "__t_user", trayKB = "__t_kb", trayClock = "__t_clock"

final class FlyoutModel: ObservableObject {
    @Published var kind = ""
    @Published var token = 0
    @Published var availableHeight: CGFloat = 700
    /// The pane was opened from the "^" overflow panel, so it shows a back button.
    @Published var fromMore = false
}

struct Row: View {
    @Environment(\.themeAccent) private var accent
    let icon: String?
    let title: String
    var subtitle: String? = nil
    var checked = false
    var image: NSImage? = nil
    var shape: AnyView? = nil
    var level: Double? = nil
    var action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let image { Image(nsImage: image).resizable().scaledToFill().frame(width: 28, height: 28).clipShape(Circle()) }
                else if let shape { shape.frame(width: 18, height: 18).flyoutSecondary() }
                else if let level { Image(systemName: "wifi", variableValue: level).frame(width: 18).flyoutSecondary() }
                else if let icon { Image(systemName: icon).frame(width: 18).flyoutSecondary() }
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.system(size: 13, weight: checked ? .semibold : .regular)).lineLimit(1)
                    if let subtitle { Text(subtitle).font(.system(size: 11)).flyoutSecondary() }
                }
                Spacer(minLength: 8)
                if checked { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(accent) }
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(hover ? 0.09 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct Header: View {
    let title: String
    var isOn: Binding<Bool>? = nil
    var body: some View {
        HStack {
            Text(title).font(.system(size: 14, weight: .semibold))
            Spacer()
            if let isOn { Toggle(title, isOn: isOn).labelsHidden() }
        }
    }
}

struct SliderRow: View {
    let low: String, high: String
    @Binding var value: Double
    var onChange: (Double) -> Void
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: low).frame(width: 18).flyoutSecondary()
            FlyoutSlider(value: $value, onChange: onChange).frame(height: 22)
            Image(systemName: high).frame(width: 20).flyoutSecondary()
        }
    }
}

struct LinkRow: View {
    let title: String, pane: String
    var body: some View {
        Row(icon: "gearshape", title: title) {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:" + pane)!)
        }
    }
}

struct FlyoutView: View {
    @ObservedObject var fm: FlyoutModel
    @ObservedObject var model: TaskbarModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if fm.fromMore && fm.kind != trayMore {
                Button { fm.fromMore = false; fm.kind = trayMore; fm.token += 1 } label: {
                    Label("Más", systemImage: "chevron.left").font(.system(size: 11.5, weight: .medium))
                }.buttonStyle(.plain).flyoutSecondary()
            }
            Group {
            switch fm.kind {
            case trayWifi: WifiPane(model: model)
            case trayVol: VolumePane(model: model)
            case trayBT: BluetoothPane(model: model)
            case trayBatt: BatteryPane(model: model)
            case trayBright: BrightPane()
            case trayDisk: DiskPane(model: model)
            case traySystem: SystemPane()
            case trayMore: MorePane(fm: fm, model: model)
            case trayDownloads: DownloadsPane()
            case trayTrash: TrashPane()
            case trayUser: UserPane()
            case trayKB: KeyboardPane(model: model)
            case trayClock: CalendarPane(maxAgendaHeight: min(400, max(60, fm.availableHeight - 480)))
            case trayUsage, UsageProvider.claude.trayID, UsageProvider.codex.trayID: UsagePane(model: model)
            default: EmptyView()
            }
            }
        }
        .id(fm.token)
        .padding(18)
        .frame(width: fm.kind.hasPrefix("__t_usage_") || fm.kind == trayClock || fm.kind == trayDisk || fm.kind == traySystem ? 380 : 316)
        .flyoutControls()
        .themedPanel()
        .fixedSize()
    }
}

struct WifiPane: View {
    @ObservedObject var model: TaskbarModel
    @State private var rev = 0
    var body: some View {
        let w = WifiInfo.shared
        let cur = w.current
        let known = w.known
        let _ = rev
        VStack(alignment: .leading, spacing: 4) {
            Header(title: "Wi-Fi", isOn: Binding(get: { model.wifiOn }, set: { v in
                try? CWWiFiClientShim.setPower(v); model.refreshTray()
            }))
            if model.wifiOn {
                Divider().padding(.vertical, 2)
                if let cur { Row(icon: "wifi", title: cur, subtitle: "Conectado", checked: true, level: model.wifiSignal) {} }
                else { Text(model.wifiConnected ? "Conectado" : "Sin conexión").font(.system(size: 12)).flyoutSecondary() }
                let near = w.nearby.filter { $0.ssid != cur }
                let nearKnown = near.filter { known.contains($0.ssid) }
                let others = near.filter { !known.contains($0.ssid) }.prefix(6)
                if !nearKnown.isEmpty {
                    Text("Redes conocidas").font(.system(size: 11)).flyoutSecondary().padding(.top, 4)
                    ForEach(nearKnown, id: \.ssid) { n in Row(icon: "wifi", title: n.ssid, level: SystemTray.signal(n.rssi)) { w.connect(n.ssid) } }
                }
                if !others.isEmpty {
                    Text("Otras redes").font(.system(size: 11)).flyoutSecondary().padding(.top, 4)
                    ForEach(Array(others), id: \.ssid) { n in
                        Row(icon: "wifi", title: n.ssid, subtitle: n.secure ? "Con contraseña" : nil, level: SystemTray.signal(n.rssi)) { w.connect(n.ssid) }
                    }
                }
                if near.isEmpty && cur != nil { EmptyView() }
                else if near.isEmpty { Text("Buscando redes…").font(.system(size: 12)).flyoutSecondary() }
            }
            Divider().padding(.vertical, 2)
            LinkRow(title: "Ajustes de Wi-Fi…", pane: "com.apple.wifi-settings-extension")
        }
        .onAppear { WifiInfo.shared.scan() }
        .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in rev += 1 }
    }
}

struct VolumePane: View {
    @ObservedObject var model: TaskbarModel
    @State private var v: Double = 0.5
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Header(title: "Sonido", isOn: Binding(get: { !model.muted }, set: { SystemTray.setMuted(!$0); model.refreshTray() }))
            SliderRow(low: "speaker.fill", high: "speaker.wave.3.fill", value: $v) { SystemTray.setVolume(Float($0)); model.refreshTray() }
            Divider()
            LinkRow(title: "Ajustes de sonido…", pane: "com.apple.Sound-Settings.extension")
        }
        .onAppear { v = Double(SystemTray.volume() ?? 0.5) }
    }
}

struct BluetoothPane: View {
    @ObservedObject var model: TaskbarModel
    @State private var devices: [(name: String, addr: String, connected: Bool)] = []
    @State private var on = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Header(title: "Bluetooth", isOn: Binding(get: { on }, set: { Bluetooth.set($0); on = $0; model.refreshTray() }))
            if on {
                Divider().padding(.vertical, 2)
                if devices.isEmpty { Text("Sin dispositivos vinculados").font(.system(size: 12)).flyoutSecondary() }
                ForEach(devices, id: \.addr) { d in
                    Row(icon: nil, title: d.name, subtitle: d.connected ? "Conectado" : nil, checked: d.connected, shape: AnyView(BluetoothShape().stroke(style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)).padding(2))) {
                        Bluetooth.toggle(addr: d.addr)
                    }
                }
            }
            Divider().padding(.vertical, 2)
            LinkRow(title: "Ajustes de Bluetooth…", pane: "com.apple.BluetoothSettings")
        }
        .onAppear { devices = Bluetooth.devices(); on = Bluetooth.on }
        .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in
            devices = Bluetooth.devices(); on = Bluetooth.on
        }
    }
}

struct BrightPane: View {
    @State private var v: Double = 0.5
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Header(title: "Brillo")
            SliderRow(low: "sun.min", high: "sun.max.fill", value: $v) { Brightness.set(Float($0)) }
            Divider()
            LinkRow(title: "Ajustes de pantalla…", pane: "com.apple.Displays-Settings.extension")
        }
        .onAppear { v = Double(Brightness.get() ?? 0.5) }
    }
}

struct UserPane: View {
    @State private var users: [Users.U] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Header(title: "Perfiles")
            Divider().padding(.vertical, 2)
            ForEach(users, id: \.name) { u in
                Row(icon: "person.crop.circle", title: u.full, checked: u.name == NSUserName(), image: u.photo) {
                    if u.name != NSUserName() { Users.switchTo(u.name) }
                }
            }
            Divider().padding(.vertical, 2)
            Row(icon: "lock", title: "Pantalla de inicio de sesión") { Users.lockScreen() }
        }
        .onAppear {
            DispatchQueue.global(qos: .utility).async {
                let loaded = Users.list()
                DispatchQueue.main.async { users = loaded }
            }
        }
    }
}

struct BluetoothShape: Shape {
    func path(in r: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + r.width * x, y: r.minY + r.height * y) }
        var path = Path()
        path.move(to: p(0.12, 0.30)); path.addLine(to: p(0.82, 0.74)); path.addLine(to: p(0.47, 1.0))
        path.addLine(to: p(0.47, 0.0)); path.addLine(to: p(0.82, 0.26)); path.addLine(to: p(0.12, 0.70))
        return path
    }
}

struct KeyboardPane: View {
    @ObservedObject var model: TaskbarModel
    @State private var sources: [Keyboard.Src] = []
    @State private var cur: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Header(title: "Idioma del teclado")
            Divider().padding(.vertical, 2)
            ForEach(sources) { s in
                Row(icon: nil, title: s.name, subtitle: s.code, checked: s.id == cur) {
                    Keyboard.select(s); cur = s.id; model.refreshTray()
                }
            }
            Divider().padding(.vertical, 2)
            LinkRow(title: "Ajustes de teclado…", pane: "com.apple.Keyboard-Settings.extension")
        }
        .onAppear { sources = Keyboard.all(); cur = Keyboard.current()?.id }
    }
}

enum CWWiFiClientShim {
    static func setPower(_ on: Bool) throws { try CWWiFiClient.shared().interface()?.setPower(on) }
}

/// Nonactivating panels can accept key focus without activating the app.
final class FlyoutPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class FlyoutController {
    let panel: NSPanel
    let fm = FlyoutModel()
    private var host: NSHostingView<FlyoutView>!
    private var barTop: CGFloat = 0
    private var centerX: CGFloat = 0
    private var screenFrame = NSRect.zero
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var kindObserver: AnyCancellable?

    init(model: TaskbarModel) {
        panel = FlyoutPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .statusBar; panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        host = NSHostingView(rootView: FlyoutView(fm: fm, model: model))
        panel.contentView = host
        for name in [Notification.Name.flyoutRefit] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.async { self?.refit() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: .flyoutHide, object: nil, queue: .main) { [weak self] _ in self?.hide() })
        kindObserver = fm.$kind.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            DispatchQueue.main.async { if self?.panel.isVisible == true { self?.refit() } }
        }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.panel.isVisible, !self.panel.frame.contains(NSEvent.mouseLocation) else { return }
            self.hide()
        }
    }

    var isVisible: Bool { panel.isVisible }
    var kind: String { fm.kind }
    func contains(_ p: NSPoint) -> Bool { panel.isVisible && panel.frame.insetBy(dx: -4, dy: -4).contains(p) }

    func show(kind: String, barTop: CGFloat, centerX: CGFloat, screen: NSScreen) {
        self.barTop = barTop; self.centerX = centerX; self.screenFrame = screen.frame
        fm.availableHeight = max(300, screen.visibleFrame.height - 90)
        if kind == trayDisk { DiskService.shared.refresh(extra: ConfigStore.shared.config.diskFolders) }
        fm.fromMore = false
        fm.kind = kind; fm.token += 1
        refit()
        panel.makeKeyAndOrderFront(nil)
    }

    func refit() {
        host.layoutSubtreeIfNeeded()
        let s = host.fittingSize
        var x = centerX - s.width / 2
        x = max(screenFrame.minX + 8, min(x, screenFrame.maxX - s.width - 8))
        let r = NSRect(x: x, y: barTop + 6, width: s.width, height: s.height)
        if r != panel.frame { panel.setFrame(r, display: true) }
    }

    func hide() { fm.kind = ""; panel.orderOut(nil) }
}

struct BatteryPane: View {
    @ObservedObject var model: TaskbarModel
    @State private var low = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var pending = false

    var remaining: String? {
        let t = IOPSGetTimeRemainingEstimate()
        guard t > 0 else { return nil }
        let m = Int(t / 60)
        return "\(m / 60) h \(m % 60) min restantes"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Header(title: "Batería")
            Divider().padding(.vertical, 2)
            let ac = model.batt?.charging ?? true
            Row(icon: ac ? "powerplug.fill" : "battery.100", title: ac ? "Adaptador de corriente" : "Batería",
                subtitle: model.batt.map { "\($0.pct)%" + (ac ? "" : (remaining.map { " · " + $0 } ?? "")) }) {}
            HStack {
                Image(systemName: "leaf.fill").frame(width: 18).flyoutSecondary()
                Text("Modo de bajo consumo").font(.system(size: 13))
                Spacer()
                Toggle("", isOn: Binding(get: { low }, set: { v in
                    low = v
                    let cmd = "do shell script \"pmset -a lowpowermode \(v ? 1 : 0)\" with administrator privileges"
                    DispatchQueue.global().async {
                        let p = Process()
                        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                        p.arguments = ["-e", cmd]
                        p.standardOutput = FileHandle.nullDevice
                        p.standardError = FileHandle.nullDevice
                        do { try p.run(); p.waitUntilExit() }
                        catch { log("low power: osascript failed: \(error)") }
                        DispatchQueue.main.async { low = ProcessInfo.processInfo.isLowPowerModeEnabled }
                    }
                })).labelsHidden()
            }

            Divider().padding(.vertical, 2)
            LinkRow(title: "Ajustes de batería…", pane: "com.apple.Battery-Settings.extension")
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            low = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }
}


struct CalendarPane: View {
    @ObservedObject var store = ConfigStore.shared
    @ObservedObject var agenda = CalendarService.shared
    var maxAgendaHeight: CGFloat = 240
    @Environment(\.themeAccent) private var accent
    @State private var offset = 0
    private let cal = Calendar.current
    private var month: Date { cal.date(byAdding: .month, value: offset, to: Date())! }

    private var days: [Date?] {
        let start = cal.date(from: cal.dateComponents([.year, .month], from: month))!
        let n = cal.range(of: .day, in: .month, for: start)!.count
        let lead = (cal.component(.weekday, from: start) - cal.firstWeekday + 7) % 7
        return Array(repeating: nil, count: lead) + (0..<n).map { cal.date(byAdding: .day, value: $0, to: start) }
    }
    private var weekdays: [String] {
        let s = cal.veryShortStandaloneWeekdaySymbols
        return (0..<7).map { s[(cal.firstWeekday - 1 + $0) % 7].uppercased() }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                VStack(alignment: .leading, spacing: 0) {
                    Text(ctx.date, format: .dateTime.hour().minute().second()).font(.system(size: 28, weight: .light))
                    Text(ctx.date, format: .dateTime.weekday(.wide).day().month(.wide).year())
                        .font(.system(size: 12)).flyoutSecondary()
                }
            }
            Divider()
            HStack {
                Text(month, format: .dateTime.month(.wide).year()).font(.system(size: 13, weight: .semibold))
                Spacer()
                nav("chevron.up") { offset -= 1 }.help(calendarText("Previous month", "Mes anterior"))
                nav("chevron.down") { offset += 1 }.help(calendarText("Next month", "Mes siguiente"))
            }
            let cols = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
            LazyVGrid(columns: cols, spacing: 2) {
                ForEach(Array(weekdays.enumerated()), id: \.offset) { _, d in
                    Text(d).font(.system(size: 10, weight: .medium)).flyoutSecondary().frame(height: 20)
                }
                ForEach(Array(days.enumerated()), id: \.offset) { _, d in
                    if let d {
                        let today = cal.isDateInToday(d)
                        Text("\(cal.component(.day, from: d))")
                            .font(.system(size: 12, weight: today ? .bold : .regular))
                            .foregroundStyle(today ? Color.white : Color.primary)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(today ? accent : Color.clear))
                    } else { Color.clear.frame(height: 30) }
                }
            }
            Divider().padding(.vertical, 2)
            if store.config.calendarEnabled {
                UpcomingEventsView(agenda: agenda, days: store.config.calendarDays, maxHeight: maxAgendaHeight) {
                    agenda.open(config: store.config)
                }
                Divider().padding(.vertical, 2)
            }
            Row(icon: "calendar", title: calendarText("Open Calendar", "Abrir Calendario")) { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app")) }
            if offset != 0 { Row(icon: "arrow.uturn.backward", title: calendarText("Back to today", "Volver a hoy")) { offset = 0 } }
            LinkRow(title: calendarText("Notification settings", "Ajustes de notificaciones"), pane: "com.apple.Notifications-Settings.extension")
        }
        .onAppear { agenda.open(config: store.config) }
        .onChange(of: store.config.calendarEnabled) { _, _ in agenda.open(config: store.config) }
        .onChange(of: store.config.calendarDays) { _, _ in agenda.open(config: store.config) }
        .onChange(of: store.config.calendarExcludedIDs) { _, _ in agenda.open(config: store.config) }
    }

    func nav(_ icon: String, _ a: @escaping () -> Void) -> some View {
        Button(action: a) { Image(systemName: icon).font(.system(size: 11, weight: .semibold)).frame(width: 26, height: 22) }
            .buttonStyle(.plain)
    }
}

struct UsagePane: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var model: TaskbarModel
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("AI plan usage").font(.system(size: 17, weight: .semibold))
                        Text("Remaining allowance").font(.system(size: 12)).flyoutSecondary()
                    }
                    ForEach(model.usage.filter(\.available)) { state in
                        provider(state, now: context.date)
                    }
                }
            }
            .frame(height: paneHeight)
        }
        .onAppear { UsageService.shared.refresh() }
    }
    private var paneHeight: CGFloat {
        var height = 68
        for state in model.usage where state.available {
            height += 100 + max(1, state.reading?.windows.count ?? 0) * 86
            if state.error != nil { height += 32 }
        }
        return CGFloat(min(600, height))
    }
    private func age(_ date: Date?, now: Date) -> String {
        guard let date else { return "Not updated yet" }
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 5 { return "Updated just now" }
        if seconds < 60 { return "Updated \(seconds) s ago" }
        if seconds < 3600 { return "Updated \(seconds / 60) min ago" }
        if seconds < 86400 { return "Updated \(seconds / 3600) h ago" }
        return "Updated \(seconds / 86400) d ago"
    }
    private func resetLabel(_ window: UsageWindow, now: Date) -> String {
        guard let reset = window.resetsAt else { return "Reset time unavailable" }
        if window.isResetting(now) { return "resetting…" }
        let formatter = DateFormatter(); formatter.locale = Locale.current; formatter.timeZone = .current
        formatter.dateFormat = "EEE d, h:mm a"
        let relative = UsagePace.formatted(reset.timeIntervalSince(now))
        return "resets " + formatter.string(from: reset) + " · in " + relative
    }
    private func provider(_ state: UsageState, now: Date) -> some View {
        let retry = max(0, Int(ceil(state.cooldownUntil?.timeIntervalSince(now) ?? 0)))
        let brand = providerColor(state.provider, dark: scheme == .dark)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ProviderMark(provider: state.provider, colored: true).frame(width: 20, height: 20)
                Text(state.provider.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(brand)
                Spacer()
                if let plan = state.reading?.plan ?? state.plan {
                    Text(usagePlanTitle(plan)).font(.system(size: 10, weight: .semibold)).foregroundStyle(brand).lineLimit(1).help(plan)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(brand.opacity(0.12)))
                }
            }
            ForEach(state.orderedWindows) { window in
                let used = window.effectiveUsed(now)
                let remaining = Int((100 - used).rounded())
                let color = FlyoutStyle.quota(remaining, dark: scheme == .dark)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(window.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 4)
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text("\(remaining)%").font(.system(size: 23, weight: .semibold))
                            Text("left").font(.system(size: 11))
                        }.monospacedDigit().foregroundStyle(FlyoutStyle.quotaText(remaining, dark: scheme == .dark)).fixedSize()
                    }
                    GeometryReader { g in
                        Capsule().fill(Color.primary.opacity(0.09))
                            .overlay(alignment: .leading) {
                                Capsule().fill(color).frame(width: g.size.width * max(0, min(1, Double(remaining) / 100)))
                            }
                    }.frame(height: 6)
                    Text(resetLabel(window, now: now)).font(.system(size: 10.5)).flyoutSecondary()
                        .fixedSize(horizontal: false, vertical: true)
                    if let pace = UsagePace.shared.pace(state.provider, window, now: now) {
                        Text(pace.text).font(.system(size: 10.5, weight: pace.warn ? .semibold : .regular))
                            .foregroundStyle(pace.warn ? Color.orange : Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue("\(remaining)% left, \(Int(used.rounded()))% used")
            }
            if let error = state.error {
                Label(error, systemImage: "exclamationmark.circle").font(.system(size: 11)).flyoutSecondary()
                    .fixedSize(horizontal: false, vertical: true)
            } else if state.reading?.windows.isEmpty ?? true {
                Text("Usage unavailable").font(.system(size: 12)).flyoutSecondary()
            }
            Divider()
            HStack(spacing: 6) {
                Text(age(state.reading?.date, now: now)).font(.system(size: 10.5)).flyoutSecondary()
                Spacer(minLength: 0)
                Button {
                    UsageService.shared.refresh(state.provider, force: true)
                } label: {
                    Label(retry > 0 ? "Retry in \(retry)s" : (state.fetching ? "Refreshing…" : "Refresh"), systemImage: "arrow.clockwise")
                        .font(.system(size: 10.5, weight: .medium))
                }
                .buttonStyle(.plain).foregroundStyle(brand)
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(brand.opacity(0.1)))
                .disabled(retry > 0 || state.fetching)
                .help(retry > 0 ? "Rate-limited; wait for the cooldown" : "Refresh " + state.provider.title)
            }
        }
        .padding(12)
        .flyoutSection()
    }
}

// Presentation only: cache values, refresh policy and provider detection stay in Usage.swift.
func usagePlanTitle(_ raw: String) -> String {
    switch raw.lowercased() {
    case "prolite": return "Pro Lite"
    case "plus": return "Plus"
    case "pro", "default_claude_pro": return "Pro"
    case "default_claude_max_5x": return "Max 5x"
    case "default_claude_max_20x": return "Max 20x"
    case "ultra": return "Ultra"
    default: return raw.replacingOccurrences(of: "_", with: " ").capitalized
    }
}


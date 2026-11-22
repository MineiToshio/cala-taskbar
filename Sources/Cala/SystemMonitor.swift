import SwiftUI
import AppKit
import Darwin
import Combine

let traySystem = "__t_system"

/// CPU, memory and per-app load, read with the same system calls Activity Monitor uses (no helper, no admin rights).
/// The cheap numbers (CPU %, memory, pressure) are sampled every few seconds while the tray item is on; the
/// per-process list is only sampled while the panel is open.
final class SystemMonitor: ObservableObject {
    static let shared = SystemMonitor()

    @Published private(set) var cpu = 0.0
    @Published private(set) var cpuUser = 0.0
    @Published private(set) var cpuSystem = 0.0
    @Published private(set) var memoryUsed: UInt64 = 0
    @Published private(set) var memoryTotal = ProcessInfo.processInfo.physicalMemory
    @Published private(set) var memoryApps: UInt64 = 0
    @Published private(set) var memoryWired: UInt64 = 0
    @Published private(set) var memoryCompressed: UInt64 = 0
    @Published private(set) var swapUsed: UInt64 = 0
    @Published private(set) var swapTotal: UInt64 = 0
    @Published private(set) var pressure = MemoryPressure.normal
    @Published private(set) var thermal = ProcessInfo.ThermalState.nominal
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var memoryHistory: [Double] = []
    @Published private var lastReading: ProcessReading?

    var processReading: ProcessReading? {
        guard let lastReading, lastReading.isFresh(at: samplingTime) else { return nil }
        return lastReading
    }

    var heaviestClosableLoad: AppLoad? {
        processReading?.loads.filter { $0.quitPID != nil }.max { $0.memory < $1.memory }
    }

    private var lastTicks: (date: TimeInterval, ticks: CPUTicks)?
    private var recentCPU: [(start: TimeInterval, end: TimeInterval, load: Double)] = []
    private var busySince: TimeInterval?
    private var hotSince: TimeInterval?
    private var pressureSince: TimeInterval?
    private var criticalPressure = CriticalDuration()
    private var criticalThermal = CriticalDuration()
    private var lastProcessSample: ProcessSample?
    private var processGeneration = 0
    private let processQueue = DispatchQueue(label: "local.cala.monitor", qos: .utility)
    private var sampling = false
    private let timebase: mach_timebase_info_data_t = {
        var t = mach_timebase_info_data_t(); mach_timebase_info(&t); return t
    }()

    /// Monotonic time including sleep, used to detect interruptions and expire readings.
    private var samplingTime: TimeInterval {
        Double(mach_continuous_time()) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }

    // MARK: Cheap sampling (main thread)

    func tick() {
        sampleCPU()
        sampleMemory()
        let info = ProcessInfo.processInfo
        let state = info.thermalState
        criticalThermal.observe(state == .critical, at: samplingTime)
        thermal = state
    }

    private struct CPUTicks {
        var user: UInt32
        var system: UInt32
        var idle: UInt32
        var nice: UInt32

        func since(_ previous: Self) -> (user: UInt64, system: UInt64, busy: UInt64, total: UInt64) {
            let user = UInt64(self.user &- previous.user) + UInt64(nice &- previous.nice)
            let system = UInt64(self.system &- previous.system)
            let busy = user + system
            return (user, system, busy, busy + UInt64(idle &- previous.idle))
        }
    }

    private static func readTicks() -> CPUTicks? {
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        var info = host_cpu_load_info()
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        return CPUTicks(user: info.cpu_ticks.0, system: info.cpu_ticks.1, idle: info.cpu_ticks.2, nice: info.cpu_ticks.3)
    }

    private func sampleCPU() {
        let now = ProcessInfo.processInfo.systemUptime
        let previous = lastTicks
        if let previous, now - previous.date < 1.5 { return }
        guard let ticks = Self.readTicks() else { return }
        lastTicks = (now, ticks)
        guard let previous else { return }
        let delta = ticks.since(previous.ticks)
        guard delta.total > 0 else { return }

        cpuUser = Double(delta.user) / Double(delta.total) * 100
        cpuSystem = Double(delta.system) / Double(delta.total) * 100
        cpu = Double(delta.busy) / Double(delta.total) * 100
        cpuHistory.append(cpu)
        if cpuHistory.count > 60 { cpuHistory.removeFirst() }

        recentCPU.append((previous.date, now, cpu))
        recentCPU.removeAll { $0.end <= now - 9 }
        let smooth = smoothedCPU
        busySince = smooth >= SystemRules.busyAt ? (busySince ?? now) : nil
        hotSince = smooth >= SystemRules.hotAt ? (hotSince ?? now) : nil
    }

    private func sampleMemory() {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let r = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        guard r == KERN_SUCCESS else { return }
        let page = UInt64(vm_kernel_page_size)
        let apps = UInt64(stats.internal_page_count &- min(stats.internal_page_count, stats.purgeable_count)) * page
        let wired = UInt64(stats.wire_count) * page
        let compressed = UInt64(stats.compressor_page_count) * page
        memoryApps = apps; memoryWired = wired; memoryCompressed = compressed
        memoryUsed = apps + wired + compressed
        memoryTotal = ProcessInfo.processInfo.physicalMemory
        memoryHistory.append(Double(memoryUsed) / Double(max(1, memoryTotal)) * 100)
        if memoryHistory.count > 60 { memoryHistory.removeFirst() }

        var level: Int32 = 1, size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 {
            let state = MemoryPressure(rawValue: Int(level)) ?? .normal
            let now = ProcessInfo.processInfo.systemUptime
            pressureSince = state == .normal ? nil : pressureSince ?? now
            criticalPressure.observe(state == .critical, at: samplingTime)
            pressure = state
        }
        var swap = xsw_usage(), swapSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 { swapUsed = swap.xsu_used; swapTotal = swap.xsu_total }
    }

    private func minutes(since start: TimeInterval?) -> Double {
        start.map { (ProcessInfo.processInfo.systemUptime - $0) / 60 } ?? 0
    }

    var busyMinutes: Double { minutes(since: busySince) }
    var hotMinutes: Double { minutes(since: hotSince) }
    var pressureMinutes: Double { minutes(since: pressureSince) }

    var smoothedCPU: Double {
        guard let end = recentCPU.last?.end, let start = recentCPU.first?.start else { return cpu }
        let cutoff = max(start, end - 9)
        let weighted = recentCPU.reduce(0) { $0 + $1.load * ($1.end - max($1.start, cutoff)) }
        return weighted / (end - cutoff)
    }

    func snapshot() -> LoadSnapshot {
        let now = samplingTime
        return LoadSnapshot(lastReading: lastReading, observedAt: now, cpuNow: cpu, cpuSmoothed: smoothedCPU,
                     busyMinutes: busyMinutes, hotMinutes: hotMinutes, pressure: pressure, pressureMinutes: pressureMinutes,
                     criticalPressureMinutes: criticalPressure.minutes(at: now), memoryUsed: memoryUsed, memoryTotal: memoryTotal,
                     thermal: thermal, criticalThermalMinutes: criticalThermal.minutes(at: now),
                     lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    // MARK: Per-app sampling (panel open)

    private struct ProcessSample {
        let date: TimeInterval
        let capturedAt: TimeInterval
        let ticks: CPUTicks
        let cpuNs: [pid_t: (start: UInt64, time: UInt64)]
    }

    func sampleProcesses() {
        guard !sampling else { return }
        sampling = true
        let lastSample = lastProcessSample
        let generation = processGeneration
        let apps = NSWorkspace.shared.runningApplications.compactMap { app -> AppRef? in
            guard app.activationPolicy != .prohibited, let url = app.bundleURL else { return nil }
            return AppRef(bundlePath: url.path, name: app.localizedName ?? url.deletingPathExtension().lastPathComponent,
                          pid: app.processIdentifier, regular: app.activationPolicy == .regular)
        }
        let regularPIDs = Dictionary(uniqueKeysWithValues: apps.filter(\.regular).map { ($0.pid, $0.name) })
        let cores = Double(max(1, ProcessInfo.processInfo.activeProcessorCount))
        processQueue.async {
            let capturedAt = self.samplingTime
            let now = ProcessInfo.processInfo.systemUptime
            guard let ticks = Self.readTicks(), let table = Self.processTable() else {
                DispatchQueue.main.async { self.sampling = false }
                return
            }

            // A window across a sampling pause is too old to describe the current load.
            let previous = lastSample.flatMap {
                (0...ProcessReading.maxAge).contains(capturedAt - $0.capturedAt) ? $0 : nil
            }
            let elapsed = previous.map { now - $0.date } ?? 0
            let delta = previous.map { ticks.since($0.ticks) }
            let cpuWindow = delta.flatMap { ticks in
                ticks.total > 0 && elapsed > 0 ? Double(ticks.busy) / Double(ticks.total) * 100 : nil
            }
            var unreadable = 0
            var otherAccounts = 0
            var executableNames: [String: String] = [:]
            let parents = table.mapValues(\.parent)
            let uid = getuid()
            var cpuNs: [pid_t: (start: UInt64, time: UInt64)] = [:]
            var groups: [String: AppLoad] = [:]
            for pid in table.keys.sorted() {
                if let owner = table[pid]?.uid, owner >= 501 && owner != uid { otherAccounts += 1 }
                var usage = rusage_info_v4()
                let result = withUnsafeMutablePointer(to: &usage) {
                    $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
                }
                guard result == 0 else {
                    unreadable += 1
                    continue
                }
                let time = usage.ri_user_time + usage.ri_system_time
                let start = usage.ri_proc_start_abstime
                let denominator = UInt64(max(1, self.timebase.denom))
                let numerator = UInt64(self.timebase.numer)
                let ns = time / denominator * numerator + time % denominator * numerator / denominator
                cpuNs[pid] = (start, ns)
                var cpu = 0.0
                if let before = previous?.cpuNs[pid], before.start == start, ns >= before.time, elapsed > 0 {
                    cpu = Double(ns - before.time) / (elapsed * 1_000_000_000) * 100 / cores
                }
                let (path, executable) = Self.processName(pid)
                let launcher = SystemRules.enclosingApp(path: path, apps: apps) == nil
                    ? SystemRules.launcher(of: pid, parents: parents, apps: regularPIDs) : nil
                let (key, name, kind) = SystemRules.classify(path: path, executable: executable, apps: apps, launcher: launcher)
                var group = groups[key] ?? AppLoad(key: key, name: name, kind: kind, cpu: 0, memory: 0, count: 0, closable: false)
                group.cpu += cpu
                group.memory += usage.ri_phys_footprint
                group.count += 1
                groups[key] = group

                if case .app(let appPID) = kind, appPID == pid {
                    executableNames[key] = executable
                } else if executableNames[key] == nil {
                    executableNames[key] = executable
                }
            }
            let orderedLoads = groups.values.sorted { $0.cpu == $1.cpu ? $0.key < $1.key : $0.cpu > $1.cpu }
            let sample = ProcessSample(date: now, capturedAt: capturedAt, ticks: ticks, cpuNs: cpuNs)
            let details = (unreadable: unreadable, otherAccounts: otherAccounts, executableNames: executableNames)
            DispatchQueue.main.async {
                self.sampling = false
                guard self.processGeneration == generation else { return }
                self.lastProcessSample = sample
                guard let cpuWindow else { return }
                let loads = orderedLoads.map { load in
                    var load = load
                    if case .app(let pid?) = load.kind {
                        load.closable = SystemAdvice.quittable(pid: pid) != nil
                    }
                    return load
                }
                // Advance counters for rejected samples without extending the valid reading's lifetime.
                if let reading = ProcessReading(capturedAt: capturedAt, cpuWindow: cpuWindow, loads: loads,
                                                unreadable: details.unreadable, otherAccounts: details.otherAccounts,
                                                executableNames: details.executableNames) {
                    self.publish(reading)
                }
            }
        }
    }

    private func publish(_ reading: ProcessReading) {
        let now = samplingTime
        guard reading.isFresh(at: now) else { return }
        lastReading = reading

        let capturedAt = reading.capturedAt
        DispatchQueue.main.asyncAfter(deadline: .now() + (reading.expiresAt - now)) { [weak self] in
            guard let self, self.lastReading?.capturedAt == capturedAt else { return }
            self.lastReading = nil
        }
    }

    func resetProcessSample() {
        processGeneration += 1
        lastProcessSample = nil
        lastReading = nil
    }

    private static func processTable() -> [pid_t: (parent: pid_t, uid: uid_t)]? {
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
        let stride = MemoryLayout<kinfo_proc>.stride
        let capacity = (size + size / 8 + stride - 1) / stride
        let buffer = UnsafeMutablePointer<kinfo_proc>.allocate(capacity: capacity)
        defer { buffer.deallocate() }
        size = capacity * stride
        guard sysctl(&mib, u_int(mib.count), buffer, &size, nil, 0) == 0 else { return nil }
        var table: [pid_t: (parent: pid_t, uid: uid_t)] = [:]
        for index in 0..<(size / stride) {
            let info = buffer[index]
            let pid = info.kp_proc.p_pid
            if pid > 0 { table[pid] = (info.kp_eproc.e_ppid, info.kp_eproc.e_ucred.cr_uid) }
        }
        return table
    }

    private static func processName(_ pid: pid_t) -> (path: String, executable: String) {
        var buffer = [CChar](repeating: 0, count: 4096)
        if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 {
            let path = String(cString: buffer)
            return (path, (path as NSString).lastPathComponent)
        }
        var name = [CChar](repeating: 0, count: 256)
        proc_name(pid, &name, UInt32(name.count))
        let executable = String(cString: name)
        return ("", executable.isEmpty ? calendarText("Process \(pid)", "Proceso \(pid)") : executable)
    }
}

func monitorTint(_ m: SystemMonitor) -> Color {
    switch SystemRules.level(m.snapshot()) {
    case .normal: return Color.primary.opacity(0.85)
    case .attention: return .orange
    case .critical: return .red
    }
}

// MARK: - Panel

struct Spark: View {
    let values: [Double]
    let color: Color
    var height: CGFloat = 34
    var body: some View {
        GeometryReader { g in
            let pts = values.suffix(60)
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.06))
                if pts.count > 1 {
                    Path { p in
                        for (i, v) in pts.enumerated() {
                            let x = g.size.width * CGFloat(i) / CGFloat(max(1, 59))
                            let y = g.size.height * (1 - CGFloat(min(100, max(0, v)) / 100))
                            i == 0 ? p.move(to: CGPoint(x: x + g.size.width * CGFloat(60 - pts.count) / 59, y: y)) : p.addLine(to: CGPoint(x: x + g.size.width * CGFloat(60 - pts.count) / 59, y: y))
                        }
                    }.stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .frame(height: height)
    }
}

struct SystemPanelModel {
    var snapshot: LoadSnapshot
    var cpuHistory: [Double]
    var memoryHistory: [Double]
    var maintenance: (text: String, strong: Bool, more: Int)?
    var tab: Int
    var icons: [String: NSImage] = [:]

    var cpuValue: Int { Int((snapshot.cpuWindow ?? snapshot.cpuNow).rounded()) }

    var cpuBreakdown: Breakdown? {
        guard let reading = snapshot.reading else { return nil }
        return SystemRules.cpuBreakdown(reading.loads, total: reading.cpuWindow, lang: Locale.preferredLanguages.first)
    }

    var breakdown: Breakdown? {
        guard tab == 1 else { return cpuBreakdown }
        guard let reading = snapshot.reading else { return nil }
        return SystemRules.memoryBreakdown(reading.loads, used: snapshot.memoryUsed,
                                           lang: Locale.preferredLanguages.first, locale: .current)
    }

    static func initialTab(_ s: LoadSnapshot) -> Int {
        let memory = SystemRules.memoryState(s)
        let cpu = SystemRules.cpuState(smoothed: s.cpuSmoothed, busyMinutes: s.busyMinutes)
        return memory.level > cpu.level ? 1 : 0
    }
}

struct PanelReservation: Equatable {
    var message: CGFloat = 0
    var maintenance: CGFloat = 0
}

private struct PanelReservationKey: PreferenceKey {
    static let defaultValue = PanelReservation()

    static func reduce(value: inout PanelReservation, nextValue: () -> PanelReservation) {
        let next = nextValue()
        value.message = max(value.message, next.message)
        value.maintenance = max(value.maintenance, next.maintenance)
    }
}

struct SystemPane: View {
    private enum Page { case main, restart, details }

    private struct LayoutSignature: Equatable {
        let page: Page
        let kind: SystemMessage.Kind?
        let style: SystemMessage.Style?
        let maintenance: Bool
    }

    @ObservedObject private var m = SystemMonitor.shared
    @ObservedObject private var advisor = RestartAdvisor.shared
    @State private var page = Page.main
    @State private var tab = 0
    @State private var reservation = PanelReservation()

    var body: some View {
        let snapshot = m.snapshot()
        let message = SystemRules.message(snapshot)
        let maintenance = advisor.visible ? RestartRules.summary(advisor.advice, lang: Locale.preferredLanguages.first) : nil
        let signature = LayoutSignature(page: page, kind: message?.kind, style: message?.style, maintenance: maintenance != nil)
        VStack(spacing: 0) {
            switch page {
            case .main:
                let model = panelModel(snapshot, maintenance: maintenance)
                SystemPanelView(model: model, reservation: $reservation, onTab: { tab = $0 },
                                onAction: { perform($0, from: snapshot) }, openRestart: { page = .restart },
                                openDetails: { page = .details })
            case .restart: RestartPane { page = .main }
            case .details:
                SystemDetailsPane(monitor: m, uptime: advisor.uptime) { page = .main }
            }
        }
        .onChange(of: signature) { _, _ in
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .flyoutRefit, object: nil)
            }
        }
        .onAppear {
            m.resetProcessSample()
            m.tick()
            tab = SystemPanelModel.initialTab(m.snapshot())
            m.sampleProcesses()
            advisor.refresh(disk: DiskInfo.read())
        }
        .onReceive(Timer.publish(every: ProcessReading.samplingInterval, on: .main, in: .common).autoconnect()) { _ in
            m.tick()
            m.sampleProcesses()
            advisor.refresh(disk: DiskInfo.read())
            if !advisor.visible && page == .restart { page = .main }
        }
    }

    private func perform(_ action: SystemAction, from displayed: LoadSnapshot) {
        if action != .openActivityMonitor {
            let current = m.snapshot()
            guard displayed.reading?.isFresh(at: current.observedAt) == true,
                  SystemRules.message(current)?.primary == action else { return }
        }
        SystemAdvice.perform(action)
    }

    private func panelModel(_ snapshot: LoadSnapshot, maintenance: (text: String, strong: Bool, more: Int)?) -> SystemPanelModel {
        var model = SystemPanelModel(snapshot: snapshot, cpuHistory: m.cpuHistory, memoryHistory: m.memoryHistory,
                                     maintenance: maintenance, tab: tab)
        let visibleKeys = Set(model.breakdown?.rows.map(\.key) ?? [])
        for load in snapshot.loads where visibleKeys.contains(load.key) {
            if case .app(let pid?) = load.kind {
                model.icons[load.key] = NSRunningApplication(processIdentifier: pid)?.icon
            }
        }
        return model
    }
}

struct SystemPanelView: View {
    @Environment(\.colorScheme) private var colorScheme
    let model: SystemPanelModel
    @Binding var reservation: PanelReservation
    let onTab: (Int) -> Void
    let onAction: (SystemAction) -> Void
    let openRestart: () -> Void
    let openDetails: () -> Void

    var body: some View {
        let s = model.snapshot
        let message = SystemRules.message(s)
        VStack(alignment: .leading, spacing: 10) {
            header(SystemRules.level(s))
            meters(s)
            if message != nil || reservation.message > 0 {
                messageSlot(message)
            }
            usageList
            VStack(spacing: 8) {
                Divider().frame(height: 1)
                    .accessibilityHidden(true)
                if model.maintenance != nil || reservation.maintenance > 0 {
                    maintenanceSlot
                }
                footer
            }
        }
        .onPreferenceChange(PanelReservationKey.self) { next in
            let measured = PanelReservation(message: max(reservation.message, next.message),
                                            maintenance: max(reservation.maintenance, next.maintenance))
            if measured != reservation { reservation = measured }
        }
    }

    private func header(_ level: SystemLevel) -> some View {
        let symbol = switch level {
        case .normal: "checkmark.circle.fill"
        case .attention: "exclamationmark.circle.fill"
        case .critical: "exclamationmark.triangle.fill"
        }
        let color: Color = switch level {
        case .normal: .green
        case .attention: .orange
        case .critical: .red
        }
        let labelColor: Color = switch level {
        case .normal: .secondary
        case .attention where colorScheme == .light: .primary
        default: color
        }
        return HStack {
            Text(calendarText("System", "Sistema")).font(.system(size: 14, weight: .semibold))
            Spacer()
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(color)
                    .accessibilityHidden(true)
                Text(SystemRules.chip(level, lang: Locale.preferredLanguages.first))
                    .font(.system(size: 11.5)).foregroundStyle(labelColor)
            }
        }
        .frame(height: 20)
    }

    private func meters(_ s: LoadSnapshot) -> some View {
        let cpu = SystemRules.cpuState(smoothed: s.cpuSmoothed, busyMinutes: s.busyMinutes)
        let memory = SystemRules.memoryState(s)
        let cpuText = switch cpu {
        case .busy: calendarText("Busy", "Ocupado")
        case .veryBusy: calendarText("Very busy", "Muy ocupado")
        default: calendarText("Normal", "Normal")
        }
        let memoryTextLabel = switch memory {
        case .veryTight: calendarText("Very tight", "Muy justa")
        default: s.pressure == .normal ? calendarText("Normal", "Normal") : calendarText("Tight", "Justa")
        }
        let gigabytes = Int((Double(s.memoryTotal) / 1_073_741_824).rounded())
        return HStack(alignment: .top, spacing: 12) {
            MeterTile(label: calendarText("Processor", "Procesador"), status: cpuText, state: cpu,
                      strained: cpu == .busy, value: "\(model.cpuValue)%", history: model.cpuHistory)
            MeterTile(label: calendarText("Memory", "Memoria"), status: memoryTextLabel, state: memory,
                      strained: s.pressure != .normal, value: memoryText(s.memoryUsed),
                      unit: calendarText("of \(gigabytes) GB", "de \(gigabytes) GB"), history: model.memoryHistory)
        }
    }

    private func messageSlot(_ message: SystemMessage?) -> some View {
        Group {
            if let message, message.style == .card {
                StatusCard(message: message, text: SystemRules.text(message), onAction: onAction)
            } else if reservation.message > 30 {
                StatusNote(title: calendarText("Better now. Nothing to do.", "Ya está mejor. No hace falta hacer nada."), recovered: true)
            } else if let message {
                StatusNote(title: SystemRules.text(message).title)
            } else {
                Color.clear.frame(height: 0)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .background {
            GeometryReader { geometry in
                Color.clear.preference(key: PanelReservationKey.self, value: PanelReservation(message: geometry.size.height))
            }
        }
        .frame(maxWidth: .infinity, minHeight: reservation.message, alignment: .topLeading)
    }

    private var usageList: some View {
        let breakdown = model.breakdown
        let rows = breakdown?.rows ?? []
        return VStack(spacing: 6) {
            HStack {
                Text(calendarText("What uses the most", "Lo que más usa")).font(.system(size: 12.5, weight: .semibold))
                Spacer(minLength: 4)
                Picker(calendarText("What uses the most", "Lo que más usa"),
                       selection: Binding(get: { model.tab }, set: onTab)) {
                    Text(calendarText("Processor", "Procesador")).tag(0)
                    Text(calendarText("Memory", "Memoria")).tag(1)
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small)
                .frame(width: 170)
            }
            .frame(height: 22)
            VStack(spacing: 4) {
                ForEach(0..<(SystemRules.topRows + 1), id: \.self) { i in
                    Group {
                        if i < rows.count {
                            let row = rows[i]
                            LoadRowView(row: row, load: model.snapshot.loads.first { $0.key == row.key },
                                        icon: model.icons[row.key], executable: model.snapshot.reading?.executableNames[row.key])
                        } else if i == 0 {
                            Text(breakdown == nil ? calendarText("Measuring…", "Midiendo…") :
                                    calendarText("Nothing noticeable now.", "Nada destacable ahora."))
                                .font(.system(size: 12.5)).flyoutSecondary()
                        } else {
                            Color.clear.accessibilityHidden(true)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 26, maxHeight: 26, alignment: .leading)
                }
            }
        }
    }

    private var maintenanceSlot: some View {
        Group {
            if let summary = model.maintenance {
                MaintenanceRow(text: summary.text, strong: summary.strong, more: summary.more, open: openRestart)
            } else {
                StatusNote(title: calendarText("No active maintenance notices.", "Sin avisos de mantenimiento."), recovered: true)
            }
        }
        .frame(height: 26, alignment: .leading)
        .background {
            GeometryReader { geometry in
                Color.clear.preference(key: PanelReservationKey.self, value: PanelReservation(maintenance: geometry.size.height))
            }
        }
        .frame(maxWidth: .infinity, minHeight: reservation.maintenance, alignment: .topLeading)
    }

    private var footer: some View {
        HStack {
            Button { onAction(.openActivityMonitor) } label: {
                Label(calendarText("Activity Monitor", "Monitor de Actividad"), systemImage: "gauge.with.dots.needle.67percent")
            }.buttonStyle(.plain)
            Spacer()
            Button(action: openDetails) {
                Label(calendarText("Details", "Detalles"), systemImage: "chevron.right")
                    .labelStyle(TrailingChevron())
            }.buttonStyle(.plain).flyoutSecondary()
        }
        .font(.system(size: 11.5))
        .frame(height: 18)
    }
}

private struct TrailingChevron: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon.font(.system(size: 10))
        }
    }
}

struct MeterTile: View {
    static let width: CGFloat = 166
    static let height: CGFloat = 68

    @Environment(\.themeAccent) private var accent
    let label: String
    let status: String
    let state: MeterState
    let strained: Bool
    let value: String
    var unit: String?
    let history: [Double]

    var body: some View {
        let graph: Color = switch state.level {
        case .normal: accent
        case .attention: .orange
        case .critical: .red
        }
        let dot: Color = state.level == .normal ? (strained ? .gray : .green) : graph
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text(label).font(.system(size: 11.5, weight: .semibold)).flyoutSecondary()
                Spacer(minLength: 2)
                Circle().fill(dot).frame(width: 7, height: 7).accessibilityHidden(true)
                Text(status).font(.system(size: 11))
            }
            .lineLimit(1)
            .frame(height: 14)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.system(size: 22, weight: .semibold)).monospacedDigit().layoutPriority(1)
                if let unit { Text(unit).font(.system(size: 11)).flyoutSecondary() }
            }
            .lineLimit(1)
            .frame(height: 26)
            .padding(.top, 2)
            Spark(values: history, color: graph, height: 22)
                .padding(.top, 4)
                .accessibilityHidden(true)
        }
        .frame(width: Self.width, height: Self.height, alignment: .topLeading)
        .accessibilityElement(children: .combine)
#if DEBUG
        .background {
            GeometryReader { geometry in
                Color.clear.preference(key: MeterFrameKey.self, value: [label: geometry.frame(in: .named("system-render"))])
            }
        }
#endif
    }
}

struct LoadRowView: View {
    @Environment(\.themeAccent) private var accent
    let row: Breakdown.Row
    let load: AppLoad?
    let icon: NSImage?
    let executable: String?

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 8) {
                Group {
                    if let icon {
                        Image(nsImage: icon).resizable().scaledToFit()
                    } else {
                        Image(systemName: symbol).font(.system(size: 12)).flyoutSecondary()
                    }
                }
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
                HStack(spacing: 4) {
                    Text(row.name).font(.system(size: 12.5)).layoutPriority(1)
                    if let suffix = row.suffix {
                        Text(suffix).font(.system(size: 11.5)).flyoutSecondary()
                    }
                }
                .lineLimit(1)
                .truncationMode(.tail)
                Spacer(minLength: 0)
                Text(row.value).font(.system(size: 12, weight: .medium)).monospacedDigit()
                    .frame(width: 48, alignment: .trailing)
            }
            .frame(height: 15)
            GeometryReader { geometry in
                Capsule().fill(Color.primary.opacity(0.08))
                    .overlay(alignment: .leading) {
                        Capsule().fill(row.isRest ? Color.primary.opacity(0.3) : accent.opacity(0.85))
                            .frame(width: max(3, geometry.size.width * row.fraction))
                    }
            }
            .frame(height: 5)
            .accessibilityHidden(true)
        }
        .frame(height: 26)
        .accessibilityElement(children: .combine)
        .help(load.map { "\(executable ?? $0.name) ×\($0.count)" } ?? row.name)
    }

    private var symbol: String {
        if row.isRest { return "gearshape.2" }
        switch load?.kind {
        case .app: return "app"
        case .tool: return "terminal"
        default: return "gearshape"
        }
    }
}

struct MaintenanceRow: View {
    let text: String
    let strong: Bool
    let more: Int
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 4) {
                if strong {
                    Circle().fill(Color.orange).frame(width: 6, height: 6).accessibilityHidden(true)
                }
                Image(systemName: "wrench.and.screwdriver").font(.system(size: 12)).flyoutSecondary()
                Text(calendarText("Maintenance: ", "Mantenimiento: ")).flyoutSecondary()
                Text(text).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                if more > 0 { Text("+\(more)").flyoutSecondary() }
                Image(systemName: "chevron.right").font(.system(size: 10)).flyoutSecondary()
            }
            .font(.system(size: 11.5))
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct SystemDetailsPane: View {
    @ObservedObject var monitor: SystemMonitor
    let uptime: TimeInterval
    let back: () -> Void

    var body: some View {
        let user = Int(monitor.cpuUser.rounded())
        let system = Int(monitor.cpuSystem.rounded())
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let apps = memoryText(monitor.memoryApps)
        let wired = memoryText(monitor.memoryWired)
        let compressed = memoryText(monitor.memoryCompressed)
        let total = memoryText(monitor.memoryTotal)
        let swap = memoryText(monitor.swapUsed)
        let swapTotal = memoryText(monitor.swapTotal)
        let pressure = monitor.pressure.title.lowercased()
        let onFor = RestartRules.uptimeText(uptime)
        let reading = monitor.processReading
        let unreadable = reading?.unreadable ?? 0
        let others = reading?.otherAccounts ?? 0
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Button(action: back) {
                    Label(calendarText("System", "Sistema"), systemImage: "chevron.left")
                }.buttonStyle(.plain)
                Spacer()
                Text(calendarText("Details", "Detalles")).fontWeight(.semibold)
            }
            Text(calendarText("CPU: user \(user)% · system \(system)% · \(cores) cores",
                              "CPU: usuario \(user)% · sistema \(system)% · \(cores) núcleos"))
            Text(calendarText("Memory: apps \(apps) · system \(wired) · compressed \(compressed), of \(total)",
                              "Memoria: apps \(apps) · sistema \(wired) · comprimida \(compressed), de \(total)"))
            Text(calendarText("Swap: \(swap) of \(swapTotal) · pressure \(pressure)",
                              "Swap: \(swap) de \(swapTotal) · presión \(pressure)"))
            Text(calendarText("On for \(onFor)", "Encendido hace \(onFor)"))
            Divider()
            Text(calendarText("System and others: unmeasured macOS and other accounts’ processes, apps below 1%, and short-lived processes.",
                              "Sistema y otros: procesos sin medir de macOS u otras cuentas, apps por debajo del 1% y procesos breves."))
            Text(calendarText("Processes Cala cannot measure: \(unreadable) (macOS and other accounts)",
                              "Procesos que Cala no puede medir: \(unreadable) (macOS y otras cuentas)"))
            Text(calendarText("Processes from other accounts: \(others)", "Procesos de otras cuentas: \(others)"))
            VStack(spacing: 0) {
                ForEach(reading?.loads.prefix(8) ?? []) { load in
                    HStack {
                        let executable = reading?.executableNames[load.key] ?? load.name
                        Text("\(executable) ×\(load.count)").lineLimit(1)
                        Spacer()
                        Text("\(Int(load.cpu.rounded()))%").monospacedDigit()
                    }
                    .frame(height: 14)
                }
            }
        }
        .font(.system(size: 11.5))
        .flyoutSecondary()
        .fixedSize(horizontal: false, vertical: true)
    }
}

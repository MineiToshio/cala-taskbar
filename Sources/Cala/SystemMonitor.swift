import SwiftUI
import AppKit
import Darwin
import Combine

let traySystem = "__t_system"

struct ProcessGroup: Identifiable, Equatable {
    var id: String { name }
    let name: String
    var cpu: Double       // percent of one core (can exceed 100)
    var memory: UInt64    // physical footprint, bytes
    var count: Int
}

enum MemoryPressure: Int {
    case normal = 1, warning = 2, critical = 4
    var title: String {
        switch self {
        case .normal: return calendarText("Normal", "Normal")
        case .warning: return calendarText("High", "Alta")
        case .critical: return calendarText("Critical", "Crítica")
        }
    }
}

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
    @Published private(set) var topCPU: [ProcessGroup] = []
    @Published private(set) var topMemory: [ProcessGroup] = []
    @Published private(set) var sampledProcesses = false

    private var lastTicks: (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)?
    private var recentCPU: [Double] = []
    private var busySince: Date?
    private var hotSince: Date?
    private var lastProcessSample: (date: Date, cpuNs: [pid_t: UInt64])?
    private let processQueue = DispatchQueue(label: "local.cala.monitor", qos: .utility)
    private var sampling = false
    private let timebase: mach_timebase_info_data_t = {
        var t = mach_timebase_info_data_t(); mach_timebase_info(&t); return t
    }()

    // MARK: Cheap sampling (main thread)

    func tick() {
        sampleCPU(); sampleMemory()
        thermal = ProcessInfo.processInfo.thermalState
    }

    private func sampleCPU() {
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        var info = host_cpu_load_info()
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard r == KERN_SUCCESS else { return }
        let now = (user: info.cpu_ticks.0, system: info.cpu_ticks.1, idle: info.cpu_ticks.2, nice: info.cpu_ticks.3)
        defer { lastTicks = now }
        guard let last = lastTicks else { return }
        let du = Double(now.user &- last.user) + Double(now.nice &- last.nice)
        let ds = Double(now.system &- last.system), di = Double(now.idle &- last.idle)
        let total = du + ds + di
        guard total > 0 else { return }
        cpuUser = du / total * 100; cpuSystem = ds / total * 100; cpu = cpuUser + cpuSystem
        cpuHistory.append(cpu); if cpuHistory.count > 60 { cpuHistory.removeFirst() }
        recentCPU.append(cpu); if recentCPU.count > 3 { recentCPU.removeFirst() }
        let smooth = smoothedCPU
        if smooth >= 75 { if busySince == nil { busySince = Date() } } else { busySince = nil }
        if smooth >= 90 { if hotSince == nil { hotSince = Date() } } else { hotSince = nil }
    }

    private func sampleMemory() {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
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
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 { pressure = MemoryPressure(rawValue: Int(level)) ?? .normal }
        var swap = xsw_usage(), swapSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 { swapUsed = swap.xsu_used; swapTotal = swap.xsu_total }
    }

    /// How long the (smoothed) load has been continuously above 75% / 90%. Short spikes are normal and do not count.
    var busyMinutes: Double { busySince.map { Date().timeIntervalSince($0) / 60 } ?? 0 }
    var hotMinutes: Double { hotSince.map { Date().timeIntervalSince($0) / 60 } ?? 0 }

    /// Average of the last ~9 seconds, so the tray does not flicker on short spikes.
    var smoothedCPU: Double { recentCPU.isEmpty ? cpu : recentCPU.reduce(0, +) / Double(recentCPU.count) }

    // MARK: Per-app sampling (panel open)

    func sampleProcesses() {
        guard !sampling else { return }
        sampling = true
        let previous = lastProcessSample
        processQueue.async {
            let now = Date()
            var cpuNs: [pid_t: UInt64] = [:]
            var groups: [String: ProcessGroup] = [:]
            let elapsed = previous.map { now.timeIntervalSince($0.date) } ?? 0
            let bufferSize = Int(proc_listallpids(nil, 0))
            var pids = [pid_t](repeating: 0, count: max(bufferSize, 0) + 64)
            let got = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
            for pid in pids.prefix(max(got, 0)) where pid > 0 {
                var usage = rusage_info_v4()
                let ok = withUnsafeMutablePointer(to: &usage) {
                    $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
                }
                guard ok == 0 else { continue }      // other users' / system processes are not readable: skipped
                let machTime = usage.ri_user_time &+ usage.ri_system_time
                let ns = machTime &* UInt64(self.timebase.numer) / UInt64(max(1, self.timebase.denom))
                cpuNs[pid] = ns
                var cpu = 0.0
                if let before = previous?.cpuNs[pid], elapsed > 0.2, ns >= before {
                    cpu = Double(ns - before) / (elapsed * 1_000_000_000) * 100
                }
                let name = Self.appName(pid)
                var g = groups[name] ?? ProcessGroup(name: name, cpu: 0, memory: 0, count: 0)
                g.cpu += cpu; g.memory += usage.ri_phys_footprint; g.count += 1
                groups[name] = g
            }
            let all = Array(groups.values)
            let cpuTop = all.filter { $0.cpu >= 0.5 }.sorted { $0.cpu > $1.cpu }.prefix(5)
            let memTop = all.sorted { $0.memory > $1.memory }.prefix(5)
            DispatchQueue.main.async {
                self.lastProcessSample = (now, cpuNs)
                self.topCPU = Array(cpuTop); self.topMemory = Array(memTop)
                self.sampledProcesses = previous != nil
                self.sampling = false
            }
        }
    }

    func resetProcessSample() { lastProcessSample = nil; sampledProcesses = false }

    /// The outermost .app in the executable path (so all of Chrome's helpers count as "Google Chrome"),
    /// otherwise the process name.
    private static func appName(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        if n > 0 {
            let path = String(cString: buffer)
            if let r = path.range(of: ".app/") {
                let head = path[path.startIndex..<r.lowerBound]
                if let slash = head.lastIndex(of: "/") { return String(head[head.index(after: slash)...]) }
            }
            return (path as NSString).lastPathComponent
        }
        var name = [CChar](repeating: 0, count: 256)
        proc_name(pid, &name, UInt32(name.count))
        let s = String(cString: name)
        return s.isEmpty ? "pid \(pid)" : s
    }
}

/// The CPU icon only changes color for load that lasts (short spikes are normal) or for memory trouble.
func monitorTint(_ m: SystemMonitor) -> Color {
    if m.pressure == .critical || m.hotMinutes >= 5 { return .red }
    if m.pressure == .warning || m.busyMinutes >= 2 { return .orange }
    return Color.primary.opacity(0.85)
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

struct SystemPane: View {
    @ObservedObject private var m = SystemMonitor.shared
    @Environment(\.themeAccent) private var accent
    private let rows = 3
    @State private var showDetails = false
    @State private var tab = 0   // 0 = processor, 1 = memory
    @State private var showRestart = false
    @ObservedObject private var advisor = RestartAdvisor.shared

    private func pressureColor(_ p: MemoryPressure) -> Color { p == .normal ? .green : (p == .warning ? .orange : .red) }

    private func dotColor(_ high: Bool, _ critical: Bool = false) -> Color { critical ? .red : (high ? .orange : .green) }

    @ViewBuilder private var mainPage: some View {
        let cores = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let cpuAdvice = SystemAdvice.cpu(smoothed: m.smoothedCPU, busyMinutes: m.busyMinutes, top: m.topCPU.first, sampled: m.sampledProcesses, cores: cores)
        let memAdvice = SystemAdvice.memory(pressure: m.pressure, top: m.topMemory.first { SystemAdvice.quittable($0.name) != nil } ?? m.topMemory.first)
        let note = SystemAdvice.note(thermal: m.thermal, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
        // One message at a time, the most important first: nobody reads a wall of text.
        let rank: (LoadAdvice) -> Int = { $0.tone == .critical ? 3 : ($0.tone == .warn ? 2 : 1) }
        let shown = [memAdvice, cpuAdvice, note].compactMap { $0 }.max { rank($0) < rank($1) }
        VStack(alignment: .leading, spacing: 12) {
            Header(title: calendarText("System", "Sistema"))
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("CPU").font(.system(size: 11.5, weight: .semibold)).flyoutSecondary()
                    Text("\(Int(m.cpu.rounded()))%").font(.system(size: 24, weight: .semibold)).monospacedDigit()
                    Spark(values: m.cpuHistory, color: m.busyMinutes >= 2 ? .orange : accent, height: 26)
                    HStack(spacing: 5) {
                        Circle().fill(dotColor(m.busyMinutes >= 2, m.hotMinutes >= 5)).frame(width: 7, height: 7)
                        Text(m.smoothedCPU >= 75 ? calendarText("Busy", "Ocupado") : calendarText("Normal", "Normal")).font(.system(size: 11.5))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 3) {
                    Text(calendarText("Memory", "Memoria")).font(.system(size: 11.5, weight: .semibold)).flyoutSecondary()
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(diskBytes(Int64(m.memoryUsed))).font(.system(size: 24, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                    }
                    Spark(values: m.memoryHistory, color: pressureColor(m.pressure) == .green ? accent : pressureColor(m.pressure), height: 26)
                    HStack(spacing: 5) {
                        Circle().fill(pressureColor(m.pressure)).frame(width: 7, height: 7)
                        Text(m.pressure == .normal ? calendarText("Normal", "Normal") : (m.pressure == .warning ? calendarText("Low free memory", "Poca libre") : calendarText("Very low", "Muy poca"))).font(.system(size: 11.5))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if let shown { AdviceCard(advice: shown) }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text(calendarText("What uses the most", "Lo que más usa")).font(.system(size: 12.5, weight: .semibold))
                Picker("", selection: $tab) {
                    Text(calendarText("Processor", "Procesador")).tag(0)
                    Text(calendarText("Memory", "Memoria")).tag(1)
                }.pickerStyle(.segmented).labelsHidden()
                if tab == 0 {
                    list(m.topCPU, value: { g in let p = g.cpu / Double(cores); return p < 1 ? "<1%" : "\(Int(p.rounded()))%" }, fraction: { min(1, $0.cpu / Double(cores) / 100 * 2) })
                } else {
                    list(m.topMemory, value: { diskBytes(Int64($0.memory)) }, fraction: { Double($0.memory) / Double(max(1, m.memoryTotal)) * 4 })
                }
            }
            // Maintenance is separate from load: restarting is not a fix for "the processor is busy".
            if advisor.visible { RestartBanner { showRestart = true } }
            Divider()
            HStack {
                Button(action: { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")) }) {
                    Label(calendarText("Activity Monitor", "Monitor de Actividad"), systemImage: "gauge.with.dots.needle.67percent").font(.system(size: 11.5))
                }.buttonStyle(.plain)
                Spacer()
                Text(calendarText("On for \(RestartRules.uptimeText(advisor.uptime))", "Encendido hace \(RestartRules.uptimeText(advisor.uptime))")).font(.system(size: 10.5)).flyoutSecondary()
            }
            DisclosureGroup(isExpanded: $showDetails) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(calendarText("CPU: user \(Int(m.cpuUser.rounded()))% · system \(Int(m.cpuSystem.rounded()))%", "CPU: usuario \(Int(m.cpuUser.rounded()))% · sistema \(Int(m.cpuSystem.rounded()))%"))
                    Text(calendarText("Memory: apps \(diskBytes(Int64(m.memoryApps))) · system \(diskBytes(Int64(m.memoryWired))) · compressed \(diskBytes(Int64(m.memoryCompressed))) of \(diskBytes(Int64(m.memoryTotal)))",
                                      "Memoria: apps \(diskBytes(Int64(m.memoryApps))) · sistema \(diskBytes(Int64(m.memoryWired))) · comprimida \(diskBytes(Int64(m.memoryCompressed))) de \(diskBytes(Int64(m.memoryTotal)))"))
                    Text(calendarText("Swap on disk: \(diskBytes(Int64(m.swapUsed))) in use of \(diskBytes(Int64(m.swapTotal)))", "Swap en disco: \(diskBytes(Int64(m.swapUsed))) en uso de \(diskBytes(Int64(m.swapTotal)))"))
                    Text(calendarText("Process shares are of the whole processor (\(cores) cores).", "Los porcentajes de la lista son del procesador completo (\(cores) núcleos)."))
                }.font(.system(size: 10.5)).flyoutSecondary().frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
            } label: {
                Text(calendarText("Technical details", "Detalles técnicos")).font(.system(size: 11)).flyoutSecondary()
            }
        }
    }

    var body: some View {
        Group {
            if showRestart { RestartPane { showRestart = false } } else { mainPage }
        }
        .onChange(of: showRestart) { _, _ in DispatchQueue.main.async { NotificationCenter.default.post(name: .flyoutRefit, object: nil) } }
        .onAppear { showRestart = false; tab = (m.pressure != .normal) && m.smoothedCPU < 75 ? 1 : 0; m.resetProcessSample(); m.tick(); m.sampleProcesses(); advisor.refresh(disk: ConfigStore.shared.config.place(trayDisk) == .hidden ? DiskInfo.read() : DiskInfo.read()) }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            m.tick(); m.sampleProcesses(); advisor.refresh(disk: DiskInfo.read())
            if advisor.visible == false && showRestart { showRestart = false }
        }
    }

    private func list(_ items: [ProcessGroup], value: @escaping (ProcessGroup) -> String, fraction: @escaping (ProcessGroup) -> Double) -> some View {
        VStack(spacing: 7) {
            ForEach(0..<rows, id: \.self) { i in
                if i < items.count {
                    VStack(spacing: 4) {
                        HStack {
                            Text(items[i].name + (items[i].count > 1 ? " ×\(items[i].count)" : "")).font(.system(size: 12.5)).lineLimit(1)
                            Spacer(minLength: 6)
                            Text(value(items[i])).font(.system(size: 12, weight: .medium)).monospacedDigit()
                        }
                        GeometryReader { g in
                            Capsule().fill(Color.primary.opacity(0.08))
                                .overlay(alignment: .leading) {
                                    Capsule().fill(accent.opacity(0.8)).frame(width: max(3, g.size.width * CGFloat(min(1, max(0, fraction(items[i]))))))
                                }
                        }.frame(height: 4)
                    }
                    .frame(height: 28)
                } else {
                    HStack {
                        Text(i == 0 ? (m.sampledProcesses ? calendarText("Nothing noticeable.", "Nada destacable.") : calendarText("Measuring…", "Midiendo…")) : " ")
                            .font(.system(size: 12.5)).flyoutSecondary()
                        Spacer()
                    }.frame(height: 28)
                }
            }
        }
    }
}

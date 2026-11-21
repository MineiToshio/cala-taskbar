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
    @Published private(set) var pressure = MemoryPressure.normal
    @Published private(set) var thermal = ProcessInfo.ThermalState.nominal
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var memoryHistory: [Double] = []
    @Published private(set) var topCPU: [ProcessGroup] = []
    @Published private(set) var topMemory: [ProcessGroup] = []
    @Published private(set) var sampledProcesses = false

    private var lastTicks: (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)?
    private var recentCPU: [Double] = []
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
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 { swapUsed = swap.xsu_used }
    }

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

    // MARK: Diagnosis

    enum Level { case ok, warn, bad }

    /// One plain sentence about why the Mac may feel slow.
    var diagnosis: (text: String, level: Level) {
        let topMem = topMemory.first, topCpu = topCPU.first
        if pressure == .critical || pressure == .warning {
            let who = topMem.map { calendarText(" \($0.name) uses \(diskBytes(Int64($0.memory))).", " \($0.name) usa \(diskBytes(Int64($0.memory))).") } ?? ""
            return (calendarText("Memory is under pressure; the Mac is swapping to disk.", "La memoria está bajo presión; el Mac está usando el disco como memoria.") + who,
                    pressure == .critical ? .bad : .warn)
        }
        if smoothedCPU >= 75 {
            let who = topCpu.map { calendarText(" \($0.name) is the heaviest (\(Int($0.cpu.rounded()))% of a core).", " \($0.name) es el que más usa (\(Int($0.cpu.rounded()))% de un núcleo).") } ?? ""
            return (calendarText("The processor is busy.", "El procesador está ocupado.") + who, smoothedCPU >= 90 ? .bad : .warn)
        }
        if thermal == .serious || thermal == .critical {
            return (calendarText("The Mac is hot and slowing itself down to cool off.", "El Mac está caliente y se frena solo para enfriarse."), thermal == .critical ? .bad : .warn)
        }
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            return (calendarText("Low Power Mode is on, which makes the Mac slower.", "El modo de bajo consumo está activo y hace el Mac más lento."), .warn)
        }
        return (calendarText("Everything looks normal.", "Todo se ve normal."), .ok)
    }
}

func monitorTint(_ m: SystemMonitor) -> Color {
    if m.pressure == .critical || m.smoothedCPU >= 90 { return .red }
    if m.pressure == .warning || m.smoothedCPU >= 75 { return .orange }
    return Color.primary.opacity(0.85)
}

// MARK: - Panel

struct Spark: View {
    let values: [Double]
    let color: Color
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
        .frame(height: 34)
    }
}

struct SystemPane: View {
    @ObservedObject private var m = SystemMonitor.shared
    @Environment(\.themeAccent) private var accent
    private let rows = 5

    private func pressureColor(_ p: MemoryPressure) -> Color { p == .normal ? .green : (p == .warning ? .orange : .red) }

    var body: some View {
        let d = m.diagnosis
        VStack(alignment: .leading, spacing: 10) {
            Header(title: calendarText("System", "Sistema"))
            Label(d.text, systemImage: d.level == .ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(d.level == .ok ? Color.green : (d.level == .warn ? Color.orange : Color.red))
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 34, alignment: .topLeading)
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("CPU").font(.system(size: 12, weight: .semibold)).flyoutSecondary()
                    Spacer()
                    Text("\(Int(m.cpu.rounded()))%").font(.system(size: 22, weight: .semibold)).monospacedDigit()
                }
                Spark(values: m.cpuHistory, color: m.smoothedCPU >= 75 ? .orange : accent)
                Text(calendarText("user \(Int(m.cpuUser.rounded()))% · system \(Int(m.cpuSystem.rounded()))%", "usuario \(Int(m.cpuUser.rounded()))% · sistema \(Int(m.cpuSystem.rounded()))%"))
                    .font(.system(size: 10.5)).flyoutSecondary()
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(calendarText("Memory", "Memoria")).font(.system(size: 12, weight: .semibold)).flyoutSecondary()
                    Spacer()
                    Text(calendarText("Pressure ", "Presión ") + m.pressure.title).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(pressureColor(m.pressure))
                        .padding(.horizontal, 7).padding(.vertical, 3).background(Capsule().fill(pressureColor(m.pressure).opacity(0.15)))
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(diskBytes(Int64(m.memoryUsed))).font(.system(size: 22, weight: .semibold)).monospacedDigit()
                    Text(calendarText("of \(diskBytes(Int64(m.memoryTotal)))", "de \(diskBytes(Int64(m.memoryTotal)))")).font(.system(size: 12)).flyoutSecondary()
                }
                Spark(values: m.memoryHistory, color: pressureColor(m.pressure) == .green ? accent : pressureColor(m.pressure))
                Text(calendarText("apps \(diskBytes(Int64(m.memoryApps))) · system \(diskBytes(Int64(m.memoryWired))) · compressed \(diskBytes(Int64(m.memoryCompressed))) · swap \(diskBytes(Int64(m.swapUsed)))",
                                  "apps \(diskBytes(Int64(m.memoryApps))) · sistema \(diskBytes(Int64(m.memoryWired))) · comprimida \(diskBytes(Int64(m.memoryCompressed))) · swap \(diskBytes(Int64(m.swapUsed)))"))
                    .font(.system(size: 10.5)).flyoutSecondary().fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            list(calendarText("Using the processor", "Usan el procesador"), m.topCPU, value: { "\(Int($0.cpu.rounded()))%" })
            list(calendarText("Using the memory", "Usan la memoria"), m.topMemory, value: { diskBytes(Int64($0.memory)) })
            Divider()
            Row(icon: "gauge.with.dots.needle.67percent", title: calendarText("Open Activity Monitor", "Abrir Monitor de Actividad")) {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
            }
        }
        .onAppear { m.resetProcessSample(); m.tick(); m.sampleProcesses() }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in m.tick(); m.sampleProcesses() }
    }

    private func list(_ title: String, _ items: [ProcessGroup], value: @escaping (ProcessGroup) -> String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 12, weight: .semibold)).flyoutSecondary()
            ForEach(0..<rows, id: \.self) { i in
                HStack {
                    if i < items.count {
                        Text(items[i].name + (items[i].count > 1 ? " ×\(items[i].count)" : "")).font(.system(size: 12.5)).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(value(items[i])).font(.system(size: 12)).monospacedDigit().flyoutSecondary()
                    } else {
                        Text(i == 0 && !m.sampledProcesses ? calendarText("Measuring…", "Midiendo…") : " ").font(.system(size: 12.5)).flyoutSecondary()
                        Spacer()
                    }
                }.frame(height: 18)
            }
        }
    }
}

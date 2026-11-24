import SwiftUI
import AppKit
import Darwin
import Combine

let traySystem = "__t_system"

enum RestProbe {
    case available([ProcessUsage])
    case unavailable
}

/// CPU, memory and per-app load, read with the same system calls Activity Monitor uses (no helper, no admin rights).
/// The cheap numbers (CPU %, memory, pressure) are sampled every few seconds while the tray item is on, and so is the
/// total energy impact (every ~5 s on a background queue). The per-process list is only sampled while the panel is open.
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
    /// Total energy impact (the score the Energía tab's rows add up to), one point about every 5 s, kept while the
    /// panel is closed. It comes from `EnergySampler`, never from the panel's own scan.
    @Published private(set) var energyHistory: [Double] = []
    @Published private var lastReading: ProcessReading?
    @Published private var lastInventory: ProcessInventory?
    @Published private var processSessionStartedAt: TimeInterval = .infinity
    @Published private(set) var restProbe: RestProbe?
    /// The metric the tray cell shows right now, after the hold that keeps it from flickering.
    @Published private(set) var shownMetric = SystemMetric.cpu

    var processReading: ProcessReading? {
        snapshot().reading
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
    private var metricHold = MetricHold()
    private var lastProcessSample: ProcessSample?
    private var scanCancel = ScanCancellation()
    private lazy var energySampler = EnergySampler(timebase: timebase) { [weak self] total in
        guard let self else { return }
        self.energyHistory.append(total)
        if self.energyHistory.count > 60 { self.energyHistory.removeFirst() }
    }
    private var processGeneration = 0
    private let processQueue = DispatchQueue(label: "local.cala.monitor", qos: .utility)
    private var sampling = false
    private let restQueue = DispatchQueue(label: "local.cala.monitor.ps", qos: .utility)
    private var restExpanded = false
    private var restInFlight = false
    private var restGeneration = 0
    private let timebase: mach_timebase_info_data_t = {
        var t = mach_timebase_info_data_t(); mach_timebase_info(&t); return t
    }()

    /// Monotonic time including sleep, used to detect interruptions and expire readings.
    private var samplingTime: TimeInterval {
        Double(mach_continuous_time()) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }

    // MARK: Cheap sampling (main thread)

    func tick() {
        energySampler.keepAlive()
        sampleCPU()
        sampleMemory()
        let info = ProcessInfo.processInfo
        let state = info.thermalState
        criticalThermal.observe(state == .critical, at: samplingTime)
        thermal = state
        let preferred = SystemMetric(rawValue: ConfigStore.shared.config.monitorBarMetric) ?? .cpu
        let metric = metricHold.update(SystemRules.levels(snapshot()), preferred: preferred, at: samplingTime)
        if metric != shownMetric { shownMetric = metric }
    }

    fileprivate struct CPUTicks {
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

    fileprivate static func readTicks() -> CPUTicks? {
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
                     lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
                     lastInventory: lastInventory, processSessionStartedAt: processSessionStartedAt)
    }

    // MARK: Per-app sampling (panel open)

    private struct ProcessSample {
        let date: TimeInterval
        let capturedAt: TimeInterval
        let ticks: CPUTicks?
        let counters: [pid_t: EnergyCounters]
    }

    func sampleProcesses() {
        refreshRest()
        guard processSessionStartedAt.isFinite, !sampling else { return }
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
        let cancel = scanCancel
        processQueue.async {
            func abandon() { DispatchQueue.main.async { _ = self.finishProcessScan(generation: generation) } }
            guard !cancel.isCancelled else { return abandon() }
            let capturedAt = self.samplingTime
            let now = ProcessInfo.processInfo.systemUptime
            let ticks = Self.readTicks()
            guard let table = Self.processTable() else {
                DispatchQueue.main.async { _ = self.finishProcessScan(generation: generation) }
                return
            }

            // A window across a sampling pause is too old to describe the current load.
            let previous = lastSample.flatMap {
                (0...ProcessReading.maxAge).contains(capturedAt - $0.capturedAt) ? $0 : nil
            }
            let elapsed = previous.map { now - $0.date } ?? 0
            // A window that is too short is not a baseline either: the next scan measures from the older sample.
            let windowTooShort = previous != nil && !SystemRules.deltaWindowUsable(elapsed: elapsed)
            let delta = windowTooShort ? nil : previous?.ticks.flatMap { ticks?.since($0) }
            let cpuWindow = delta.flatMap { ticks in
                ticks.total > 0 && elapsed > 0 ? Double(ticks.busy) / Double(ticks.total) * 100 : nil
            }
            var unreadable = 0
            var withDeltas = 0
            var otherAccounts = 0
            var executableNames: [String: String] = [:]
            let parents = table.mapValues(\.parent)
            let uid = getuid()
            var counters: [pid_t: EnergyCounters] = [:]
            var groups: [String: AppLoad] = [:]
            var measured: [MeasuredProcess] = []
            for (index, pid) in table.keys.sorted().enumerated() {
                if index.isMultiple(of: 64), cancel.isCancelled { return abandon() }
                guard let owner = table[pid]?.uid else { continue }
                let otherAccount = SystemRules.isOtherAccount(owner, currentUID: uid)
                if otherAccount { otherAccounts += 1 }
                guard let (current, footprint) = Self.rusageCounters(pid, timebase: self.timebase) else {
                    unreadable += 1
                    continue
                }
                counters[pid] = current
                var cpu = 0.0
                var energy = 0.0
                if cpuWindow != nil, let before = previous?.counters[pid], before.start == current.start,
                   current.cpuNanoseconds >= before.cpuNanoseconds {
                    cpu = Double(current.cpuNanoseconds - before.cpuNanoseconds) / (elapsed * 1_000_000_000) * 100 / cores
                    energy = SystemRules.energyScore(from: before, to: current, elapsed: elapsed) ?? 0
                    withDeltas += 1
                }
                if otherAccount {
                    let sample = ProcessUsage(pid: pid, uid: owner, executable: "", cpu: cpu, memory: footprint,
                                              energy: energy)
                    measured.append(MeasuredProcess(usage: sample, loadKey: nil))
                    continue
                }

                let (path, executable) = Self.processName(pid)
                let launcher = SystemRules.enclosingApp(path: path, apps: apps) == nil
                    ? SystemRules.launcher(of: pid, parents: parents, apps: regularPIDs) : nil
                let (key, name, kind) = SystemRules.classify(path: path, executable: executable, apps: apps, launcher: launcher)
                var group = groups[key] ?? AppLoad(key: key, name: name, kind: kind, cpu: 0, memory: 0, count: 0, closable: false)
                group.cpu += cpu
                group.memory += footprint
                group.energy += energy
                group.count += 1
                groups[key] = group
                let sample = ProcessUsage(pid: pid, uid: owner, executable: executable, cpu: cpu, memory: footprint,
                                          energy: energy)
                measured.append(MeasuredProcess(usage: sample, loadKey: key))

                if case .app(let appPID) = kind, appPID == pid {
                    executableNames[key] = executable
                } else if executableNames[key] == nil {
                    executableNames[key] = executable
                }
            }
            let orderedLoads = groups.values.sorted { $0.cpu == $1.cpu ? $0.key < $1.key : $0.cpu > $1.cpu }
            let sample = ProcessSample(date: now, capturedAt: capturedAt, ticks: ticks, counters: counters)
            let details = (unreadable: unreadable, withDeltas: withDeltas, otherAccounts: otherAccounts, executableNames: executableNames, measured: measured)
            DispatchQueue.main.async {
                guard self.finishProcessScan(generation: generation) else { return }
                if !windowTooShort { self.lastProcessSample = sample }
                self.lastInventory = ProcessInventory(capturedAt: capturedAt, loads: orderedLoads, processes: details.measured)
                // The first scan has no previous counters: every process would read zero and the whole load would
                // fall into “Sistema y otros”. Without a reading the CPU and Energía lists keep their skeleton.
                guard let cpuWindow,
                      SystemRules.canPublishReading(cpuWindow: cpuWindow, processesWithDeltas: details.withDeltas) else { return }
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
                                                executableNames: details.executableNames, processes: details.measured) {
                    self.publish(reading)
                }
            }
        }
    }

    private func finishProcessScan(generation: Int) -> Bool {
        sampling = false
        guard processGeneration == generation else {
            sampleProcesses()
            return false
        }
        return true
    }

    func setRestExpanded(_ expanded: Bool) {
        guard restExpanded != expanded else { return }
        restExpanded = expanded
        restGeneration += 1
        restProbe = nil
        if expanded { refreshRest() }
    }

    private func refreshRest() {
        guard restExpanded, !restInFlight else { return }
        restInFlight = true
        let generation = restGeneration
        restQueue.async {
            let probe = Self.runPS()
            DispatchQueue.main.async {
                self.restInFlight = false
                guard self.restExpanded else { return }
                guard self.restGeneration == generation else {
                    self.refreshRest()
                    return
                }
                self.restProbe = probe
            }
        }
    }

    private static func runPS() -> RestProbe {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-A", "-o", "pid=,uid=,pcpu=,rss=,comm="]
        process.environment = ["LC_ALL": "C"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return .unavailable
        }

        let timeout = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1, execute: timeout)
        defer { timeout.cancel() }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return .unavailable }
        let samples = SystemRules.parsePS(String(decoding: data, as: UTF8.self), currentUID: getuid())
        return samples.isEmpty ? .unavailable : .available(samples)
    }

    private func publish(_ reading: ProcessReading) {
        let now = samplingTime
        guard reading.isFresh(at: now) else { return }
        lastReading = reading

        let capturedAt = reading.capturedAt
        DispatchQueue.main.asyncAfter(deadline: .now() + (reading.expiresAt - now)) { [weak self] in
            guard let self, self.processSessionStartedAt <= capturedAt,
                  self.lastReading?.capturedAt == capturedAt else { return }
            self.objectWillChange.send()
        }
    }

    func setProcessPanelOpen(_ open: Bool) {
        processGeneration += 1
        scanCancel.cancel()
        scanCancel = ScanCancellation()
        lastProcessSample = nil
        processSessionStartedAt = open ? samplingTime : .infinity
    }

    /// One `proc_pid_rusage` read: the counters behind the energy score and the physical footprint. nil when unreadable.
    fileprivate static func rusageCounters(_ pid: pid_t, timebase: mach_timebase_info_data_t) -> (EnergyCounters, UInt64)? {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard result == 0 else { return nil }
        let time = usage.ri_user_time + usage.ri_system_time
        let denominator = UInt64(max(1, timebase.denom))
        let numerator = UInt64(timebase.numer)
        let ns = time / denominator * numerator + time % denominator * numerator / denominator
        return (EnergyCounters(start: usage.ri_proc_start_abstime, cpuNanoseconds: ns,
                               wakeups: usage.ri_pkg_idle_wkups &+ usage.ri_interrupt_wkups),
                usage.ri_phys_footprint)
    }

    fileprivate static func processTable() -> [pid_t: (parent: pid_t, uid: uid_t)]? {
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

/// Samples the machine's total energy impact in the background so the Energía sparkline is continuous, like CPU and
/// memory, even while the panel is closed. It reads `proc_pid_rusage` for every process about every 5 s on its own
/// utility queue (no `top`, no `ps`, nothing on the main thread). It only runs while `keepAlive()` keeps being called
/// from the monitor's tick, so a hidden tray item costs nothing.
private final class EnergySampler: @unchecked Sendable {
    private struct Baseline {
        let capturedAt: TimeInterval
        let uptime: TimeInterval
        let ticks: SystemMonitor.CPUTicks
        let counters: [pid_t: EnergyCounters]
    }

    private static let idleLimit: TimeInterval = 30  // No tick for this long: drop the baseline and stop scanning.

    private let queue = DispatchQueue(label: "local.cala.monitor.energy", qos: .utility)
    private let timebase: mach_timebase_info_data_t
    private let deliver: (Double) -> Void
    private let lock = NSLock()
    private var lastKeepAlive: TimeInterval = -.infinity
    private var timer: DispatchSourceTimer?
    private var baseline: Baseline?  // Only touched on `queue`.

    init(timebase: mach_timebase_info_data_t, deliver: @escaping (Double) -> Void) {
        self.timebase = timebase
        self.deliver = deliver
    }

    /// Called from the main thread on every monitor tick. Starts the timer the first time.
    func keepAlive() {
        lock.lock(); defer { lock.unlock() }
        lastKeepAlive = ProcessInfo.processInfo.systemUptime
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + 0.2, repeating: SystemRules.energyInterval, leeway: .milliseconds(500))
        source.setEventHandler { [weak self] in self?.scan() }
        timer = source
        source.resume()
    }

    private var isAlive: Bool {
        lock.lock(); defer { lock.unlock() }
        return ProcessInfo.processInfo.systemUptime - lastKeepAlive < Self.idleLimit
    }

    private func scan() {
        guard isAlive else { baseline = nil; return }
        let capturedAt = Double(mach_continuous_time()) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
        let uptime = ProcessInfo.processInfo.systemUptime
        guard let ticks = SystemMonitor.readTicks(), let table = SystemMonitor.processTable() else { baseline = nil; return }
        var counters: [pid_t: EnergyCounters] = [:]
        counters.reserveCapacity(table.count)
        for pid in table.keys {
            if let (current, _) = SystemMonitor.rusageCounters(pid, timebase: timebase) { counters[pid] = current }
        }
        let before = baseline
        baseline = Baseline(capturedAt: capturedAt, uptime: uptime, ticks: ticks, counters: counters)
        guard let before, SystemRules.energyWindowUsable(gap: capturedAt - before.capturedAt) else { return }

        let elapsed = uptime - before.uptime
        let window = ticks.since(before.ticks)
        guard elapsed > 0, window.total > 0 else { return }
        let cores = Double(max(1, ProcessInfo.processInfo.activeProcessorCount))
        var energy = 0.0
        var measuredCPU = 0.0
        for (pid, current) in counters {
            guard let old = before.counters[pid], old.start == current.start,
                  current.cpuNanoseconds >= old.cpuNanoseconds else { continue }
            measuredCPU += Double(current.cpuNanoseconds - old.cpuNanoseconds) / (elapsed * 1_000_000_000) * 100 / cores
            energy += SystemRules.energyScore(from: old, to: current, elapsed: elapsed) ?? 0
        }
        let cpuWindow = Double(window.busy) / Double(window.total) * 100
        let total = SystemRules.energyTotal(measuredEnergy: energy, measuredCPU: measuredCPU, cpuWindow: cpuWindow,
                                            cores: Int(cores))
        DispatchQueue.main.async { [deliver] in deliver(total) }
    }
}

/// Lets the panel stop a process scan in flight when it closes or reopens.
private final class ScanCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

/// Tint of the tray cell: the level of the metric it shows.
func monitorTint(_ m: SystemMonitor, dark: Bool) -> Color {
    let level = SystemRules.levels(m.snapshot())[m.shownMetric]
    return level == .normal ? Color.primary.opacity(0.85) : StatusColor.color(for: level, dark: dark)
}

// MARK: - Panel

struct Spark: View {
    let values: [Double]
    let color: Color
    var height: CGFloat = 34
    var scale = 100.0
    var body: some View {
        GeometryReader { g in
            let pts = values.suffix(60)
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.06))
                if pts.count > 1 {
                    Path { p in
                        for (i, v) in pts.enumerated() {
                            let x = g.size.width * CGFloat(i) / CGFloat(max(1, 59))
                            let y = g.size.height * (1 - CGFloat(min(scale, max(0, v)) / scale))
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
    var energyHistory: [Double] = []
    var maintenance: (text: String, strong: Bool, more: Int)?
    var tab: Int
    var icons: [String: NSImage] = [:]
    var expandedKey: String?
    var reservesExpandedHeight = false
    var restProbe: RestProbe?
    var currentUID: UInt32 = 0
    var cores = 1
    var reservation = PanelReservation()
    /// Room the screen allows for the panel, including the flyout padding.
    var maxHeight = SystemPanelLayout.maxHeight

    var message: SystemMessage? { SystemRules.message(snapshot) }
    var showsCPUMeterSkeleton: Bool { cpuHistory.isEmpty && snapshot.displayedReading == nil }
    var showsMemoryMeterSkeleton: Bool { memoryHistory.isEmpty }
    var showsEnergyMeterSkeleton: Bool { energyHistory.isEmpty && snapshot.displayedReading == nil }
    /// The Procesador and Energía lists wait for per-process deltas, which a single scan cannot give.
    var showsCPUSkeleton: Bool { SystemRules.listIsLoading(metric: metric, availability: snapshot.cpuAvailability) }

    /// The Energía meter's number: the same total the Energía tab's rows add up to.
    var energyValue: Int { SystemRules.energyValue(reading: snapshot.displayedReading, history: energyHistory, cores: cores) ?? 0 }

    var slots: PanelReservation {
        let currentHeight = switch message?.style {
        case .card: SystemPanelLayout.cardHeight
        case .note: SystemPanelLayout.noteHeight
        case nil: 0
        }
        return PanelReservation(messageHeight: max(reservation.messageHeight, currentHeight),
                                hasMaintenance: maintenance != nil || reservation.hasMaintenance)
    }

    var layout: SystemPanelLayout {
        let slots = slots
        return SystemPanelLayout(messageHeight: slots.messageHeight, hasMaintenance: slots.hasMaintenance, maxHeight: maxHeight)
    }

    static let tabs: [LoadMetric] = [.cpu, .memory, .energy]

    var metric: LoadMetric { Self.tabs.indices.contains(tab) ? Self.tabs[tab] : .cpu }

    // The number and rows always refer to the same CPU window, even while a previous one is displayed.
    var cpuValue: Int { Int((snapshot.displayedReading?.cpuWindow ?? snapshot.cpuNow).rounded()) }

    var cpuBreakdown: Breakdown? {
        guard let reading = snapshot.displayedReading else { return nil }
        return SystemRules.cpuBreakdown(reading.loads, total: reading.cpuWindow, lang: appLanguage,
                                        rowLimit: layout.rowLimit)
    }

    var breakdown: Breakdown? {
        switch metric {
        case .cpu: return cpuBreakdown
        case .energy: return energyBreakdown
        case .memory: break
        }
        guard let inventory = snapshot.displayedInventory else { return nil }
        return SystemRules.memoryBreakdown(inventory.loads, used: snapshot.memoryUsed,
                                           lang: appLanguage, locale: .current, rowLimit: layout.rowLimit)
    }

    // Energy comes from the same window as the processor rows.
    var energyBreakdown: Breakdown? {
        guard let reading = snapshot.displayedReading else { return nil }
        return SystemRules.energyBreakdown(reading.loads, unattributed: SystemRules.unattributedEnergy(reading, cores: cores),
                                           lang: appLanguage, locale: .current, rowLimit: layout.rowLimit)
    }

    private var inventory: ProcessInventory? {
        metric == .memory ? snapshot.displayedInventory : snapshot.displayedReading?.inventory
    }

    var listAvailability: ProcessReadingAvailability {
        inventory.map { snapshot.processAvailability(capturedAt: $0.capturedAt) } ?? .missing
    }

    // `ps` has no energy column, so the Energy tab breaks down measured processes only.
    private var usableRestProbe: RestProbe? { listAvailability == .fresh && metric != .energy ? restProbe : nil }

    func detailRows(for row: Breakdown.Row, in breakdown: Breakdown) -> [LoadDetail] {
        let lang = appLanguage
        let layout = detailLayout(for: row, in: breakdown)
        guard let inventory else { return [] }
        if row.isRest {
            let ps: [ProcessUsage]?
            if case .available(let samples) = usableRestProbe { ps = samples } else { ps = nil }
            return SystemRules.restDetails(row, breakdown: breakdown, loads: inventory.loads,
                                           measured: inventory.processes, ps: ps, metric: metric,
                                           currentUID: currentUID, cores: cores, lang: lang, capacity: layout.capacity)
        }
        return SystemRules.toolDetails(row, loads: inventory.loads, metric: metric, lang: lang, capacity: layout.capacity,
                                       allowActions: snapshot.canUseProcessActions(capturedAt: inventory.capturedAt))
    }

    func detailLayout(for row: Breakdown.Row, in breakdown: Breakdown) -> LoadDetailLayout {
        LoadDetailLayout(parentCount: breakdown.rows.count, showsEstimate: row.isRest, listHeight: layout.expandedListHeight)
    }

    var restNote: String {
        if case .available(let samples) = usableRestProbe,
           samples.contains(where: { $0.uid < 500 && (metric == .cpu ? $0.cpu != nil : $0.memory != nil) }) {
            return calendarText("Estimated breakdown", "Reparto aproximado")
        }
        return calendarText("Only available measurements", "Solo mediciones disponibles")
    }

    /// Opens on the worst metric right now (heat opens Energía), or on the user's choice when all is fine.
    static func initialTab(_ s: LoadSnapshot, preferred: SystemMetric = .cpu) -> Int {
        tabs.firstIndex(of: SystemRules.openingMetric(SystemRules.levels(s), preferred: preferred)) ?? 0
    }
}

struct PanelReservation: Equatable {
    var messageHeight = 0
    var hasMaintenance = false
}

struct SystemPane: View {
    private enum Page { case main, restart, details }

    private struct LayoutSignature: Equatable {
        let page: Page
        let kind: SystemMessage.Kind?
        let style: SystemMessage.Style?
        let maintenance: Bool
        let expanded: Bool
        let layout: SystemPanelLayout
    }

    /// Room the screen allows, capped at `SystemPanelLayout.maxHeight`.
    var maxHeight = SystemPanelLayout.maxHeight
    @ObservedObject private var m = SystemMonitor.shared
    @ObservedObject private var advisor = RestartAdvisor.shared
    @State private var page = Page.main
    @State private var tab = 0
    @State private var expandedKey: String?
    @State private var reservesExpandedHeight = false
    @State private var reservation = PanelReservation()

    var body: some View {
        let snapshot = m.snapshot()
        let model = panelModel(snapshot)
        let message = model.message
        let restIsExpanded = page == .main && expandedKey == "rest" && model.listAvailability == .fresh && model.metric != .energy
            && model.breakdown?.rows.contains(where: \.isRest) == true
        let signature = LayoutSignature(page: page, kind: message?.kind, style: message?.style,
                                        maintenance: model.maintenance != nil, expanded: reservesExpandedHeight,
                                        layout: model.layout)
        VStack(spacing: 0) {
            switch page {
            case .main:
                SystemPanelView(model: model,
                                onTab: { tab = $0; expandedKey = nil; m.setRestExpanded(false) },
                                onExpand: toggleExpansion,
                                onAction: { perform($0, from: snapshot) },
                                onDetailAction: { performDetail($0, from: snapshot) },
                                openRestart: { m.setRestExpanded(false); page = .restart },
                                openDetails: { m.setRestExpanded(false); page = .details })
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
        .onChange(of: model.slots, initial: true) { _, slots in reservation = slots }
        .onChange(of: restIsExpanded) { _, expanded in m.setRestExpanded(expanded) }
        .onDisappear {
            m.setRestExpanded(false)
            m.setProcessPanelOpen(false)
        }
        .onAppear {
            m.setProcessPanelOpen(true)
            m.tick()
            let preferred = SystemMetric(rawValue: ConfigStore.shared.config.monitorBarMetric) ?? .cpu
            tab = SystemPanelModel.initialTab(m.snapshot(), preferred: preferred)
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

    private func toggleExpansion(_ row: Breakdown.Row) {
        expandedKey = expandedKey == row.key ? nil : row.key
        reservesExpandedHeight = true
    }

    private func performDetail(_ action: SystemAction, from displayed: LoadSnapshot) {
        let current = m.snapshot()
        let model = panelModel(current)
        guard displayed.reading?.isFresh(at: current.observedAt) == true,
              let breakdown = model.breakdown,
              let row = breakdown.rows.first(where: { $0.isTool && $0.key == expandedKey }),
              model.detailRows(for: row, in: breakdown).contains(where: { $0.action == action }) else { return }
        SystemAdvice.perform(action)
    }

    private func panelModel(_ snapshot: LoadSnapshot) -> SystemPanelModel {
        let maintenance = advisor.visible ? RestartRules.summary(advisor.advice, lang: appLanguage) : nil
        var model = SystemPanelModel(snapshot: snapshot, cpuHistory: m.cpuHistory, memoryHistory: m.memoryHistory,
                                     energyHistory: m.energyHistory, maintenance: maintenance, tab: tab, expandedKey: expandedKey,
                                     reservesExpandedHeight: reservesExpandedHeight, restProbe: m.restProbe,
                                     currentUID: getuid(), cores: ProcessInfo.processInfo.activeProcessorCount,
                                     reservation: reservation, maxHeight: maxHeight)
        let visibleKeys = Set(model.breakdown?.rows.flatMap(\.loadKeys) ?? [])
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
    let onTab: (Int) -> Void
    var onExpand: (Breakdown.Row) -> Void = { _ in }
    let onAction: (SystemAction) -> Void
    var onDetailAction: (SystemAction) -> Void = { _ in }
    let openRestart: () -> Void
    let openDetails: () -> Void

    var body: some View {
        let s = model.snapshot
        let message = model.message
        let slots = model.slots
        let breakdown = model.breakdown
        let rows = breakdown?.rows ?? []
        let expanded = rows.first { $0.expandable && $0.key == model.expandedKey }
        let layout = model.layout
        let retainedHeight = CGFloat(layout.expandedListHeight)
        let foldedHeight = CGFloat(SystemPanelLayout.height(forRows: max(1, rows.count)))
        let loadingExpanded = model.expandedKey != nil && model.reservesExpandedHeight && expanded == nil
        let retainedAfterFold = model.reservesExpandedHeight && expanded == nil && !loadingExpanded
        let contentHeight = breakdown == nil ? CGFloat(layout.listHeight) : foldedHeight
        let listHeight = expanded != nil || loadingExpanded ? retainedHeight
            : (retainedAfterFold ? contentHeight : CGFloat(layout.listHeight))
        // The message keeps its natural height. The block reserves the largest message seen while the panel is open,
        // so a shorter card or a recovery note leaves its spare room below the list and the footer does not jump.
        let reserved = slots.messageHeight
        let blockHeight = (reserved > 0 ? reserved + 10 : 0) + layout.meterHeight + 10 + SystemPanelLayout.listHeaderHeight
        VStack(alignment: .leading, spacing: 10) {
            header
            VStack(alignment: .leading, spacing: 10) {
                if reserved > 0 {
                    messageSlot(message, reserved: reserved)
                }
                meters(s, rowHeight: CGFloat(layout.meterRowHeight))
                usageList(breakdown, rows: rows, expanded: expanded, height: listHeight)
            }
            .frame(height: CGFloat(blockHeight) + listHeight, alignment: .top)
            VStack(spacing: 8) {
                Divider().frame(height: 1)
                    .accessibilityHidden(true)
                if slots.hasMaintenance {
                    maintenanceSlot
                }
                footer
            }
        }
        .padding(.bottom, retainedAfterFold ? retainedHeight - contentHeight : 0)
    }

    private var header: some View {
        Text(calendarText("System", "Sistema")).font(.system(size: 14, weight: .semibold))
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 20)
    }

    private func meters(_ s: LoadSnapshot, rowHeight: CGFloat) -> some View {
        let cpu = SystemRules.cpuState(smoothed: s.cpuSmoothed, busyMinutes: s.busyMinutes)
        let memory = SystemRules.memoryState(s)
        let heat = SystemRules.heatLevel(s)
        let heatText = SystemRules.heatStatus(s)
        let cpuText = SystemRules.cpuStatus(cpu)
        let memoryTextLabel = SystemRules.memoryStatus(s.pressure, state: memory)
        let gigabytes = Int((Double(s.memoryTotal) / 1_073_741_824).rounded())
        return VStack(spacing: 0) {
            MeterRow(label: calendarText("Processor", "Procesador"), status: cpuText, level: cpu.level,
                     strained: cpu == .busy, value: "\(model.cpuValue)%", history: model.cpuHistory, height: rowHeight,
                     loading: model.showsCPUMeterSkeleton, select: { onTab(0) })
            MeterRow(label: calendarText("Memory", "Memoria"), status: memoryTextLabel, level: memory.level,
                     strained: s.pressure != .normal, value: memoryText(s.memoryUsed),
                     unit: calendarText("of \(gigabytes) GB", "de \(gigabytes) GB"), history: model.memoryHistory,
                     height: rowHeight, loading: model.showsMemoryMeterSkeleton, select: { onTab(1) })
            // Same layout as the others: title over the thermal state, the total energy impact on the right.
            MeterRow(label: calendarText("Energy", "Energía"), status: heatText, level: heat,
                     strained: SystemRules.heatWarm(s), value: "\(model.energyValue)",
                     unit: calendarText("impact", "de impacto"), history: model.energyHistory,
                     scale: max(100, model.energyHistory.suffix(60).max() ?? 0), height: rowHeight,
                     loading: model.showsEnergyMeterSkeleton, separated: false, select: { onTab(2) })
        }
    }

    private func messageSlot(_ message: SystemMessage?, reserved: Int) -> some View {
        Group {
            if let message, message.style == .card {
                StatusCard(message: message, text: SystemRules.text(message), onAction: onAction)
            } else if reserved > SystemPanelLayout.noteHeight {
                StatusNote(title: calendarText("Better now. Nothing to do.", "Ya está mejor. No hace falta hacer nada."), recovered: true)
            } else if let message {
                StatusNote(title: SystemRules.text(message).title)
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func usageList(_ breakdown: Breakdown?, rows: [Breakdown.Row], expanded: Breakdown.Row?,
                           height: CGFloat) -> some View {
        let layout = breakdown.flatMap { data in expanded.map { model.detailLayout(for: $0, in: data) } }
        return VStack(spacing: CGFloat(SystemPanelLayout.listHeaderHeight - 22)) {
            HStack(spacing: 6) {
                Text(calendarText("What uses the most", "Lo que más usa")).font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1).fixedSize()
                if model.listAvailability == .remembered {
                    // With three tabs the note falls back to an icon when the words do not fit.
                    ViewThatFits(in: .horizontal) {
                        Text(calendarText("Previous sample", "Lectura anterior"))
                            .font(.system(size: 10)).flyoutSecondary().lineLimit(1)
                        Image(systemName: "clock.arrow.circlepath").font(.system(size: 10)).flyoutSecondary()
                            .help(calendarText("Previous sample", "Lectura anterior"))
                            .accessibilityLabel(calendarText("Previous sample", "Lectura anterior"))
                    }
                }
                Spacer(minLength: 0)
                Picker(calendarText("What uses the most", "Lo que más usa"),
                       selection: Binding(get: { model.tab }, set: onTab)) {
                    Text(calendarText("Processor", "Procesador")).tag(0)
                    Text(calendarText("Memory", "Memoria")).tag(1)
                    Text(calendarText("Energy", "Energía")).tag(2)
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small)
                .frame(maxWidth: 234)  // Natural width in Spanish; English is narrower.
            }
            .frame(height: 22)
            Group {
                if model.showsCPUSkeleton {
                    SystemLoadingPulse {
                        VStack(spacing: CGFloat(SystemPanelLayout.rowSpacing)) {
                            ForEach(0..<model.layout.rowLimit, id: \.self) { index in
                                loadingRow(index)
                            }
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(calendarText("Loading system data", "Cargando datos del sistema"))
                } else {
                    VStack(alignment: .leading, spacing: CGFloat(layout?.spacing ?? SystemPanelLayout.rowSpacing)) {
                        if rows.isEmpty {
                            Text(breakdown == nil
                                 ? calendarText("Waiting for the first memory reading.", "Aún no hay una lectura de memoria.")
                                 : calendarText("Nothing noticeable now.", "Nada destacable ahora."))
                                .font(.system(size: 12.5)).flyoutSecondary().frame(height: CGFloat(SystemPanelLayout.rowHeight))
                        }
                        ForEach(rows, id: \.key) { row in
                            let isExpanded = expanded?.key == row.key
                            let rowHeight = layout.map { isExpanded ? LoadDetailLayout.expandedRowHeight : $0.siblingHeight }
                                ?? SystemPanelLayout.rowHeight
                            loadRow(row, isExpanded: isExpanded, height: CGFloat(rowHeight))
                            if isExpanded, let breakdown, let layout {
                                loadDetails(row, in: breakdown, layout: layout)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: height, alignment: .topLeading)
        }
    }

    private func loadingRow(_ index: Int) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                SystemSkeletonMark().frame(width: 16, height: 16)
                SystemSkeletonMark().frame(width: index.isMultiple(of: 2) ? 103 : 128, height: 10)
                Spacer()
                SystemSkeletonMark().frame(width: 28, height: 10)
            }
            SystemSkeletonMark().frame(height: 5)
        }
        .frame(height: CGFloat(SystemPanelLayout.rowHeight))
    }

    @ViewBuilder private func loadRow(_ row: Breakdown.Row, isExpanded: Bool, height: CGFloat) -> some View {
        let key = row.loadKeys.first
        let view = LoadRowView(row: row, icon: model.icons[row.key],
                               executable: key.flatMap { model.snapshot.reading?.executableNames[$0] },
                               isExpanded: isExpanded, height: height)
        if row.expandable {
            Button { onExpand(row) } label: { view.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .accessibilityHint(isExpanded ? calendarText("Collapse breakdown", "Plegar desglose")
                                   : calendarText("Expand breakdown", "Expandir desglose"))
        } else {
            view
        }
    }

    private func loadDetails(_ row: Breakdown.Row, in breakdown: Breakdown, layout: LoadDetailLayout) -> some View {
        let details = model.detailRows(for: row, in: breakdown)
        let labels = model.metric.values(for: details, parent: row, locale: .current)
        return VStack(alignment: .leading, spacing: 0) {
            if row.isRest {
                Text(model.restNote).font(.system(size: 10)).flyoutSecondary()
                    .frame(height: CGFloat(layout.headerHeight))
            }
            ForEach(Array(zip(details, labels)), id: \.0.id) { detail, label in
                HStack(spacing: 6) {
                    Text(detail.name).lineLimit(1).layoutPriority(1)
                    if let count = detail.count {
                        Text(calendarText(count == 1 ? "1 process" : "\(count) processes",
                                          count == 1 ? "1 proceso" : "\(count) procesos"))
                            .lineLimit(1).flyoutSecondary()
                    }
                    Spacer(minLength: 0)
                    if let action = detail.action {
                        Button(SystemRules.actionLabel(action, lang: appLanguage)) {
                            onDetailAction(action)
                        }
                        .buttonStyle(.plain).foregroundStyle(Color.accentColor).lineLimit(1)
                    }
                    Text(label)
                        .monospacedDigit().frame(minWidth: 42, alignment: .trailing)
                }
                .frame(height: CGFloat(LoadDetailLayout.detailRowHeight))
            }
        }
        .font(.system(size: 11.5))
        .padding(.leading, 24).padding(.trailing, 8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 5))
        .id(row.key)
    }

    private var maintenanceSlot: some View {
        Group {
            if let summary = model.maintenance {
                MaintenanceRow(text: summary.text, strong: summary.strong, more: summary.more, open: openRestart)
            } else {
                StatusNote(title: calendarText("No active maintenance notices.", "Sin avisos de mantenimiento."), recovered: true)
            }
        }
        .frame(height: CGFloat(SystemPanelLayout.maintenanceHeight - 8), alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .topLeading)
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
#if DEBUG
        .background {
            GeometryReader { geometry in
                Color.clear.preference(key: SystemFooterYKey.self, value: geometry.frame(in: .named("system-render")).minY)
            }
        }
#endif
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

struct SystemSkeletonMark: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.12))
    }
}

struct SystemLoadingPulse<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewBuilder let content: () -> Content

    var body: some View {
        if reduceMotion {
            content()
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 24)) { context in
                let phase = context.date.timeIntervalSinceReferenceDate * Double.pi / 1.3
                content().opacity(0.88 + 0.12 * cos(phase))
            }
        }
    }
}

struct MeterStatusIndicator: View {
    @Environment(\.colorScheme) private var scheme
    let level: SystemLevel
    let strained: Bool

    init(state: MeterState, strained: Bool) { self.init(level: state.level, strained: strained) }
    init(level: SystemLevel, strained: Bool) { self.level = level; self.strained = strained }

    var body: some View {
        let tone: StatusTone = level == .normal ? .ok : StatusTone(level)
        let color: Color = level == .normal && strained ? .secondary : StatusColor.color(tone, dark: scheme == .dark)
        Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true)
    }
}

/// One line of the meter list: title over its status on the left, then the value and sparkline in right-aligned
/// columns. Clicking it shows the matching tab of “What uses the most”.
struct MeterRow: View {
    static let width = CGFloat(SystemPanelLayout.contentWidth)
    static let sparkWidth: CGFloat = 130
    static let valueGap: CGFloat = 16

    @Environment(\.themeAccent) private var accent
    @Environment(\.colorScheme) private var scheme
    let label: String
    let status: String
    let level: SystemLevel
    let strained: Bool
    let value: String
    var unit: String?
    let history: [Double]
    var scale = 100.0
    var height = CGFloat(SystemPanelLayout.meterRowHeight)
    var loading = false
    var separated = true
    var select: () -> Void = {}

    var body: some View {
        let graph: Color = level == .normal ? accent : StatusColor.color(for: level, dark: scheme == .dark)
        Button(action: select) {
            HStack(spacing: 0) {
                // Title over status (31 pt, within the 34 pt floor) leaves the value and sparkline columns room for
                // “99,6 GB de 128 GB”.
                VStack(alignment: .leading, spacing: 2) { title; statusLabel }
                    .lineLimit(1).fixedSize()
                Spacer(minLength: Self.valueGap)
                if loading {
                    SystemLoadingPulse {
                        HStack(spacing: 12) {
                            SystemSkeletonMark().frame(width: unit == nil ? 44 : 120, height: 16)
                            SystemSkeletonMark().frame(width: Self.sparkWidth, height: min(26, height - 10))
                        }
                    }
                    .accessibilityHidden(true)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(value).font(.system(size: 20, weight: .semibold)).monospacedDigit()
                        if let unit { Text(unit).font(.system(size: 11)).flyoutSecondary() }
                    }
                    .lineLimit(1).fixedSize()
                    Spark(values: history, color: graph, height: min(26, height - 10), scale: scale)
                        .frame(width: Self.sparkWidth)
                        .padding(.leading, 12)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: Self.width, height: height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            if separated { Divider().opacity(0.6).accessibilityHidden(true) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(calendarText("Shows it in What uses the most", "Lo muestra en Lo que más usa"))
#if DEBUG
        .background {
            GeometryReader { geometry in
                Color.clear.preference(key: MeterFrameKey.self, value: [label: geometry.frame(in: .named("system-render"))])
            }
        }
#endif
    }

    private var title: some View {
        Text(label).font(.system(size: 12, weight: .semibold)).flyoutSecondary()
    }

    private var statusLabel: some View {
        HStack(spacing: 4) {
            MeterStatusIndicator(level: level, strained: strained)
            Text(status).font(.system(size: 11.5))
        }
    }
}

struct LoadRowView: View {
    @Environment(\.themeAccent) private var accent
    let row: Breakdown.Row
    let icon: NSImage?
    let executable: String?
    let isExpanded: Bool
    let height: CGFloat

    var body: some View {
        VStack(spacing: height < 26 ? 1 : 3) {
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
                if row.expandable {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold)).flyoutSecondary()
                        .frame(width: 9).accessibilityHidden(true)
                }
                Text(row.value).font(.system(size: 12, weight: .medium)).monospacedDigit()
                    .frame(width: 48, alignment: .trailing)
            }
            .frame(height: 15)
            if height > 16 {
                GeometryReader { geometry in
                    Capsule().fill(Color.primary.opacity(0.08))
                        .overlay(alignment: .leading) {
                            Capsule().fill(row.isRest ? Color.primary.opacity(0.3) : accent.opacity(0.85))
                                .frame(width: max(3, geometry.size.width * row.fraction))
                        }
                }
                .frame(height: height < 26 ? 4 : 5)
                .accessibilityHidden(true)
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .combine)
        .help(executable ?? row.name)
    }

    private var symbol: String {
        if row.isRest { return "gearshape.2" }
        if row.isTool { return "terminal" }
        return row.suffix == nil ? "app" : "gearshape"
    }
}

/// A discreet line above the footer. Strong advice keeps its dot.
struct MaintenanceRow: View {
    let text: String
    let strong: Bool
    let more: Int
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 4) {
                if strong {
                    Circle().fill(StatusColor.color(.pending)).frame(width: 6, height: 6).accessibilityHidden(true)
                }
                Image(systemName: "wrench.and.screwdriver").font(.system(size: 10))
                Text(text).lineLimit(1).truncationMode(.tail)
                if more > 0 { Text("+\(more)") }
                Image(systemName: "chevron.right").font(.system(size: 9))
                Spacer(minLength: 0)
            }
            .font(.system(size: 11))
            .flyoutSecondary()
            .frame(height: CGFloat(SystemPanelLayout.maintenanceHeight - 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(calendarText("Maintenance: \(text)", "Mantenimiento: \(text)"))
        .accessibilityValue(more > 0 ? calendarText("\(more) more", "\(more) más") : "")
    }
}

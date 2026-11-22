import Foundation

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

enum SystemLevel: Int, Comparable {
    case normal, attention, critical

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

enum LoadKind: Equatable {
    case app(pid: Int32?)  // nil when a bundle's load belongs to multiple running instances.
    case tool(executable: String, launcher: String?, launcherPID: Int32?)
    case system
}

struct AppLoad: Equatable, Identifiable {
    var id: String { key }
    let key: String
    let name: String
    let kind: LoadKind
    var cpu: Double      // Percent of the whole processor, across all cores.
    var memory: UInt64   // Physical footprint in bytes.
    var count: Int
    var closable: Bool

    var quitPID: Int32? {
        guard closable, case .app(let pid) = kind else { return nil }
        return pid
    }
}

struct AppRef: Equatable {
    let bundlePath: String
    let name: String
    let pid: Int32
    let regular: Bool
}

/// A pause longer than two background ticks breaks a run of critical readings.
struct CriticalDuration {
    private static let maxGap: TimeInterval = 6
    private var run: (first: TimeInterval, last: TimeInterval)?

    mutating func observe(_ critical: Bool, at now: TimeInterval) {
        guard critical else { run = nil; return }
        if let run, (0...Self.maxGap).contains(now - run.last) {
            self.run = (run.first, now)
        } else {
            run = (now, now)
        }
    }

    func minutes(at now: TimeInterval) -> Double {
        guard let run, (0...Self.maxGap).contains(now - run.last) else { return 0 }
        return (run.last - run.first) / 60
    }
}

enum LoadMetric {
    case cpu, memory

    func weight(_ load: AppLoad) -> Double {
        switch self {
        case .cpu: return load.cpu
        case .memory: return Double(load.memory)
        }
    }

    func value(_ amount: Int, locale: Locale) -> String {
        switch self {
        case .cpu: return "\(amount)%"
        case .memory: return memoryText(UInt64(amount), locale: locale)
        }
    }

    func values(for details: [LoadDetail], parent: Breakdown.Row, locale: Locale) -> [String] {
        guard let display = parent.memoryDisplay, parent.amount > 0 else {
            return details.map { value($0.amount, locale: locale) }
        }
        let scale = Double(display.count) / Double(parent.amount)
        let shares = SystemRules.apportion(details.map { Double($0.amount) * scale }, to: display.count)
        return shares.map { display.unit.text($0, locale: locale) }
    }
}

struct ProcessUsage: Equatable {
    let pid: Int32
    let uid: UInt32
    let executable: String
    let cpu: Double?
    let memory: UInt64?
}

struct MeasuredProcess {
    let usage: ProcessUsage
    let loadKey: String?
}

struct LoadDetail: Equatable, Identifiable {
    let id: String
    let name: String
    let count: Int?
    let amount: Int
    let action: SystemAction?
}

struct SystemPanelLayout: Equatable {
    static let maxHeight = 520
    static let maxRows = 7
    static let rowHeight = 26
    static let rowSpacing = 4
    static let cardHeight = 91
    static let noteHeight = 30

    let rowLimit: Int
    let listHeight: Int
    let expandedListHeight: Int

    init(messageHeight: Int, hasMaintenance: Bool) {
        // Fixed chrome includes the flyout padding and the “More” navigation row.
        let chrome = 231 + (messageHeight > 0 ? messageHeight + 10 : 0) + (hasMaintenance ? 34 : 0)
        let available = Self.maxHeight - chrome
        let preferred = Self.maxRows - (messageHeight > Self.noteHeight ? 1 : 0) - (hasMaintenance ? 1 : 0)
        rowLimit = min(preferred, (available + Self.rowSpacing) / (Self.rowHeight + Self.rowSpacing))
        listHeight = Self.height(forRows: rowLimit)
        expandedListHeight = min(available, listHeight + 34)
    }

    static func height(forRows count: Int) -> Int {
        count * rowHeight + max(0, count - 1) * rowSpacing
    }
}

struct LoadDetailLayout {
    static let expandedRowHeight = 22
    static let detailRowHeight = 18
    static let maxDetailRows = 5

    let siblingHeight: Int
    let spacing: Int
    let headerHeight: Int
    let capacity: Int

    init(parentCount: Int, showsEstimate: Bool, listHeight: Int) {
        let header = showsEstimate ? 14 : 0
        let normalBudget = listHeight - parentCount * (Self.expandedRowHeight + 4) - header
        let useCompactSiblings = normalBudget < 2 * Self.detailRowHeight
        let siblingHeight = useCompactSiblings ? 16 : Self.expandedRowHeight
        let spacing = useCompactSiblings ? 3 : 4
        let budget = listHeight - Self.expandedRowHeight - max(0, parentCount - 1) * siblingHeight
            - parentCount * spacing - header
        self.siblingHeight = siblingHeight
        self.spacing = spacing
        headerHeight = header
        // The subtotal takes one slot when needed. Integer division leaves any partial slot unused.
        capacity = min(Self.maxDetailRows, max(0, budget) / Self.detailRowHeight)
    }
}

enum ProcessReadingAvailability: Equatable {
    case fresh, remembered, missing

    init(capturedAt: TimeInterval, observedAt: TimeInterval, openedAt: TimeInterval) {
        let age = observedAt - capturedAt
        if !(0...ProcessReading.cacheAge).contains(age) {
            self = .missing
        } else if capturedAt >= openedAt && age < ProcessReading.maxAge {
            self = .fresh
        } else {
            self = .remembered
        }
    }
}

/// Memory footprints are available from a single process scan.
struct ProcessInventory {
    let capturedAt: TimeInterval
    let loads: [AppLoad]
    let processes: [MeasuredProcess]
}

/// A complete process window. Small sampling skew is handled by the CPU breakdown;
/// larger discrepancies are rejected before any of these values reach the panel.
struct ProcessReading {
    static let samplingInterval: TimeInterval = 2
    static let maxAge: TimeInterval = 2 * samplingInterval
    static let cacheAge: TimeInterval = 30

    let capturedAt: TimeInterval
    let cpuWindow: Double
    let loads: [AppLoad]
    let unreadable: Int
    let otherAccounts: Int
    let executableNames: [String: String]
    let processes: [MeasuredProcess]

    init?(capturedAt: TimeInterval, cpuWindow: Double, loads: [AppLoad], unreadable: Int = 0, otherAccounts: Int = 0,
          executableNames: [String: String] = [:], processes: [MeasuredProcess] = []) {
        guard (0...100).contains(cpuWindow),
              loads.allSatisfy({ $0.cpu.isFinite && $0.cpu >= 0 }),
              loads.reduce(0, { $0 + $1.cpu }) <= cpuWindow + SystemRules.mismatch else { return nil }
        self.capturedAt = capturedAt
        self.cpuWindow = cpuWindow
        self.loads = loads
        self.unreadable = unreadable
        self.otherAccounts = otherAccounts
        self.executableNames = executableNames
        self.processes = processes
    }

    var expiresAt: TimeInterval { capturedAt + Self.maxAge }

    var inventory: ProcessInventory {
        ProcessInventory(capturedAt: capturedAt, loads: loads, processes: processes)
    }

    func isFresh(at now: TimeInterval) -> Bool {
        now >= capturedAt && now < expiresAt
    }
}

struct LoadSnapshot {
    var lastReading: ProcessReading?
    var observedAt: TimeInterval
    var cpuNow: Double
    var cpuSmoothed: Double
    var busyMinutes: Double
    var hotMinutes: Double
    var pressure: MemoryPressure
    var pressureMinutes: Double
    var criticalPressureMinutes = 0.0
    var memoryUsed: UInt64
    var memoryTotal: UInt64
    var thermal: ProcessInfo.ThermalState
    var criticalThermalMinutes = 0.0
    var lowPower: Bool
    var lastInventory: ProcessInventory? = nil
    var processSessionStartedAt: TimeInterval = -.infinity

    func processAvailability(capturedAt: TimeInterval) -> ProcessReadingAvailability {
        ProcessReadingAvailability(capturedAt: capturedAt, observedAt: observedAt, openedAt: processSessionStartedAt)
    }

    var cpuAvailability: ProcessReadingAvailability {
        lastReading.map { processAvailability(capturedAt: $0.capturedAt) } ?? .missing
    }

    var reading: ProcessReading? {
        cpuAvailability == .fresh ? lastReading : nil
    }

    func canUseProcessActions(capturedAt: TimeInterval) -> Bool {
        reading?.capturedAt == capturedAt
    }

    var displayedReading: ProcessReading? {
        cpuAvailability == .missing ? nil : lastReading
    }

    var displayedInventory: ProcessInventory? {
        guard let inventory = lastInventory ?? lastReading?.inventory,
              processAvailability(capturedAt: inventory.capturedAt) != .missing else { return nil }
        return inventory
    }

    var cpuWindow: Double? { reading?.cpuWindow }
    var loads: [AppLoad] { reading?.loads ?? [] }
}

enum MeterState: Equatable {
    case normal, busy, veryBusy, tight, veryTight

    var level: SystemLevel {
        switch self {
        case .normal, .busy: return .normal
        case .veryBusy, .tight: return .attention
        case .veryTight: return .critical
        }
    }
}

enum SystemAction: Equatable {
    case quit(name: String, pid: Int32, frees: UInt64?)
    case activate(name: String, pid: Int32)
    case openActivityMonitor
}

struct SystemMessage: Equatable {
    enum Style: Equatable { case note, card }
    enum Kind: Equatable {
        case spike, lowPower
        case measuring(minutes: Int)
        case appBusy(name: String, minutes: Int, closable: Bool)
        case toolBusy(tool: String, launcher: String?, minutes: Int)
        case systemTask(name: String, minutes: Int)
        case systemLoad(minutes: Int)
        case spread(minutes: Int)
        case memoryLow(top: String?, bytes: UInt64?)
        case memoryCritical(top: String?, bytes: UInt64?)
        case hot(critical: Bool)
    }
    let kind: Kind
    let level: SystemLevel
    let style: Style
    let primary: SystemAction?
    let secondary: SystemAction?
}

struct MessageText: Equatable {
    let title: String
    let detail: String?
    let primary: String?
    let secondary: String?
}

struct Breakdown: Equatable {
    struct Row: Equatable {
        let key: String
        let name: String
        let suffix: String?
        let value: String
        let fraction: Double
        let isRest: Bool
        let amount: Int
        let loadKeys: [String]
        var isTool = false
        var memoryDisplay: MemoryDisplay?

        var expandable: Bool { isRest || isTool }
    }
    var rows: [Row]
    var consistent: Bool
}

enum SystemRules {
    static let busyAt = 75.0, hotAt = 90.0, sustainedMin = 2.0
    static let memWarnMin = 2.0, memCriticalMin = 1.0, heatCriticalMin = 2.0
    static let rowMin = 1.0, mismatch = 5.0
    static let culpritShare = 0.25, culpritMin = 10.0, systemShare = 0.5
    static let nameMax = 18

    static func cpuState(smoothed: Double, busyMinutes: Double) -> MeterState {
        guard smoothed >= busyAt else { return .normal }
        return busyMinutes >= sustainedMin ? .veryBusy : .busy
    }

    static func memoryState(pressure: MemoryPressure, minutes: Double, criticalMinutes: Double) -> MeterState {
        switch pressure {
        case .normal: return .normal
        case .warning: return minutes >= memWarnMin ? .tight : .normal
        case .critical: return criticalMinutes >= memCriticalMin ? .veryTight : .tight
        }
    }

    static func memoryState(_ s: LoadSnapshot) -> MeterState {
        memoryState(pressure: s.pressure, minutes: s.pressureMinutes, criticalMinutes: s.criticalPressureMinutes)
    }

    static func memoryStatus(_ pressure: MemoryPressure, state: MeterState,
                             lang: String? = Locale.preferredLanguages.first) -> String {
        if state == .veryTight { return calendarText("Very tight", "Muy justa", preferredLanguage: lang) }
        return pressure == .normal ? calendarText("Normal", "Normal", preferredLanguage: lang)
                                   : calendarText("Tight", "Justa", preferredLanguage: lang)
    }

    static func level(_ s: LoadSnapshot) -> SystemLevel {
        max(cpuState(smoothed: s.cpuSmoothed, busyMinutes: s.busyMinutes).level,
            memoryState(s).level,
            heatLevel(s))
    }

    private static func heatLevel(_ s: LoadSnapshot) -> SystemLevel {
        switch s.thermal {
        case .critical: return s.criticalThermalMinutes >= heatCriticalMin ? .critical : .attention
        case .serious: return .attention
        default: return .normal
        }
    }

    static func message(_ s: LoadSnapshot) -> SystemMessage? {
        let memory = memoryState(s).level
        let heat = heatLevel(s)
        if memory != .normal && memory >= heat { return memoryMessage(s.loads, level: memory) }
        if heat != .normal { return card(.hot(critical: heat == .critical), level: heat, secondary: .openActivityMonitor) }
        switch cpuState(smoothed: s.cpuSmoothed, busyMinutes: s.busyMinutes) {
        case .veryBusy: return cpuMessage(s)
        case .busy: return SystemMessage(kind: .spike, level: .normal, style: .note, primary: nil, secondary: nil)
        default:
            return s.lowPower ? SystemMessage(kind: .lowPower, level: .normal, style: .note, primary: nil, secondary: nil) : nil
        }
    }

    private static func card(_ kind: SystemMessage.Kind, level: SystemLevel = .attention,
                             primary: SystemAction? = nil, secondary: SystemAction? = nil) -> SystemMessage {
        SystemMessage(kind: kind, level: level, style: .card, primary: primary, secondary: secondary)
    }

    private static func cpuMessage(_ s: LoadSnapshot) -> SystemMessage {
        let minutes = Int(s.busyMinutes)
        guard let reading = s.reading else { return card(.measuring(minutes: minutes)) }

        let total = reading.cpuWindow
        let unattributed = max(0, total - reading.loads.reduce(0) { $0 + $1.cpu })
        if unattributed >= systemShare * total {
            return card(.systemLoad(minutes: minutes), primary: .openActivityMonitor)
        }

        guard let top = reading.loads.max(by: { $0.cpu < $1.cpu }),
              top.cpu >= max(culpritMin, culpritShare * total) else {
            return card(.spread(minutes: minutes), secondary: .openActivityMonitor)
        }
        switch top.kind {
        case .app:
            let pid = top.quitPID
            let kind = SystemMessage.Kind.appBusy(name: top.name, minutes: minutes, closable: pid != nil)
            if let pid {
                return card(kind, primary: .quit(name: top.name, pid: pid, frees: nil), secondary: .openActivityMonitor)
            }
            return card(kind, primary: .openActivityMonitor)
        case .tool(_, let launcher, let pid):
            let kind = SystemMessage.Kind.toolBusy(tool: top.name, launcher: launcher, minutes: minutes)
            if let launcher, let pid {
                return card(kind, primary: .activate(name: launcher, pid: pid), secondary: .openActivityMonitor)
            }
            return card(kind, primary: .openActivityMonitor)
        case .system:
            return card(.systemTask(name: top.name, minutes: minutes), secondary: .openActivityMonitor)
        }
    }

    private static func memoryMessage(_ loads: [AppLoad], level: SystemLevel) -> SystemMessage {
        let closable = loads.filter { $0.quitPID != nil }.max { $0.memory < $1.memory }
        let top = closable ?? loads.max { $0.memory < $1.memory }
        let kind: SystemMessage.Kind = level == .critical
            ? .memoryCritical(top: top?.name, bytes: top?.memory)
            : .memoryLow(top: top?.name, bytes: top?.memory)
        if let top, let pid = top.quitPID {
            return card(kind, level: level, primary: .quit(name: top.name, pid: pid, frees: top.memory))
        }
        if let top, case .tool(_, let launcher?, let pid?) = top.kind {
            return card(kind, level: level, primary: .activate(name: launcher, pid: pid))
        }
        return card(kind, level: level, primary: .openActivityMonitor)
    }

    static func text(_ m: SystemMessage, lang: String? = Locale.preferredLanguages.first,
                     locale: Locale = .current) -> MessageText {
        func tr(_ en: String, _ es: String) -> String { calendarText(en, es, preferredLanguage: lang) }
        let title: String
        let detail: String?
        switch m.kind {
        case .spike:
            title = tr("Short spike: normal and settles on its own.", "Pico momentáneo: es normal y baja solo.")
            detail = nil
        case .lowPower:
            title = tr("Low Power Mode: a bit slower on purpose.", "Modo de bajo consumo: va más lento adrede.")
            detail = nil
        case .measuring(let min):
            title = tr("Busy for \(min) min", "Lleva \(min) min muy ocupado")
            detail = tr("A new reading will show which apps are using the processor.", "La próxima lectura mostrará qué apps usan el procesador.")
        case .systemLoad:
            title = tr("Cala can’t identify some of the load", "Hay carga que Cala no puede identificar")
            detail = tr("It may be macOS or another account. Wait a few minutes. If it lasts, open Activity Monitor.",
                        "Puede ser macOS u otra cuenta. Espera unos minutos. Si sigue, abre el Monitor de Actividad.")
        case .appBusy(let name, let min, let closable):
            title = tr("\(short(name, limit: 17)) is keeping the Mac busy", "\(short(name)) está cargando el Mac")
            detail = closable
                ? tr("Your Mac has been busy for \(min) min. Quit the app if unused. It will ask to save.",
                     "El Mac lleva \(min) min ocupado. Si no usas la app, ciérrala. Te pedirá guardar.")
                : tr("Your Mac has been busy for \(min) min. If it lasts, check Activity Monitor.",
                     "El Mac lleva \(min) min ocupado. Si sigue así, abre el Monitor de Actividad.")
        case .toolBusy(let tool, let launcher, let min):
            let tool = short(displayName(tool, lang: lang))
            if let launcher {
                title = tr("A task from \(short(launcher)) is busy", "Una tarea de \(short(launcher, limit: 16)) carga el Mac")
                detail = tr("Your Mac has been busy for \(min) min. \(tool) leads now. If unexpected, check it there.",
                            "El Mac lleva \(min) min ocupado. Ahora destaca \(tool). Revísalo allí si no lo esperabas.")
            } else {
                title = tr("A background task is busy", "Una tarea en segundo plano carga el Mac")
                detail = tr("Your Mac has been busy for \(min) min. If \(tool) is unfamiliar, check Activity Monitor.",
                            "El Mac lleva \(min) min ocupado. Si no reconoces \(tool), abre el Monitor de Actividad.")
            }
        case .systemTask(let name, let min):
            let display = short(displayName(name, lang: lang))
            title = tr("\(display) is working", "\(display) está trabajando")
            detail = tr("Your Mac has been busy for \(min) min. Give the task a little time to finish.",
                        "El Mac lleva \(min) min ocupado. Dale un poco de tiempo a la tarea para que termine.")
        case .spread(let min):
            title = tr("Several apps are keeping the Mac busy", "Varias apps cargan el Mac a la vez")
            detail = tr("Your Mac has been busy for \(min) min. Close unused apps. The list shows what uses most.",
                        "El Mac lleva \(min) min ocupado. Cierra las apps que no uses. Abajo ves cuáles pesan más.")
        case .memoryLow(let top, let bytes), .memoryCritical(let top, let bytes):
            let critical = m.level == .critical
            title = critical ? tr("Almost out of memory: save your work", "Casi sin memoria: guarda tu trabajo")
                             : tr("Memory is running low", "Queda poca memoria libre")
            let prefix = critical ? "" : tr("The Mac is slower. ", "El Mac va más lento. ")
            var culprit: String?
            if let top, let bytes {
                let amount = memoryText(bytes, locale: locale)
                switch m.primary {
                case .quit:
                    culprit = tr("\(short(top)) uses \(amount).", "\(short(top)) ocupa \(amount).")
                case .activate(let launcher, _):
                    let top = displayName(top, lang: lang)
                    culprit = tr("\(short(top)) from \(short(launcher)) uses \(amount).",
                                 "\(short(top)) de \(short(launcher)) ocupa \(amount).")
                default: break
                }
            }
            detail = prefix + (culprit.map { tr("Quit what you do not use; \($0)", "Cierra lo que no uses; \($0)") }
                               ?? tr("Quit the apps you are not using.", "Cierra las apps que no uses."))
        case .hot(let critical):
            title = critical ? tr("The Mac is very hot", "El Mac está muy caliente")
                             : tr("The Mac is hot and slowing down", "El Mac está caliente y va más lento")
            detail = critical
                ? tr("Save your work, pause heavy tasks and let it cool down.", "Guarda tu trabajo, pausa las tareas pesadas y deja que se enfríe.")
                : tr("Keep the vents clear and pause heavy tasks for a while.", "Deja libres las rejillas y pausa las tareas pesadas un rato.")
        }
        return MessageText(title: short(title, limit: 46),
                           detail: detail.map { short($0, limit: 105) },
                           primary: m.primary.map { actionLabel($0, lang: lang) },
                           secondary: m.secondary.map { actionLabel($0, lang: lang) })
    }

    static func actionLabel(_ action: SystemAction, lang: String?) -> String {
        switch action {
        case .quit(let name, _, _):
            return calendarText("Quit \(short(name))…", "Cerrar \(short(name, limit: 16))…", preferredLanguage: lang)
        case .activate(let name, _):
            return calendarText("Go to \(short(name))", "Ir a \(short(name))", preferredLanguage: lang)
        case .openActivityMonitor:
            return calendarText("Activity Monitor", "Monitor de Actividad", preferredLanguage: lang)
        }
    }

    private static func short(_ text: String, limit: Int = nameMax) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }

    static func chip(_ level: SystemLevel, lang: String?) -> String {
        switch level {
        case .normal: return calendarText("All good", "Todo bien", preferredLanguage: lang)
        case .attention: return calendarText("Check this", "Revisa esto", preferredLanguage: lang)
        case .critical: return calendarText("Act now", "Actúa ahora", preferredLanguage: lang)
        }
    }

    private struct DisplayLoad {
        let key: String
        var load: AppLoad
        var loadKeys: [String]
        let isTool: Bool
    }

    /// Panel rows combine a tool across launchers. Culprit actions still use separate samples per launcher PID.
    private static func displayLoads(_ loads: [AppLoad]) -> [DisplayLoad] {
        var groups: [String: DisplayLoad] = [:]
        for load in loads {
            let isTool: Bool
            if case .tool = load.kind { isTool = true } else { isTool = false }
            let key = isTool ? "tool|\(load.name)" : load.key
            if var group = groups[key] {
                group.load.cpu += load.cpu
                group.load.memory += load.memory
                group.load.count += load.count
                group.loadKeys.append(load.key)
                groups[key] = group
            } else {
                groups[key] = DisplayLoad(key: key, load: load, loadKeys: [load.key], isTool: isTool)
            }
        }
        return Array(groups.values)
    }

    static func cpuBreakdown(_ loads: [AppLoad], total: Double, lang: String?,
                             rowLimit: Int = SystemPanelLayout.maxRows) -> Breakdown {
        let top = displayLoads(loads).filter { $0.load.cpu >= rowMin }.sorted {
            $0.load.cpu == $1.load.cpu ? $0.key < $1.key : $0.load.cpu > $1.load.cpu
        }.prefix(max(0, rowLimit - 1))
        let sum = top.reduce(0) { $0 + $1.load.cpu }
        let rest = total - sum
        guard rest >= -mismatch else { return Breakdown(rows: [], consistent: false) }
        let scale = rest < 0 ? total / sum : 1
        let values = top.map { $0.load.cpu * scale } + [max(0, rest)]
        let integers = apportion(values, to: Int(total.rounded()))
        let denominator = max(total, 10)
        var rows = zip(top, zip(values, integers)).compactMap { group, value -> Breakdown.Row? in
            let (raw, integer) = value
            guard integer > 0 else { return nil }
            return row(group, value: "\(integer)%", amount: integer, fraction: raw / denominator, lang: lang)
        }
        if let remainder = integers.last, remainder >= 1 {
            rows.append(restRow(value: "\(remainder)%", amount: remainder, fraction: max(0, rest) / denominator, lang: lang))
        }
        return Breakdown(rows: rows, consistent: true)
    }

    static func apportion(_ values: [Double], to total: Int) -> [Int] {
        var integers = values.map { Int($0.rounded(.down)) }
        let order = values.indices.sorted {
            let first = values[$0] - Double(integers[$0])
            let second = values[$1] - Double(integers[$1])
            return first == second ? $0 < $1 : first > second
        }
        for index in order.prefix(max(0, total - integers.reduce(0, +))) {
            integers[index] += 1
        }
        return integers
    }

    static func memoryBreakdown(_ loads: [AppLoad], used: UInt64, lang: String?, locale: Locale,
                                rowLimit: Int = SystemPanelLayout.maxRows) -> Breakdown {
        guard used > 0 else { return Breakdown(rows: [], consistent: true) }
        let groups = displayLoads(loads).filter { $0.load.memory > 0 }.sorted {
            $0.load.memory == $1.load.memory ? $0.key < $1.key : $0.load.memory > $1.load.memory
        }
        let measured = groups.reduce(0) { $0 + $1.load.memory }
        let amounts: [Int]
        if measured > used {
            // Process footprints can overlap, including groups below the visible cutoff.
            let scale = Double(used) / Double(measured)
            amounts = apportion(groups.map { Double($0.load.memory) * scale }, to: Int(used))
        } else {
            amounts = groups.map { Int($0.load.memory) }
        }
        let unmeasured = Int(used) - amounts.reduce(0, +)

        // Use the meter's precision across the list: different binary units cannot always add up exactly.
        // Apportion all groups before applying the row limit so resizing never changes an app's label.
        let unit = MemoryDisplayUnit(total: used)
        let displayedTotal = unit.roundedCount(forBytes: used)
        let displayShares = (amounts + [unmeasured]).map { unit.count(forBytes: UInt64($0)) }
        let displayedAmounts = apportion(displayShares, to: displayedTotal)

        var rows: [Breakdown.Row] = []
        var remainingBytes = Int(used)
        var remainingDisplayed = displayedTotal
        for i in groups.indices.prefix(max(0, rowLimit - 1)) where amounts[i] > 0 {
            let display = MemoryDisplay(unit: unit, count: displayedAmounts[i])
            rows.append(row(groups[i], value: display.text(locale: locale), amount: amounts[i],
                            fraction: Double(amounts[i]) / Double(used), lang: lang, memoryDisplay: display))
            remainingBytes -= amounts[i]
            remainingDisplayed -= displayedAmounts[i]
        }
        if remainingBytes > 0 {
            let display = MemoryDisplay(unit: unit, count: remainingDisplayed)
            rows.append(restRow(value: display.text(locale: locale), amount: remainingBytes,
                                fraction: Double(remainingBytes) / Double(used), lang: lang, memoryDisplay: display))
        }
        return Breakdown(rows: rows, consistent: true)
    }

    private static func row(_ group: DisplayLoad, value: String, amount: Int,
                            fraction: Double, lang: String?, memoryDisplay: MemoryDisplay? = nil) -> Breakdown.Row {
        let load = group.load
        let suffix: String?
        switch load.kind {
        case .app: suffix = nil
        case .tool(_, let launcher?, _) where group.loadKeys.count == 1:
            suffix = calendarText("from \(launcher)", "de \(launcher)", preferredLanguage: lang)
        case .tool(let executable, _, _):
            let what = friendly(executable: executable)?.what ?? (en: "background process", es: "proceso sin ventana")
            suffix = calendarText(what.en, what.es, preferredLanguage: lang)
        case .system:
            let what = systemDescription(load.name)
            suffix = calendarText(what.en, what.es, preferredLanguage: lang)
        }
        let name: String
        if case .app = load.kind { name = load.name } else { name = displayName(load.name, lang: lang) }
        return Breakdown.Row(key: group.key, name: name, suffix: suffix, value: value, fraction: min(1, fraction),
                             isRest: false, amount: amount, loadKeys: group.loadKeys, isTool: group.isTool,
                             memoryDisplay: memoryDisplay)
    }

    private static func displayName(_ name: String, lang: String?) -> String {
        switch name {
        case "Compilador": return calendarText("Compiler", "Compilador", preferredLanguage: lang)
        case "Fotos": return calendarText("Photos", "Fotos", preferredLanguage: lang)
        case "Actualización de macOS": return calendarText("macOS Update", "Actualización de macOS", preferredLanguage: lang)
        default: return name
        }
    }

    private static func systemDescription(_ name: String) -> (en: String, es: String) {
        let executable: String
        switch name {
        case "Spotlight": executable = "mds"
        case "Fotos": executable = "photoanalysisd"
        case "iCloud": executable = "bird"
        case "Time Machine": executable = "backupd"
        case "Actualización de macOS": executable = "softwareupdated"
        default: return ("macOS services", "servicios de macOS")
        }
        return friendly(executable: executable)?.what ?? ("macOS services", "servicios de macOS")
    }

    private static func restRow(value: String, amount: Int, fraction: Double, lang: String?,
                                memoryDisplay: MemoryDisplay? = nil) -> Breakdown.Row {
        Breakdown.Row(key: "rest", name: calendarText("System and others", "Sistema y otros", preferredLanguage: lang),
                      suffix: nil, value: value, fraction: fraction, isRest: true, amount: amount, loadKeys: [],
                      memoryDisplay: memoryDisplay)
    }

    private struct DetailGroup {
        let id: String
        let name: String
        var count: Int? = nil
        var weight = 0.0
        var action: SystemAction? = nil
    }

    static func toolDetails(_ row: Breakdown.Row, loads: [AppLoad], metric: LoadMetric, lang: String?,
                            capacity: Int = LoadDetailLayout.maxDetailRows, allowActions: Bool = true) -> [LoadDetail] {
        let keys = Set(row.loadKeys)
        var groups: [String: DetailGroup] = [:]
        for load in loads where keys.contains(load.key) {
            guard case .tool(_, let launcher, let pid) = load.kind else { continue }
            let id = pid.map { "launcher|\($0)" } ?? "unlaunched"
            let name = launcher ?? calendarText("No launcher", "Sin lanzador", preferredLanguage: lang)
            let action = allowActions ? launcher.flatMap { name in pid.map { SystemAction.activate(name: name, pid: $0) } } : nil
            var group = groups[id] ?? DetailGroup(id: id, name: name, count: 0, action: action)
            group.count = (group.count ?? 0) + load.count
            group.weight += metric.weight(load)
            groups[id] = group
        }
        return detailRows(Array(groups.values), parent: row.amount, capacity: capacity, lang: lang)
    }

    static func isOtherAccount(_ uid: UInt32, currentUID: UInt32) -> Bool {
        (500..<0xFF_FF_FF_00).contains(uid) && uid != currentUID
    }

    static func parsePS(_ output: String, currentUID: UInt32) -> [ProcessUsage] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(maxSplits: 4, whereSeparator: \.isWhitespace)
            guard fields.count == 5, let pid = Int32(fields[0]), pid >= 0,
                  let uid = UInt32(fields[1]) ?? Int32(fields[1]).map(UInt32.init(bitPattern:)) else { return nil }
            let cpu = Double(fields[2]).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            let memory = UInt64(fields[3]).flatMap { $0 <= UInt64.max / 1_024 ? $0 * 1_024 : nil }
            guard cpu != nil || memory != nil else { return nil }
            let executable = isOtherAccount(uid, currentUID: currentUID) ? "" : String(fields[4])
            return ProcessUsage(pid: pid, uid: uid, executable: executable, cpu: cpu, memory: memory)
        }
    }

    static func restDetails(_ row: Breakdown.Row, breakdown: Breakdown, loads: [AppLoad], measured: [MeasuredProcess],
                            ps: [ProcessUsage]?, metric: LoadMetric, currentUID: UInt32, cores: Int, lang: String?,
                            capacity: Int = LoadDetailLayout.maxDetailRows) -> [LoadDetail] {
        let visibleKeys = Set(breakdown.rows.flatMap(\.loadKeys))
        let measuredByPID = Dictionary(uniqueKeysWithValues: measured.map { ($0.usage.pid, $0) })
        let loadsByKey = Dictionary(uniqueKeysWithValues: loads.map { ($0.key, $0) })
        let available = ps ?? measured.map(\.usage)
        let otherID = "other"
        var groups: [String: DetailGroup] = [:]
        for process in available {
            let match = measuredByPID[process.pid].flatMap { $0.usage.uid == process.uid ? $0 : nil }
            if let key = match?.loadKey, visibleKeys.contains(key) { continue }
            let weight: Double
            switch metric {
            case .cpu: weight = (process.cpu ?? 0) / Double(ps == nil ? 1 : max(1, cores))
            case .memory: weight = Double(process.memory ?? 0)
            }
            guard weight > 0 else { continue }
            let id: String
            let name: String
            if isOtherAccount(process.uid, currentUID: currentUID) {
                id = "otherAccount"
                name = calendarText("Another Mac account", "Otra cuenta del Mac", preferredLanguage: lang)
            } else if process.uid == currentUID, let app = measuredApp(match) {
                id = "app|\(app.key)"
                name = app.name
            } else if let service = systemProcess(process.executable, lang: lang) {
                (id, name) = service
            } else {
                id = otherID
                name = calendarText("Other", "Otros", preferredLanguage: lang)
            }
            var group = groups[id] ?? DetailGroup(id: id, name: name)
            group.weight += weight
            groups[id] = group
        }

        func measuredApp(_ process: MeasuredProcess?) -> AppLoad? {
            guard let key = process?.loadKey, let load = loadsByKey[key] else { return nil }
            if case .app = load.kind { return load }
            if case .tool(_, _, let launcherPID?) = load.kind,
               let launcher = measuredByPID[launcherPID], launcher.usage.uid == currentUID,
               let launcherKey = launcher.loadKey, let app = loadsByKey[launcherKey], case .app = app.kind {
                return app
            }
            return nil
        }
        // ps %CPU is a decaying, per-core average and RSS can count shared pages. Treat both as weights,
        // cap overestimates proportionally and leave any unexplained share in “Other” within the sampled parent.
        let attributed = groups.values.reduce(0) { $0 + $1.weight }
        let residual = max(0, Double(row.amount) - attributed)
        if residual > 0 {
            var other = groups[otherID] ?? DetailGroup(id: otherID, name: calendarText("Other", "Otros", preferredLanguage: lang))
            other.weight += residual
            groups[otherID] = other
        }
        return detailRows(Array(groups.values), parent: row.amount, capacity: capacity, keep: otherID, lang: lang)
    }

    private static func detailRows(_ groups: [DetailGroup], parent: Int, capacity: Int, keep: String? = nil,
                                   lang: String?) -> [LoadDetail] {
        guard capacity > 0 else { return [] }
        let sorted = groups.sorted { $0.weight == $1.weight ? $0.id < $1.id : $0.weight > $1.weight }
        let sum = sorted.reduce(0) { $0 + $1.weight }
        let values = apportion(sorted.map { sum > 0 ? $0.weight / sum * Double(parent) : 0 }, to: sum > 0 ? parent : 0)
        var all = zip(sorted, values).compactMap { group, value -> LoadDetail? in
            guard value > 0 || group.id == keep else { return nil }
            return LoadDetail(id: group.id, name: group.name, count: group.count, amount: value, action: group.action)
        }
        guard all.count > capacity else { return all }
        var visible = Array(all.prefix(capacity - 1))
        all.removeFirst(capacity - 1)
        if capacity > 3, let keep, let index = all.firstIndex(where: { $0.id == keep }) {
            let retained = all.remove(at: index)
            all.insert(visible.removeLast(), at: 0)
            visible.append(retained)
        }
        let n = all.count
        visible.append(LoadDetail(id: "more", name: calendarText("and \(n) more", "y \(n) más", preferredLanguage: lang),
                                  count: nil, amount: all.reduce(0) { $0 + $1.amount }, action: nil))
        return visible
    }

    static func systemProcess(_ path: String, lang: String?) -> (id: String, name: String)? {
        let executable = (path as NSString).lastPathComponent.lowercased()
        let info: (String, String, String)
        switch executable {
        case "windowserver": info = ("windows", "Display and windows (macOS)", "Pantalla y ventanas (macOS)")
        case "kernel_task": info = ("kernel", "Temperature control (macOS)", "Control de temperatura (macOS)")
        case "mds", "mds_stores", "mdworker", "mdworker_shared", "corespotlightd":
            info = ("spotlight", "Spotlight indexing", "Spotlight indexando")
        case "backupd", "backupd-helper": info = ("backup", "Time Machine", "Time Machine")
        case "photoanalysisd", "mediaanalysisd": info = ("photos", "Photo analysis", "Análisis de fotos")
        case "bird", "cloudd", "fileproviderd": info = ("icloud", "iCloud sync", "Sincronización de iCloud")
        case "fseventsd": info = ("files", "File changes (macOS)", "Cambios de archivos (macOS)")
        case "softwareupdated": info = ("update", "macOS Update", "Actualización de macOS")
        case "coreaudiod": info = ("audio", "Audio (macOS)", "Audio (macOS)")
        default: return nil
        }
        return (info.0, calendarText(info.1, info.2, preferredLanguage: lang))
    }

    static func friendly(executable: String) -> (name: String, what: (en: String, es: String), system: Bool)? {
        let basename = (executable as NSString).lastPathComponent
        let executable = basename.lowercased()
        switch executable {
        case "node": return ("Node.js", ("JavaScript program", "programa de JavaScript"), false)
        case "python", "python3": return ("Python", ("Python program", "programa de Python"), false)
        case _ where executable.hasPrefix("python3."): return ("Python", ("Python program", "programa de Python"), false)
        case "ruby", "java", "php":
            let name = executable == "php" ? "PHP" : executable.capitalized
            return (name, ("\(name) program", "programa de \(name)"), false)
        case "bun", "deno": return (executable.capitalized, ("JavaScript program", "programa de JavaScript"), false)
        case "claude": return ("Claude Code", ("terminal assistant", "asistente en terminal"), false)
        case "codex": return ("Codex", ("terminal assistant", "asistente en terminal"), false)
        case "postgres": return ("PostgreSQL", ("database", "base de datos"), false)
        case "mysqld": return ("MySQL", ("database", "base de datos"), false)
        case "redis-server": return ("Redis", ("database", "base de datos"), false)
        case _ where executable.hasPrefix("com.docker.") || executable.hasPrefix("qemu-system-"):
            return ("Docker", ("containers", "contenedores"), false)
        case "swift-frontend", "clang", "ld", "cc1":
            return ("Compilador", ("compiling code", "compilando código"), false)
        case "git": return ("Git", ("version control", "control de versiones"), false)
        case "mds", "mds_stores", "mdworker", "mdworker_shared", "corespotlightd":
            return ("Spotlight", ("macOS search", "búsqueda de macOS"), true)
        case "photoanalysisd", "mediaanalysisd": return ("Fotos", ("photo analysis", "análisis de fotos"), true)
        case "bird", "cloudd", "fileproviderd": return ("iCloud", ("syncing", "sincronización"), true)
        case "backupd": return ("Time Machine", ("backup", "copia de seguridad"), true)
        case "softwareupdated":
            return ("Actualización de macOS", ("download and install", "descarga e instalación"), true)
        case "windowserver": return ("macOS", ("display", "pantalla"), true)
        case "kernel_task": return ("macOS", ("kernel", "núcleo"), true)
        case "fseventsd": return ("macOS", ("files", "archivos"), true)
        default: return nil
        }
    }

    static func enclosingApp(path: String, apps: [AppRef]) -> AppRef? {
        apps.filter { path.hasPrefix($0.bundlePath + "/") }.max { $0.bundlePath.count < $1.bundlePath.count }
    }

    static func classify(path: String, executable: String, apps: [AppRef],
                         launcher: (name: String, pid: Int32)?) -> (key: String, name: String, kind: LoadKind) {
        if let app = enclosingApp(path: path, apps: apps) {
            let multipleInstances = apps.contains { $0.bundlePath == app.bundlePath && $0.pid != app.pid }
            return (app.bundlePath, app.name, .app(pid: multipleInstances ? nil : app.pid))
        }
        let executable = (executable as NSString).lastPathComponent
        let friendly = friendly(executable: executable)
        let name = friendly?.name ?? executable
        if friendly?.system == true { return (name, name, .system) }
        let key = launcher.map { "\(name)|\($0.name)|\($0.pid)" } ?? "\(name)|-"
        return (key, name, .tool(executable: executable, launcher: launcher?.name, launcherPID: launcher?.pid))
    }

    static func launcher(of pid: Int32, parents: [Int32: Int32], apps: [Int32: String]) -> (name: String, pid: Int32)? {
        var child = pid
        for _ in 0..<30 {
            guard let parent = parents[child], parent > 1 else { return nil }
            if let name = apps[parent] { return (name, parent) }
            child = parent
        }
        return nil
    }
}

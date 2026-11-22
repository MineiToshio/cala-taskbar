import Foundation

let lang = "es"
let locale = Locale(identifier: "es_ES")
var failures = 0
var passes = 0

func expect(_ id: String, _ ok: Bool, _ note: @autoclosure () -> String = "") {
    if ok {
        passes += 1
        print("PASS \(id)")
    } else {
        failures += 1
        print("FAIL \(id) \(note())")
    }
}

func gib(_ amount: Double) -> UInt64 { UInt64((amount * 1_073_741_824).rounded()) }

func app(_ name: String, _ cpu: Double, pid: Int32 = 1, memory: Double = 0, closable: Bool = true) -> AppLoad {
    AppLoad(key: name, name: name, kind: .app(pid: pid), cpu: cpu, memory: gib(memory), count: 1, closable: closable)
}

func node(_ cpu: Double, launcher: String? = "Terminal", pid: Int32? = 700, memory: Double = 0) -> AppLoad {
    let launcher = launcher.flatMap { name in pid.map { (name, $0) } }
    let group = SystemRules.classify(path: "/opt/homebrew/bin/node", executable: "node", apps: [], launcher: launcher)
    return AppLoad(key: group.key, name: group.name, kind: group.kind,
                   cpu: cpu, memory: gib(memory), count: 16, closable: false)
}

func base(window: Double = 21, smoothed: Double = 22, busy: Double = 0, loads: [AppLoad] = []) -> LoadSnapshot {
    LoadSnapshot(lastReading: ProcessReading(capturedAt: 100, cpuWindow: window, loads: loads),
                 observedAt: 100, cpuNow: window, cpuSmoothed: smoothed,
                 busyMinutes: busy, hotMinutes: 0, pressure: .normal, pressureMinutes: 0,
                 memoryUsed: gib(9), memoryTotal: gib(16), thermal: .nominal, lowPower: false)
}

func setLoads(_ snapshot: inout LoadSnapshot, _ loads: [AppLoad]) {
    snapshot.lastReading = ProcessReading(capturedAt: snapshot.observedAt, cpuWindow: snapshot.cpuNow, loads: loads)
}

var messageCases: [LoadSnapshot] = []
func checkMessage(_ id: String, _ snapshot: LoadSnapshot, kind: SystemMessage.Kind?,
                  level: SystemLevel = .normal, style: SystemMessage.Style = .card,
                  primary: SystemAction? = nil, secondary: SystemAction? = nil,
                  title: String? = nil, detail: String? = nil, extra: Bool = true) {
    messageCases.append(snapshot)
    let message = SystemRules.message(snapshot)
    let expected = kind.map { SystemMessage(kind: $0, level: level, style: style, primary: primary, secondary: secondary) }
    let text = message.map { SystemRules.text($0, lang: lang, locale: locale) }
    expect(id, message == expected && SystemRules.level(snapshot) == level && extra
           && (title == nil || text?.title == title) && (detail == nil || text?.detail == detail),
           "message=\(String(describing: message)), text=\(String(describing: text))")
}

let fine = base(loads: [app("Safari", 6), app("Mail", 2)])
checkMessage("M1 todo bien", fine, kind: nil, extra: SystemRules.chip(.normal, lang: lang) == "Todo bien")

let spike = base(window: 90, smoothed: 88, busy: 0.5)
checkMessage("M2 pico corto", spike, kind: .spike, style: .note,
             title: "Pico momentáneo: es normal y baja solo.",
             extra: SystemRules.cpuState(smoothed: 88, busyMinutes: 0.5) == .busy)

let xcode = app("Xcode", 52, pid: 501)
let sustained = base(window: 80, smoothed: 85, busy: 3.2, loads: [xcode, app("Safari", 5)])
checkMessage("M3 sostenida por app", sustained, kind: .appBusy(name: "Xcode", minutes: 3, closable: true),
             level: .attention, primary: .quit(name: "Xcode", pid: 501, frees: nil), secondary: .openActivityMonitor,
             title: "Xcode está cargando el Mac", detail: "El Mac lleva 3 min ocupado. Si no usas la app, ciérrala. Te pedirá guardar.")

var protected = sustained
setLoads(&protected, [app("Finder", 52, closable: false), app("Safari", 5)])
checkMessage("M3b app protegida", protected, kind: .appBusy(name: "Finder", minutes: 3, closable: false),
             level: .attention, primary: .openActivityMonitor)

let terminal = base(window: 85, smoothed: 90, busy: 4, loads: [node(60)])
checkMessage("M4 node lanzado por Terminal", terminal, kind: .toolBusy(tool: "Node.js", launcher: "Terminal", minutes: 4),
             level: .attention, primary: .activate(name: "Terminal", pid: 700), secondary: .openActivityMonitor,
             title: "Una tarea de Terminal carga el Mac", detail: "El Mac lleva 4 min ocupado. Ahora destaca Node.js. Revísalo allí si no lo esperabas.")

var noLauncher = terminal
setLoads(&noLauncher, [node(60, launcher: nil, pid: nil)])
checkMessage("M4b node sin lanzador", noLauncher, kind: .toolBusy(tool: "Node.js", launcher: nil, minutes: 4),
             level: .attention, primary: .openActivityMonitor, title: "Una tarea en segundo plano carga el Mac")

let chrome = app("Google Chrome", 0, pid: 900, memory: 3.2)
let closeChrome = SystemAction.quit(name: "Google Chrome", pid: 900, frees: gib(3.2))
let low = SystemMessage.Kind.memoryLow(top: "Google Chrome", bytes: gib(3.2))
let critical = SystemMessage.Kind.memoryCritical(top: "Google Chrome", bytes: gib(3.2))
var high = base(loads: [chrome])
high.pressure = .warning
high.pressureMinutes = 3
checkMessage("M5 memoria alta", high, kind: low, level: .attention, primary: closeChrome,
             detail: "El Mac va más lento. Cierra lo que no uses; Google Chrome ocupa 3,2 GB.")
var briefWarning = high
briefWarning.pressureMinutes = 1
checkMessage("M5b aviso breve", briefWarning, kind: nil, extra: SystemRules.memoryState(briefWarning) == .normal)
var criticalMemory = high
criticalMemory.pressure = .critical
criticalMemory.pressureMinutes = 1.5
criticalMemory.criticalPressureMinutes = 1.5
checkMessage("M5c memoria crítica", criticalMemory, kind: critical, level: .critical, primary: closeChrome,
             title: "Casi sin memoria: guarda tu trabajo")
var briefCritical = criticalMemory
briefCritical.pressureMinutes = 3.5
briefCritical.criticalPressureMinutes = 0.5
checkMessage("M5d presión crítica breve tras presión moderada", briefCritical, kind: low, level: .attention, primary: closeChrome)

let backgroundLoads = [node(7, launcher: "Claude", pid: 697), app("Claude", 0.4),
                       AppLoad(key: "Claude Code|Claude|697", name: "Claude Code",
                               kind: .tool(executable: "claude", launcher: "Claude", launcherPID: 697),
                               cpu: 0.3, memory: 0, count: 4, closable: false)]
let background = base(window: 100, smoothed: 98, busy: 2.4, loads: backgroundLoads)
checkMessage("M6 carga no atribuible", background, kind: .systemLoad(minutes: 2), level: .attention,
             primary: .openActivityMonitor, title: "Hay carga que Cala no puede identificar",
             detail: "Puede ser macOS u otra cuenta. Espera unos minutos. Si sigue, abre el Monitor de Actividad.")

let spread = base(window: 80, smoothed: 80, busy: 3, loads: [
    app("A", 15), app("B", 14), app("C", 13), app("D", 12), app("E", 10)
])
checkMessage("M7 carga repartida", spread, kind: .spread(minutes: 3), level: .attention, secondary: .openActivityMonitor)

var hot = sustained
hot.thermal = .serious
checkMessage("M8 calor y CPU", hot, kind: .hot(critical: false), level: .attention, secondary: .openActivityMonitor)
hot.thermal = .critical
hot.criticalThermalMinutes = 2
checkMessage("M9 calor crítico sostenido", hot, kind: .hot(critical: true), level: .critical, secondary: .openActivityMonitor)
var briefHeat = hot
briefHeat.criticalThermalMinutes = 119.0 / 60
checkMessage("M9b calor crítico breve", briefHeat, kind: .hot(critical: false), level: .attention, secondary: .openActivityMonitor)

var both = sustained
both.pressure = .critical
both.pressureMinutes = 1.5
both.criticalPressureMinutes = 1.5
setLoads(&both, sustained.loads + [chrome])
checkMessage("M10 memoria crítica y CPU", both, kind: critical, level: .critical, primary: closeChrome)

var measuring = base(window: 80, smoothed: 80, busy: 3)
measuring.lastReading = nil
checkMessage("M11 midiendo", measuring, kind: .measuring(minutes: 3), level: .attention)

let spotlight = AppLoad(key: "Spotlight", name: "Spotlight", kind: .system, cpu: 40, memory: 0, count: 2, closable: false)
checkMessage("M12 servicio de macOS", base(window: 70, smoothed: 80, busy: 3, loads: [spotlight]),
             kind: .systemTask(name: "Spotlight", minutes: 3), level: .attention, secondary: .openActivityMonitor)

var lowPower = fine
lowPower.lowPower = true
checkMessage("M13 bajo consumo", lowPower, kind: .lowPower, style: .note)
lowPower = spike
lowPower.lowPower = true
checkMessage("M14 bajo consumo y pico", lowPower, kind: .spike, style: .note)

var veryHotCPU = base(window: 97, smoothed: 97, busy: 8)
veryHotCPU.hotMinutes = 6
checkMessage("M15 CPU nunca en rojo", veryHotCPU, kind: .systemLoad(minutes: 8), level: .attention,
             primary: .openActivityMonitor)

var pressureClock = CriticalDuration()
pressureClock.observe(false, at: 0)
pressureClock.observe(false, at: 120)
pressureClock.observe(true, at: 121)
var pressureTransition = briefCritical
pressureTransition.criticalPressureMinutes = pressureClock.minutes(at: 121)
checkMessage("M5e primera lectura crítica tras dos minutos de presión", pressureTransition,
             kind: low, level: .attention, primary: closeChrome)
for time in stride(from: 124, through: 181, by: 3) { pressureClock.observe(true, at: Double(time)) }
pressureTransition.criticalPressureMinutes = pressureClock.minutes(at: 181)
checkMessage("M5f un minuto crítico continuo activa rojo", pressureTransition,
             kind: critical, level: .critical, primary: closeChrome)
pressureClock.observe(false, at: 182)
pressureClock.observe(true, at: 243)
pressureTransition.criticalPressureMinutes = pressureClock.minutes(at: 243)
checkMessage("M5g la presión moderada reinicia el contador crítico", pressureTransition,
             kind: low, level: .attention, primary: closeChrome)

var heatClock = CriticalDuration()
heatClock.observe(false, at: 60)
heatClock.observe(true, at: 61)
for time in stride(from: 64, through: 181, by: 3) { heatClock.observe(true, at: Double(time)) }
hot.criticalThermalMinutes = heatClock.minutes(at: 181)
checkMessage("M9c dos minutos críticos continuos activan rojo", hot,
             kind: .hot(critical: true), level: .critical, secondary: .openActivityMonitor)
heatClock.observe(false, at: 182)
heatClock.observe(true, at: 303)
hot.criticalThermalMinutes = heatClock.minutes(at: 303)
checkMessage("M9d el descenso térmico reinicia el contador crítico", hot,
             kind: .hot(critical: false), level: .attention, secondary: .openActivityMonitor)

let rejected = ProcessReading(capturedAt: 100, cpuWindow: 20, loads: [app("Xcode", 30, pid: 501, memory: 5)])
expect("B9 se rechaza una ventana incoherente completa", rejected == nil)
let rejectedTail = ProcessReading(capturedAt: 100, cpuWindow: 20, loads: [app("A", 8), app("B", 8), app("C", 6), app("D", 5)])
let tolerated = ProcessReading(capturedAt: 100, cpuWindow: 30, loads: [app("A", 16), app("B", 15)])
expect("B10 la validación incluye las filas ocultas y tolera 1 punto", rejectedTail == nil && tolerated != nil)

var retained = terminal
retained.lastReading = rejected ?? retained.lastReading
let retainedRows = retained.reading.map { SystemRules.cpuBreakdown($0.loads, total: $0.cpuWindow, lang: lang).rows }
checkMessage("M18 cifra, filas y acción conservan la misma lectura válida", retained,
             kind: .toolBusy(tool: "Node.js", launcher: "Terminal", minutes: 4),
             level: .attention, primary: .activate(name: "Terminal", pid: 700), secondary: .openActivityMonitor,
             extra: retained.cpuWindow == 85 && retainedRows?.map(\.value) == ["60%", "25%"])

var rejectedFirst = sustained
rejectedFirst.lastReading = rejected
checkMessage("M19 primera ventana inválida no habilita acciones", rejectedFirst, kind: .measuring(minutes: 3),
             level: .attention, extra: rejectedFirst.cpuWindow == nil && rejectedFirst.loads.isEmpty)
rejectedFirst.pressure = .warning
rejectedFirst.pressureMinutes = 3
checkMessage("M19b la ventana inválida tampoco recomienda cerrar por memoria", rejectedFirst,
             kind: .memoryLow(top: nil, bytes: nil), level: .attention, primary: .openActivityMonitor)

var handoff = sustained
handoff.busyMinutes = 4
let previousLeader = SystemRules.message(handoff)
setLoads(&handoff, [node(60), app("Xcode", 5, pid: 501)])
let handoffEnglish = SystemRules.message(handoff).map { SystemRules.text($0, lang: "en").detail }
checkMessage("M20 el relevo de líder conserva la duración del Mac", handoff,
             kind: .toolBusy(tool: "Node.js", launcher: "Terminal", minutes: 4), level: .attention,
             primary: .activate(name: "Terminal", pid: 700), secondary: .openActivityMonitor,
             detail: "El Mac lleva 4 min ocupado. Ahora destaca Node.js. Revísalo allí si no lo esperabas.",
             extra: previousLeader?.primary == .quit(name: "Xcode", pid: 501, frees: nil)
                 && handoffEnglish == "Your Mac has been busy for 4 min. Node.js leads now. If unexpected, check it there.")

let unknownEnglish = SystemRules.message(background).map { SystemRules.text($0, lang: "en") }
expect("M21 carga desconocida en inglés con espera y acción",
       unknownEnglish?.title == "Cala can’t identify some of the load"
           && unknownEnglish?.detail == "It may be macOS or another account. Wait a few minutes. If it lasts, open Activity Monitor."
           && unknownEnglish?.primary == "Activity Monitor")

let sharedPath = "/Applications/Editor.app"
let idleInstance = AppRef(bundlePath: sharedPath, name: "Editor", pid: 901, regular: true)
let busyInstance = AppRef(bundlePath: sharedPath, name: "Editor", pid: 902, regular: true)
let sharedExecutable = sharedPath + "/Contents/MacOS/Editor"
let grouped = SystemRules.classify(path: sharedExecutable, executable: "Editor", apps: [idleInstance, busyInstance], launcher: nil)
let reversed = SystemRules.classify(path: sharedExecutable, executable: "Editor", apps: [busyInstance, idleInstance], launcher: nil)
expect("G5 dos instancias comparten fila sin un PID de cierre",
       grouped.key == sharedPath && grouped.kind == .app(pid: nil) && reversed.kind == grouped.kind)
let ambiguous = AppLoad(key: grouped.key, name: grouped.name, kind: grouped.kind,
                        cpu: 60, memory: gib(5), count: 2, closable: true)
let mixed = base(window: 80, smoothed: 85, busy: 4, loads: [ambiguous])
checkMessage("M22 carga de una app con dos instancias no ofrece cerrar", mixed,
             kind: .appBusy(name: "Editor", minutes: 4, closable: false),
             level: .attention, primary: .openActivityMonitor)
var mixedMemory = high
setLoads(&mixedMemory, [ambiguous, chrome].map { load in
    var load = load
    load.cpu = 0
    return load
})
checkMessage("M23 memoria elige Chrome y evita el grupo con varios PID", mixedMemory,
             kind: low, level: .attention, primary: closeChrome)

var pausedClock = CriticalDuration()
for time in stride(from: 0, through: 120, by: 3) { pausedClock.observe(true, at: Double(time)) }
let beforePause = pausedClock.minutes(at: 120)
let duringPause = pausedClock.minutes(at: 300)
pausedClock.observe(true, at: 300)
let afterPause = pausedClock.minutes(at: 300)
pausedClock.observe(true, at: 303)
expect("M24 un hueco de tres minutos no prolonga un tramo crítico",
       beforePause == 2 && duringPause == 0 && afterPause == 0 && pausedClock.minutes(at: 303) == 3.0 / 60)

var expiredApp = sustained
expiredApp.observedAt = 103.9
let beforeExpiry = SystemRules.message(expiredApp)
expiredApp.observedAt = 104.1
expiredApp.lastReading = rejected ?? expiredApp.lastReading
checkMessage("M25 caducan la atribución y el cierre tras dos intervalos sin lectura válida", expiredApp,
             kind: .measuring(minutes: 3), level: .attention,
             extra: beforeExpiry?.primary == .quit(name: "Xcode", pid: 501, frees: nil)
                 && expiredApp.reading == nil && expiredApp.cpuWindow == nil && expiredApp.loads.isEmpty)

var expiredTool = terminal
expiredTool.observedAt = 104.1
checkMessage("M26 caduca Ir a Terminal con la lectura de Node.js", expiredTool,
             kind: .measuring(minutes: 4), level: .attention,
             extra: expiredTool.loads.isEmpty)
setLoads(&expiredTool, [node(65, pid: 702)])
checkMessage("M26b una lectura válida nueva recupera la acción con su propio PID", expiredTool,
             kind: .toolBusy(tool: "Node.js", launcher: "Terminal", minutes: 4),
             level: .attention, primary: .activate(name: "Terminal", pid: 702), secondary: .openActivityMonitor,
             extra: expiredTool.reading?.capturedAt == 104.1)

var expiredMemory = criticalMemory
expiredMemory.observedAt = 104.1
checkMessage("M27 presión crítica vigente sin señalar una app de una lectura caducada", expiredMemory,
             kind: .memoryCritical(top: nil, bytes: nil), level: .critical, primary: .openActivityMonitor,
             extra: expiredMemory.loads.isEmpty)

let idleTerminal = node(5, pid: 701)
let busyTerminal = node(60, pid: 702)
let anotherTask = node(1, pid: 702)
expect("G6 el mismo lanzador agrupa por PID y distingue instancias del mismo nombre",
       idleTerminal.key != busyTerminal.key && anotherTask.key == busyTerminal.key)
let twoTerminals = base(window: 85, smoothed: 85, busy: 4, loads: [idleTerminal, busyTerminal])
let terminalRows = SystemRules.cpuBreakdown(twoTerminals.loads, total: 85, lang: lang).rows
checkMessage("M28 Ir a Terminal apunta al lanzador que concentra la carga", twoTerminals,
             kind: .toolBusy(tool: "Node.js", launcher: "Terminal", minutes: 4),
             level: .attention, primary: .activate(name: "Terminal", pid: 702), secondary: .openActivityMonitor,
             extra: terminalRows.map(\.value) == ["60%", "5%", "20%"])

expect("M16 nivel coherente en todas las tarjetas", messageCases.allSatisfy {
    guard let message = SystemRules.message($0), message.style == .card else { return true }
    return message.level == SystemRules.level($0)
})

let name = "ABCDEFGHIJKLMNOPQR"
let oversized = name + "STUVWXYZ"
let toolMemory = node(0, launcher: name, memory: 3.2)
var memoryWithTool = high
setLoads(&memoryWithTool, [toolMemory])
var longApp = sustained
setLoads(&longApp, [app(oversized, 52, pid: 501)])
var longProtected = protected
setLoads(&longProtected, [app(name, 52, closable: false)])
var longTool = terminal
setLoads(&longTool, [AppLoad(key: name, name: name, kind: .tool(executable: name, launcher: name, launcherPID: 700),
                          cpu: 60, memory: 0, count: 1, closable: false)])
var longToolAlone = longTool
setLoads(&longToolAlone, [AppLoad(key: name, name: name, kind: .tool(executable: name, launcher: nil, launcherPID: nil),
                               cpu: 60, memory: 0, count: 1, closable: false)])
var longSystem = base(window: 70, smoothed: 80, busy: 3)
setLoads(&longSystem, [AppLoad(key: name, name: name, kind: .system, cpu: 40, memory: 0, count: 1, closable: false)])
var longMemory = criticalMemory
setLoads(&longMemory, [app(name, 0, memory: 3.2)])
let lengthCases = messageCases + [longApp, longProtected, longTool, longToolAlone, longSystem, longMemory, memoryWithTool]
expect("M17 textos es/en respetan 46/105/24", lengthCases.allSatisfy { snapshot in
    guard let message = SystemRules.message(snapshot) else { return true }
    return ["es", "en"].allSatisfy {
        let text = SystemRules.text(message, lang: $0, locale: locale)
        return text.title.count <= 46 && (text.detail?.count ?? 0) <= 105
            && (text.primary?.count ?? 0) <= 24 && (text.secondary?.count ?? 0) <= 24
    }
})

func checkCPU(_ id: String, _ total: Double, _ loads: [AppLoad], _ values: [String]) {
    let result = SystemRules.cpuBreakdown(loads, total: total, lang: lang)
    let integers = result.rows.compactMap { Int($0.value.dropLast()) }
    expect(id, result.consistent && result.rows.map(\.value) == values && integers.reduce(0, +) == Int(total.rounded()),
           result.rows.map(\.value).joined(separator: " + "))
}

checkCPU("B1 redondeo", 40.4, [app("Chrome", 24.3), app("Xcode", 8.4), app("Mail", 0.6)], ["24%", "8%", "8%"])
checkCPU("B2 exceso pequeño", 30, [app("A", 16), app("B", 15)], ["15%", "15%"])
expect("B3 muestra incoherente", !SystemRules.cpuBreakdown([app("A", 30)], total: 20, lang: lang).consistent)
checkCPU("B4 sin fila ≥1%", 5, [app("A", 0.6), app("B", 0.4)], ["5%"])
checkCPU("B5 resto pequeño", 24.6, [app("A", 24)], ["24%", "1%"])
let m6 = SystemRules.cpuBreakdown(backgroundLoads, total: 100, lang: lang)
expect("B6 Node.js 7% + sistema 93%", m6.consistent && m6.rows.count == 2
       && m6.rows.first?.name == "Node.js" && m6.rows.first?.suffix == "de Claude" && m6.rows.first?.fraction == 0.07
       && m6.rows.last?.isRest == true && m6.rows.last?.name == "Sistema y otros" && m6.rows.last?.fraction == 0.93
       && m6.rows.map(\.value) == ["7%", "93%"])
checkCPU("B7 en reposo", 3, [], ["3%"])
expect("B8 reparto por resto mayor", SystemRules.apportion([24.3, 8.4, 7.7], to: 40) == [24, 8, 8])

let memory = SystemRules.memoryBreakdown([app("Chrome", 0, memory: 3.1), app("Xcode", 0, memory: 2),
                                         app("Slack", 0, memory: 0.9), app("Mail", 0, memory: 0.3)],
                                        used: gib(12.6), lang: lang, locale: locale)
expect("R1 unidades binarias y resto", memory.rows.map(\.value) == ["3,1 GB", "2,0 GB", "922 MB", "6,6 GB"]
       && memory.rows.last?.isRest == true, memory.rows.map(\.value).joined(separator: ", "))
let shared = SystemRules.memoryBreakdown([app("Chrome", 0, memory: 2.5), app("Xcode", 0, memory: 2)],
                                        used: gib(4), lang: lang, locale: locale)
expect("R2 huellas de memoria superpuestas", shared.rows.count == 2 && shared.rows.allSatisfy { !$0.isRest })

let nodeName = SystemRules.friendly(executable: "node")
expect("F1 Node.js", nodeName?.name == "Node.js" && nodeName?.system == false)
expect("F2 Python versionado", SystemRules.friendly(executable: "python3.12")?.name == "Python")
let search = SystemRules.friendly(executable: "mdworker_shared")
expect("F3 Spotlight", search?.name == "Spotlight" && search?.system == true)
expect("F4 ejecutable desconocido", SystemRules.friendly(executable: "foo") == nil)

let chromePath = "/Applications/Google Chrome.app"
let chromeRef = AppRef(bundlePath: chromePath, name: "Google Chrome", pid: 900, regular: true)
let helper = SystemRules.classify(path: chromePath + "/Contents/Frameworks/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper",
                                  executable: "Google Chrome Helper", apps: [chromeRef], launcher: nil)
expect("G1 helper agrupado con Chrome", helper.kind == .app(pid: 900) && helper.name == "Google Chrome" && helper.key == chromePath)
let xcodePath = "/Applications/Xcode.app"
let simPath = xcodePath + "/Contents/Developer/Applications/Simulator.app"
let refs = [AppRef(bundlePath: xcodePath, name: "Xcode", pid: 501, regular: true),
            AppRef(bundlePath: simPath, name: "Simulator", pid: 502, regular: true)]
let sim = SystemRules.classify(path: simPath + "/Contents/MacOS/Simulator", executable: "Simulator", apps: refs, launcher: nil)
expect("G2 se toma la app más interna", sim.kind == .app(pid: 502) && sim.name == "Simulator" && sim.key == simPath)

let claudeRef = AppRef(bundlePath: "/Applications/Claude.app", name: "Claude", pid: 697, regular: true)
let claude = SystemRules.classify(path: "~/Library/Application Support/Claude/claude-code/2.1/x/claude.app/Contents/MacOS/claude",
                                   executable: "claude", apps: [claudeRef], launcher: ("Claude", 697))
expect("G3 Claude Code pertenece a Claude", claude.kind == .tool(executable: "claude", launcher: "Claude", launcherPID: 697)
       && claude.name == "Claude Code" && claude.key == "Claude Code|Claude|697")
expect("G4 Node.js sin lanzador", SystemRules.classify(path: "/opt/homebrew/bin/node", executable: "node", apps: [], launcher: nil).key == "Node.js|-")

let ancestor = SystemRules.launcher(of: 10, parents: [10: 9, 9: 8, 8: 1], apps: [8: "Terminal"])
expect("P1 primer ancestro app", ancestor?.name == "Terminal" && ancestor?.pid == 8)
expect("P2 se detiene en launchd", SystemRules.launcher(of: 10, parents: [10: 1], apps: [1: "launchd"]) == nil)
let chain = Dictionary(uniqueKeysWithValues: (2...41).map { (Int32($0), Int32($0 + 1)) })
expect("P3 límite de 30 ancestros", SystemRules.launcher(of: 2, parents: chain, apps: [42: "Terminal"]) == nil
       && SystemRules.launcher(of: 10, parents: [10: 11, 11: 10], apps: [:]) == nil)

let restart = RestartRules.evaluate(RestartInput(uptime: 21 * 86_400, ram: gib(16), pendingUpdate: "macOS"))
let summary = RestartRules.summary(restart, lang: lang)
expect("S1 actualización tiene prioridad", summary?.text == "actualización de macOS pendiente" && summary?.strong == true && summary?.more == 1)
expect("S2 sin mantenimiento", RestartRules.summary(RestartAdvice(), lang: lang) == nil)

print("\(passes) PASS, \(failures) FAIL")
exit(failures == 0 ? 0 : 1)

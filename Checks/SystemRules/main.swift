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
checkMessage("M1 todo bien", fine, kind: nil)

let xcodeLoad = app("Xcode", 52, pid: 501)
// The processor turns amber after 45 s busy. Before 15 s the note says short spike; from 15 s on it says busy for a while.
let spike = base(window: 90, smoothed: 88, busy: 0.1)
checkMessage("M2 pico corto (menos de 15 s)", spike, kind: .spike, style: .note,
             title: "Pico momentáneo: es normal y baja solo.",
             extra: SystemRules.cpuState(smoothed: 88, busyMinutes: 0.1) == .busy)
expect("M2a umbrales: ámbar a los 45 s y pico solo hasta los 15 s",
       SystemRules.sustainedMin == 0.75 && SystemRules.sustainedMin * 60 == 45
           && SystemRules.spikeMin == 0.25 && SystemRules.spikeMin * 60 == 15)
let busyAWhile = base(window: 90, smoothed: 88, busy: 0.5)
checkMessage("M2b ocupado un rato (30 s): ya no es un pico momentáneo", busyAWhile, kind: .busyAWhile, style: .note,
             title: "Lleva un rato ocupado; si sigue así te aviso.",
             extra: SystemRules.cpuState(smoothed: 88, busyMinutes: 0.5) == .busy)
let busyAWhileEN = SystemRules.message(busyAWhile).map { SystemRules.text($0, lang: "en", locale: Locale(identifier: "en_US")) }
let spikeEN = SystemRules.message(spike).map { SystemRules.text($0, lang: "en", locale: Locale(identifier: "en_US")) }
expect("M2c textos en inglés del pico y del ocupado un rato",
       spikeEN?.title == "Short spike: normal and settles on its own."
           && busyAWhileEN?.title == "Busy for a while; I'll tell you if it lasts.", "\(String(describing: busyAWhileEN))")
func cpuNote(_ seconds: Double) -> (state: MeterState, kind: SystemMessage.Kind?, level: SystemLevel) {
    let s = base(window: 90, smoothed: 88, busy: seconds / 60)
    return (SystemRules.cpuState(smoothed: 88, busyMinutes: seconds / 60), SystemRules.message(s)?.kind, SystemRules.level(s))
}
let at14 = cpuNote(14.9), at15 = cpuNote(15), at44 = cpuNote(44.9), at45 = cpuNote(45)
expect("M2d el pico momentáneo solo se muestra antes de 15 s",
       at14.kind == .spike && at15.kind == .busyAWhile && at44.kind == .busyAWhile
           && cpuNote(0).kind == .spike,
       "\(at14) \(at15) \(at44)")
expect("M2e el procesador pasa a ámbar justo a los 45 s, no antes",
       at14.state == .busy && at44.state == .busy && at44.level == .normal
           && at45.state == .veryBusy && at45.level == .attention
           && SystemRules.cpuState(smoothed: 74.9, busyMinutes: 5) == .normal,
       "\(at44) \(at45)")
let atThreshold = base(window: 80, smoothed: 85, busy: 0.75, loads: [xcodeLoad, app("Safari", 5)])
let atThresholdText = SystemRules.message(atThreshold).map { SystemRules.text($0, lang: lang, locale: locale) }
expect("M2f a los 45 s la tarjeta ya no dice 0 min",
       SystemRules.busyMinutesLabel(0.75) == 1 && SystemRules.busyMinutesLabel(1.99) == 1
           && SystemRules.busyMinutesLabel(2.4) == 2
           && SystemRules.message(atThreshold)?.kind == .appBusy(name: "Xcode", minutes: 1, closable: true)
           && atThresholdText?.detail?.hasPrefix("El Mac lleva 1 min ocupado") == true, "\(String(describing: atThresholdText))")

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
checkMessage("M8 calor y CPU", hot, kind: .hot(critical: false, top: nil), level: .attention, secondary: .openActivityMonitor)
hot.thermal = .critical
hot.criticalThermalMinutes = 2
checkMessage("M9 calor crítico sostenido", hot, kind: .hot(critical: true, top: nil), level: .critical, secondary: .openActivityMonitor)
var briefHeat = hot
briefHeat.criticalThermalMinutes = 119.0 / 60
checkMessage("M9b calor crítico breve", briefHeat, kind: .hot(critical: false, top: nil), level: .attention, secondary: .openActivityMonitor)

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
             kind: .hot(critical: true, top: nil), level: .critical, secondary: .openActivityMonitor)
heatClock.observe(false, at: 182)
heatClock.observe(true, at: 303)
hot.criticalThermalMinutes = heatClock.minutes(at: 303)
checkMessage("M9d el descenso térmico reinicia el contador crítico", hot,
             kind: .hot(critical: false, top: nil), level: .attention, secondary: .openActivityMonitor)

// Heat names what uses the most energy and offers to quit it only when it is a closable app.
func energetic(_ load: AppLoad, _ energy: Double) -> AppLoad {
    var load = load
    load.energy = energy
    return load
}
var hotChrome = base(loads: [energetic(app("Google Chrome", 9, pid: 900), 24.6), energetic(app("Safari", 6, pid: 100), 7)])
hotChrome.thermal = .serious
let quitChrome = SystemAction.quit(name: "Google Chrome", pid: 900, frees: nil)
checkMessage("M8b el calor nombra lo que más energía usa", hotChrome, kind: .hot(critical: false, top: "Google Chrome"),
             level: .attention, primary: quitChrome, secondary: .openActivityMonitor,
             title: "El Mac está caliente", detail: "Lo que más energía usa es Google Chrome.")
let hotChromeText = SystemRules.message(hotChrome).map { SystemRules.text($0, lang: "en", locale: locale) }
let hotChromeES = SystemRules.message(hotChrome).map { SystemRules.text($0, lang: lang, locale: locale) }
expect("M8c textos del calor con app cerrable en es/en",
       hotChromeES?.primary == "Cerrar Google Chrome…" && hotChromeES?.secondary == "Monitor de Actividad"
           && hotChromeText?.title == "The Mac is hot" && hotChromeText?.detail == "Google Chrome uses the most energy."
           && hotChromeText?.primary == "Quit Google Chrome…", "\(String(describing: hotChromeES)) | \(String(describing: hotChromeText))")
var hotFinder = hotChrome
setLoads(&hotFinder, [energetic(app("Finder", 9, pid: 300, closable: false), 30), energetic(app("Safari", 6, pid: 100), 7)])
checkMessage("M8d sin app cerrable la tarjeta no ofrece cerrar", hotFinder, kind: .hot(critical: false, top: "Finder"),
             level: .attention, secondary: .openActivityMonitor, detail: "Lo que más energía usa es Finder.")
let hotFinderEN = SystemRules.message(hotFinder).map { SystemRules.text($0, lang: "en", locale: locale) }
expect("M8e sin app cerrable en inglés solo queda el Monitor de Actividad",
       hotFinderEN?.primary == nil && hotFinderEN?.secondary == "Activity Monitor"
           && hotFinderEN?.detail == "Finder uses the most energy.", "\(String(describing: hotFinderEN))")
var veryHotChrome = hotChrome
veryHotChrome.thermal = .critical
veryHotChrome.criticalThermalMinutes = 3
checkMessage("M8f calor crítico con culpable", veryHotChrome, kind: .hot(critical: true, top: "Google Chrome"),
             level: .critical, primary: quitChrome, secondary: .openActivityMonitor,
             title: "El Mac está muy caliente", detail: "Guarda tu trabajo. Lo que más energía usa es Google Chrome.")
var hotIdle = hotChrome
setLoads(&hotIdle, [energetic(app("Safari", 6, pid: 100), 0.5)])
checkMessage("M8g sin un consumo destacable se mantiene el consejo general", hotIdle, kind: .hot(critical: false, top: nil),
             level: .attention, secondary: .openActivityMonitor, title: "El Mac está caliente y va más lento")
var hotNode = hotChrome
setLoads(&hotNode, [energetic(node(3), 6), energetic(node(3, launcher: "Claude", pid: 697), 6),
                    energetic(app("Safari", 6, pid: 100), 10)])
let hotNodeList = SystemRules.energyBreakdown(hotNode.loads, unattributed: 0, lang: lang, locale: locale)
checkMessage("M8i el calor nombra al líder de la lista de Energía y no cierra un grupo de herramientas", hotNode,
             kind: .hot(critical: false, top: "Node.js"), level: .attention, secondary: .openActivityMonitor,
             detail: "Lo que más energía usa es Node.js.",
             extra: hotNodeList.rows.first?.name == "Node.js" && hotNodeList.rows.first?.value == "12,0")
var hotSole = hotChrome
setLoads(&hotSole, [energetic(app("Google Chrome", 9, pid: 900), 4)])
checkMessage("M8j un único consumo de 4 puntos también se nombra y se ofrece cerrar", hotSole,
             kind: .hot(critical: false, top: "Google Chrome"), level: .attention, primary: quitChrome,
             secondary: .openActivityMonitor,
             extra: SystemRules.energyBreakdown(hotSole.loads, unattributed: 0, lang: lang, locale: locale).rows.first?.name
                 == "Google Chrome")
var hotStale = hotChrome
hotStale.observedAt += ProcessReading.maxAge + 1
checkMessage("M8h sin lectura fresca no se nombra ni se cierra nada", hotStale, kind: .hot(critical: false, top: nil),
             level: .attention, secondary: .openActivityMonitor)

// MARK: Energy impact

func counters(_ cpuMs: UInt64, _ wakeups: UInt64, start: UInt64 = 1) -> EnergyCounters {
    EnergyCounters(start: start, cpuNanoseconds: cpuMs * 1_000_000, wakeups: wakeups)
}
let energyBefore: [Int32: EnergyCounters] = [10: counters(1_000, 100), 20: counters(5_000, 0), 30: counters(0, 0),
                                             40: counters(9_000, 50), 50: counters(100, 0, start: 7)]
let energyAfter: [Int32: EnergyCounters] = [10: counters(1_500, 100), 20: counters(5_200, 2_000), 30: counters(250, 0),
                                            40: counters(8_000, 60), 50: counters(400, 0, start: 8), 60: counters(900, 0)]
let ranking = SystemRules.energyRanking(before: energyBefore, after: energyAfter, elapsed: 2)
expect("N1 el impacto energético suma tiempo de CPU y despertares por segundo",
       ranking.map(\.pid) == [20, 10, 30] && ranking.map { ($0.score * 10).rounded() / 10 } == [30, 25, 12.5],
       "\(ranking)")
expect("N2 se descartan PID nuevos, reutilizados o con contadores que retroceden",
       SystemRules.energyScore(from: nil, to: counters(1, 1), elapsed: 2) == nil
           && SystemRules.energyScore(from: counters(100, 0, start: 7), to: counters(400, 0, start: 8), elapsed: 2) == nil
           && SystemRules.energyScore(from: counters(9_000, 50), to: counters(8_000, 60), elapsed: 2) == nil
           && SystemRules.energyScore(from: counters(1, 1), to: counters(2, 2), elapsed: 0) == nil)
expect("N3 un núcleo ocupado sin despertares puntúa 100",
       SystemRules.energyScore(from: counters(0, 0), to: counters(2_000, 0), elapsed: 2) == 100)

let energyLoads = [energetic(app("Google Chrome", 9, pid: 900), 24.64), energetic(app("Safari", 6, pid: 100), 7.33),
                   energetic(node(5), 12.01), energetic(app("Mail", 1, pid: 101), 0.02)]
let energyRows = SystemRules.energyBreakdown(energyLoads, unattributed: 6, lang: lang, locale: locale, rowLimit: 3)
expect("N4 Energía ordena por impacto, muestra un decimal y agrupa el resto en Sistema y otros",
       energyRows.rows.map(\.name) == ["Google Chrome", "Node.js", "Sistema y otros"]
           && energyRows.rows.map(\.value) == ["24,6", "12,0", "13,4"]
           && energyRows.rows.reduce(0) { $0 + $1.amount } == 500 && energyRows.rows.last?.isRest == true,
       "\(energyRows.rows.map { ($0.name, $0.value, $0.amount) })")
let energyEN = SystemRules.energyBreakdown(energyLoads, unattributed: 6, lang: "en", locale: Locale(identifier: "en_US"))
expect("N5 en inglés usa punto decimal y el texto del resto",
       energyEN.rows.first?.value == "24.6" && energyEN.rows.last?.name == "System and others"
           && SystemRules.energyBreakdown([], unattributed: 0, lang: lang, locale: locale).rows.isEmpty,
       "\(energyEN.rows.map { ($0.name, $0.value) })")
let energyReading = ProcessReading(capturedAt: 100, cpuWindow: 30, loads: [app("A", 10), app("B", 5)])!
expect("N6 la carga que Cala no lee cuenta como tiempo de procesador por núcleo",
       SystemRules.unattributedEnergy(energyReading, cores: 8) == 120)
let otherAccountProcess = MeasuredProcess(usage: ProcessUsage(pid: 90, uid: 502, executable: "", cpu: 2, memory: nil,
                                                              energy: 30), loadKey: nil)
let mixedReading = ProcessReading(capturedAt: 100, cpuWindow: 30, loads: [app("A", 10), app("B", 5)],
                                  processes: [otherAccountProcess])!
expect("N8 otra cuenta suma su energía medida y solo se estima la CPU que nadie explica",
       SystemRules.unattributedEnergy(mixedReading, cores: 8) == 30 + (30 - 15 - 2) * 8,
       "\(SystemRules.unattributedEnergy(mixedReading, cores: 8))")
// The Energía meter shows the total its tab adds up to, and the background sampler computes the same total.
let totalLoads = [energetic(app("A", 10), 12.4), energetic(app("B", 5), 6.1)]
let totalReading = ProcessReading(capturedAt: 100, cpuWindow: 30, loads: totalLoads, processes: [otherAccountProcess])!
let totalTab = SystemRules.energyBreakdown(totalReading.loads, unattributed: SystemRules.unattributedEnergy(totalReading, cores: 8),
                                           lang: lang, locale: locale)
let panelTotal = SystemRules.energyTotal(totalReading, cores: 8)
let backgroundTotal = SystemRules.energyTotal(measuredEnergy: 12.4 + 6.1 + 30, measuredCPU: 10 + 5 + 2, cpuWindow: 30, cores: 8)
expect("N9 el total de Energía coincide entre el panel, su lista y el muestreo de fondo",
       abs(panelTotal - backgroundTotal) < 1e-9 && abs(panelTotal - (12.4 + 6.1 + 30 + 13 * 8)) < 1e-9
           && abs(Double(totalTab.rows.reduce(0) { $0 + $1.amount }) / 10 - panelTotal) < 0.2,
       "\(panelTotal) \(backgroundTotal) \(totalTab.rows.map(\.amount))")
expect("N9b el procesador que nadie explica nunca resta energía",
       SystemRules.energyTotal(measuredEnergy: 5, measuredCPU: 40, cpuWindow: 30, cores: 8) == 5
           && SystemRules.energyTotal(measuredEnergy: 0, measuredCPU: 0, cpuWindow: 0, cores: 8) == 0)
expect("N9c el número del medidor sale de la lectura mostrada y, sin ella, del último muestreo de fondo",
       SystemRules.energyValue(reading: totalReading, history: [1, 2], cores: 8) == Int(panelTotal.rounded())
           && SystemRules.energyValue(reading: nil, history: [10, 41.6], cores: 8) == 42
           && SystemRules.energyValue(reading: nil, history: [], cores: 8) == nil)
expect("N9d el muestreo de fondo descarta ventanas rotas por la suspensión o por un reloj parado",
       SystemRules.energyInterval == 5
           && SystemRules.energyWindowUsable(gap: 5) && SystemRules.energyWindowUsable(gap: 6.2)
           && !SystemRules.energyWindowUsable(gap: 0.2) && !SystemRules.energyWindowUsable(gap: 45)
           && !SystemRules.energyWindowUsable(gap: -1))

// First sample: without per-process deltas the Procesador and Energía lists show the skeleton, not “Sistema y otros 100%”.
expect("S1 una primera pasada sin deltas por proceso no se publica como lectura",
       !SystemRules.canPublishReading(cpuWindow: nil, processesWithDeltas: 0)
           && !SystemRules.canPublishReading(cpuWindow: nil, processesWithDeltas: 40)
           && !SystemRules.canPublishReading(cpuWindow: 35, processesWithDeltas: 0)
           && SystemRules.canPublishReading(cpuWindow: 35, processesWithDeltas: 1)
           && SystemRules.canPublishReading(cpuWindow: 0, processesWithDeltas: 12))
expect("S2 una ventana demasiado corta no sirve como medición ni como punto de partida",
       !SystemRules.deltaWindowUsable(elapsed: 0) && !SystemRules.deltaWindowUsable(elapsed: 0.1)
           && !SystemRules.deltaWindowUsable(elapsed: 0.49) && SystemRules.deltaWindowUsable(elapsed: 0.5)
           && SystemRules.deltaWindowUsable(elapsed: 2))
var firstScan = base()
firstScan.lastReading = nil
var oneReading = base()
var reopenedOld = base()
reopenedOld.processSessionStartedAt = 500
expect("S3 sin lectura, Procesador y Energía muestran el esqueleto y Memoria no",
       SystemRules.listIsLoading(metric: .cpu, availability: firstScan.cpuAvailability)
           && SystemRules.listIsLoading(metric: .energy, availability: firstScan.cpuAvailability)
           && !SystemRules.listIsLoading(metric: .memory, availability: firstScan.cpuAvailability)
           && !SystemRules.listIsLoading(metric: .cpu, availability: oneReading.cpuAvailability)
           && !SystemRules.listIsLoading(metric: .energy, availability: oneReading.cpuAvailability)
           && !SystemRules.listIsLoading(metric: .energy, availability: reopenedOld.cpuAvailability),
       "\(firstScan.cpuAvailability) \(oneReading.cpuAvailability) \(reopenedOld.cpuAvailability)")

let nodeEnergy = SystemRules.energyBreakdown([energetic(node(4), 9), energetic(node(3, launcher: "Claude", pid: 697), 3)],
                                             unattributed: 0, lang: lang, locale: locale)
let nodeEnergyRow = nodeEnergy.rows.first { $0.isTool }
let nodeEnergyChildren = nodeEnergyRow.map {
    SystemRules.toolDetails($0, loads: [energetic(node(4), 9), energetic(node(3, launcher: "Claude", pid: 697), 3)],
                            metric: .energy, lang: lang)
} ?? []
expect("N7 las subfilas de Energía suman su fila padre con un decimal",
       nodeEnergyRow?.value == "12,0" && nodeEnergyRow.map {
           LoadMetric.energy.values(for: nodeEnergyChildren, parent: $0, locale: locale) } == ["9,0", "3,0"],
       "\(nodeEnergyChildren)")

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

var reopenedApp = sustained
reopenedApp.observedAt = 105
reopenedApp.processSessionStartedAt = 105
reopenedApp.cpuNow = 92
let recalled = reopenedApp.displayedReading
let recalledTotal = recalled.map { reading in
    SystemRules.cpuBreakdown(reading.loads, total: reading.cpuWindow, lang: lang).rows.reduce(0) { $0 + $1.amount }
}
expect("C1 reapertura a 5 s muestra la lista de inmediato y conserva su total",
       reopenedApp.cpuAvailability == .remembered && recalled?.capturedAt == 100
           && recalledTotal == 80 && recalled?.cpuWindow == 80 && reopenedApp.cpuNow == 92)
expect("C2 una lista recordada no ofrece Cerrar",
       reopenedApp.reading == nil && SystemRules.message(reopenedApp)?.primary == nil)
reopenedApp.observedAt = 130
expect("C3 la caché incluye el límite exacto de 30 s", reopenedApp.displayedReading != nil)
reopenedApp.observedAt = 160
expect("C4 reapertura a 60 s deja el procesador sin lista utilizable",
       reopenedApp.cpuAvailability == .missing && reopenedApp.displayedReading == nil)

var reopenedTool = terminal
reopenedTool.processSessionStartedAt = 101
reopenedTool.observedAt = 101
let rememberedTool = reopenedTool.displayedReading!
let rememberedRow = SystemRules.cpuBreakdown(rememberedTool.loads, total: rememberedTool.cpuWindow, lang: lang)
    .rows.first(where: \.isTool)!
let rememberedDetails = SystemRules.toolDetails(rememberedRow, loads: rememberedTool.loads, metric: .cpu, lang: lang,
                                               allowActions: reopenedTool.canUseProcessActions(capturedAt: 100))
expect("C5 ni siquiera una muestra del panel anterior de 1 s habilita Ir a Terminal",
       reopenedTool.cpuAvailability == .remembered && SystemRules.message(reopenedTool)?.primary == nil
           && rememberedDetails.count == 1 && rememberedDetails.allSatisfy { $0.action == nil })
setLoads(&reopenedTool, [node(60, pid: 702)])
expect("C6 la primera ventana válida de la nueva sesión habilita el lanzador correcto",
       reopenedTool.cpuAvailability == .fresh && reopenedTool.canUseProcessActions(capturedAt: 101)
           && SystemRules.message(reopenedTool)?.primary == .activate(name: "Terminal", pid: 702))

var firstMemoryScan = reopenedApp
firstMemoryScan.lastReading = nil
firstMemoryScan.processSessionStartedAt = 160
firstMemoryScan.lastInventory = ProcessInventory(capturedAt: 160, loads: [app("Safari", 0, memory: 2)], processes: [])
expect("C7 la primera pasada da memoria atribuida sin una ventana de CPU ni acciones",
       firstMemoryScan.displayedInventory?.loads.first?.memory == gib(2)
           && firstMemoryScan.cpuAvailability == .missing && !firstMemoryScan.canUseProcessActions(capturedAt: 160))

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
             extra: terminalRows.map(\.value) == ["65%", "20%"])

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
                                        used: gib(12.6), lang: lang, locale: locale, rowLimit: 4)
expect("R1 unidades binarias y resto", memory.rows.map(\.value) == ["3,1 GB", "2,0 GB", "0,9 GB", "6,6 GB"]
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
expect("S1 actualización tiene prioridad", summary?.text == "macOS pendiente de actualizar" && summary?.strong == true && summary?.more == 1)
expect("S2 sin mantenimiento", RestartRules.summary(RestartAdvice(), lang: lang) == nil)

let launcherLoads = [node(40, launcher: "Terminal", pid: 701, memory: 1.5),
                     node(20, launcher: "Claude", pid: 702, memory: 1.0)]
let launcherCPU = SystemRules.cpuBreakdown(launcherLoads, total: 85, lang: lang)
let nodeCPU = launcherCPU.rows.first!
let launcherCPUDetails = SystemRules.toolDetails(nodeCPU, loads: launcherLoads, metric: .cpu, lang: lang)
expect("E1 una fila de Node.js se reparte por lanzador con sus acciones",
       nodeCPU.isTool && nodeCPU.amount == 60 && launcherCPU.rows.last?.amount == 25
       && launcherCPUDetails.map(\.name) == ["Terminal", "Claude"] && launcherCPUDetails.map(\.amount) == [40, 20]
       && launcherCPUDetails.map(\.count) == [16, 16]
       && launcherCPUDetails.map(\.action) == [.activate(name: "Terminal", pid: 701), .activate(name: "Claude", pid: 702)])

let launcherMemory = SystemRules.memoryBreakdown(launcherLoads, used: gib(8), lang: lang, locale: locale)
let nodeMemory = launcherMemory.rows.first!
let launcherMemoryDetails = SystemRules.toolDetails(nodeMemory, loads: launcherLoads, metric: .memory, lang: lang)
expect("E2 memoria de Node.js se normaliza en bytes al total de la fila",
       nodeMemory.isTool && nodeMemory.value == "2,5 GB"
           && launcherMemoryDetails.map(\.amount) == [Int(gib(1.5)), Int(gib(1))]
           && launcherMemoryDetails.reduce(0) { $0 + $1.amount } == nodeMemory.amount)

let sixLaunchers = (1...6).map { node(Double(7 - $0), launcher: "L\($0)", pid: Int32(710 + $0)) }
let sixRow = SystemRules.cpuBreakdown(sixLaunchers, total: 25, lang: lang).rows.first!
let sixDetails = SystemRules.toolDetails(sixRow, loads: sixLaunchers, metric: .cpu, lang: lang)
expect("E3 cuatro subfilas y un subtotal para los dos lanzadores restantes",
       sixDetails.count == 5 && sixDetails.last?.name == "y 2 más" && sixDetails.last?.amount == 3
           && sixDetails.last?.action == nil && sixDetails.reduce(0) { $0 + $1.amount } == sixRow.amount)

let orphan = node(4, launcher: nil, pid: nil)
let orphanRow = SystemRules.cpuBreakdown([orphan], total: 4, lang: lang).rows.first!
let orphanDetails = SystemRules.toolDetails(orphanRow, loads: [orphan], metric: .cpu, lang: lang)
expect("E4 un proceso sin lanzador conserva su parte sin acción",
       orphanDetails.count == 1 && orphanDetails.first?.name == "Sin lanzador"
           && orphanDetails.first?.amount == 4 && orphanDetails.first?.action == nil)

let psText = """
   11    0   80.0  8192 /System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer
   12    0   16.0  2048 kernel_task
   13  499   16.0   128 /System/Library/Services/mds
   14    0   32.0   512 mdworker
   15  502   32.0  1024 /Users/other/Private Tool.app/Contents/MacOS/Secret
   16  503    8.0   256 /System/Library/Not WindowServer/WindowServer
   17  501   12.5   100 /Users/me/My Script
   18  501      -  2048 /Users/me/Memory Only
   19  501    nan     - invalid
   20  501   98.0  2048 /Applications/Already Counted.app
"""
let ps = SystemRules.parsePS(psText, currentUID: 501)
expect("E5 parser conserva rutas con espacios y RSS con CPU no disponible",
       ps.count == 9 && ps.first(where: { $0.pid == 17 })?.executable == "/Users/me/My Script"
           && ps.first(where: { $0.pid == 18 })?.cpu == nil && ps.first(where: { $0.pid == 18 })?.memory == 2_097_152)
expect("E6 las muestras de otras cuentas pierden sus nombres al leer ps",
       ps.filter { $0.uid == 502 || $0.uid == 503 }.allSatisfy { $0.executable.isEmpty }
           && ps.filter { $0.uid == 502 || $0.uid == 503 }.count == 2
           && !SystemRules.isOtherAccount(499, currentUID: 501) && SystemRules.isOtherAccount(500, currentUID: 501))
expect("E7 nombres conocidos de macOS y aliases de Spotlight",
       SystemRules.systemProcess("WindowServer", lang: lang)?.name == "Pantalla y ventanas (macOS)"
           && SystemRules.systemProcess("kernel_task", lang: lang)?.name == "Control de temperatura (macOS)"
           && ["mds", "mdworker", "mds_stores"].allSatisfy { SystemRules.systemProcess($0, lang: lang)?.name == "Spotlight indexando" }
           && SystemRules.systemProcess("backupd", lang: lang)?.name == "Time Machine"
           && SystemRules.systemProcess("backupd", lang: "en")?.name == "Time Machine"
           && SystemRules.systemProcess("no-match", lang: lang) == nil)

let referenceApp = app("Already counted", 35, pid: 20, memory: 2)
let measuredApp = MeasuredProcess(usage: ProcessUsage(pid: 20, uid: 501, executable: "Already Counted", cpu: 35, memory: gib(2)),
                                  loadKey: referenceApp.key)
let restCPU = SystemRules.cpuBreakdown([referenceApp], total: 70, lang: lang)
let restParent = restCPU.rows.last!
let restRows = SystemRules.restDetails(restParent, breakdown: restCPU, loads: [referenceApp], measured: [measuredApp], ps: ps,
                                      metric: .cpu, currentUID: 501, cores: 8, lang: lang)
expect("E8 el resto excluye PID visibles, agrupa cuentas y conserva el residuo",
       restRows.first(where: { $0.id == "otherAccount" })?.amount == 5
           && restRows.first(where: { $0.id == "spotlight" })?.amount == 6
           && restRows.contains { $0.name == "Otros" }
           && !restRows.contains { $0.name.contains("Counted") || $0.name.contains("Secret") }
           && restRows.reduce(0) { $0 + $1.amount } == restParent.amount)

let over = SystemRules.cpuBreakdown([], total: 10, lang: lang)
let overParent = over.rows.first!
let overRows = SystemRules.restDetails(overParent, breakdown: over, loads: [], measured: [], ps: Array(ps.prefix(2)),
                                      metric: .cpu, currentUID: 501, cores: 8, lang: lang)
expect("E9 las medias de ps se escalan si superan la fila padre",
       overRows.map(\.amount) == [8, 2] && overRows.reduce(0) { $0 + $1.amount } == overParent.amount)

let measuredFallback = MeasuredProcess(usage: ProcessUsage(pid: 31, uid: 501, executable: "mdworker", cpu: 3, memory: gib(0.5)),
                                       loadKey: "below-cut")
let withoutPS = SystemRules.restDetails(restParent, breakdown: restCPU, loads: [referenceApp], measured: [measuredApp, measuredFallback], ps: nil,
                                       metric: .cpu, currentUID: 501, cores: 8, lang: lang)
expect("E10 sin ps solo se usa lo medido y lo demás queda en Otros",
       withoutPS.map(\.name) == ["Otros", "Spotlight indexando"] && withoutPS.map(\.amount) == [32, 3])
let noMeasurements = SystemRules.restDetails(restParent, breakdown: restCPU, loads: [referenceApp], measured: [], ps: nil,
                                            metric: .cpu, currentUID: 501, cores: 8, lang: lang)
expect("E11 sin ninguna medición todo el resto sigue contabilizado",
       noMeasurements.count == 1 && noMeasurements[0].name == "Otros" && noMeasurements[0].amount == restParent.amount)
let restMemory = SystemRules.memoryBreakdown([referenceApp], used: gib(8), lang: lang, locale: locale)
let restMemoryParent = restMemory.rows.last!
let memoryPS = ps.filter { $0.uid != 501 || $0.pid == 20 }
let memoryRows = SystemRules.restDetails(restMemoryParent, breakdown: restMemory, loads: [referenceApp], measured: [measuredApp], ps: memoryPS,
                                        metric: .memory, currentUID: 501, cores: 8, lang: lang)
expect("E12 RSS se reparte dentro de los bytes de la fila padre de Memoria",
       memoryRows.first(where: { $0.id == "otherAccount" })?.amount == 1_310_720
           && memoryRows.reduce(0) { $0 + $1.amount } == restMemoryParent.amount)

let fourParents = LoadDetailLayout(parentCount: 4, showsEstimate: true, listHeight: 150)
let occupiedHeight = LoadDetailLayout.expandedRowHeight + 3 * fourParents.siblingHeight + 4 * fourParents.spacing
    + fourParents.headerHeight + fourParents.capacity * LoadDetailLayout.detailRowHeight
expect("E13 cuatro filas con cabecera admiten tres subfilas completas",
       fourParents.capacity == 3 && fourParents.siblingHeight == 16
           && occupiedHeight <= 150
           && occupiedHeight + LoadDetailLayout.detailRowHeight > 150)
let fullToolParents = LoadDetailLayout(parentCount: 4, showsEstimate: false, listHeight: 150)
expect("E14 cuatro filas de lanzadores conservan sus barras cuando caben dos subfilas",
       fullToolParents.capacity == 2 && fullToolParents.siblingHeight == LoadDetailLayout.expandedRowHeight)

let limited = SystemRules.toolDetails(sixRow, loads: sixLaunchers, metric: .cpu, lang: lang, capacity: fourParents.capacity)
expect("E15 el subtotal ocupa un hueco entero y conserva el total",
       limited.count == 3 && limited.map(\.amount) == [6, 5, 10] && limited.last?.name == "y 4 más")

let fiveLaunchers = Array(sixLaunchers.prefix(5))
let fiveRow = SystemRules.cpuBreakdown(fiveLaunchers, total: 25, lang: lang).rows.first!
let namedFifth = SystemRules.toolDetails(fiveRow, loads: fiveLaunchers, metric: .cpu, lang: lang)
expect("E16 con cinco grupos y cinco huecos el último conserva su nombre y acción",
       namedFifth.count == 5 && namedFifth.last?.name == "L5" && namedFifth.last?.action != nil)
let threeLaunchers = Array(sixLaunchers.prefix(3))
let threeRow = SystemRules.cpuBreakdown(threeLaunchers, total: 25, lang: lang).rows.first!
let namedThird = SystemRules.toolDetails(threeRow, loads: threeLaunchers, metric: .cpu, lang: lang, capacity: fourParents.capacity)
expect("E17 con tres huecos el tercer grupo conserva su nombre", namedThird.map(\.name) == ["L1", "L2", "L3"])

let tinyLoads = [node(0.9, launcher: "Terminal", pid: 715), node(0.1, launcher: "Claude", pid: 716)]
let tinyRow = SystemRules.cpuBreakdown(tinyLoads, total: 1, lang: lang).rows.first!
let tinyDetails = SystemRules.toolDetails(tinyRow, loads: tinyLoads, metric: .cpu, lang: lang)
expect("E18 se ocultan lanzadores que redondean a 0%", tinyDetails.map(\.name) == ["Terminal"] && tinyDetails.map(\.amount) == [1])
let tinyRest = SystemRules.cpuBreakdown([], total: 1, lang: lang)
let tinyPS = SystemRules.parsePS("1 0 50 0 WindowServer\n2 0 1 0 mds\n3 0 0.01 0 desconocido", currentUID: 501)
let tinyRestDetails = SystemRules.restDetails(tinyRest.rows[0], breakdown: tinyRest, loads: [], measured: [],
                                             ps: tinyPS, metric: .cpu, currentUID: 501, cores: 1, lang: lang)
expect("E19 Spotlight a 0% se oculta y se conserva Otros a 0%",
       tinyRestDetails.map(\.name) == ["Pantalla y ventanas (macOS)", "Otros"] && tinyRestDetails.map(\.amount) == [1, 0])

let specialPS = SystemRules.parsePS("1 -2 2 1 nobody\n2 4294967294 3 1 nobody\n3 4294967040 4 1 system\n4 502 5 1 privado",
                                    currentUID: 501)
let specialBreakdown = SystemRules.cpuBreakdown([], total: 14, lang: lang)
let specialDetails = SystemRules.restDetails(specialBreakdown.rows[0], breakdown: specialBreakdown, loads: [], measured: [],
                                             ps: specialPS, metric: .cpu, currentUID: 501, cores: 1, lang: lang)
expect("E20 nobody firmado, sin signo y UID reservados se contabilizan fuera de otras cuentas",
       specialPS.map(\.uid) == [4_294_967_294, 4_294_967_294, 0xFF_FF_FF_00, 502]
           && specialDetails.map(\.name) == ["Otros", "Otra cuenta del Mac"] && specialDetails.map(\.amount) == [9, 5])

let hiddenClaude = app("Claude", 8, pid: 100)
let hiddenChrome = app("Google Chrome", 7, pid: 104)
let cliLoad = AppLoad(key: "Claude Code|Claude|100", name: "Claude Code",
                      kind: .tool(executable: "claude", launcher: "Claude", launcherPID: 100),
                      cpu: 5, memory: 0, count: 1, closable: false)
let unmappedCLI = AppLoad(key: "Codex|-", name: "Codex", kind: .tool(executable: "codex", launcher: nil, launcherPID: nil),
                           cpu: 3, memory: 0, count: 1, closable: false)
let appLoads = [app("A", 30), app("B", 20), app("C", 15), hiddenClaude, hiddenChrome, cliLoad, unmappedCLI]
let ownPS = SystemRules.parsePS("""
    100 501 2 0 /Applications/Claude.app/Contents/MacOS/Claude
    101 501 3 0 /Applications/Claude.app/Contents/Frameworks/Claude Helper (Renderer)
    102 501 5 0 /usr/local/bin/claude
    104 501 4 0 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome
    105 501 3 0 /Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Helper (GPU)
    106 501 3 0 /usr/local/bin/codex
    107 501 2 0 /usr/local/bin/unknown
    108   0 6 0 /System/Library/mds
    109 502 1 0 /Users/other/Claude
    """, currentUID: 501)
let measuredKeys: [Int32: String] = [
    100: hiddenClaude.key, 101: hiddenClaude.key, 102: cliLoad.key,
    104: hiddenChrome.key, 105: hiddenChrome.key, 106: unmappedCLI.key
]
let appSamples = ownPS.compactMap { process in
    measuredKeys[process.pid].map { MeasuredProcess(usage: process, loadKey: $0) }
} + [MeasuredProcess(usage: ProcessUsage(pid: 109, uid: 501, executable: "Claude", cpu: 0, memory: 0), loadKey: hiddenClaude.key)]
let appRest = SystemRules.cpuBreakdown(appLoads, total: 100, lang: lang, rowLimit: 4)
let appDetail = SystemRules.restDetails(appRest.rows.last!, breakdown: appRest, loads: appLoads, measured: appSamples,
                                        ps: ownPS, metric: .cpu, currentUID: 501, cores: 1, lang: lang)
expect("E21 ps une los helpers y CLI verificados bajo su app, y anonimiza los desconocidos",
       appDetail.map(\.name) == ["Otros", "Claude", "Google Chrome", "Spotlight indexando", "Otra cuenta del Mac"]
           && appDetail.map(\.amount) == [11, 10, 7, 6, 1])
let appDetailFallback = SystemRules.restDetails(appRest.rows.last!, breakdown: appRest, loads: appLoads, measured: appSamples,
                                                ps: nil, metric: .cpu, currentUID: 501, cores: 1, lang: lang)
expect("E22 sin ps se mantienen las apps agrupadas y no aparecen nombres de binarios",
       appDetailFallback.map(\.name) == ["Otros", "Claude", "Google Chrome"]
           && appDetailFallback.map(\.amount) == [18, 10, 7])

let rankedRest = SystemRules.cpuBreakdown([], total: 100, lang: lang)
let rankedPS = SystemRules.parsePS("1 0 45 0 WindowServer\n2 0 25 0 mds\n3 0 15 0 kernel_task\n4 0 10 0 backupd",
                                   currentUID: 501)
func rankedDetails(_ capacity: Int, ps: [ProcessUsage] = rankedPS) -> [LoadDetail] {
    SystemRules.restDetails(rankedRest.rows[0], breakdown: rankedRest, loads: [], measured: [],
                            ps: ps, metric: .cpu, currentUID: 501, cores: 1, lang: lang, capacity: capacity)
}
let threeSlots = rankedDetails(3)
let twoSlots = rankedDetails(2)
expect("E23 con dos o tres huecos se muestran los grupos más grandes y Otros va al subtotal",
       threeSlots.map(\.id) == ["windows", "spotlight", "more"] && threeSlots.map(\.amount) == [45, 25, 30]
           && threeSlots.last?.name == "y 3 más"
           && twoSlots.map(\.id) == ["windows", "more"] && twoSlots.map(\.amount) == [45, 55]
           && twoSlots.last?.name == "y 4 más")
let fourSlots = rankedDetails(4)
expect("E24 con cuatro huecos se conserva la fila Otros aunque sea pequeña",
       fourSlots.map(\.id) == ["windows", "spotlight", "other", "more"] && fourSlots.map(\.amount) == [45, 25, 5, 25])
let largestOtherPS = SystemRules.parsePS("1 0 20 0 WindowServer\n2 0 10 0 mds\n3 0 5 0 kernel_task\n4 0 5 0 backupd",
                                         currentUID: 501)
let largestOther = rankedDetails(3, ps: largestOtherPS)
expect("E25 un Otros grande conserva su posición entre los primeros grupos",
       largestOther.map(\.id) == ["other", "windows", "more"] && largestOther.map(\.amount) == [60, 20, 20])

// (screen allowance, message, maintenance) → (meter row height, list rows)
let card = SystemPanelLayout.cardHeight, note = SystemPanelLayout.noteHeight
let panelCases: [(max: Int, message: Int, maintenance: Bool, meter: Int, rows: Int)] = [
    (640, 0, false, 42, 6), (640, 0, true, 42, 6), (640, note, false, 42, 6), (640, note, true, 42, 6),
    (640, card, false, 42, 6), (640, card, true, 42, 6),
    (520, 0, false, 42, 6), (520, 0, true, 42, 5), (520, note, false, 42, 5), (520, note, true, 42, 4),
    (520, card, false, 38, 4), (520, card, true, 34, 3)
]
func chrome(_ layout: SystemPanelLayout, message: Int, maintenance: Bool) -> Int {
    // Padding, “More” row, header, list header, footer and gaps, plus the meters, message and maintenance line.
    165 + 3 * layout.meterRowHeight + (message == 0 ? 0 : message + 10) + (maintenance ? 24 : 0)
}
expect("L1 con 640 pt caben seis filas y medidores de 42 pt; con 520 pt bajan las filas y luego los medidores", panelCases.allSatisfy { sample in
    let layout = SystemPanelLayout(messageHeight: sample.message, hasMaintenance: sample.maintenance, maxHeight: sample.max)
    return layout.meterRowHeight == sample.meter && layout.rowLimit == sample.rows
        && layout.listHeight == SystemPanelLayout.height(forRows: sample.rows)
        && layout.expandedListHeight >= layout.listHeight
        && chrome(layout, message: sample.message, maintenance: sample.maintenance) + layout.expandedListHeight <= sample.max
}, "\(panelCases.map { SystemPanelLayout(messageHeight: $0.message, hasMaintenance: $0.maintenance, maxHeight: $0.max) }.map { ($0.meterRowHeight, $0.rowLimit) })")
expect("L2 cada estado expandido admite subfilas completas en Procesador y Memoria", panelCases.allSatisfy { sample in
    let panel = SystemPanelLayout(messageHeight: sample.message, hasMaintenance: sample.maintenance, maxHeight: sample.max)
    return (1...panel.rowLimit).allSatisfy { count in
        [true, false].allSatisfy { showsEstimate in
            let detail = LoadDetailLayout(parentCount: count, showsEstimate: showsEstimate,
                                          listHeight: panel.expandedListHeight)
            let parentHeight = LoadDetailLayout.expandedRowHeight + (count - 1) * detail.siblingHeight + count * detail.spacing
            let used = parentHeight + detail.headerHeight + detail.capacity * LoadDetailLayout.detailRowHeight
            return detail.capacity >= 2 && used <= panel.expandedListHeight
        }
    }
})
let tinyPanel = SystemPanelLayout(messageHeight: card, hasMaintenance: true, maxHeight: 440)
expect("L2b en pantallas muy bajas los medidores no bajan de 34 pt",
       tinyPanel.meterRowHeight == SystemPanelLayout.minMeterRowHeight && tinyPanel.rowLimit >= 1)

let enoughLoads = (1...8).map { app("App \($0)", Double(10 - $0), memory: Double(10 - $0) / 2) }
expect("L3 las filas de Procesador suman el total y reservan el último hueco para Sistema y otros", (4...7).allSatisfy { limit in
    let data = SystemRules.cpuBreakdown(enoughLoads, total: 70, lang: lang, rowLimit: limit)
    return data.rows.count == limit && data.rows.first?.name == "App 1" && data.rows.last?.isRest == true
        && data.rows.reduce(0) { $0 + $1.amount } == 70
})
expect("L4 Memoria aplica el mismo límite y sus bytes suman el total", (4...7).allSatisfy { limit in
    let data = SystemRules.memoryBreakdown(enoughLoads, used: gib(30), lang: lang, locale: locale, rowLimit: limit)
    return data.rows.count == limit && data.rows.first?.name == "App 1" && data.rows.last?.isRest == true
        && data.rows.reduce(0) { $0 + $1.amount } == Int(gib(30))
})
expect("L5 Memoria normaliza las huellas superpuestas al valor del medidor",
       shared.rows.reduce(0) { $0 + $1.amount } == Int(gib(4)))
let smallRestMemory = SystemRules.memoryBreakdown([app("A", 0, memory: 1)], used: gib(1) + 1_048_576,
                                                 lang: lang, locale: locale)
expect("L6 un resto pequeño de Memoria conserva la igualdad con el total",
       smallRestMemory.rows.last?.isRest == true && smallRestMemory.rows.last?.amount == 1_048_576)

let overlappingApps = (1...6).map { app("App \($0)", 0, memory: 2) }
let wideMemory = SystemRules.memoryBreakdown(overlappingApps, used: gib(8), lang: lang, locale: locale, rowLimit: 7)
let narrowMemory = SystemRules.memoryBreakdown(overlappingApps, used: gib(8), lang: lang, locale: locale, rowLimit: 5)
let retainedAppRows = Array(wideMemory.rows.prefix(4))
let omittedAppRows = wideMemory.rows.suffix(2)
expect("L7 cambiar el límite de filas conserva bytes y etiquetas de cada app",
       narrowMemory.rows.count == 5 && Array(narrowMemory.rows.prefix(4)) == retainedAppRows
           && narrowMemory.rows.last?.isRest == true
           && narrowMemory.rows.last?.amount == omittedAppRows.reduce(0) { $0 + $1.amount }
           && narrowMemory.rows.last?.value == "2,6 GB")

let fractionalApps = (1...4).map { app("App \($0)", 0, memory: 1.24) }
let roundedGB = SystemRules.memoryBreakdown(fractionalApps, used: gib(5), lang: lang, locale: locale)
let totalGBLabel = memoryText(gib(5), locale: locale)
expect("L8 las etiquetas de 1,24 GB se reparten en décimas y suman 5,0 GB",
       roundedGB.rows.map(\.value) == ["1,3 GB", "1,3 GB", "1,2 GB", "1,2 GB", "0,0 GB"]
           && roundedGB.rows.compactMap(\.memoryDisplay).reduce(0) { $0 + $1.count } == 50
           && totalGBLabel == "5,0 GB")

var smallApps = (1...3).map { app("App \($0)", 0) }
for index in smallApps.indices { smallApps[index].memory = 1_258_291 }
let roundedMB = SystemRules.memoryBreakdown(smallApps, used: 4_194_304, lang: lang, locale: locale)
expect("L9 con un medidor en MB todas las etiquetas suman su valor entero",
       roundedMB.rows.map(\.value) == ["1 MB", "1 MB", "1 MB", "1 MB"]
           && memoryText(4_194_304, locale: locale) == "4 MB"
           && roundedMB.rows.compactMap(\.memoryDisplay).reduce(0) { $0 + $1.count } == 4)

let memoryChildren = SystemRules.toolDetails(nodeMemory, loads: launcherLoads, metric: .memory, lang: lang)
expect("L10 las etiquetas de las subfilas de Memoria suman su fila padre",
       LoadMetric.memory.values(for: memoryChildren, parent: nodeMemory, locale: locale) == ["1,5 GB", "1,0 GB"]
           && nodeMemory.value == "2,5 GB")

let worstPanel = SystemPanelLayout(messageHeight: card, hasMaintenance: true)
let smallWorst = SystemPanelLayout(messageHeight: card, hasMaintenance: true, maxHeight: 520)
expect("L11 el peor caso cabe en 640 pt con seis filas y en 520 pt con tres y medidores de 34 pt",
       chrome(worstPanel, message: card, maintenance: true) + worstPanel.expandedListHeight <= 640 && worstPanel.rowLimit == 6
           && chrome(smallWorst, message: card, maintenance: true) + smallWorst.expandedListHeight <= 520
           && smallWorst.rowLimit == 3 && smallWorst.meterRowHeight == 34 && smallWorst.chrome == 165 + 3 * 34,
       "\(worstPanel) | \(smallWorst)")

// MARK: Tray metric

func levels(_ cpu: SystemLevel = .normal, _ memory: SystemLevel = .normal, _ heat: SystemLevel = .normal) -> MetricLevels {
    MetricLevels(cpu: cpu, memory: memory, heat: heat)
}
expect("T1 todo normal muestra la métrica elegida",
       SystemRules.dominant(levels(), preferred: .cpu) == .cpu && SystemRules.dominant(levels(), preferred: .memory) == .memory)
expect("T2 gana el nivel más alto",
       SystemRules.dominant(levels(.attention, .critical, .normal), preferred: .cpu) == .memory
           && SystemRules.dominant(levels(.critical, .attention, .attention), preferred: .memory) == .cpu
           && SystemRules.dominant(levels(.attention), preferred: .memory) == .cpu)
expect("T3 empates: calor, luego memoria, luego CPU",
       SystemRules.dominant(levels(.attention, .attention, .attention), preferred: .cpu) == .heat
           && SystemRules.dominant(levels(.critical, .critical, .normal), preferred: .cpu) == .memory
           && SystemRules.dominant(levels(.attention, .normal, .attention), preferred: .memory) == .heat)

var heatSnapshot = fine
heatSnapshot.thermal = .serious
var tightSnapshot = high
tightSnapshot.cpuNow = 8
expect("T4 los niveles salen de las reglas del panel",
       SystemRules.levels(heatSnapshot) == levels(.normal, .normal, .attention)
           && SystemRules.levels(tightSnapshot) == levels(.normal, .attention, .normal)
           && SystemRules.levels(criticalMemory).memory == .critical && SystemRules.levels(sustained).cpu == .attention)
expect("T5 el panel abre la pestaña de la métrica mostrada; calor abre Energía",
       SystemRules.panelMetric(for: .memory, levels()) == .memory && SystemRules.panelMetric(for: .cpu, levels(.normal, .critical)) == .cpu
           && SystemRules.panelMetric(for: .heat, levels(.normal, .attention, .attention)) == .energy
           && SystemRules.panelMetric(for: .heat, levels(.attention, .attention, .critical)) == .energy
           && SystemRules.panelMetric(for: .heat, levels(.normal, .normal, .attention)) == .energy
           && SystemRules.panelMetric(for: SystemRules.dominant(SystemRules.levels(heatSnapshot), preferred: .cpu),
                                      SystemRules.levels(heatSnapshot)) == .energy
           && SystemRules.panelMetric(for: SystemRules.dominant(SystemRules.levels(tightSnapshot), preferred: .cpu),
                                      SystemRules.levels(tightSnapshot)) == .memory)

var heldCPU = MetricHold()
_ = heldCPU.update(levels(.attention), preferred: .cpu, at: 0)
let heldTie = heldCPU.update(levels(.attention, .normal, .attention), preferred: .cpu, at: 10)
expect("T5b al abrir, el calor empatado abre Energía aunque la bandeja siga retenida en CPU",
       heldTie == .cpu && SystemRules.openingMetric(levels(.attention, .normal, .attention), preferred: .cpu) == .energy
           && SystemRules.openingMetric(levels(), preferred: .memory) == .memory
           && SystemRules.openingMetric(levels(.critical, .attention, .attention), preferred: .memory) == .cpu)

var heldMemory = MetricHold()
let h0 = heldMemory.update(levels(), preferred: .cpu, at: 0)
let h1 = heldMemory.update(levels(.normal, .attention), preferred: .cpu, at: 10)
let h2 = heldMemory.update(levels(), preferred: .cpu, at: 20)
let h3 = heldMemory.update(levels(), preferred: .cpu, at: 39.9)
let h4 = heldMemory.update(levels(), preferred: .cpu, at: 40)
expect("T6 la memoria se mantiene 30 s y luego vuelve a la elegida",
       [h0, h1, h2, h3, h4] == [.cpu, .memory, .memory, .memory, .cpu], "\([h0, h1, h2, h3, h4])")

var escalation = MetricHold()
let e0 = escalation.update(levels(.normal, .attention), preferred: .cpu, at: 0)
let e1 = escalation.update(levels(.normal, .attention, .critical), preferred: .cpu, at: 5)
let e2 = escalation.update(levels(.critical, .attention, .critical), preferred: .cpu, at: 6)
let e3 = escalation.update(levels(.normal, .critical, .attention), preferred: .cpu, at: 7)
expect("T7 un nivel estrictamente mayor cambia al instante; un empate espera",
       [e0, e1, e2, e3] == [.memory, .heat, .heat, .memory], "\([e0, e1, e2, e3])")

var tie = MetricHold()
let t0 = tie.update(levels(.normal, .attention), preferred: .cpu, at: 0)
let t1 = tie.update(levels(.normal, .attention, .attention), preferred: .cpu, at: 29)
let t2 = tie.update(levels(.normal, .attention, .attention), preferred: .cpu, at: 30)
expect("T8 un empate con más prioridad cambia al vencer el plazo",
       [t0, t1, t2] == [.memory, .memory, .heat], "\([t0, t1, t2])")

var choice = MetricHold()
let c0 = choice.update(levels(), preferred: .cpu, at: 0)
let c1 = choice.update(levels(), preferred: .memory, at: 1)
let c2 = choice.update(levels(.attention), preferred: .memory, at: 2)
let c3 = choice.update(levels(.attention), preferred: .cpu, at: 3)
let c4 = choice.update(levels(), preferred: .cpu, at: 4)
expect("T9 cambiar la preferencia aplica al instante si todo va bien",
       [c0, c1, c2, c3, c4] == [.cpu, .memory, .cpu, .cpu, .cpu], "\([c0, c1, c2, c3, c4])")

var traySnapshot = tightSnapshot
traySnapshot.memoryUsed = gib(12)
expect("T10 valores de la bandeja",
       SystemRules.trayValue(.cpu, traySnapshot, lang: lang) == "8%"
           && SystemRules.trayValue(.memory, traySnapshot, lang: lang) == "75%"
           && SystemRules.trayValue(.heat, heatSnapshot, lang: lang) == "Alta"
           && SystemRules.trayValue(.heat, heatSnapshot, lang: "en") == "Hot"
           && SystemRules.trayValue(.heat, fine, lang: lang) == "Normal")
var warmSnapshot = fine
warmSnapshot.thermal = .fair
expect("T10b temperatura elevada sigue en nivel normal y usa la misma palabra en panel y bandeja",
       SystemRules.levels(warmSnapshot).heat == .normal && SystemRules.heatWarm(warmSnapshot)
           && SystemRules.heatStatus(warmSnapshot, lang: lang) == "Elevada"
           && SystemRules.heatStatus(warmSnapshot, lang: "en") == "Warm"
           && SystemRules.trayValue(.heat, warmSnapshot, lang: lang) == "Elevada"
           && SystemRules.heatStatus(heatSnapshot, lang: lang) == "Alta" && SystemRules.heatStatus(fine, lang: "en") == "Normal"
           && SystemRules.message(warmSnapshot) == nil)
let tip = SystemRules.trayTooltip(tightSnapshot, pending: "macOS pendiente de actualizar", lang: lang)
var hotAndTight = tightSnapshot
hotAndTight.thermal = .critical
hotAndTight.criticalThermalMinutes = 3
let hotTip = SystemRules.trayTooltip(hotAndTight, pending: nil, lang: lang)
let calmTip = SystemRules.trayTooltip(fine, pending: nil, lang: "en")
expect("T11 el tooltip pone primero los problemas, luego la CPU y al final lo pendiente",
       tip == "Memoria justa · CPU 8% · macOS pendiente de actualizar"
           && hotTip == "Energía crítica · Memoria justa · CPU 8%" && calmTip == "CPU 21%",
       "\(tip) | \(hotTip) | \(calmTip)")

var criticalHeat = fine
criticalHeat.thermal = .critical
criticalHeat.criticalThermalMinutes = 119.0 / 60
expect("T12 antes de 120 s el calor crítico conserva el nivel y los textos de atención",
       SystemRules.levels(criticalHeat).heat == .attention
           && SystemRules.heatStatus(SystemRules.heatLevel(criticalHeat), lang: lang) == "Alta"
           && SystemRules.trayValue(.heat, criticalHeat, lang: lang) == "Alta"
           && SystemRules.trayValue(.heat, criticalHeat, lang: "en") == "Hot"
           && SystemRules.trayTooltip(criticalHeat, pending: nil, lang: lang) == "Energía alta · CPU 21%"
           && SystemRules.trayTooltip(criticalHeat, pending: nil, lang: "en") == "Energy: hot · CPU 21%")
criticalHeat.criticalThermalMinutes = 120.0 / 60
expect("T13 a los 120 s el calor pasa al nivel y a los textos críticos",
       SystemRules.levels(criticalHeat).heat == .critical
           && SystemRules.heatStatus(SystemRules.heatLevel(criticalHeat), lang: lang) == "Crítica"
           && SystemRules.trayValue(.heat, criticalHeat, lang: lang) == "Crítica"
           && SystemRules.trayValue(.heat, criticalHeat, lang: "en") == "Critical"
           && SystemRules.trayTooltip(criticalHeat, pending: nil, lang: lang) == "Energía crítica · CPU 21%"
           && SystemRules.trayTooltip(criticalHeat, pending: nil, lang: "en") == "Energy: critical · CPU 21%")

var heldHeat = MetricHold()
let firstHeat = heldHeat.update(levels(.normal, .normal, .attention), preferred: .cpu, at: 0)
let changedPreference = heldHeat.update(levels(), preferred: .memory, at: 1)
let beforeHeatHoldExpiry = heldHeat.update(levels(), preferred: .memory, at: 29.9)
let atHeatHoldExpiry = heldHeat.update(levels(), preferred: .memory, at: 30)
expect("T14 la nueva preferencia espera a que venza la retención del calor",
       [firstHeat, changedPreference, beforeHeatHoldExpiry, atHeatHoldExpiry] == [.heat, .heat, .heat, .memory])

print("\(passes) PASS, \(failures) FAIL")
exit(failures == 0 ? 0 : 1)

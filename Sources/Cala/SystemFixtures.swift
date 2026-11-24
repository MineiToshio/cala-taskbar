#if DEBUG
import AppKit
import SwiftUI

struct MeterFrameKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, newer in newer })
    }
}

struct SystemFooterYKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil

    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = nextValue() ?? value
    }
}

@MainActor
enum SystemFixtures {
    private static func gib(_ amount: Double) -> UInt64 { UInt64((amount * 1_073_741_824).rounded()) }

    private static func app(_ name: String, _ cpu: Double, pid: Int32, memory: Double, energy: Double? = nil) -> AppLoad {
        AppLoad(key: name, name: name, kind: .app(pid: pid), cpu: cpu, memory: gib(memory), count: 1, closable: true,
                energy: energy ?? cpu * 1.2)
    }

    private static func node(_ cpu: Double, launcher: String, pid: Int32, count: Int = 16) -> AppLoad {
        let group = SystemRules.classify(path: "/opt/homebrew/bin/node", executable: "node", apps: [], launcher: (launcher, pid))
        return AppLoad(key: group.key, name: group.name, kind: group.kind, cpu: cpu, memory: gib(1.4), count: count, closable: false)
    }

    private static func snapshot(cpu: Double, smoothed: Double, busy: Double = 0, loads: [AppLoad]) -> LoadSnapshot {
        LoadSnapshot(lastReading: ProcessReading(capturedAt: 100, cpuWindow: cpu, loads: loads), observedAt: 100,
                     cpuNow: cpu, cpuSmoothed: smoothed, busyMinutes: busy, hotMinutes: 0,
                     pressure: .normal, pressureMinutes: 0, memoryUsed: gib(9), memoryTotal: gib(16),
                     thermal: .nominal, lowPower: false)
    }

    private static let safari = app("Safari", 6, pid: 100, memory: 0.9)
    private static let mail = app("Mail", 2, pid: 101, memory: 0.3)
    private static let xcode = app("Xcode", 52, pid: 501, memory: 2)
    private static let chrome = app("Google Chrome", 4, pid: 900, memory: 3.2)
    private static let preview = app("Preview", 3, pid: 103, memory: 0.4)
    private static let terminalApp = app("Terminal", 2, pid: 700, memory: 0.2)
    private static let calendar = app("Calendar", 1, pid: 104, memory: 0.25)
    private static let notes = app("Notes", 1, pid: 105, memory: 0.35)

    private static func model(_ snapshot: LoadSnapshot, tab: Int? = nil,
                              maintenance: (text: String, strong: Bool, more: Int)? = nil) -> SystemPanelModel {
        let cpu = snapshot.cpuNow
        let memory = Double(snapshot.memoryUsed) / Double(snapshot.memoryTotal) * 100
        let history = (0..<60).map { i -> Double in
            let variation = Double((i * 13) % 7)
            if snapshot.busyMinutes > 2 { return i < 14 ? 25 + variation : cpu - variation }
            if snapshot.cpuSmoothed >= SystemRules.busyAt { return i < 53 ? 25 + variation : cpu - variation }
            return cpu - variation / 2
        }
        let memoryHistory = (0..<60).map { memory - Double(60 - $0) / 12 - Double($0 % 9) / 3 }
        let resources = [
            "Safari": "/Applications/Safari.app/Contents/Resources/AppIcon.icns",
            "Mail": "/System/Applications/Mail.app/Contents/Resources/ApplicationIcon.icns",
            "Xcode": "/Applications/Xcode.app/Contents/Resources/Xcode.icns",
            "Google Chrome": "/Applications/Google Chrome.app/Contents/Resources/app.icns",
            "Slack": "/Applications/Slack.app/Contents/Resources/electron.icns"
        ]
        var icons: [String: NSImage] = [:]
        for load in snapshot.displayedInventory?.loads ?? [] {
            if let path = resources[load.key] {
                icons[load.key] = NSImage(contentsOfFile: path)
            }
        }
        // A background history that ends on the total the Energía tab shows.
        let total = snapshot.reading.map { SystemRules.energyTotal($0, cores: 1) } ?? 10
        var energyHistory: [Double] = []
        for i in 0..<59 {
            let wobble = Double((i * 7) % 5) * 0.07
            energyHistory.append(total * (0.7 + wobble))
        }
        energyHistory.append(total)
        return SystemPanelModel(snapshot: snapshot, cpuHistory: history, memoryHistory: memoryHistory,
                                energyHistory: energyHistory, maintenance: maintenance, tab: tab ?? SystemPanelModel.initialTab(snapshot), icons: icons)
    }

    static let all: [(name: String, model: SystemPanelModel)] = {
        let fine = snapshot(cpu: 21, smoothed: 22, loads: [safari, mail, chrome, preview, terminalApp, calendar, notes])
        let spike = snapshot(cpu: 90, smoothed: 88, busy: 0.1, loads: [])
        let busyAWhile = snapshot(cpu: 90, smoothed: 88, busy: 0.5, loads: [])
        var lightSafari = safari
        lightSafari.cpu = 5
        let sustained = snapshot(cpu: 80, smoothed: 85, busy: 3.2,
                                 loads: [xcode, lightSafari, chrome, preview, mail, calendar])
        let terminal = snapshot(cpu: 85, smoothed: 90, busy: 4,
                                 loads: [node(60, launcher: "Terminal", pid: 700), lightSafari, chrome, preview, mail, notes])
        var critical = fine
        critical.pressure = .critical
        critical.pressureMinutes = 1.5
        critical.criticalPressureMinutes = 1.5
        critical.memoryUsed = gib(12.6)
        let claude = app("Claude", 0.4, pid: 697, memory: 0.5)
        let claudeCode = AppLoad(key: "Claude Code|Claude|697", name: "Claude Code",
                                 kind: .tool(executable: "claude", launcher: "Claude", launcherPID: 697),
                                 cpu: 0.3, memory: gib(0.2), count: 4, closable: false)
        let background = snapshot(cpu: 100, smoothed: 98, busy: 2.4,
                                  loads: [node(7, launcher: "Claude", pid: 697), claude, claudeCode])
        var worstCase = background
        lightSafari.cpu = 4
        worstCase.lastReading = ProcessReading(capturedAt: 100, cpuWindow: 100,
                                                loads: background.loads + [lightSafari, mail, preview, calendar])
        let maintenance = RestartRules.summary(
            RestartRules.evaluate(RestartInput(uptime: 21 * 86_400, ram: gib(16), pendingUpdate: "macOS")),
            lang: appLanguage
        )
        var measuring = fine
        measuring.lastReading = nil
        var measuringBusy = sustained
        measuringBusy.lastReading = nil
        var memory = fine
        var lightChrome = chrome
        lightChrome.memory = gib(3.1)
        memory.memoryUsed = gib(12.6)
        var idleXcode = xcode
        idleXcode.cpu = 0
        memory.lastReading = ProcessReading(capturedAt: 100, cpuWindow: 21, loads: [lightChrome, idleXcode, app("Slack", 0, pid: 102, memory: 0.9),
                                                               mail, preview, terminalApp, calendar, notes])

        let manyLaunchers = snapshot(cpu: 85, smoothed: 90, busy: 4, loads: [
            node(40, launcher: "Terminal", pid: 700, count: 12),
            node(20, launcher: "Claude", pid: 697, count: 5)
        ])
        var expandedNode = model(manyLaunchers)
        expandedNode.expandedKey = expandedNode.breakdown?.rows.first(where: \.isTool)?.key
        expandedNode.reservesExpandedHeight = true
        var expandedRest = model(background)
        expandedRest.expandedKey = "rest"
        expandedRest.reservesExpandedHeight = true
        expandedRest.currentUID = 501
        expandedRest.cores = 8
        expandedRest.restProbe = .available(SystemRules.parsePS(
            """
            11 0 224.0 240000 /System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer
            12 0 112.0 120000 kernel_task
            13 0 96.0 42000 /System/Library/Frameworks/CoreServices.framework/mds
            14 502 144.0 160000 /Users/demo/Private.app
            15 0 48.0 24000 /System/Library/CoreServices/backupd
            """, currentUID: 501))
        var expandedWorst = model(worstCase, maintenance: maintenance)
        expandedWorst.expandedKey = expandedRest.expandedKey
        expandedWorst.reservesExpandedHeight = true
        expandedWorst.currentUID = expandedRest.currentUID
        expandedWorst.cores = expandedRest.cores
        expandedWorst.restProbe = expandedRest.restProbe
        var foldedRest = expandedRest
        foldedRest.expandedKey = nil
        var quietExpansion = model(fine)
        quietExpansion.expandedKey = "rest"
        quietExpansion.reservesExpandedHeight = true
        var expiredExpansion = quietExpansion
        expiredExpansion.snapshot.observedAt += ProcessReading.cacheAge + 1
        var startup = model(measuring)
        startup.cpuHistory = []
        startup.memoryHistory = []
        startup.energyHistory = []
        var recent = terminal
        recent.cpuNow = 97
        recent.observedAt = 105
        recent.processSessionStartedAt = 105
        var late = recent
        late.observedAt = 160
        late.processSessionStartedAt = 160
        var recentExpanded = model(recent)
        recentExpanded.expandedKey = expandedNode.expandedKey
        recentExpanded.reservesExpandedHeight = true
        var hot = fine
        hot.thermal = .serious
        hot.lastReading = ProcessReading(capturedAt: 100, cpuWindow: 21, loads: [
            app("Google Chrome", 9, pid: 900, memory: 3.2, energy: 24.6), safari, mail, preview, terminalApp, calendar, notes
        ])
        var hotWorst = hot
        hotWorst.thermal = .critical
        hotWorst.criticalThermalMinutes = 3
        var expandedHot = model(hotWorst, maintenance: maintenance)
        expandedHot.expandedKey = "rest"
        expandedHot.reservesExpandedHeight = true
        // The memory card cleared while the panel stayed open.
        // A 520 pt screen allowance: rows drop first, then the meter rows shrink.
        func small(_ model: SystemPanelModel) -> SystemPanelModel {
            var model = model
            model.maxHeight = 520
            return model
        }
        var bigMemory = critical
        bigMemory.memoryTotal = gib(128)
        bigMemory.memoryUsed = gib(99.6)
        var recovered = model(fine, tab: 1)
        recovered.reservation = PanelReservation(messageHeight: SystemPanelLayout.cardHeight, hasMaintenance: false)
        var warm = fine
        warm.thermal = .fair
        var firstMemory = memory
        firstMemory.lastInventory = memory.reading?.inventory
        firstMemory.lastReading = nil
        return [
            ("todo-bien", model(fine)),
            ("pico-corto", model(spike)),
            ("ocupado-un-rato", model(busyAWhile)),
            ("sostenida-node", model(terminal)),
            ("sostenida-app", model(sustained)),
            ("memoria-alta", model(critical)),
            ("memoria-alta-cpu", model(critical, tab: 0)),
            ("no-atribuible", model(background)),
            ("con-mantenimiento", model(worstCase, maintenance: maintenance)),
            ("expandido-node", expandedNode),
            ("expandido-sistema", expandedRest),
            ("expandido-sistema-desde-mas", expandedWorst),
            ("plegado-sistema", foldedRest),
            ("expandido-sin-avisos", quietExpansion),
            ("expandido-caducado", expiredExpansion),
            ("midiendo", model(measuring)),
            ("midiendo-arranque", startup),
            ("midiendo-carga", model(measuringBusy)),
            ("reapertura-reciente", model(recent)),
            ("reapertura-reciente-desplegada", recentExpanded),
            ("reapertura-tardia", model(late)),
            ("memoria-primera-pasada", model(firstMemory, tab: 1)),
            ("lista-memoria", model(memory, tab: 1)),
            ("calor-energia", model(hot)),
            ("calor-critico-expandido", expandedHot),
            ("energia-elevada", model(warm)),
            ("recuperado", recovered),
            ("pantalla-pequena-normal", small(model(fine))),
            ("pantalla-pequena-peor", small(expandedWorst)),
            ("memoria-128-gb", model(bigMemory)),
            ("memoria-128-gb-pequena", small(model(bigMemory)))
        ]
    }()
    static let detail = SystemDetailsModel(cpuUser: 16, cpuSystem: 5, cores: 10, memoryUsed: gib(9),
                                          memoryTotal: gib(16), memoryApps: gib(5.3), memoryWired: gib(2.5),
                                          memoryCompressed: gib(1.2), swapUsed: gib(0.45), swapTotal: gib(1),
                                          pressure: .warning, pressureState: .tight, uptime: 2 * 86_400 + 3 * 3_600,
                                          unreadable: 196, otherAccounts: 24)

    static func restartSample(reasonCount: Int, denied: Bool) -> RestartPanelView {
        let input = RestartInput(uptime: 34 * 86_400, swapUsed: gib(6), swapTotal: gib(7), ram: gib(16),
                                 compressed: gib(6), pressure: .critical, pressureMinutes: 12,
                                 diskFreeFraction: 0.1, pendingUpdate: "macOS Tahoe", heaviestApp: ("Google Chrome", gib(3.2)))
        var advice = RestartRules.evaluate(input)
        precondition(advice.reasons.count == 6)
        if reasonCount < advice.reasons.count {
            advice.reasons = Array(advice.reasons.prefix(reasonCount))
            advice.fine = [calendarText("Disk space is fine", "Espacio en disco correcto")]
        }
        return RestartPanelView(advice: advice, uptime: input.uptime, heaviest: chrome,
                                message: denied ? RestartPane.restartError(denied: true) : "",
                                back: {}, later: {}, openSoftwareUpdate: {}, restart: {})
    }

}

@MainActor
enum SystemRender {
    private enum RenderError: Error {
        case bitmapUnavailable
        case invalidLayout(name: String, size: CGSize, meters: [String: CGRect])
        case invalidBreakdown(name: String, total: Int, values: [String])
        case staleAction(name: String)
        case footerMoved
    }

    private static var footerPositions: [String: CGFloat] = [:]

    static func run(dir: String) -> Never {
        do {
            let output = URL(fileURLWithPath: dir, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            for fixture in SystemFixtures.all {
                let model = fixture.model
                let view = SystemPanelView(model: model, onTab: { _ in }, onAction: { _ in }, openRestart: {}, openDetails: {})
                let visibleRows = model.breakdown?.rows.count ?? 0
                let loadingRows = model.showsCPUSkeleton ? model.layout.rowLimit : 0
                print("\(fixture.name) → \(visibleRows) filas, \(loadingRows) marcadores, límite \(model.layout.rowLimit)")
                if let cpuBreakdown = model.cpuBreakdown {
                    let cpu = cpuBreakdown.rows.map(\.value)
                    let numbers = cpu.compactMap { Int($0.dropLast()) }
                    guard numbers.count == cpu.count, numbers.reduce(0, +) == model.cpuValue else {
                        throw RenderError.invalidBreakdown(name: fixture.name, total: model.cpuValue, values: cpu)
                    }
                    let label = model.tab == 0 ? "CPU" : "CPU (muestra de la pestaña \(model.tab == 1 ? "Memoria" : "Energía"))"
                    print("\(label) \(fixture.name) → \(cpu.joined(separator: " + ")) = \(model.cpuValue)%")
                }
                if model.tab == 1, let breakdown = model.breakdown {
                    let unit = MemoryDisplayUnit(total: model.snapshot.memoryUsed)
                    let total = unit.roundedCount(forBytes: model.snapshot.memoryUsed)
                    let displayed = breakdown.rows.compactMap(\.memoryDisplay)
                    guard displayed.count == breakdown.rows.count, displayed.allSatisfy({ $0.unit == unit }),
                          displayed.reduce(0, { $0 + $1.count }) == total else {
                        throw RenderError.invalidBreakdown(name: fixture.name, total: total, values: breakdown.rows.map(\.value))
                    }
                    print("Memoria \(fixture.name) → \(breakdown.rows.map(\.value).joined(separator: " + ")) = \(memoryText(model.snapshot.memoryUsed))")
                }
                if let breakdown = model.breakdown,
                   let parent = breakdown.rows.first(where: { $0.key == model.expandedKey }) {
                    let children = model.detailRows(for: parent, in: breakdown)
                    if model.listAvailability == .remembered && children.contains(where: { $0.action != nil }) {
                        throw RenderError.staleAction(name: fixture.name)
                    }
                    let layout = model.detailLayout(for: parent, in: breakdown)
                    guard children.count <= layout.capacity, children.reduce(0, { $0 + $1.amount }) == parent.amount else {
                        throw RenderError.invalidBreakdown(name: fixture.name, total: parent.amount,
                                                           values: children.map { String($0.amount) })
                    }
                    print("Desglose \(fixture.name) → \(children.map { String($0.amount) }.joined(separator: " + ")) = \(parent.amount)")
                }
                if fixture.name == "expandido-sistema-desde-mas" {
                    let light = try png(withMore(view), name: fixture.name, dark: false, in: output, layout: model.layout)
                    try light.write(to: output.appendingPathComponent("\(fixture.name).png"), options: .atomic)
                    try png(withMore(view), name: fixture.name, dark: true, in: output, layout: model.layout)
                } else {
                    let light = try png(view, name: fixture.name, dark: false, in: output, layout: model.layout)
                    if fixture.name != "lista-memoria" {
                        try light.write(to: output.appendingPathComponent("\(fixture.name).png"), options: .atomic)
                    }
                    try png(view, name: fixture.name, dark: true, in: output, layout: model.layout)
                }
                if fixture.name == "con-mantenimiento" {
                    try png(withMore(view), name: "con-mantenimiento-desde-mas", dark: false, in: output, layout: model.layout)
                    try png(withMore(view), name: "con-mantenimiento-desde-mas", dark: true, in: output, layout: model.layout)
                }
            }
            guard let expandedFooter = footerPositions["expandido-sin-avisos-light"],
                  let expiredFooter = footerPositions["expandido-caducado-light"],
                  abs(expandedFooter - expiredFooter) < 0.01 else { throw RenderError.footerMoved }
            print("Pie al desplegar y caducar → \(expandedFooter) pt en ambos")
            try checkStableFooter(["todo-bien", "midiendo", "midiendo-arranque", "memoria-primera-pasada"])
            try checkStableFooter(["sostenida-node", "midiendo-carga", "reapertura-reciente", "reapertura-tardia"])
            try checkStableFooter(["memoria-alta", "recuperado"])

            let detail = SystemDetailsView(model: SystemFixtures.detail, back: {}, openActivityMonitor: {})
            let detailRowCount = SystemFixtures.detail.sections.reduce(0) { $0 + $1.rows.count }
            print("detalle → \(detailRowCount) filas en \(SystemFixtures.detail.sections.count) secciones")
            let detailLight = try png(detail, name: "detalle", dark: false, in: output, hasMeters: false)
            try detailLight.write(to: output.appendingPathComponent("detalle.png"), options: .atomic)
            try png(detail, name: "detalle", dark: true, in: output, hasMeters: false)
            try png(withMore(detail), name: "detalle-desde-mas", dark: false, in: output, hasMeters: false)
            let restartFixtures = [
                ("reinicio-6-motivos", 6, false),
                ("reinicio-error-permiso", 6, true),
                ("reinicio-revision", 3, false)
            ]
            for (name, reasonCount, denied) in restartFixtures {
                let restart = SystemFixtures.restartSample(reasonCount: reasonCount, denied: denied)
                let image = try png(restart, name: name, dark: false, in: output, hasMeters: false)
                try image.write(to: output.appendingPathComponent("\(name).png"), options: .atomic)
                try png(restart, name: name, dark: true, in: output, hasMeters: false)
                try png(withMore(restart), name: "\(name)-desde-mas", dark: false, in: output, hasMeters: false)
            }
            exit(0)
        } catch {
            fputs("System render failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func checkStableFooter(_ names: [String]) throws {
        let positions = names.compactMap { footerPositions["\($0)-light"] }
        guard positions.count == names.count, let first = positions.first,
              positions.allSatisfy({ abs($0 - first) < 0.01 }) else { throw RenderError.footerMoved }
        print("Pie estable en \(names.joined(separator: ", ")) → \(first) pt")
    }

    private static func withMore<V: View>(_ view: V) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {} label: {
                Label(calendarText("More", "Más"), systemImage: "chevron.left")
                    .font(.system(size: 11.5, weight: .medium))
            }.buttonStyle(.plain).flyoutSecondary()
            view
        }
    }

    @discardableResult
    private static func png<V: View>(_ view: V, name: String, dark: Bool, in directory: URL, layout: SystemPanelLayout? = nil,
                                     hasMeters: Bool = true) throws -> Data {
        var meters: [String: CGRect] = [:]
        var footerY: CGFloat?
        let width = CGFloat(SystemPanelLayout.width)
        let root = view.padding(18).frame(width: width).flyoutControls().themedPanel(theme: .named("system")).fixedSize()
            .environment(\.colorScheme, dark ? .dark : .light)
            .coordinateSpace(name: "system-render")
            .onPreferenceChange(MeterFrameKey.self) { meters = $0 }
            .onPreferenceChange(SystemFooterYKey.self) { footerY = $0 }
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: width, height: 700),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        let size = host.fittingSize
        window.setContentSize(size)
        host.frame = NSRect(origin: .zero, size: size)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        let frames = meters.values.sorted { $0.minY < $1.minY }
        let rowHeight = CGFloat(layout?.meterRowHeight ?? SystemPanelLayout.meterRowHeight)
        let expected = CGSize(width: MeterRow.width, height: rowHeight)
        let metersMatch = frames.count == 3 && frames.allSatisfy { $0.size == expected && $0.minX == frames[0].minX }
            && frames[1].minY == frames[0].maxY && frames[2].minY == frames[1].maxY
        let limit = CGFloat(layout?.maxHeight ?? SystemPanelLayout.maxHeight)
        guard size.width == width, size.height <= limit, !hasMeters || metersMatch else {
            throw RenderError.invalidLayout(name: name, size: size, meters: meters)
        }
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw RenderError.bitmapUnavailable }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw RenderError.bitmapUnavailable }
        let style = dark ? "dark" : "light"
        if let footerY { footerPositions["\(name)-\(style)"] = footerY }
        try data.write(to: directory.appendingPathComponent("\(name)-\(style).png"), options: .atomic)
        let metersNote = hasMeters ? ", medidores 3 filas de \(Int(MeterRow.width))×\(Int(rowHeight)) pt, límite \(Int(limit)) pt" : ""
        print("\(name)-\(style) → \(Int(size.width))×\(Int(size.height.rounded(.up))) pt\(metersNote)")
        return data
    }
}
#endif

#if DEBUG
import AppKit
import SwiftUI

struct MeterFrameKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, newer in newer })
    }
}

@MainActor
enum SystemFixtures {
    private static func gib(_ amount: Double) -> UInt64 { UInt64((amount * 1_073_741_824).rounded()) }

    private static func app(_ name: String, _ cpu: Double, pid: Int32, memory: Double) -> AppLoad {
        AppLoad(key: name, name: name, kind: .app(pid: pid), cpu: cpu, memory: gib(memory), count: 1, closable: true)
    }

    private static func node(_ cpu: Double, launcher: String, pid: Int32) -> AppLoad {
        let group = SystemRules.classify(path: "/opt/homebrew/bin/node", executable: "node", apps: [], launcher: (launcher, pid))
        return AppLoad(key: group.key, name: group.name, kind: group.kind, cpu: cpu, memory: gib(1.4), count: 16, closable: false)
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
    private static let chrome = app("Google Chrome", 0, pid: 900, memory: 3.2)

    private static func model(_ snapshot: LoadSnapshot, tab: Int? = nil,
                              maintenance: (text: String, strong: Bool, more: Int)? = nil) -> SystemPanelModel {
        let cpu = snapshot.cpuWindow ?? snapshot.cpuNow
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
        for load in snapshot.loads {
            if let path = resources[load.key] {
                icons[load.key] = NSImage(contentsOfFile: path)
            }
        }
        return SystemPanelModel(snapshot: snapshot, cpuHistory: history, memoryHistory: memoryHistory,
                                maintenance: maintenance, tab: tab ?? SystemPanelModel.initialTab(snapshot), icons: icons)
    }

    static let all: [(name: String, model: SystemPanelModel)] = {
        let fine = snapshot(cpu: 21, smoothed: 22, loads: [safari, mail])
        let spike = snapshot(cpu: 90, smoothed: 88, busy: 0.5, loads: [])
        var lightSafari = safari
        lightSafari.cpu = 5
        let sustained = snapshot(cpu: 80, smoothed: 85, busy: 3.2, loads: [xcode, lightSafari])
        let terminal = snapshot(cpu: 85, smoothed: 90, busy: 4, loads: [node(60, launcher: "Terminal", pid: 700)])
        var critical = snapshot(cpu: 21, smoothed: 22, loads: [chrome, safari, mail])
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
        worstCase.lastReading = ProcessReading(capturedAt: 100, cpuWindow: 100, loads: background.loads + [lightSafari, mail])
        let maintenance = RestartRules.summary(
            RestartRules.evaluate(RestartInput(uptime: 21 * 86_400, ram: gib(16), pendingUpdate: "macOS")),
            lang: Locale.preferredLanguages.first
        )
        var measuring = fine
        measuring.lastReading = nil
        var memory = fine
        var lightChrome = chrome
        lightChrome.memory = gib(3.1)
        memory.memoryUsed = gib(12.6)
        var idleXcode = xcode
        idleXcode.cpu = 0
        memory.lastReading = ProcessReading(capturedAt: 100, cpuWindow: 21, loads: [lightChrome, idleXcode, app("Slack", 0, pid: 102, memory: 0.9), mail])

        return [
            ("todo-bien", model(fine)),
            ("pico-corto", model(spike)),
            ("sostenida-node", model(terminal)),
            ("sostenida-app", model(sustained)),
            ("memoria-alta", model(critical)),
            ("memoria-alta-cpu", model(critical, tab: 0)),
            ("no-atribuible", model(background)),
            ("con-mantenimiento", model(worstCase, maintenance: maintenance)),
            ("midiendo", model(measuring)),
            ("lista-memoria", model(memory, tab: 1))
        ]
    }()
}

@MainActor
enum SystemRender {
    private enum RenderError: Error {
        case bitmapUnavailable
        case invalidLayout(name: String, size: CGSize, meters: [String: CGRect])
        case invalidBreakdown(name: String, total: Int, values: [String])
    }

    static func run(dir: String) -> Never {
        do {
            let output = URL(fileURLWithPath: dir, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            for fixture in SystemFixtures.all {
                let view = SystemPanelView(model: fixture.model, reservation: .constant(PanelReservation()),
                                           onTab: { _ in }, onAction: { _ in }, openRestart: {}, openDetails: {})
                let model = fixture.model
                if fixture.name != "midiendo" {
                    let cpu = model.cpuBreakdown?.rows.map(\.value) ?? []
                    let numbers = cpu.compactMap { Int($0.dropLast()) }
                    guard model.snapshot.reading != nil, numbers.count == cpu.count, numbers.reduce(0, +) == model.cpuValue else {
                        throw RenderError.invalidBreakdown(name: fixture.name, total: model.cpuValue, values: cpu)
                    }
                    let label = model.tab == 0 ? "CPU" : "CPU (muestra de la pestaña Memoria)"
                    print("\(label) \(fixture.name) → \(cpu.joined(separator: " + ")) = \(model.cpuValue)%")
                }
                let light = try png(view, name: fixture.name, dark: false, in: output)
                if fixture.name != "midiendo", fixture.name != "lista-memoria" {
                    try light.write(to: output.appendingPathComponent("\(fixture.name).png"), options: .atomic)
                }
                try png(view, name: fixture.name, dark: true, in: output)
                if fixture.name == "con-mantenimiento" {
                    let overflow = VStack(alignment: .leading, spacing: 8) {
                        Button {} label: {
                            Label(calendarText("More", "Más"), systemImage: "chevron.left")
                                .font(.system(size: 11.5, weight: .medium))
                        }.buttonStyle(.plain).flyoutSecondary()
                        view
                    }
                    try png(overflow, name: "con-mantenimiento-desde-mas", dark: false, in: output)
                    try png(overflow, name: "con-mantenimiento-desde-mas", dark: true, in: output)
                }
            }
            exit(0)
        } catch {
            fputs("System render failed: \(error)\n", stderr)
            exit(1)
        }
    }

    @discardableResult
    private static func png<V: View>(_ view: V, name: String, dark: Bool, in directory: URL) throws -> Data {
        var meters: [String: CGRect] = [:]
        let root = view.padding(18).frame(width: 380).flyoutControls().themedPanel(theme: .named("system")).fixedSize()
            .environment(\.colorScheme, dark ? .dark : .light)
            .coordinateSpace(name: "system-render")
            .onPreferenceChange(MeterFrameKey.self) { meters = $0 }
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 380, height: 600),
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
        let frames = meters.values.sorted { $0.minX < $1.minX }
        let expected = CGSize(width: MeterTile.width, height: MeterTile.height)
        guard size.width == 380, size.height <= 520, frames.count == 2,
              frames[0].size == expected, frames[1].size == expected,
              frames[0].minY == frames[1].minY, frames[1].minX - frames[0].maxX == 12 else {
            throw RenderError.invalidLayout(name: name, size: size, meters: meters)
        }
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw RenderError.bitmapUnavailable }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw RenderError.bitmapUnavailable }
        let style = dark ? "dark" : "light"
        try data.write(to: directory.appendingPathComponent("\(name)-\(style).png"), options: .atomic)
        print("\(name)-\(style) → \(Int(size.width))×\(Int(size.height.rounded(.up))) pt, medidores 166×68 pt")
        return data
    }
}
#endif

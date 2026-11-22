import SwiftUI

struct SystemDetailsPane: View {
    @ObservedObject var monitor: SystemMonitor
    let uptime: TimeInterval
    let back: () -> Void

    var body: some View {
        let snapshot = monitor.snapshot()
        let reading = snapshot.reading
        SystemDetailsView(
            model: SystemDetailsModel(cpuUser: monitor.cpuUser, cpuSystem: monitor.cpuSystem,
                                      cores: ProcessInfo.processInfo.activeProcessorCount,
                                      memoryUsed: monitor.memoryUsed, memoryTotal: monitor.memoryTotal,
                                      memoryApps: monitor.memoryApps, memoryWired: monitor.memoryWired,
                                      memoryCompressed: monitor.memoryCompressed, swapUsed: monitor.swapUsed,
                                      swapTotal: monitor.swapTotal, pressure: snapshot.pressure,
                                      pressureState: SystemRules.memoryState(snapshot), uptime: uptime,
                                      unreadable: reading?.unreadable, otherAccounts: reading?.otherAccounts),
            back: back, openActivityMonitor: SystemAdvice.openActivityMonitor
        )
    }
}

struct SystemDetailsModel {
    struct Row {
        let label: String
        let icon: String
        let value: String?
        var showsPressure = false
    }

    struct Section {
        let title: String
        let icon: String
        let rows: [Row]
        var note: String? = nil
    }

    let cpuUser: Double
    let cpuSystem: Double
    let cores: Int
    let memoryUsed: UInt64
    let memoryTotal: UInt64
    let memoryApps: UInt64
    let memoryWired: UInt64
    let memoryCompressed: UInt64
    let swapUsed: UInt64
    let swapTotal: UInt64
    let pressure: MemoryPressure
    let pressureState: MeterState
    let uptime: TimeInterval
    let unreadable: Int?
    let otherAccounts: Int?

    var sections: [Section] {
        [
            Section(title: calendarText("Processor", "Procesador"), icon: "cpu", rows: [
                Row(label: calendarText("Apps and tasks", "Apps y tareas"), icon: "square.grid.2x2",
                    value: "\(Int(cpuUser.rounded()))%"),
                Row(label: "macOS", icon: "gearshape", value: "\(Int(cpuSystem.rounded()))%"),
                Row(label: calendarText("Capacity", "Capacidad"), icon: "square.stack.3d.up",
                    value: calendarText("\(cores) cores", "\(cores) núcleos"))
            ]),
            Section(title: calendarText("Memory", "Memoria"), icon: "memorychip", rows: [
                Row(label: calendarText("In use", "En uso"), icon: "chart.bar",
                    value: calendarText("\(memoryText(memoryUsed)) of \(memoryText(memoryTotal))",
                                        "\(memoryText(memoryUsed)) de \(memoryText(memoryTotal))")),
                Row(label: calendarText("Apps", "Apps"), icon: "square.grid.2x2", value: memoryText(memoryApps)),
                Row(label: calendarText("Reserved by the system", "Reservada por el sistema"), icon: "gearshape",
                    value: memoryText(memoryWired)),
                Row(label: calendarText("Compressed", "Comprimida"), icon: "arrow.down.right.and.arrow.up.left",
                    value: memoryText(memoryCompressed)),
                Row(label: calendarText("Pressure", "Presión"), icon: "gauge.with.dots.needle.67percent",
                    value: SystemRules.memoryStatus(pressure, state: pressureState), showsPressure: true),
                Row(label: calendarText("Memory on disk", "Memoria en disco"), icon: "internaldrive",
                    value: calendarText("\(memoryText(swapUsed)) of \(memoryText(swapTotal))",
                                        "\(memoryText(swapUsed)) de \(memoryText(swapTotal))"))
            ], note: calendarText("The Mac uses the disk when it runs short of memory.",
                                  "El Mac usa el disco cuando se queda corto de memoria.")),
            Section(title: calendarText("Mac activity", "Actividad del Mac"), icon: "waveform.path", rows: [
                Row(label: calendarText("Time on", "Tiempo encendido"), icon: "clock", value: RestartRules.uptimeText(uptime)),
                Row(label: calendarText("Unmeasured", "Sin medir"), icon: "eye.slash", value: unreadable.map(processCount)),
                Row(label: calendarText("Other accounts", "Otras cuentas"), icon: "person.2", value: otherAccounts.map(processCount))
            ], note: calendarText("“System and others” includes background tasks and usage Cala can’t measure.",
                                  "«Sistema y otros» incluye tareas de fondo y consumo que Cala no puede medir."))
        ]
    }

    private func processCount(_ count: Int) -> String {
        calendarText(count == 1 ? "1 process" : "\(count) processes", count == 1 ? "1 proceso" : "\(count) procesos")
    }
}

struct SystemDetailsView: View {
    let model: SystemDetailsModel
    let back: () -> Void
    let openActivityMonitor: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(action: back) {
                    Label(calendarText("System", "Sistema"), systemImage: "chevron.left")
                        .font(.system(size: 11.5, weight: .medium))
                }.buttonStyle(.plain).flyoutSecondary()
                Spacer()
                Text(calendarText("Details", "Detalles")).font(.system(size: 14, weight: .semibold))
            }
            .frame(height: 20)

            ForEach(model.sections, id: \.title) { section in
                sectionView(section)
            }

            Button(action: openActivityMonitor) {
                Label(calendarText("Activity Monitor", "Monitor de Actividad"), systemImage: "gauge.with.dots.needle.67percent")
            }
            .buttonStyle(.plain)
            .font(.system(size: 11.5))
            .flyoutSecondary()
            .frame(height: 18)
        }
    }

    private func sectionView(_ section: SystemDetailsModel.Section) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(section.title, systemImage: section.icon)
                .font(.system(size: 12.5, weight: .semibold))
                .frame(height: 15)

            VStack(spacing: 0) {
                ForEach(section.rows, id: \.label) { row in
                    HStack(spacing: 6) {
                        Image(systemName: row.icon)
                            .frame(width: 14)
                            .accessibilityHidden(true)
                        Text(row.label).lineLimit(1)
                        Spacer(minLength: 4)
                        Group {
                            if let value = row.value {
                                HStack(spacing: 4) {
                                    if row.showsPressure {
                                        MeterStatusIndicator(state: model.pressureState, strained: model.pressure != .normal)
                                    }
                                    Text(value).monospacedDigit().fontWeight(.medium).foregroundStyle(.primary)
                                        .lineLimit(1)
                                }
                            } else {
                                SystemLoadingPulse {
                                    SystemSkeletonMark().frame(width: 66, height: 10)
                                }
                                .accessibilityLabel(calendarText("Loading", "Cargando"))
                            }
                        }
                        .frame(width: 138, alignment: .trailing)
                    }
                    .font(.system(size: 11.5))
                    .flyoutSecondary()
                    .frame(height: 18)
                    .accessibilityElement(children: .combine)
                }
            }

            if let note = section.note {
                Text(note).font(.system(size: 11)).flyoutSecondary()
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .flyoutSection()
    }
}

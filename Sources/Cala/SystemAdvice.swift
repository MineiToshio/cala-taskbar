import SwiftUI
import AppKit

/// Plain-language guidance for the CPU and memory sections of the system panel: say what is going on, whether it is
/// worth worrying about, which app is behind it and what the person can do. Alarm colors are reserved for situations
/// that last; a short spike is only an informational note.
struct LoadAdvice {
    enum Tone { case info, warn, critical }
    let tone: Tone
    let text: String
    /// What is using it, when known ("Lo está usando sobre todo Chrome…") or a note that it is still being measured.
    var culprit: String?
    /// App that can be quit politely to relieve the load.
    var quitName: String?
    var quitDetail: String?
}

enum SystemAdvice {
    private static func minutes(_ m: Double) -> String { m < 1 ? calendarText("a minute", "un minuto") : calendarText("\(Int(m)) min", "\(Int(m)) min") }

    /// Apps that must never be offered for closing.
    private static let protected: Set<String> = ["Finder", "Cala", "WindowServer", "Dock", "loginwindow", "SystemUIServer"]

    static func quittable(_ name: String) -> NSRunningApplication? {
        guard !protected.contains(name) else { return nil }
        return NSWorkspace.shared.runningApplications.first { $0.activationPolicy == .regular && $0.localizedName == name }
    }

    static func cpu(smoothed: Double, busyMinutes: Double, top: ProcessGroup?, sampled: Bool, cores: Int,
                    closable: (String) -> Bool = { quittable($0) != nil }) -> LoadAdvice? {
        guard smoothed >= 75 else { return nil }
        let long = busyMinutes >= 2
        var culprit: String?
        var quit: String?
        if let top {
            let used = max(1, Int((top.cpu / 100).rounded()))
            culprit = calendarText("It is mostly \(top.name) (about \(used) of your \(cores) cores).",
                                   "Lo está usando sobre todo \(top.name) (unos \(used) de tus \(cores) núcleos).")
            if closable(top.name) { quit = top.name }
        } else if !sampled {
            culprit = calendarText("Checking what is using it…", "Midiendo qué lo está usando…")
        } else {
            culprit = calendarText("No single app stands out: it is the sum of several.", "Ninguna app destaca sola: es la suma de varias.")
        }
        if long {
            let help = quit != nil
                ? calendarText("If you do not need that app right now, closing it lets the Mac breathe.", "Si no necesitas esa app ahora, ciérrala para que el Mac respire.")
                : calendarText("It may be a long task (compiling, exporting, indexing). If you do not recognize it, open Activity Monitor.", "Puede ser una tarea larga (compilar, exportar, indexar). Si no la reconoces, abre el Monitor de Actividad.")
            return LoadAdvice(tone: .warn,
                              text: calendarText("The processor has been busy for \(minutes(busyMinutes)). \(help)", "El procesador lleva \(minutes(busyMinutes)) muy ocupado. \(help)"),
                              culprit: culprit, quitName: quit, quitDetail: nil)
        }
        return LoadAdvice(tone: .info,
                          text: calendarText("Working hard right now. This is normal in short bursts and usually settles in a minute or two. Nothing to do.",
                                             "Trabajando a tope en este momento. Es normal en picos cortos y suele bajar solo en uno o dos minutos. No hace falta hacer nada."),
                          culprit: culprit, quitName: nil, quitDetail: nil)
    }

    static func memory(pressure: MemoryPressure, top: ProcessGroup?,
                       closable: (String) -> Bool = { quittable($0) != nil }) -> LoadAdvice? {
        guard pressure != .normal else { return nil }
        var culprit: String?
        var quit: String?
        var detail: String?
        if let top {
            culprit = calendarText("The app using the most is \(top.name) (\(diskBytes(Int64(top.memory)))).", "La app que más usa es \(top.name) (\(diskBytes(Int64(top.memory)))).")
            if closable(top.name) { quit = top.name; detail = diskBytes(Int64(top.memory)) }
        }
        return LoadAdvice(tone: pressure == .critical ? .critical : .warn,
                          text: calendarText("Your Mac is running low on free memory and is leaning on the disk, which makes it slower. Closing apps you are not using helps.",
                                             "A tu Mac le queda poca memoria libre y está apoyándose en el disco, por eso puede ir más lento. Cerrar apps que no usas ayuda."),
                          culprit: culprit, quitName: quit, quitDetail: detail)
    }

    /// Thermal and Low Power Mode notes, shown under the CPU section.
    static func note(thermal: ProcessInfo.ThermalState, lowPower: Bool) -> LoadAdvice? {
        if thermal == .serious || thermal == .critical {
            return LoadAdvice(tone: thermal == .critical ? .critical : .warn,
                              text: calendarText("The Mac is hot and slows itself down to cool off. Keep its vents uncovered and close heavy apps.",
                                                 "El Mac está caliente y se frena solo para enfriarse. Deja libres las rejillas y cierra las apps pesadas."))
        }
        if lowPower {
            return LoadAdvice(tone: .info, text: calendarText("Low Power Mode is on: the Mac will feel a bit slower on purpose.", "El modo de bajo consumo está activo: el Mac irá algo más lento a propósito."))
        }
        return nil
    }

    /// Asks before quitting, then asks the app to quit (it will offer to save anything unsaved).
    static func confirmQuit(_ name: String, detail: String?) {
        guard let app = quittable(name) else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = calendarText("Close \(name)?", "¿Cerrar \(name)?")
        alert.informativeText = calendarText("If it has unsaved changes it will ask you before closing.", "Si tiene cambios sin guardar, te preguntará antes de cerrarse.")
            + (detail.map { calendarText(" It frees about \($0).", " Libera unos \($0).") } ?? "")
        alert.addButton(withTitle: calendarText("Cancel", "Cancelar"))
        alert.addButton(withTitle: calendarText("Close \(name)", "Cerrar \(name)"))
        if alert.runModal() == .alertSecondButtonReturn { app.terminate() }
    }
}

struct AdviceCard: View {
    let advice: LoadAdvice
    var seeAction: (() -> Void)?
    private var color: Color {
        switch advice.tone { case .info: return .secondary; case .warn: return .orange; case .critical: return .red }
    }
    private var icon: String {
        switch advice.tone { case .info: return "info.circle"; case .warn: return "exclamationmark.circle"; case .critical: return "exclamationmark.triangle.fill" }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: icon).font(.system(size: 13)).foregroundStyle(color).padding(.top, 1)
                VStack(alignment: .leading, spacing: 4) {
                    Text(advice.text).font(.system(size: 11.5)).fixedSize(horizontal: false, vertical: true)
                    if let culprit = advice.culprit { Text(culprit).font(.system(size: 11.5, weight: .medium)).fixedSize(horizontal: false, vertical: true) }
                }
            }
            if advice.quitName != nil || seeAction != nil {
                HStack(spacing: 8) {
                    if let name = advice.quitName {
                        Button(calendarText("Close \(name)", "Cerrar \(name)")) { SystemAdvice.confirmQuit(name, detail: advice.quitDetail) }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                    }
                    if let seeAction {
                        Button(calendarText("See what is using it", "Ver qué lo usa"), action: seeAction).buttonStyle(.bordered).controlSize(.small)
                    }
                }
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(color.opacity(advice.tone == .info ? 0.08 : 0.12)))
    }
}

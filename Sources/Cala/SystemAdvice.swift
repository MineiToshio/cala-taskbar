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
        let quit = top.flatMap { closable($0.name) ? $0.name : nil }
        if busyMinutes >= 2 {
            let who = top.map { calendarText(" because of \($0.name)", " por \($0.name)") } ?? ""
            let help = quit != nil
                ? calendarText("If you do not need it, close it.", "Si no la necesitas, ciérrala.")
                : (top != nil ? calendarText("It may be a long task. If you do not recognize it, open Activity Monitor.", "Puede ser una tarea larga. Si no la reconoces, abre el Monitor de Actividad.") : "")
            return LoadAdvice(tone: .warn,
                              text: calendarText("Busy for \(minutes(busyMinutes))\(who). \(help)", "Lleva \(minutes(busyMinutes)) muy ocupado\(who). \(help)"),
                              culprit: nil, quitName: quit, quitDetail: nil)
        }
        let who = top.map { calendarText(" Mostly \($0.name).", " Sobre todo \($0.name).") } ?? (sampled ? "" : calendarText(" Checking what it is…", " Viendo qué es…"))
        return LoadAdvice(tone: .info,
                          text: calendarText("Working hard right now. This is normal and usually settles on its own.\(who)", "Trabajando mucho ahora. Es normal y suele bajar solo.\(who)"),
                          culprit: nil, quitName: nil, quitDetail: nil)
    }

    static func memory(pressure: MemoryPressure, top: ProcessGroup?,
                       closable: (String) -> Bool = { quittable($0) != nil }) -> LoadAdvice? {
        guard pressure != .normal else { return nil }
        var quit: String?
        var detail: String?
        var who = ""
        if let top {
            who = calendarText(" The one using the most: \(top.name) (\(diskBytes(Int64(top.memory)))).", " La que más usa: \(top.name) (\(diskBytes(Int64(top.memory)))).")
            if closable(top.name) { quit = top.name; detail = diskBytes(Int64(top.memory)) }
        }
        return LoadAdvice(tone: pressure == .critical ? .critical : .warn,
                          text: calendarText("Little free memory: the Mac is slower. Close apps you do not use.\(who)", "Poca memoria libre: el Mac va más lento. Cierra las apps que no uses.\(who)"),
                          culprit: nil, quitName: quit, quitDetail: detail)
    }

    /// Thermal and Low Power Mode notes, shown under the CPU section.
    static func note(thermal: ProcessInfo.ThermalState, lowPower: Bool) -> LoadAdvice? {
        if thermal == .serious || thermal == .critical {
            return LoadAdvice(tone: thermal == .critical ? .critical : .warn,
                              text: calendarText("The Mac is hot and is slowing itself down. Keep its vents clear.", "El Mac está caliente y se frena solo. Deja libres las rejillas."))
        }
        if lowPower {
            return LoadAdvice(tone: .info, text: calendarText("Low Power Mode is on: the Mac is a bit slower on purpose.", "Modo de bajo consumo: el Mac va algo más lento a propósito."))
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
            if let name = advice.quitName {
                Button(calendarText("Close \(name)", "Cerrar \(name)")) { SystemAdvice.confirmQuit(name, detail: advice.quitDetail) }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(color.opacity(advice.tone == .info ? 0.08 : 0.12)))
    }
}

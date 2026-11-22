import SwiftUI
import AppKit
import Darwin

// MARK: - Rules (pure, so they can be tested with sample numbers)

struct RestartInput {
    var uptime: TimeInterval
    var swapUsed: UInt64 = 0
    var swapTotal: UInt64 = 0
    var ram: UInt64
    var compressed: UInt64 = 0
    var pressure: MemoryPressure = .normal
    /// Minutes the memory pressure has been above normal without a break.
    var pressureMinutes: Double = 0
    var diskFreeFraction: Double?
    /// Name of a macOS update that is waiting and needs a restart, e.g. "macOS Tahoe 26.7.3".
    var pendingUpdate: String?
    var heaviestApp: (name: String, bytes: UInt64)?
}

struct RestartReason: Identifiable {
    enum Action { case closeApp(name: String, bytes: UInt64), openSoftwareUpdate }
    let id: String
    let symbol: String
    let title: String
    let detail: String
    let strong: Bool
    var action: Action?
}

struct RestartAdvice {
    var reasons: [RestartReason] = []
    /// What was checked and is fine, shown so the advice does not look like a generic alarm.
    var fine: [String] = []
    var strong: Bool { reasons.contains { $0.strong } }
}

enum RestartRules {
    private static let day: TimeInterval = 86_400
    private static let gb: UInt64 = 1_073_741_824

    static func uptimeText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds)), d = total / 86400, h = (total % 86400) / 3600, m = (total % 3600) / 60
        if d > 0 { return "\(d) d \(h) h" }
        return h > 0 ? "\(h) h \(m) min" : "\(m) min"
    }
    private static func bytes(_ n: UInt64) -> String { n == 0 ? "0 GB" : diskBytes(Int64(n)) }

    static func evaluate(_ i: RestartInput) -> RestartAdvice {
        var advice = RestartAdvice()
        let days = i.uptime / day

        // 1. A macOS update is waiting. Restarting alone does not install it, so the action is the Software Update pane.
        if let update = i.pendingUpdate {
            advice.reasons.append(RestartReason(
                id: "update", symbol: "arrow.down.app.fill",
                title: calendarText("A macOS update is waiting", "Hay una actualización de macOS esperando"),
                detail: calendarText("\(update) needs a restart to install. Restarting by itself does not install it: open Software Update.",
                                     "\(update) necesita reiniciar para instalarse. Reiniciar solo no la instala: ábrela en Actualización de software."),
                strong: true, action: .openSoftwareUpdate))
        } else {
            advice.fine.append(calendarText("No macOS update is waiting", "No hay actualizaciones de macOS pendientes"))
        }

        // 2. Many days without restarting.
        if days >= 14 {
            advice.reasons.append(RestartReason(
                id: "uptime", symbol: "clock.badge.exclamationmark",
                title: calendarText("Your Mac has been on for \(Int(days)) days", "Tu Mac lleva \(Int(days)) días encendido"),
                detail: calendarText("A restart now and then clears processes and memory that pile up over time. Most guides suggest every one to four weeks.",
                                     "Reiniciar de vez en cuando limpia procesos y memoria que se acumulan con el tiempo. Casi todas las guías sugieren hacerlo cada una a cuatro semanas."),
                strong: days >= 30))
        } else {
            advice.fine.append(calendarText("On for \(uptimeText(i.uptime))", "Encendido hace \(uptimeText(i.uptime))"))
        }

        // 3. A lot of swap (memory parked on disk).
        let swapLimit = max(4 * gb, i.ram / 4)
        if i.swapUsed >= swapLimit && days >= 3 {
            var r = RestartReason(
                id: "swap", symbol: "internaldrive.fill",
                title: calendarText("\(bytes(i.swapUsed)) of your disk are being used as memory", "Estás usando \(bytes(i.swapUsed)) de tu disco como memoria"),
                detail: calendarText("When RAM runs short, macOS parks idle data on disk (swap). It is released when apps quit, but part of it can stay until you restart.",
                                     "Cuando la RAM no alcanza, macOS guarda datos inactivos en el disco (swap). Se libera al cerrar apps, pero una parte puede quedarse hasta que reinicies."),
                strong: i.pressure != .normal)
            if let app = i.heaviestApp { r.action = .closeApp(name: app.name, bytes: app.bytes) }
            advice.reasons.append(r)
        } else {
            advice.fine.append(calendarText("Swap: \(bytes(i.swapUsed))", "Swap: \(bytes(i.swapUsed))"))
        }

        // 4. Compressed memory piling up.
        if i.ram > 0 && Double(i.compressed) / Double(i.ram) >= 0.35 && days >= 3 {
            advice.reasons.append(RestartReason(
                id: "compressed", symbol: "rectangle.compress.vertical",
                title: calendarText("\(bytes(i.compressed)) of memory are compressed", "Hay \(bytes(i.compressed)) de memoria comprimida"),
                detail: calendarText("macOS compresses memory before using the disk. A very high amount after several days usually means apps have been holding on to memory.",
                                     "macOS comprime la memoria antes de usar el disco. Una cantidad muy alta tras varios días suele significar que las apps se han ido quedando con memoria."),
                strong: false))
        }

        // 5. Memory pressure that does not go away.
        if i.pressure != .normal && i.pressureMinutes >= 10 {
            var r = RestartReason(
                id: "pressure", symbol: "gauge.with.dots.needle.100percent",
                title: calendarText("Memory has been under pressure for \(Int(i.pressureMinutes)) min", "La memoria lleva \(Int(i.pressureMinutes)) min bajo presión"),
                detail: calendarText("Your Mac has been struggling to find memory for a while. Closing the heaviest app can help; if it does not, restart.",
                                     "Tu Mac lleva un rato con dificultades para encontrar memoria. Cerrar la app más pesada puede ayudar; si no, reinicia."),
                strong: true)
            if let app = i.heaviestApp { r.action = .closeApp(name: app.name, bytes: app.bytes) }
            advice.reasons.append(r)
        } else if i.pressure != .normal {
            advice.fine.append(calendarText("Memory pressure: \(i.pressure.title.lowercased()) for \(Int(i.pressureMinutes)) min (not yet sustained)",
                                            "Presión de memoria: \(i.pressure.title.lowercased()) desde hace \(Int(i.pressureMinutes)) min (aún no es sostenida)"))
        } else {
            advice.fine.append(calendarText("Memory pressure: normal", "Presión de memoria: normal"))
        }

        // 6. Tight disk with a big swap: restarting gives space back.
        if let free = i.diskFreeFraction, free < 0.15, i.swapTotal >= 4 * gb {
            advice.reasons.append(RestartReason(
                id: "disk", symbol: "externaldrive.badge.exclamationmark",
                title: calendarText("Little disk space left and a large swap", "Poco espacio en disco y un swap grande"),
                detail: calendarText("Only \(Int((free * 100).rounded()))% of your disk is free and the swap files take \(bytes(i.swapTotal)). Restarting gives that space back.",
                                     "Solo te queda \(Int((free * 100).rounded()))% de disco libre y los archivos de swap ocupan \(bytes(i.swapTotal)). Reiniciar te devuelve ese espacio."),
                strong: false))
        } else if let free = i.diskFreeFraction {
            advice.fine.append(calendarText("Disk: \(Int((free * 100).rounded()))% free", "Disco: \(Int((free * 100).rounded()))% libre"))
        }
        return advice
    }
}

// MARK: - Advisor (state and system data)

final class RestartAdvisor: ObservableObject {
    static let shared = RestartAdvisor()
    @Published private(set) var advice = RestartAdvice()
    @Published private(set) var uptime: TimeInterval = 0
    @Published private(set) var snoozedUntil: Date?
    private var pressureSince: Date?
    private var pendingCache: (date: Date, name: String?)?
    private let snoozeKey = "restartSnoozeUntil"

    init() {
        let t = UserDefaults.standard.double(forKey: snoozeKey)
        snoozedUntil = t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    /// Shown only when at least one reason applies and the user has not postponed it (a critical memory pressure
    /// overrides the postponement).
    var visible: Bool {
        guard ConfigStore.shared.config.restartAdvice, !advice.reasons.isEmpty else { return false }
        if let until = snoozedUntil, until > Date(), SystemMonitor.shared.pressure != .critical { return false }
        return true
    }
    var strongVisible: Bool { visible && advice.strong }

    static func bootDate() -> Date {
        var tv = timeval(), size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 else { return Date() }
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec))
    }

    /// A macOS update that is waiting and requires a restart, read from the system's own record (no network, no scan).
    static func pendingUpdate() -> String? {
        guard let plist = NSDictionary(contentsOfFile: "/Library/Preferences/com.apple.SoftwareUpdate.plist"),
              let list = plist["RecommendedUpdates"] as? [[String: Any]] else { return nil }
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let current = "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        for update in list {
            let restart = (update["MobileSoftwareUpdate"] as? Bool) ?? ((update["MobileSoftwareUpdate"] as? Int) == 1)
            guard restart, let version = update["Display Version"] as? String,
                  version.compare(current, options: .numeric) == .orderedDescending else { continue }
            let name = (update["Display Name"] as? String ?? "macOS \(version)")
                .replacingOccurrences(of: "\u{00a0}", with: " ").split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
            return name
        }
        return nil
    }

    /// Call every few seconds (it only reads cheap counters; the update record is re-read every 10 minutes).
    func refresh(disk: DiskInfo?) {
        let m = SystemMonitor.shared
        uptime = Date().timeIntervalSince(Self.bootDate())
        if m.pressure == .normal { pressureSince = nil } else if pressureSince == nil { pressureSince = Date() }
        if pendingCache == nil || Date().timeIntervalSince(pendingCache!.date) > 600 { pendingCache = (Date(), Self.pendingUpdate()) }
        let skip: Set<String> = ["Finder", "Cala", "WindowServer"]
        let heaviest = m.topMemory.first { !skip.contains($0.name) }.map { (name: $0.name, bytes: $0.memory) }
        let input = RestartInput(uptime: uptime, swapUsed: m.swapUsed, swapTotal: m.swapTotal, ram: m.memoryTotal, compressed: m.memoryCompressed,
                                 pressure: m.pressure, pressureMinutes: pressureSince.map { Date().timeIntervalSince($0) / 60 } ?? 0,
                                 diskFreeFraction: disk?.freeFraction, pendingUpdate: pendingCache?.name, heaviestApp: heaviest)
        let new = RestartRules.evaluate(input)
        if new.reasons.map(\.id) != advice.reasons.map(\.id) || new.fine != advice.fine || new.reasons.map(\.title) != advice.reasons.map(\.title) { advice = new }
    }

    func snooze(days: Int = 3) {
        let until = Date().addingTimeInterval(Double(days) * 86_400)
        UserDefaults.standard.set(until.timeIntervalSince1970, forKey: snoozeKey)
        snoozedUntil = until
    }

    // MARK: Actions

    /// Asks Finder to restart (the same permission used for the Trash). Finder then shows its usual confirmation.
    static func restart(done: @escaping (Bool, Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            NSAppleScript(source: "tell application \"Finder\" to restart")?.executeAndReturnError(&error)
            let code = (error?[NSAppleScript.errorNumber] as? NSNumber)?.intValue
            DispatchQueue.main.async { done(code == nil, code == -1743) }
        }
    }

    static func confirmRestart() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = calendarText("Restart your Mac now?", "¿Reiniciar tu Mac ahora?")
        alert.informativeText = calendarText("All apps will be asked to quit. Save your work first.", "Se pedirá a todas las apps que se cierren. Guarda tu trabajo antes.")
        alert.addButton(withTitle: calendarText("Cancel", "Cancelar"))
        alert.addButton(withTitle: calendarText("Restart", "Reiniciar")).hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }
}

// MARK: - UI

struct RestartBanner: View {
    @ObservedObject private var advisor = RestartAdvisor.shared
    let open: () -> Void
    var body: some View {
        if advisor.visible {
            let n = advisor.advice.reasons.count
            Button(action: open) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise.circle.fill").font(.system(size: 15))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(calendarText("We recommend restarting", "Recomendamos reiniciar")).font(.system(size: 12.5, weight: .semibold))
                        Text(calendarText("\(n) reason\(n == 1 ? "" : "s")", "\(n) motivo\(n == 1 ? "" : "s")")).font(.system(size: 11)).opacity(0.85)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(advisor.advice.strong ? Color.orange : Color.yellow)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 9).fill((advisor.advice.strong ? Color.orange : Color.yellow).opacity(0.14)))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke((advisor.advice.strong ? Color.orange : Color.yellow).opacity(0.35), lineWidth: 0.5))
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
    }
}

struct RestartPane: View {
    @ObservedObject private var advisor = RestartAdvisor.shared
    let back: () -> Void
    @State private var showFine = false
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: back) {
                Label(calendarText("System", "Sistema"), systemImage: "chevron.left").font(.system(size: 11.5, weight: .medium))
            }.buttonStyle(.plain).flyoutSecondary()
            VStack(alignment: .leading, spacing: 3) {
                Text(calendarText("Why restarting helps", "Por qué conviene reiniciar")).font(.system(size: 17, weight: .semibold))
                Text(calendarText("Your Mac has been on for \(RestartRules.uptimeText(advisor.uptime)). These are the reasons:", "Tu Mac lleva \(RestartRules.uptimeText(advisor.uptime)) encendido. Estos son los motivos:"))
                    .font(.system(size: 12)).flyoutSecondary()
            }
            ForEach(advisor.advice.reasons) { reason in card(reason) }
            DisclosureGroup(isExpanded: $showFine) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(advisor.advice.fine, id: \.self) { line in
                        Label(line, systemImage: "checkmark.circle.fill").font(.system(size: 11.5)).foregroundStyle(Color.green)
                            .labelStyle(.titleAndIcon)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
            } label: {
                Text(calendarText("Checked and fine", "Revisado y está bien")).font(.system(size: 12, weight: .medium))
            }
            Divider()
            if !message.isEmpty { Text(message).font(.system(size: 11.5)).foregroundStyle(Color.orange).fixedSize(horizontal: false, vertical: true) }
            let onlyUpdate = advisor.advice.reasons.allSatisfy { $0.id == "update" }
            HStack {
                Button(calendarText("Later", "Más tarde")) { advisor.snooze(); back() }
                Spacer()
                if advisor.advice.reasons.contains(where: { $0.id == "update" }) {
                    if onlyUpdate {
                        Button(calendarText("Open Software Update", "Abrir Actualización de software")) { openSoftwareUpdate() }.buttonStyle(.borderedProminent)
                    } else {
                        Button(calendarText("Open Software Update", "Abrir Actualización de software")) { openSoftwareUpdate() }.buttonStyle(.bordered)
                    }
                }
                if !onlyUpdate {
                    Button(calendarText("Restart now…", "Reiniciar ahora…")) { restart() }.buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private func card(_ r: RestartReason) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: r.symbol).font(.system(size: 15)).foregroundStyle(r.strong ? Color.orange : Color.yellow).frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(r.title).font(.system(size: 12.5, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                Text(r.detail).font(.system(size: 11.5)).flyoutSecondary().fixedSize(horizontal: false, vertical: true)
                switch r.action {
                case .closeApp(let name, let bytes):
                    Text(calendarText("Closing \(name) would free about \(diskBytes(Int64(bytes))).", "Cerrar \(name) liberaría unos \(diskBytes(Int64(bytes))).")).font(.system(size: 11.5, weight: .medium))
                case .openSoftwareUpdate, .none: EmptyView()
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.06)))
    }

    private func openSoftwareUpdate() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension")!)
    }

    private func restart() {
        guard RestartAdvisor.confirmRestart() else { return }
        RestartAdvisor.restart { ok, denied in
            if !ok { message = denied ? calendarText("Cala needs permission to control Finder to restart. Allow it in System Settings → Privacy & Security → Automation.", "Cala necesita permiso para controlar Finder y poder reiniciar. Actívalo en Ajustes del Sistema → Privacidad y seguridad → Automatización.") : calendarText("Could not restart.", "No se pudo reiniciar.") }
        }
    }
}

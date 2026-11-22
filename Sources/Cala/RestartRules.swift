import Foundation

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
    var amount: Int?
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
                strong: days >= 30, amount: Int(days)))
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
                strong: true, amount: Int(i.pressureMinutes))
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

extension RestartReason {
    func short(lang: String?) -> String {
        let amount = amount ?? 0
        switch id {
        case "update": return calendarText("macOS update waiting", "actualización de macOS pendiente", preferredLanguage: lang)
        case "uptime": return calendarText("on for \(amount) days", "\(amount) días encendido", preferredLanguage: lang)
        case "swap": return calendarText("lots of memory parked on disk", "mucha memoria guardada en disco", preferredLanguage: lang)
        case "compressed": return calendarText("lots of compressed memory", "mucha memoria comprimida", preferredLanguage: lang)
        case "pressure": return calendarText("memory tight for \(amount) min", "memoria justa hace \(amount) min", preferredLanguage: lang)
        case "disk": return calendarText("low disk and large swap", "poco disco y swap grande", preferredLanguage: lang)
        default: return title
        }
    }
}

extension RestartRules {
    static func summary(_ a: RestartAdvice, lang: String?) -> (text: String, strong: Bool, more: Int)? {
        let priority = ["update", "longUptime", "swap", "disk", "compressed", "pressure", "uptime"]
        func rank(_ reason: RestartReason) -> Int {
            let key = reason.id == "uptime" && reason.strong ? "longUptime" : reason.id
            return priority.firstIndex(of: key) ?? priority.count
        }
        guard let reason = a.reasons.min(by: { rank($0) < rank($1) }) else { return nil }
        return (reason.short(lang: lang), a.strong, a.reasons.count - 1)
    }
}

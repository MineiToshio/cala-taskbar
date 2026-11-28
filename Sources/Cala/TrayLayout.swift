import Foundation


extension TrayPlace {
    var title: String {
        switch self {
        case .bar: return tx("In the bar", "En la barra")
        case .more: return tx("In More ⌃", "En Más ⌃")
        case .hidden: return tx("Hidden", "Oculto")
        }
    }
}

struct TrayItemInfo {
    let id: String
    fileprivate let englishTitle: String
    fileprivate var spanishTitle: String? = nil
    var title: String { tx(englishTitle, spanishTitle ?? englishTitle) }
    let symbol: String
    let defaultPlace: TrayPlace
}

enum TrayItems {
    static let usage = TrayItemInfo(id: trayUsage, englishTitle: "Claude & Codex", spanishTitle: "Claude y Codex",
                                    symbol: "chart.bar.fill", defaultPlace: .bar)

    /// Default left-to-right order.
    static let all: [TrayItemInfo] = [
        TrayItemInfo(id: trayKB, englishTitle: "Keyboard", spanishTitle: "Teclado", symbol: "keyboard", defaultPlace: .more),
        TrayItemInfo(id: trayWifi, englishTitle: "Wi-Fi", symbol: "wifi", defaultPlace: .bar),
        TrayItemInfo(id: trayBT, englishTitle: "Bluetooth", symbol: "dot.radiowaves.right", defaultPlace: .more),
        TrayItemInfo(id: trayBright, englishTitle: "Brightness", spanishTitle: "Brillo", symbol: "sun.max.fill", defaultPlace: .more),
        TrayItemInfo(id: trayVol, englishTitle: "Volume", spanishTitle: "Volumen", symbol: "speaker.wave.2.fill", defaultPlace: .bar),
        usage,
        TrayItemInfo(id: traySystem, englishTitle: "CPU and memory", spanishTitle: "CPU y memoria", symbol: "cpu", defaultPlace: .bar),
        TrayItemInfo(id: trayDisk, englishTitle: "Disk", spanishTitle: "Disco", symbol: "internaldrive", defaultPlace: .bar),
        TrayItemInfo(id: trayMail, englishTitle: "Mail", spanishTitle: "Correo", symbol: "envelope", defaultPlace: .bar),
        TrayItemInfo(id: trayBatt, englishTitle: "Battery", spanishTitle: "Batería", symbol: "battery.75", defaultPlace: .bar),
        TrayItemInfo(id: trayUser, englishTitle: "User", spanishTitle: "Usuario", symbol: "person.crop.circle", defaultPlace: .more),
        TrayItemInfo(id: trayDownloads, englishTitle: "Downloads", spanishTitle: "Descargas", symbol: "arrow.down.circle", defaultPlace: .more),
        TrayItemInfo(id: trayTrash, englishTitle: "Trash", spanishTitle: "Papelera", symbol: "trash", defaultPlace: .more),
    ]
    static func info(_ id: String) -> TrayItemInfo? { all.first { $0.id == id } }
}

extension Config {
    func place(_ id: String) -> TrayPlace {
        if let raw = trayLayout[id], let p = TrayPlace(rawValue: raw) { return p }
        // Settings from before the layout existed: the old on/off switches still apply.
        if id == trayDisk && !diskEnabled { return .hidden }
        if id == traySystem && !monitorEnabled { return .hidden }
        return TrayItems.info(id)?.defaultPlace ?? .hidden
    }

    /// Saved order first (known ids only), then anything new in its default position.
    var orderedTrayIDs: [String] {
        let known = Set(TrayItems.all.map(\.id))
        var seen = Set<String>()
        var out = trayOrder.filter { known.contains($0) && seen.insert($0).inserted }
        for item in TrayItems.all where !seen.contains(item.id) {
            // Insert after the item that precedes it by default, so a new item does not jump to the end.
            if let i = TrayItems.all.firstIndex(where: { $0.id == item.id }), i > 0,
               let at = out.firstIndex(of: TrayItems.all[i - 1].id) { out.insert(item.id, at: at + 1) } else { out.append(item.id) }
            seen.insert(item.id)
        }
        return out
    }
    var barTrayIDs: [String] { orderedTrayIDs.filter { place($0) == .bar } }
    var moreTrayIDs: [String] { orderedTrayIDs.filter { place($0) == .more } }
}

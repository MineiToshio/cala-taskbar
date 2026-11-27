import SwiftUI
import AppKit

extension Notification.Name {
    /// Posted when a flyout pane changed height after loading data, so the panel can resize itself.
    static let flyoutRefit = Notification.Name("local.cala.flyoutRefit")
}

extension TaskbarModel {
    /// Whether a tray item has anything to show on this Mac right now.
    func trayAvailable(_ id: String) -> Bool {
        switch id {
        case trayKB: return !kbCode.isEmpty
        case trayBright: return hasBright
        case trayDisk: return disk != nil
        case trayBatt: return batt != nil
        case trayUsage: return usage.contains(where: \.available)
        default: return true
        }
    }
}

extension TaskbarModel {
    var wifiSymbol: String { !wifiOn ? "wifi.slash" : (wifiConnected ? "wifi" : "wifi.exclamationmark") }
    var volumeSymbol: String {
        if muted || volume == 0 { return "speaker.slash.fill" }
        return volume < 0.34 ? "speaker.wave.1.fill" : (volume < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill")
    }
    static func batterySymbol(_ b: (pct: Int, charging: Bool, isCharging: Bool)) -> String {
        if b.charging { return "battery.100.bolt" }   // on AC power (charging or full)
        switch b.pct { case ..<13: return "battery.0"; case ..<38: return "battery.25"
        case ..<63: return "battery.50"; case ..<88: return "battery.75"; default: return "battery.100" }
    }
}

/// The icon of a tray item, drawn exactly as on the bar. The bar, the "^" panel and Settings → Bandeja all use it, so
/// they can never disagree. With a model it follows the live state (Wi-Fi signal, mute, charge...).
struct TrayGlyph: View {
    let id: String
    var model: TaskbarModel?

    // A plain model reference is not observed: SwiftUI would keep the first drawing (e.g. the generic user icon
    // when the photo loads a moment later). With a model, an observing wrapper redraws on every change.
    var body: some View {
        if let model { LiveTrayGlyph(id: id, model: model) } else { trayGlyphContent(id: id, model: nil) }
    }
}

private struct LiveTrayGlyph: View {
    let id: String
    @ObservedObject var model: TaskbarModel
    var body: some View { trayGlyphContent(id: id, model: model) }
}

@ViewBuilder
private func trayGlyphContent(id: String, model: TaskbarModel?) -> some View {
        switch id {
        case trayKB:
            if let code = model?.kbCode, !code.isEmpty { Text(code).font(.system(size: 11)) }
            else { Image(systemName: "keyboard").font(.system(size: 14)) }
        case trayWifi:
            if let m = model, m.wifiOn, m.wifiConnected { Image(systemName: "wifi", variableValue: m.wifiSignal).font(.system(size: 14)) }
            else { Image(systemName: model?.wifiSymbol ?? "wifi").font(.system(size: 14)) }
        case trayBT:
            BluetoothShape().stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                .frame(width: 10, height: 15).opacity((model?.btOn ?? true) ? 1 : 0.4)
        case trayBright:
            Image(systemName: "sun.max.fill").font(.system(size: 14))
        case trayVol:
            Image(systemName: model?.volumeSymbol ?? "speaker.wave.2.fill").font(.system(size: 14))
        case trayUsage:
            // Two services, one glyph: both marks side by side.
            HStack(spacing: 3) {
                ProviderMark(provider: .claude).frame(width: 13, height: 13)
                ProviderMark(provider: .codex).frame(width: 13, height: 13)
            }
        case traySystem:
            Image(systemName: "cpu").font(.system(size: 14))
        case trayDisk:
            Image(systemName: "internaldrive").font(.system(size: 14))
        case trayBatt:
            Image(systemName: model?.batt.map(TaskbarModel.batterySymbol) ?? "battery.100").font(.system(size: 14))
        case trayUser:
            if let photo = model?.userPhoto { Image(nsImage: photo).resizable().scaledToFill().frame(width: 20, height: 20).clipShape(Circle()) }
            else { Image(systemName: "person.crop.circle").font(.system(size: 14)) }
        case trayDownloads:
            Image(systemName: "arrow.down.circle").font(.system(size: 14))
        case trayTrash:
            Image(systemName: "trash").font(.system(size: 14))
        case trayMore:
            Image(systemName: "chevron.up").font(.system(size: 14))
        default:
            EmptyView()
        }
}

// MARK: - "^" overflow panel

struct MorePane: View {
    @ObservedObject var fm: FlyoutModel
    @ObservedObject var model: TaskbarModel
    @ObservedObject private var store = ConfigStore.shared
    @State private var hover: String?

    var body: some View {
        let ids = store.config.moreTrayIDs.filter { model.trayAvailable($0) }
        VStack(alignment: .leading, spacing: 12) {
            Header(title: tx("More", "Más"))
            if ids.isEmpty {
                Text(tx("Nothing here. Choose what to show in Settings → Tray.", "No hay nada aquí. Elige qué mostrar en Configuración → Bandeja.")).font(.system(size: 12)).flyoutSecondary()
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    ForEach(ids, id: \.self) { id in
                        if let info = TrayItems.info(id) {
                            Button {
                                fm.fromMore = true; fm.kind = id; fm.token += 1
                            } label: {
                                VStack(spacing: 6) {
                                    TrayGlyph(id: id, model: model).scaleEffect(1.3).frame(height: 26)
                                    Text(info.title).font(.system(size: 11)).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity).frame(height: 66)
                                .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(hover == id ? 0.12 : 0.06)))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .onHover { hover = $0 ? id : (hover == id ? nil : hover) }
                            .reportFrame(id, in: "flyout")
                        }
                    }
                }
            }
            Divider()
            Row(icon: "slider.horizontal.3", title: tx("Choose what to show…", "Elegir qué se muestra…")) {
                NotificationCenter.default.post(name: .flyoutHide, object: nil)
                SettingsWindowController.shared.show(pane: .tray)
            }
        }
    }
}

extension Notification.Name { static let flyoutHide = Notification.Name("local.cala.flyoutHide") }

// MARK: - Downloads

final class DownloadsModel: ObservableObject {
    static let shared = DownloadsModel()
    struct Entry: Identifiable {
        let url: URL
        let size: Int64?
        let added: Date
        let isDirectory: Bool
        var id: String { url.path }
    }
    @Published var files: [Entry] = []
    @Published var total = 0
    @Published var denied = false
    @Published var loaded = false

    func reload() {
        DispatchQueue.global(qos: .userInitiated).async {
            let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            let keys: Set<URLResourceKey> = [.addedToDirectoryDateKey, .contentModificationDateKey, .fileSizeKey, .isDirectoryKey]
            do {
                let urls = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
                let partial: Set<String> = ["crdownload", "download", "part", "opdownload"]
                let all = urls.filter { !partial.contains($0.pathExtension.lowercased()) }.map { u -> Entry in
                    let v = try? u.resourceValues(forKeys: keys)
                    return Entry(url: u, size: v?.fileSize.map(Int64.init), added: v?.addedToDirectoryDate ?? v?.contentModificationDate ?? .distantPast,
                                 isDirectory: v?.isDirectory ?? false)
                }.sorted { $0.added > $1.added }
                DispatchQueue.main.async {
                    self.files = Array(all.prefix(10)); self.total = all.count; self.denied = false; self.loaded = true
                    NotificationCenter.default.post(name: .flyoutRefit, object: nil)
                }
            } catch {
                DispatchQueue.main.async {
                    self.denied = true; self.loaded = true
                    NotificationCenter.default.post(name: .flyoutRefit, object: nil)
                }
            }
        }
    }
}

func relativeAge(_ date: Date) -> String {
    let s = max(0, Int(Date().timeIntervalSince(date)))
    if s < 60 { return tx("now", "ahora") }
    if s < 3600 { return tx("\(s / 60) min ago", "hace \(s / 60) min") }
    if s < 86400 { return tx("\(s / 3600) h ago", "hace \(s / 3600) h") }
    return tx("\(s / 86400) d ago", "hace \(s / 86400) d")
}

struct DownloadsPane: View {
    @ObservedObject private var model = DownloadsModel.shared
    @State private var hover: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Header(title: tx("Downloads", "Descargas"))
            Divider().padding(.vertical, 2)
            if model.denied {
                Label(tx("Cala doesn't have permission to read Downloads.", "Cala no tiene permiso para leer Descargas."), systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundStyle(StatusColor.color(.attention))
                Row(icon: "gearshape", title: tx("Open Files & Folders…", "Abrir Archivos y carpetas…")) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!)
                }
            } else if model.files.isEmpty {
                Text(model.loaded ? tx("No downloads.", "No hay descargas.") : tx("Loading…", "Cargando…")).font(.system(size: 12)).flyoutSecondary().padding(.vertical, 6)
            } else {
                ForEach(model.files) { f in fileRow(f) }
                if model.total > model.files.count {
                    Text(tx("and \(model.total - model.files.count) more in the folder", "y \(model.total - model.files.count) más en la carpeta")).font(.system(size: 10.5)).flyoutSecondary().padding(.leading, 4)
                }
            }
            Divider().padding(.vertical, 2)
            Row(icon: "folder", title: tx("Open Downloads folder", "Abrir carpeta Descargas")) {
                NSWorkspace.shared.open(FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0])
            }
        }
        .onAppear { model.reload() }
    }

    private func fileRow(_ f: DownloadsModel.Entry) -> some View {
        HStack(spacing: 10) {
            Button { NSWorkspace.shared.open(f.url) } label: {
                HStack(spacing: 10) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: f.url.path)).resizable().frame(width: 26, height: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(f.url.lastPathComponent).font(.system(size: 12.5)).lineLimit(1).truncationMode(.middle)
                        Text([f.isDirectory ? tx("Folder", "Carpeta") : f.size.map(diskBytes), relativeAge(f.added)].compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 10.5)).flyoutSecondary()
                    }
                    Spacer(minLength: 4)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            Button { NSWorkspace.shared.activateFileViewerSelecting([f.url]) } label: {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).frame(width: 22, height: 22)
            }.buttonStyle(.plain).help(tx("Show in Finder", "Mostrar en Finder"))
        }
        .padding(.vertical, 3).padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(hover == f.id ? 0.09 : 0)))
        .onHover { hover = $0 ? f.id : (hover == f.id ? nil : hover) }
    }
}

// MARK: - Trash (through Finder: macOS protects the Trash folder itself)

enum TrashService {
    private static let queue = DispatchQueue(label: "local.cala.trash", qos: .userInitiated)
    private static let notAuthorized = -1743

    private static func run(_ source: String) -> (value: NSAppleEventDescriptor?, errorNumber: Int?) {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return (result, (error?[NSAppleScript.errorNumber] as? NSNumber)?.intValue)
    }

    enum Permission { case granted, denied, notAsked }

    /// Whether Cala may already send Apple events to Finder, without ever showing the macOS prompt. Main-thread callback.
    static func permission(_ done: @escaping (Permission) -> Void) {
        queue.async {
            let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
            let status = target.aeDesc.map { AEDeterminePermissionToAutomateTarget($0, AEEventClass(typeWildCard), AEEventID(typeWildCard), false) } ?? OSStatus(procNotFound)
            let p: Permission = status == noErr ? .granted : (Int(status) == notAuthorized ? .denied : .notAsked)
            DispatchQueue.main.async { done(p) }
        }
    }

    /// Calls back on the main thread with the number of items (nil if unknown) and whether Automation was denied.
    static func count(_ done: @escaping (Int?, Bool) -> Void) {
        queue.async {
            let r = run("tell application \"Finder\" to count items of trash")
            let n = r.value.map { Int($0.int32Value) }
            DispatchQueue.main.async { done(r.errorNumber == nil ? n : nil, r.errorNumber == notAuthorized) }
        }
    }

    static func empty(_ done: @escaping (Bool) -> Void) {
        queue.async {
            let r = run("tell application \"Finder\" to empty trash")
            DispatchQueue.main.async { done(r.errorNumber == nil) }
        }
    }
}

final class TrashModel: ObservableObject {
    static let shared = TrashModel()
    @Published var count: Int?
    @Published var denied = false
    @Published var working = false
    @Published var message = ""

    func refresh() {
        TrashService.count { n, denied in
            self.count = n; self.denied = denied
            NotificationCenter.default.post(name: .flyoutRefit, object: nil)
        }
    }

    /// Confirms first (Cancel is the default button), then empties the Trash through Finder.
    func confirmAndEmpty() {
        guard !working else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = tx("Empty the Trash?", "¿Vaciar la Papelera?")
        alert.informativeText = (count.map { tx("\($0) item(s) will be permanently deleted. ", "Se eliminarán \($0) elemento(s) de forma definitiva. ") } ?? tx("Everything in the Trash will be permanently deleted. ", "Se eliminará todo lo que hay en la Papelera. ")) + tx("This can't be undone.", "Esto no se puede deshacer.")
        alert.addButton(withTitle: tx("Cancel", "Cancelar"))
        alert.addButton(withTitle: tx("Empty Trash", "Vaciar Papelera")).hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        working = true; message = ""
        let before = DiskInfo.read()?.available ?? 0
        TrashService.empty { ok in
            self.working = false
            let freed = max(0, (DiskInfo.read()?.available ?? 0) - before)
            self.message = ok ? tx("Trash emptied. Freed about \(diskBytes(freed)).", "Papelera vaciada. Liberados unos \(diskBytes(freed)).") : tx("Couldn't empty the Trash.", "No se pudo vaciar la Papelera.")
            log("trash: emptied=\(ok)")
            self.refresh()
        }
    }
}

struct TrashPane: View {
    @ObservedObject private var model = TrashModel.shared

    private var status: String {
        guard let n = model.count else { return model.denied ? tx("No permission", "Sin permiso") : tx("Measuring…", "Midiendo…") }
        return n == 0 ? tx("The Trash is empty", "La Papelera está vacía") : tx("\(n) item\(n == 1 ? "" : "s")", "\(n) elemento\(n == 1 ? "" : "s")")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Header(title: tx("Trash", "Papelera"))
            Divider().padding(.vertical, 2)
            Row(icon: model.count == 0 ? "trash" : "trash.fill", title: status, subtitle: model.message.isEmpty ? nil : model.message) {}
            if model.denied {
                Text(tx("Cala needs permission to control Finder so it can count and empty the Trash.", "Cala necesita permiso para controlar Finder y poder contar y vaciar la Papelera.")).font(.system(size: 11)).foregroundStyle(StatusColor.color(.attention))
                    .fixedSize(horizontal: false, vertical: true)
                Row(icon: "gearshape", title: tx("Open Automation…", "Abrir Automatización…")) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
                }
            }
            Divider().padding(.vertical, 2)
            Row(icon: "folder", title: tx("Open Trash", "Abrir Papelera")) { NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/.Trash")) }
            Row(icon: "trash.slash", title: tx("Empty Trash…", "Vaciar Papelera…")) { model.confirmAndEmpty() }
                .disabled(model.working || (model.count ?? 1) == 0 || model.denied)
        }
        .onAppear { model.refresh() }
    }
}

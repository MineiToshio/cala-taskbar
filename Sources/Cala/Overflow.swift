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

// MARK: - "^" overflow panel

struct MorePane: View {
    @ObservedObject var fm: FlyoutModel
    @ObservedObject var model: TaskbarModel
    @ObservedObject private var store = ConfigStore.shared
    @State private var hover: String?

    private func icon(_ id: String, _ info: TrayItemInfo) -> some View {
        Group {
            if id == trayUser, let photo = model.userPhoto {
                Image(nsImage: photo).resizable().scaledToFill().frame(width: 24, height: 24).clipShape(Circle())
            } else if id == trayKB, !model.kbCode.isEmpty {
                Text(model.kbCode).font(.system(size: 15, weight: .semibold))
            } else {
                Image(systemName: info.symbol).font(.system(size: 19))
            }
        }.frame(height: 26)
    }

    var body: some View {
        let ids = store.config.moreTrayIDs.filter { model.trayAvailable($0) }
        VStack(alignment: .leading, spacing: 12) {
            Header(title: "Más")
            if ids.isEmpty {
                Text("No hay nada aquí. Elige qué mostrar en Configuración → Bandeja.").font(.system(size: 12)).flyoutSecondary()
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    ForEach(ids, id: \.self) { id in
                        if let info = TrayItems.info(id) {
                            Button {
                                fm.fromMore = true; fm.kind = id; fm.token += 1
                            } label: {
                                VStack(spacing: 6) {
                                    icon(id, info)
                                    Text(info.title).font(.system(size: 11)).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity).frame(height: 66)
                                .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(hover == id ? 0.12 : 0.06)))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .onHover { hover = $0 ? id : (hover == id ? nil : hover) }
                        }
                    }
                }
            }
            Divider()
            Row(icon: "slider.horizontal.3", title: "Elegir qué se muestra…") {
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
    if s < 60 { return "ahora" }
    if s < 3600 { return "hace \(s / 60) min" }
    if s < 86400 { return "hace \(s / 3600) h" }
    return "hace \(s / 86400) d"
}

struct DownloadsPane: View {
    @ObservedObject private var model = DownloadsModel.shared
    @State private var hover: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Header(title: "Descargas")
            Divider().padding(.vertical, 2)
            if model.denied {
                Label("Cala no tiene permiso para leer Descargas.", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundStyle(Color.orange)
                Row(icon: "gearshape", title: "Abrir Archivos y carpetas…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!)
                }
            } else if model.files.isEmpty {
                Text(model.loaded ? "No hay descargas." : "Cargando…").font(.system(size: 12)).flyoutSecondary().padding(.vertical, 6)
            } else {
                ForEach(model.files) { f in fileRow(f) }
                if model.total > model.files.count {
                    Text("y \(model.total - model.files.count) más en la carpeta").font(.system(size: 10.5)).flyoutSecondary().padding(.leading, 4)
                }
            }
            Divider().padding(.vertical, 2)
            Row(icon: "folder", title: "Abrir carpeta Descargas") {
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
                        Text([f.isDirectory ? "Carpeta" : f.size.map(diskBytes), relativeAge(f.added)].compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 10.5)).flyoutSecondary()
                    }
                    Spacer(minLength: 4)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            Button { NSWorkspace.shared.activateFileViewerSelecting([f.url]) } label: {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).frame(width: 22, height: 22)
            }.buttonStyle(.plain).help("Mostrar en Finder")
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
        alert.messageText = "¿Vaciar la Papelera?"
        alert.informativeText = (count.map { "Se eliminarán \($0) elemento(s) de forma definitiva. " } ?? "Se eliminará todo lo que hay en la Papelera. ") + "Esto no se puede deshacer."
        alert.addButton(withTitle: "Cancelar")
        alert.addButton(withTitle: "Vaciar Papelera").hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        working = true; message = ""
        let before = DiskInfo.read()?.available ?? 0
        TrashService.empty { ok in
            self.working = false
            let freed = max(0, (DiskInfo.read()?.available ?? 0) - before)
            self.message = ok ? "Papelera vaciada. Liberados unos \(diskBytes(freed))." : "No se pudo vaciar la Papelera."
            log("trash: emptied=\(ok)")
            self.refresh()
        }
    }
}

struct TrashPane: View {
    @ObservedObject private var model = TrashModel.shared

    private var status: String {
        guard let n = model.count else { return model.denied ? "Sin permiso" : "Midiendo…" }
        return n == 0 ? "La Papelera está vacía" : "\(n) elemento\(n == 1 ? "" : "s")"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Header(title: "Papelera")
            Divider().padding(.vertical, 2)
            Row(icon: model.count == 0 ? "trash" : "trash.fill", title: status, subtitle: model.message.isEmpty ? nil : model.message) {}
            if model.denied {
                Text("Cala necesita permiso para controlar Finder y poder contar y vaciar la Papelera.").font(.system(size: 11)).foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Row(icon: "gearshape", title: "Abrir Automatización…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
                }
            }
            Divider().padding(.vertical, 2)
            Row(icon: "folder", title: "Abrir Papelera") { NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/.Trash")) }
            Row(icon: "trash.slash", title: "Vaciar Papelera…") { model.confirmAndEmpty() }
                .disabled(model.working || (model.count ?? 1) == 0 || model.denied)
        }
        .onAppear { model.refresh() }
    }
}

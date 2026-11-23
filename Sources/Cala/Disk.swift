import SwiftUI
import AppKit
import Combine

let trayDisk = "__t_disk"

/// Free space of the user's data volume. "Available" includes purgeable space (caches macOS frees on demand),
/// the same number System Settings shows.
struct DiskInfo: Equatable {
    var total: Int64
    var available: Int64
    var purgeable: Int64

    var freeFraction: Double { total > 0 ? min(1, max(0, Double(available) / Double(total))) : 0 }
    var freePercent: Int { Int((freeFraction * 100).rounded()) }
    var usedBytes: Int64 { max(0, total - available) }
    /// Free space that is not purgeable.
    var freeBytes: Int64 { max(0, available - purgeable) }
    var isLow: Bool { freeFraction < 0.15 }

    static func read() -> DiskInfo? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let v = try? url.resourceValues(forKeys: keys), let total = v.volumeTotalCapacity, total > 0 else { return nil }
        let raw = Int64(v.volumeAvailableCapacity ?? 0)
        let available = v.volumeAvailableCapacityForImportantUsage ?? raw
        return DiskInfo(total: Int64(total), available: max(available, raw), purgeable: max(0, available - raw))
    }
}

/// Warning colors only when space is short; otherwise the tray stays monochrome.
func diskTint(_ d: DiskInfo) -> Color {
    d.freeFraction < 0.10 ? .red : (d.freeFraction < 0.20 ? .orange : Color.primary.opacity(0.85))
}

struct DiskFolder: Identifiable, Equatable {
    let path: String
    let name: String
    let symbol: String
    var bytes: Int64?
    /// Some files could not be read (permissions), so the real size is at least `bytes`.
    var partial = false
    /// Sub-paths skipped while measuring (they are listed as their own rows).
    var excluding: [String] = []
    var id: String { path }
}

/// Measures a short list of folders where developer tools and AI agents pile up data. Runs in the background
/// only while the storage panel is opened (at most once every 10 minutes). It also measures /Users/Shared, the
/// other user accounts' home folders (what their permissions let this user read) and the rest of the user's own
/// folder (Documents, Downloads, Desktop...; macOS asks permission once per protected folder). The panel adds a
/// last "Sistema y otros" row (used space minus everything measured) so the rows add up to the used space.
final class DiskService: ObservableObject {
    static let shared = DiskService()
    @Published private(set) var folders: [DiskFolder] = []
    @Published private(set) var scanning = false
    private var lastScan = Date.distantPast
    private var lastExtra: [String] = []
    private var generation = 0

    static func candidates(extra: [String]) -> [DiskFolder] {
        let h = NSHomeDirectory()
        let builtin: [(String, String, String)] = [
            ("/Applications", tx("Applications", "Aplicaciones"), "app.fill"),
            (h + "/Library/Developer", tx("Xcode and simulators", "Xcode y simuladores"), "hammer.fill"),
            (h + "/Library/Caches", tx("Caches", "Cachés"), "tray.full.fill"),
            (h + "/Library/Application Support", tx("App data", "Datos de apps"), "folder.fill"),
            (h + "/.claude", "Claude Code", "sparkles"),
            (h + "/.codex", "Codex", "sparkles"),
            (h + "/.npm", "npm", "shippingbox.fill"),
            (h + "/.cache", "~/.cache", "shippingbox.fill"),
            (h + "/.cargo", "Cargo", "shippingbox.fill"),
            (h + "/.gradle", "Gradle", "shippingbox.fill"),
            (h + "/.bun", "Bun", "shippingbox.fill"),
            ("/opt/homebrew", "Homebrew", "mug.fill"),
        ]
        var seen = Set<String>()
        var out: [DiskFolder] = []
        func add(_ path: String, _ name: String, _ symbol: String) {
            let p = (path as NSString).standardizingPath
            var isDir: ObjCBool = false
            guard !seen.contains(p), FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue else { return }
            seen.insert(p); out.append(DiskFolder(path: p, name: name, symbol: symbol, bytes: nil))
        }
        for (p, n, s) in builtin { add(p, n, s) }
        add("/Users/Shared", tx("Shared (/Users/Shared)", "Compartido (/Users/Shared)"), "person.2.fill")
        // Other macOS user accounts on this Mac (e.g. a work session): their folders count against the same disk.
        let me = (h as NSString).lastPathComponent
        let others = (try? FileManager.default.contentsOfDirectory(atPath: "/Users")) ?? []
        for u in others.sorted() where u != "Shared" && u != me && !u.hasPrefix(".") && u != "Guest" {
            add("/Users/" + u, tx("Account: ", "Sesión: ") + u, "person.fill")
        }
        for e in extra {
            let p = (e.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
            if !p.isEmpty { add(p, (p as NSString).lastPathComponent, "folder.badge.gearshape") }
        }
        // Everything else in the user's own folder (Documents, Downloads, Desktop, Movies...), so the list adds up.
        // Reading those folders makes macOS ask for permission once each.
        let inHome = out.map(\.path).filter { $0.hasPrefix(h + "/") }
        out.append(DiskFolder(path: h, name: tx("Your home folder (rest)", "Tu carpeta personal (resto)"), symbol: "house.fill", bytes: nil, excluding: inHome))
        return out
    }

    /// Allocated size on disk of everything under `path`, and whether some of it could not be read.
    static func size(of path: String, excluding: [String] = []) -> (bytes: Int64, partial: Bool) {
        let skip = Set(excluding)
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isDirectoryKey]
        var partial = false
        guard let e = FileManager.default.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: Array(keys),
                                                     options: [], errorHandler: { _, _ in partial = true; return true }) else { return (0, true) }
        var total: Int64 = 0
        for case let u as URL in e {
            if !skip.isEmpty, skip.contains(u.path) { e.skipDescendants(); continue }
            guard let v = try? u.resourceValues(forKeys: keys), v.isDirectory != true else { continue }
            total += Int64(v.totalFileAllocatedSize ?? 0)
        }
        return (total, partial)
    }

    /// Call on the main thread. Publishes the folder list at once (so the panel has its final height) and
    /// fills in the sizes as each folder finishes.
    func refresh(extra: [String], force: Bool = false) {
        let fresh = Date().timeIntervalSince(lastScan) < 600 && extra == lastExtra && !folders.isEmpty
        if fresh && !force { return }
        lastScan = Date(); lastExtra = extra
        generation += 1
        let gen = generation
        let old = Dictionary(folders.map { ($0.path, $0.bytes) }, uniquingKeysWith: { a, _ in a })
        var list = Self.candidates(extra: extra)
        for i in list.indices { list[i].bytes = old[list[i].path] ?? nil }   // keep the last known size while re-measuring
        folders = list
        scanning = true
        let paths = list.map(\.path)
        let skips = Dictionary(list.map { ($0.path, $0.excluding) }, uniquingKeysWith: { a, _ in a })
        let started = Date()
        DispatchQueue.global(qos: .utility).async {
            let group = DispatchGroup()
            for p in paths {
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    let r = Self.size(of: p, excluding: skips[p] ?? [])
                    DispatchQueue.main.async {
                        if gen == self.generation, let i = self.folders.firstIndex(where: { $0.path == p }) {
                            self.folders[i].bytes = r.bytes; self.folders[i].partial = r.partial
                        }
                    }
                    group.leave()
                }
            }
            group.wait()
            DispatchQueue.main.async {
                guard gen == self.generation else { return }
                self.scanning = false
                log("disk: measured \(paths.count) folders in \(Int(Date().timeIntervalSince(started))) s")
            }
        }
    }
}

struct DiskBar: View {
    @Environment(\.themeAccent) private var accent
    let info: DiskInfo
    var body: some View {
        GeometryReader { geo in
            let t = max(1, Double(info.total))
            let used = geo.size.width * Double(info.usedBytes) / t
            let purge = geo.size.width * Double(info.purgeable) / t
            HStack(spacing: 1.5) {
                RoundedRectangle(cornerRadius: 3).fill(info.isLow ? Color.orange : accent).frame(width: max(2, used))
                if info.purgeable > 0 { RoundedRectangle(cornerRadius: 3).fill((info.isLow ? Color.orange : accent).opacity(0.38)).frame(width: max(2, purge)) }
                RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.14))
            }
        }
        .frame(height: 12)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

struct DiskPane: View {
    @ObservedObject var model: TaskbarModel
    @ObservedObject private var service = DiskService.shared
    @ObservedObject private var store = ConfigStore.shared
    @Environment(\.themeAccent) private var accent

    private let rowHeight: CGFloat = 34

    private var sorted: [DiskFolder] {
        service.folders.sorted { ($0.bytes ?? -1) > ($1.bytes ?? -1) }
    }

    /// What the measured folders do not explain: macOS itself, system data, the Trash and anything not listed.
    /// Shown last so that the rows add up to the used space.
    private var remainder: DiskFolder? {
        guard let d = model.disk, !service.folders.isEmpty, service.folders.allSatisfy({ $0.bytes != nil }) else { return nil }
        let measured = service.folders.reduce(Int64(0)) { $0 + ($1.bytes ?? 0) }
        return DiskFolder(path: "", name: tx("System and others (not measured)", "Sistema y otros (no medido)"), symbol: "gearshape.2.fill", bytes: max(0, d.usedBytes - measured))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Header(title: tx("Storage", "Almacenamiento"))
            if let d = model.disk {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tx("\(diskBytes(d.available)) available", "\(diskBytes(d.available)) disponibles")).font(.system(size: 20, weight: .semibold))
                    Text(tx("of \(diskBytes(d.total)) · \(d.freePercent)% free", "de \(diskBytes(d.total)) · \(d.freePercent)% libre")).font(.system(size: 12)).flyoutSecondary()
                }
                DiskBar(info: d)
                HStack(spacing: 14) {
                    legend(accent, tx("Used", "Usado"), d.usedBytes)
                    if d.purgeable > 0 { legend(accent.opacity(0.38), tx("Purgeable", "Liberable"), d.purgeable) }
                    legend(Color.primary.opacity(0.18), tx("Free", "Libre"), d.freeBytes)
                }
                if d.isLow {
                    Label(tx("Space is running low. Start with the biggest items in the list.", "Queda poco espacio. Empieza por lo más grande de la lista."), systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11)).foregroundStyle(Color.orange).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                SystemLoadingPulse {
                    VStack(alignment: .leading, spacing: 10) {
                        VStack(alignment: .leading, spacing: 5) {
                            SystemSkeletonMark().frame(width: 150, height: 22)
                            SystemSkeletonMark().frame(width: 110, height: 10)
                        }
                        SystemSkeletonMark().frame(height: 12)
                        SystemSkeletonMark().frame(width: 220, height: 10)
                    }
                }
            }
            Divider()
            HStack {
                Text(tx("Where the space goes", "Dónde se va el espacio")).font(.system(size: 12, weight: .semibold)).flyoutSecondary()
                Spacer()
            }
            ScrollView {
                VStack(spacing: 0) {
                    let top = Double(sorted.first?.bytes ?? 1)
                    ForEach(sorted) { f in folderRow(f, top: max(1, top)) }
                    if let r = remainder { folderRow(r, top: max(1, top)) }
                    else if !service.folders.isEmpty { folderRow(DiskFolder(path: "", name: tx("System and others (not measured)", "Sistema y otros (no medido)"), symbol: "gearshape.2.fill", bytes: nil), top: 1) }
                }
            }
            .frame(height: min(CGFloat(service.folders.count + 1) * rowHeight, 272))
            Divider()
            Row(icon: "sparkles", title: tx("Review and free up space…", "Revisar y limpiar espacio…"), subtitle: tx("Only opens a list; deletes nothing", "Solo abre una lista; no borra nada")) {
                (NSApp.delegate as? AppDelegate)?.flyout.hide()
                CleanupWindowController.shared.show()
            }
            Row(icon: "arrow.clockwise", title: tx("Measure again", "Volver a medir")) { service.refresh(extra: store.config.diskFolders, force: true) }
            LinkRow(title: tx("Storage settings…", "Ajustes de almacenamiento…"), pane: "com.apple.settings.Storage")
        }
    }

    private func legend(_ c: Color, _ title: String, _ bytes: Int64) -> some View {
        HStack(spacing: 4) {
            Circle().fill(c).frame(width: 7, height: 7)
            Text("\(title) \(diskBytes(bytes))").font(.system(size: 10.5)).flyoutSecondary()
        }
    }

    private func folderRow(_ f: DiskFolder, top: Double) -> some View {
        Button { if !f.path.isEmpty { NSWorkspace.shared.open(URL(fileURLWithPath: f.path)) } } label: {
            HStack(spacing: 10) {
                Image(systemName: f.symbol).frame(width: 18).flyoutSecondary()
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(f.name).font(.system(size: 12.5)).lineLimit(1)
                        Spacer(minLength: 6)
                        if let b = f.bytes {
                            Text((f.partial ? "≥ " : "") + diskBytes(b)).font(.system(size: 11.5)).monospacedDigit().flyoutSecondary()
                        } else {
                            SystemLoadingPulse { SystemSkeletonMark().frame(width: 44, height: 10) }
                        }
                    }
                    GeometryReader { g in
                        Capsule().fill(Color.primary.opacity(0.1))
                            .overlay(alignment: .leading) {
                                if f.bytes != nil {
                                    Capsule().fill(accent.opacity(0.75)).frame(width: g.size.width * CGFloat(Double(f.bytes ?? 0) / top))
                                }
                            }
                    }.frame(height: 3)
                }
            }
            .frame(height: rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(f.path.isEmpty ? tx("macOS, system data, the Trash and anything not in the list", "macOS, datos del sistema, la Papelera y lo que no está en la lista") : f.partial ? f.path + tx(" — some files can't be read; the real size is larger", " — hay archivos sin permiso de lectura; el tamaño real es mayor") : f.path)
    }
}

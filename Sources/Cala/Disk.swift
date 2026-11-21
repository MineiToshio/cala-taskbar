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

func diskBytes(_ n: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
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
    var id: String { path }
}

/// Measures a short list of folders where developer tools and AI agents pile up data. Runs in the background
/// only while the storage panel is opened (at most once every 10 minutes) and never touches the protected
/// folders (Documents, Desktop, Downloads, Trash), so macOS shows no permission prompts.
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
            ("/Applications", "Aplicaciones", "app.fill"),
            (h + "/Library/Developer", "Xcode y simuladores", "hammer.fill"),
            (h + "/Library/Caches", "Cachés", "tray.full.fill"),
            (h + "/Library/Application Support", "Datos de apps", "folder.fill"),
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
        for e in extra {
            let p = (e.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
            if !p.isEmpty { add(p, (p as NSString).lastPathComponent, "folder.badge.gearshape") }
        }
        return out
    }

    /// Allocated size on disk of everything under `path`.
    static func size(of path: String) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isDirectoryKey]
        guard let e = FileManager.default.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: Array(keys),
                                                     options: [], errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        for case let u as URL in e {
            guard let v = try? u.resourceValues(forKeys: keys), v.isDirectory != true else { continue }
            total += Int64(v.totalFileAllocatedSize ?? 0)
        }
        return total
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
        let started = Date()
        DispatchQueue.global(qos: .utility).async {
            let group = DispatchGroup()
            for p in paths {
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    let n = Self.size(of: p)
                    DispatchQueue.main.async {
                        if gen == self.generation, let i = self.folders.firstIndex(where: { $0.path == p }) { self.folders[i].bytes = n }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Header(title: "Almacenamiento")
            if let d = model.disk {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(diskBytes(d.available)) disponibles").font(.system(size: 20, weight: .semibold))
                    Text("de \(diskBytes(d.total)) · \(d.freePercent)% libre").font(.system(size: 12)).flyoutSecondary()
                }
                DiskBar(info: d)
                HStack(spacing: 14) {
                    legend(accent, "Usado", d.usedBytes)
                    if d.purgeable > 0 { legend(accent.opacity(0.38), "Liberable", d.purgeable) }
                    legend(Color.primary.opacity(0.18), "Libre", d.freeBytes)
                }
                if d.isLow {
                    Label("Queda poco espacio. Empieza por lo más grande de la lista.", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11)).foregroundStyle(Color.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider()
            HStack {
                Text("Dónde se va el espacio").font(.system(size: 12, weight: .semibold)).flyoutSecondary()
                Spacer()
                if service.scanning { ProgressView().controlSize(.small).scaleEffect(0.7) }
            }
            ScrollView {
                VStack(spacing: 0) {
                    let top = Double(sorted.first?.bytes ?? 1)
                    ForEach(sorted) { f in folderRow(f, top: max(1, top)) }
                }
            }
            .frame(height: min(CGFloat(service.folders.count) * rowHeight, 272))
            Divider()
            Row(icon: "arrow.clockwise", title: "Volver a medir") { service.refresh(extra: store.config.diskFolders, force: true) }
            LinkRow(title: "Ajustes de almacenamiento…", pane: "com.apple.settings.Storage")
        }
    }

    private func legend(_ c: Color, _ title: String, _ bytes: Int64) -> some View {
        HStack(spacing: 4) {
            Circle().fill(c).frame(width: 7, height: 7)
            Text("\(title) \(diskBytes(bytes))").font(.system(size: 10.5)).flyoutSecondary()
        }
    }

    private func folderRow(_ f: DiskFolder, top: Double) -> some View {
        Button { NSWorkspace.shared.open(URL(fileURLWithPath: f.path)) } label: {
            HStack(spacing: 10) {
                Image(systemName: f.symbol).frame(width: 18).flyoutSecondary()
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(f.name).font(.system(size: 12.5)).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(f.bytes.map(diskBytes) ?? "…").font(.system(size: 11.5)).monospacedDigit().flyoutSecondary()
                    }
                    GeometryReader { g in
                        Capsule().fill(Color.primary.opacity(0.1))
                            .overlay(alignment: .leading) {
                                Capsule().fill(accent.opacity(0.75)).frame(width: g.size.width * CGFloat(Double(f.bytes ?? 0) / top))
                            }
                    }.frame(height: 3)
                }
            }
            .frame(height: rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(f.path)
    }
}

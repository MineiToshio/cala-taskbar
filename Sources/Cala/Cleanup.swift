import SwiftUI
import AppKit

// MARK: - Git helper

enum Git {
    struct Result { var out: String; var err: String; var status: Int32 }

    /// `/usr/bin/git` is a shim that pops up the "install developer tools" dialog when they are missing, so it is
    /// only used when a real developer directory is installed.
    static let available: Bool = {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select"); p.arguments = ["-p"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }()

    /// Runs /usr/bin/git without ever prompting or taking optional locks. Off-main only.
    static func run(_ args: [String], timeout: TimeInterval = 180) -> Result {
        let p = Process(), o = Pipe(), e = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"; env["GIT_OPTIONAL_LOCKS"] = "0"; env["LC_ALL"] = "C"
        p.environment = env
        p.standardOutput = o; p.standardError = e; p.standardInput = FileHandle.nullDevice
        guard available, (try? p.run()) != nil else { return Result(out: "", err: "git not available", status: -1) }
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        group.enter(); DispatchQueue.global().async { outData = o.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter(); DispatchQueue.global().async { errData = e.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        p.waitUntilExit(); group.wait(); killer.cancel()
        return Result(out: String(decoding: outData, as: UTF8.self), err: String(decoding: errData, as: UTF8.self), status: p.terminationStatus)
    }
}

// MARK: - Models

struct WorktreeGroup: Identifiable, Equatable {
    var id: String { path }
    let path: String
    let repoRoot: String
    let repoName: String
    let head: String
    let mainHead: String
    var branch: String?
    var locked = false
    /// Linked worktrees physically inside this one, deepest first. They are removed before it.
    var children: [String] = []
    var bytes: Int64?
    var lastCommit: Date?
    var dirty: Bool?
    var childrenDirty = false
    /// Detached HEAD whose commits are on no branch: removing the worktree would lose them.
    var orphanCommits = false
    var integrated = false
    /// A running process (an agent session, a terminal, a dev server) has its working directory inside.
    var busy = false
    var name: String { (path as NSString).lastPathComponent }
    var checked: Bool { dirty != nil }
    /// Safe = nothing would be lost: clean tree (also untracked files), clean inner worktrees, commits kept on a branch.
    var safe: Bool { checked && dirty == false && !childrenDirty && !orphanCommits && !locked && !busy }
    var reason: String? {
        if locked { return calendarText("Locked", "Bloqueado") }
        if busy { return calendarText("In use", "En uso") }
        if dirty == true { return calendarText("Unsaved changes", "Cambios sin guardar") }
        if childrenDirty { return calendarText("Inner worktree has changes", "Un worktree interno tiene cambios") }
        if orphanCommits { return calendarText("Commits not on any branch", "Commits que no están en ninguna rama") }
        return nil
    }
}

struct CacheItem: Identifiable, Equatable {
    var id: String { path }
    let path: String
    let name: String
    let note: String
    var bytes: Int64?
}

// MARK: - Discovery and removal

enum Cleanup {
    /// Folders where projects live: every project Claude Code or Codex has opened (exact paths from their own
    /// config files; only the paths are read) plus the extra folders from Settings → General → Disco.
    static func projectPaths(extra: [String]) -> [String] {
        let fm = FileManager.default, home = NSHomeDirectory()
        var out: [String] = []
        if let size = (try? fm.attributesOfItem(atPath: home + "/.claude.json")[.size] as? NSNumber)?.intValue, size < 40_000_000,
           let data = fm.contents(atPath: home + "/.claude.json"),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let projects = obj["projects"] as? [String: Any] {
            out += projects.keys
        }
        if let toml = try? String(contentsOfFile: home + "/.codex/config.toml", encoding: .utf8),
           let regex = try? NSRegularExpression(pattern: #"\[projects\."([^"]+)"\]"#) {
            let range = NSRange(toml.startIndex..., in: toml)
            for m in regex.matches(in: toml, range: range) { if let r = Range(m.range(at: 1), in: toml) { out.append(String(toml[r])) } }
        }
        for e in extra {
            let root = (e.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
            guard !root.isEmpty else { continue }
            out.append(root)
            for child in (try? fm.contentsOfDirectory(atPath: root)) ?? [] where !child.hasPrefix(".") { out.append(root + "/" + child) }
        }
        var seen = Set<String>()
        return out.filter { p in
            var isDir: ObjCBool = false
            return p.hasPrefix("/") && fm.fileExists(atPath: p + "/.git") && fm.fileExists(atPath: p, isDirectory: &isDir) && isDir.boolValue && seen.insert(p).inserted
        }
    }

    private struct Entry { var path: String; var head = ""; var branch: String?; var locked = false }

    private static func parse(_ porcelain: String) -> [Entry] {
        var entries: [Entry] = []
        for block in porcelain.components(separatedBy: "\n\n") {
            var e: Entry?
            for line in block.split(separator: "\n") {
                if line.hasPrefix("worktree ") { e = Entry(path: String(line.dropFirst(9))) }
                else if line.hasPrefix("HEAD ") { e?.head = String(line.dropFirst(5)) }
                else if line.hasPrefix("branch ") { e?.branch = String(line.dropFirst(7)).replacingOccurrences(of: "refs/heads/", with: "") }
                else if line.hasPrefix("locked") { e?.locked = true }
            }
            if let e { entries.append(e) }
        }
        return entries
    }

    /// Top-level linked worktrees of every repository found (the main worktree is never offered).
    static func discover(extra: [String]) -> [WorktreeGroup] {
        var seenMain = Set<String>(), groups: [WorktreeGroup] = []
        for project in projectPaths(extra: extra) {
            let r = Git.run(["-C", project, "worktree", "list", "--porcelain"], timeout: 30)
            guard r.status == 0 else { continue }
            let entries = parse(r.out)
            guard let main = entries.first, seenMain.insert(main.path).inserted else { continue }
            let linked = entries.dropFirst().filter { FileManager.default.fileExists(atPath: $0.path) }
            let paths = linked.map(\.path)
            for e in linked where !paths.contains(where: { e.path.hasPrefix($0 + "/") }) {
                let inner = paths.filter { $0.hasPrefix(e.path + "/") }.sorted { $0.count > $1.count }
                var g = WorktreeGroup(path: e.path, repoRoot: main.path, repoName: (main.path as NSString).lastPathComponent,
                                      head: e.head, mainHead: main.head, branch: e.branch)
                g.locked = e.locked; g.children = inner
                groups.append(g)
            }
        }
        return groups
    }

    /// Tracked or untracked changes in `path`, ignoring anything that lives inside `nested` worktrees.
    private static func isDirty(_ path: String, nested: [String]) -> Bool {
        let r = Git.run(["-C", path, "status", "--porcelain", "--untracked-files=all"])
        guard r.status == 0 else { return true }          // unknown counts as "not safe"
        let skip = nested.map { String($0.dropFirst(path.count + 1)) + "/" }
        for line in r.out.split(separator: "\n") {
            let rel = String(line.dropFirst(3)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if skip.contains(where: { rel == String($0.dropLast()) || rel.hasPrefix($0) }) { continue }
            return true
        }
        return false
    }

    /// Working directories of this user's running processes (one `lsof` call). nil when they could not be read: then
    /// every worktree counts as in use, so nothing is offered for removal on a guess.
    static func busyDirectories() -> [String]? {
        let p = Process(), o = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-a", "-d", "cwd", "-Fn", "-u", String(getuid())]
        p.standardOutput = o; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        // lsof can stall on an unreachable network volume; a stuck scan must not block the window forever.
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: killer)
        let data = o.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit(); killer.cancel()
        guard p.terminationReason == .exit, p.terminationStatus == 0 || !data.isEmpty else { return nil }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").filter { $0.hasPrefix("n") }.map { String($0.dropFirst()) }
    }

    static func details(_ group: WorktreeGroup, busyDirs: [String]?) -> WorktreeGroup {
        var g = group
        g.busy = busyDirs?.contains { $0 == g.path || $0.hasPrefix(g.path + "/") } ?? true
        g.bytes = DiskService.size(of: g.path).bytes
        g.dirty = isDirty(g.path, nested: g.children)
        g.childrenDirty = g.children.contains { child in isDirty(child, nested: g.children.filter { $0.hasPrefix(child + "/") }) }
        let t = Git.run(["-C", g.path, "log", "-1", "--format=%ct"], timeout: 30)
        if let secs = TimeInterval(t.out.trimmingCharacters(in: .whitespacesAndNewlines)) { g.lastCommit = Date(timeIntervalSince1970: secs) }
        g.integrated = !g.head.isEmpty && Git.run(["-C", g.repoRoot, "merge-base", "--is-ancestor", g.head, g.mainHead], timeout: 30).status == 0
        if g.branch == nil, !g.head.isEmpty {
            let b = Git.run(["-C", g.repoRoot, "branch", "--contains", g.head], timeout: 30)
            g.orphanCommits = b.status == 0 && b.out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return g
    }

    /// `git worktree remove` without --force: git itself refuses a worktree with changes, so a mistake in our own
    /// checks still cannot delete unsaved work. Inner worktrees go first. Branches are left untouched.
    static func remove(_ g: WorktreeGroup) -> String? {
        for path in g.children + [g.path] {
            let r = Git.run(["-C", g.repoRoot, "worktree", "remove", path], timeout: 600)
            if r.status != 0 {
                let line = r.err.split(separator: "\n").first.map(String.init) ?? "git worktree remove failed"
                return (path as NSString).lastPathComponent + ": " + line
            }
        }
        _ = Git.run(["-C", g.repoRoot, "worktree", "prune"], timeout: 60)
        return nil
    }

    // MARK: Caches

    static func caches() -> [CacheItem] {
        let h = NSHomeDirectory()
        let list: [(String, String, String)] = [
            (h + "/Library/Caches", calendarText("App caches", "Cachés de apps"), calendarText("Apps rebuild them as needed. Quit big apps first.", "Las apps las regeneran. Cierra antes las apps grandes.")),
            (h + "/Library/Developer/Xcode/DerivedData", "Xcode DerivedData", calendarText("Build output; Xcode recreates it.", "Resultado de compilar; Xcode lo recrea.")),
            (h + "/Library/Developer/Xcode/iOS DeviceSupport", calendarText("Xcode device support", "Soporte de dispositivos de Xcode"), calendarText("Downloaded again when you connect a device.", "Se vuelve a descargar al conectar un dispositivo.")),
            (h + "/.npm/_cacache", calendarText("npm cache", "Caché de npm"), calendarText("Packages are downloaded again on demand.", "Los paquetes se vuelven a bajar cuando hacen falta.")),
            (h + "/.cache", "~/.cache", calendarText("May include downloaded models or browsers; they are fetched again.", "Puede incluir modelos o navegadores descargados; se vuelven a bajar.")),
            (h + "/.gradle/caches", calendarText("Gradle cache", "Caché de Gradle"), calendarText("Dependencies are downloaded again.", "Las dependencias se vuelven a bajar.")),
            (h + "/.bun/install/cache", calendarText("Bun cache", "Caché de Bun"), calendarText("Packages are downloaded again on demand.", "Los paquetes se vuelven a bajar cuando hacen falta.")),
            (h + "/.cargo/registry/cache", calendarText("Cargo cache", "Caché de Cargo"), calendarText("Crates are downloaded again on demand.", "Los crates se vuelven a bajar cuando hacen falta.")),
        ]
        return list.compactMap { path, name, note in
            isRealFolder(path) ? CacheItem(path: path, name: name, note: note) : nil
        }
    }

    /// A directory that is not itself a symlink: a cache folder redirected elsewhere (another disk, a project) is never offered.
    static func isRealFolder(_ path: String) -> Bool {
        guard let type = (try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType else { return false }
        return type == .typeDirectory
    }

    /// Deletes the contents of a cache folder (never the folder itself). Entries are removed as they are: a symlink
    /// inside is unlinked, never followed. Returns how many entries could not be removed.
    static func empty(_ item: CacheItem) -> Int {
        let fm = FileManager.default
        // Re-checked at deletion time, and only for the fixed list of known cache folders.
        guard caches().contains(where: { $0.path == item.path }), isRealFolder(item.path) else { return 1 }
        var failed = 0
        for child in (try? fm.contentsOfDirectory(atPath: item.path)) ?? [] {
            do { try fm.removeItem(atPath: item.path + "/" + child) } catch { failed += 1 }
        }
        return failed
    }
}

// MARK: - View model

final class CleanupModel: ObservableObject {
    static let shared = CleanupModel()
    @Published var groups: [WorktreeGroup] = []
    @Published var caches: [CacheItem] = []
    @Published var scanning = false
    @Published var working = false
    @Published var selected = Set<String>()
    @Published var message = ""
    /// nil until checked: counting the Trash goes through Finder, which makes macOS ask for permission once.
    @Published var trashCount: Int?
    @Published var trashDenied = false
    @Published var trashChecking = false
    private var generation = 0
    static let trashID = "__trash"

    func checkTrash() {
        trashChecking = true
        TrashService.count { n, denied in
            self.trashCount = n; self.trashDenied = denied; self.trashChecking = false
        }
    }
    var trashSelected: Bool { selected.contains(Self.trashID) && (trashCount ?? 0) > 0 }

    func scan() {
        guard !working else { return }
        generation += 1
        let gen = generation
        scanning = true; message = ""; selected = []; trashCount = nil; trashDenied = false
        caches = Cleanup.caches(); groups = []
        let extra = ConfigStore.shared.config.diskFolders
        let cacheList = caches
        DispatchQueue.global(qos: .utility).async {
            let found = Cleanup.discover(extra: extra)
            let busy = Cleanup.busyDirectories()
            DispatchQueue.main.async { if gen == self.generation { self.groups = found } }
            let done = DispatchGroup(), limit = DispatchSemaphore(value: 4)
            for g in found {
                limit.wait(); done.enter()
                DispatchQueue.global(qos: .utility).async {
                    let d = Cleanup.details(g, busyDirs: busy)
                    DispatchQueue.main.async {
                        if gen == self.generation, let i = self.groups.firstIndex(where: { $0.id == d.id }) { self.groups[i] = d }
                    }
                    limit.signal(); done.leave()
                }
            }
            for c in cacheList {
                limit.wait(); done.enter()
                DispatchQueue.global(qos: .utility).async {
                    let n = DiskService.size(of: c.path).bytes
                    DispatchQueue.main.async {
                        if gen == self.generation, let i = self.caches.firstIndex(where: { $0.id == c.id }) { self.caches[i].bytes = n }
                    }
                    limit.signal(); done.leave()
                }
            }
            done.wait()
            DispatchQueue.main.async { if gen == self.generation { self.scanning = false } }
        }
    }

    var selectedGroups: [WorktreeGroup] { groups.filter { selected.contains($0.id) && $0.safe } }
    var selectedCaches: [CacheItem] { caches.filter { selected.contains($0.id) } }
    var selectedBytes: Int64 {
        selectedGroups.reduce(0) { $0 + ($1.bytes ?? 0) } + selectedCaches.reduce(0) { $0 + ($1.bytes ?? 0) }
    }

    func selectSafe() { selected.formUnion(groups.filter(\.safe).map(\.id)) }

    /// Asks for confirmation (nothing is deleted before), then removes the selection in the background.
    func removeSelected() {
        let gs = selectedGroups, cs = selectedCaches, trash = trashSelected
        guard !gs.isEmpty || !cs.isEmpty || trash, !working else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = selectedBytes > 0 ? calendarText("Free up \(diskBytes(selectedBytes))\(trash ? " and empty the Trash" : "")?", "¿Liberar \(diskBytes(selectedBytes))\(trash ? " y vaciar la Papelera" : "")?")
                                              : calendarText("Empty the Trash?", "¿Vaciar la Papelera?")
        var lines: [String] = []
        let items = gs.map { $0.repoName + " / " + $0.name + " (" + diskBytes($0.bytes ?? 0) + ")" }
            + cs.map { $0.name + " (" + diskBytes($0.bytes ?? 0) + ")" }
            + (trash ? [calendarText("Trash (\(trashCount ?? 0) items)", "Papelera (\(trashCount ?? 0) elementos)")] : [])
        lines.append(calendarText("This will delete:", "Se va a eliminar:"))
        lines += items.prefix(12).map { "• " + $0 }
        if items.count > 12 { lines.append(calendarText("• …and \(items.count - 12) more", "• …y \(items.count - 12) más")) }
        lines.append("")
        if !gs.isEmpty { lines.append(calendarText("Worktrees are removed with git; your branches and commits stay.", "Los worktrees se quitan con git; tus ramas y commits se conservan.")) }
        if trash { lines.append(calendarText("Everything in the Trash is deleted for good.", "Todo lo que hay en la Papelera se borra para siempre.")) }
        if !cs.isEmpty { lines.append(calendarText("Caches are rebuilt automatically when needed.", "Las cachés se reconstruyen solas cuando hacen falta.")) }
        lines.append(calendarText("Nothing else is touched. This cannot be undone.", "No se toca nada más. Esto no se puede deshacer."))
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: calendarText("Cancel", "Cancelar"))
        let destructive = alert.addButton(withTitle: calendarText("Delete", "Eliminar"))
        destructive.hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        working = true; message = ""
        let before = DiskInfo.read()?.available ?? 0
        DispatchQueue.global(qos: .utility).async {
            var problems: [String] = []
            for g in gs { if let p = Cleanup.remove(g) { problems.append(p) } }
            for c in cs { let n = Cleanup.empty(c); if n > 0 { problems.append("\(c.name): \(n) " + calendarText("item(s) could not be removed", "elemento(s) no se pudieron quitar")) } }
            if trash {
                let sem = DispatchSemaphore(value: 0)
                var ok = false
                TrashService.empty { ok = $0; sem.signal() }
                sem.wait()
                if !ok { problems.append(calendarText("Trash could not be emptied", "No se pudo vaciar la Papelera")) }
            }
            DispatchQueue.main.async {
                self.working = false
                let freed = max(0, (DiskInfo.read()?.available ?? 0) - before)
                self.message = calendarText("Freed about \(diskBytes(freed)).", "Liberados unos \(diskBytes(freed)).")
                    + (problems.isEmpty ? "" : "\n" + problems.prefix(5).joined(separator: "\n"))
                log("cleanup: removed \(gs.count) worktrees, emptied \(cs.count) caches, \(problems.count) problems")
                DiskService.shared.refresh(extra: ConfigStore.shared.config.diskFolders, force: true)
                let note = self.message
                self.scan()
                self.message = note
            }
        }
    }
}

// MARK: - Window and view

final class CleanupWindowController {
    static let shared = CleanupWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 660),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.title = calendarText("Cala · Free up space", "Cala · Limpiar espacio")
            w.contentView = NSHostingView(rootView: CleanupView(model: CleanupModel.shared))
            w.contentMinSize = NSSize(width: 600, height: 480)
            w.center()
            window = w
        }
        CleanupModel.shared.scan()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct CleanupView: View {
    @ObservedObject var model: CleanupModel

    private func ago(_ d: Date) -> String {
        let days = Int(Date().timeIntervalSince(d) / 86400)
        if days < 1 { return calendarText("today", "hoy") }
        return calendarText("\(days) d ago", "hace \(days) d")
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(calendarText("Free up space", "Limpiar espacio")).font(.system(size: 20, weight: .semibold))
                        Card {
                            VStack(alignment: .leading, spacing: 8) {
                                explain("eye", calendarText("Opening this window deletes nothing.", "Abrir esta ventana no borra nada."),
                                        calendarText("It only lists what takes space and whether it is safe to remove.", "Solo lista lo que ocupa espacio y si es seguro quitarlo."))
                                explain("checkmark.square", calendarText("You choose what goes.", "Tú eliges qué se va."),
                                        calendarText("Nothing is selected by default. Before anything is deleted you see the full list and the total, and you can cancel.", "No hay nada marcado por defecto. Antes de borrar ves la lista completa y el total, y puedes cancelar."))
                                explain("lock.shield", calendarText("Your work is protected.", "Tu trabajo está protegido."),
                                        calendarText("Worktrees with unsaved changes, or in use, cannot be selected. Git refuses to remove them anyway, and branches and commits are never deleted.", "Los worktrees con cambios sin guardar, o en uso, no se pueden marcar. Git los rechaza igualmente, y las ramas y los commits nunca se borran."))
                                explain("arrow.triangle.2.circlepath", calendarText("Caches come back by themselves.", "Las cachés vuelven solas."),
                                        calendarText("They are just downloads and build leftovers; the apps recreate them when needed.", "Son solo descargas y restos de compilación; las apps las recrean cuando hacen falta."))
                            }
                            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    SectionTitle(text: calendarText("Agent worktrees", "Worktrees de agentes"))
                    Card {
                        if model.groups.isEmpty {
                            Text(model.scanning ? calendarText("Looking for worktrees…", "Buscando worktrees…") : calendarText("No worktrees found.", "No se encontraron worktrees."))
                                .font(.system(size: 12)).foregroundStyle(.secondary).padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ForEach(Array(model.groups.sorted { ($0.bytes ?? -1) > ($1.bytes ?? -1) }.enumerated()), id: \.element.id) { i, g in
                            if i > 0 { RowDivider() }
                            worktreeRow(g)
                        }
                    }
                    HStack {
                        Text(calendarText("Removed with git: it refuses a worktree with unsaved changes, and branches stay.", "Se quitan con git: rechaza un worktree con cambios sin guardar y las ramas se conservan."))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        Button(calendarText("Select safe ones", "Seleccionar los seguros")) { model.selectSafe() }.disabled(model.working)
                    }
                    SectionTitle(text: calendarText("Trash", "Papelera"))
                    Card { trashRow }
                    SectionTitle(text: calendarText("Caches that regenerate", "Cachés que se regeneran"))
                    Card {
                        ForEach(Array(model.caches.enumerated()), id: \.element.id) { i, c in
                            if i > 0 { RowDivider() }
                            cacheRow(c)
                        }
                    }
                }
                .padding(24)
            }
            Divider()
            HStack(spacing: 12) {
                if model.scanning || model.working { ProgressView().controlSize(.small) }
                Text(model.message.isEmpty ? (model.working ? calendarText("Working…", "Trabajando…") : "") : model.message)
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(3)
                Spacer()
                Button(calendarText("Review and delete selected (\(diskBytes(model.selectedBytes)))…", "Revisar y eliminar lo seleccionado (\(diskBytes(model.selectedBytes)))…")) { model.removeSelected() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.working || (model.selectedGroups.isEmpty && model.selectedCaches.isEmpty && !model.trashSelected))
            }
            .padding(14)
        }
        .frame(minWidth: 600, minHeight: 480)
    }

    private func explain(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).frame(width: 18).foregroundStyle(.secondary).padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5, weight: .semibold))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func check(_ id: String, enabled: Bool) -> some View {
        Toggle("", isOn: Binding(get: { model.selected.contains(id) }, set: { on in
            if on { model.selected.insert(id) } else { model.selected.remove(id) }
        })).labelsHidden().toggleStyle(.checkbox).disabled(!enabled || model.working)
    }

    private func subtitle(_ g: WorktreeGroup) -> String {
        var parts: [String] = [g.repoName]
        if let b = g.branch { parts.append(b) }
        if let d = g.lastCommit { parts.append(calendarText("last commit ", "último commit ") + ago(d)) }
        if !g.children.isEmpty { parts.append(calendarText("includes \(g.children.count) inner worktrees", "incluye \(g.children.count) worktrees internos")) }
        return parts.joined(separator: " · ")
    }

    private func worktreeRow(_ g: WorktreeGroup) -> some View {
        HStack(spacing: 12) {
            check(g.id, enabled: g.safe)
            VStack(alignment: .leading, spacing: 3) {
                Text(g.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(subtitle(g)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let reason = g.reason {
                Text(reason).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.orange)
            } else if g.checked {
                Text(g.integrated ? calendarText("Merged", "Integrado") : calendarText("Safe", "Seguro")).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.green)
            } else {
                ProgressView().controlSize(.small).scaleEffect(0.7)
            }
            Text(g.bytes.map(diskBytes) ?? "…").font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .help(g.path)
    }

    private var trashRow: some View {
        HStack(spacing: 12) {
            check(CleanupModel.trashID, enabled: (model.trashCount ?? 0) > 0)
            VStack(alignment: .leading, spacing: 3) {
                Text(calendarText("Empty the Trash", "Vaciar la Papelera")).font(.system(size: 13, weight: .medium))
                Text(trashNote).font(.system(size: 11)).foregroundStyle(model.trashDenied ? .orange : .secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if model.trashChecking {
                ProgressView().controlSize(.small).scaleEffect(0.7)
            } else if model.trashCount == nil && !model.trashDenied {
                Button(calendarText("Check", "Comprobar")) { model.checkTrash() }
            } else if model.trashDenied {
                Button(calendarText("Open Automation settings", "Abrir Automatización")) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
                }
            } else if let n = model.trashCount {
                Text(calendarText("\(n) items", "\(n) elementos")).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var trashNote: String {
        if model.trashDenied { return calendarText("Cala needs permission to control Finder to count and empty the Trash.", "Cala necesita permiso para controlar Finder y poder contar y vaciar la Papelera.") }
        if let n = model.trashCount {
            return n == 0 ? calendarText("The Trash is empty.", "La Papelera está vacía.") : calendarText("Deletes everything in the Trash for good.", "Borra para siempre todo lo que hay en la Papelera.")
        }
        return calendarText("Press Check to count the items. The first time, macOS asks to let Cala control Finder.", "Pulsa Comprobar para contar los elementos. La primera vez, macOS pregunta si dejas que Cala controle Finder.")
    }

    private func cacheRow(_ c: CacheItem) -> some View {
        HStack(spacing: 12) {
            check(c.id, enabled: true)
            VStack(alignment: .leading, spacing: 3) {
                Text(c.name).font(.system(size: 13, weight: .medium))
                Text(c.note).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Text(c.bytes.map(diskBytes) ?? "…").font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .help(c.path)
    }
}

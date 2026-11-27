import CryptoKit
import Foundation

/// Identity of one cached message body. A body is only reused for the same account, mailbox, UIDVALIDITY epoch and UID,
/// read by the same sanitizer/format version.
struct MailBodyKey: Hashable {
    /// Bump whenever MailMIME.content's output (sanitizer, inline images) or the stored format changes.
    static let formatVersion = 1

    let account: String
    let mailbox: String
    let validity: UInt32
    let uid: UInt32
    var format: Int = MailBodyKey.formatVersion

    init(account: String, mailbox: String = "INBOX", validity: UInt32, uid: UInt32, format: Int = MailBodyKey.formatVersion) {
        self.account = account
        self.mailbox = mailbox
        self.validity = validity
        self.uid = uid
        self.format = format
    }

    init?(_ message: MailMessage) {
        guard let validity = message.uidValidity, message.uid > 0 else { return nil }
        self.init(account: message.accountID, validity: validity, uid: message.uid)
    }
}

/// Parsed message bodies (MailContent, never raw RFC 822): a small in-memory LRU plus a per-account disk store under
/// ~/Library/Caches/<bundle id>/Mail/<sha256(account)>/<sha256(mailbox)>/<validity>/<uid>.v<format>.json.
/// Directories are 0700 and files 0600, writes are atomic, the folder is excluded from backups, and each account keeps
/// at most `diskLimit` bytes and `maxAge` of bodies (least recently used goes first).
///
/// Thread-safe. Disk calls block on file I/O, so the app calls them off the main thread; the memory calls are cheap.
final class MailBodyCache: @unchecked Sendable {
    enum Source: String { case memory, disk }

    private struct Stored: Codable {
        let html: String?
        let text: String
    }

    private struct DiskEntry {
        var bytes: Int
        var used: Date
    }

    let directory: URL?
    let memoryLimit: Int
    let memoryCount: Int
    let diskLimit: Int
    let maxAge: TimeInterval
    private let now: () -> Date
    private let lock = NSLock()
    private var memory: [MailBodyKey: (content: MailContent, bytes: Int, tick: UInt64)] = [:]
    private var memoryBytes = 0
    private var tick: UInt64 = 0
    /// Per account folder path: relative file name -> size and last use. Built on first use of that account.
    private var disk: [String: [String: DiskEntry]] = [:]

    init(directory: URL?, memoryLimit: Int = 24 * 1024 * 1024, memoryCount: Int = 30,
         diskLimit: Int = 100 * 1024 * 1024, maxAge: TimeInterval = 30 * 24 * 3600, now: @escaping () -> Date = Date.init) {
        self.directory = directory
        self.memoryLimit = memoryLimit
        self.memoryCount = memoryCount
        self.diskLimit = diskLimit
        self.maxAge = maxAge
        self.now = now
    }

    /// ~/Library/Caches/<bundle id>/Mail
    static func defaultDirectory() -> URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        return caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "local.cala", isDirectory: true)
            .appendingPathComponent("Mail", isDirectory: true)
    }

    static func size(of content: MailContent) -> Int { (content.html?.utf8.count ?? 0) + content.text.utf8.count }

    // MARK: Memory

    func memoryContent(for key: MailBodyKey) -> MailContent? {
        lock.withLock {
            guard var entry = memory[key] else { return nil }
            tick += 1
            entry.tick = tick
            memory[key] = entry
            return entry.content
        }
    }

    /// Memory only (cheap; the disk copy is written separately with `store`).
    func rememberInMemory(_ content: MailContent, for key: MailBodyKey) { remember(content, for: key) }

    private func remember(_ content: MailContent, for key: MailBodyKey) {
        lock.withLock {
            let bytes = Self.size(of: content)
            guard bytes <= memoryLimit else { return }
            if let old = memory[key] { memoryBytes -= old.bytes }
            tick += 1
            memory[key] = (content, bytes, tick)
            memoryBytes += bytes
            while memoryBytes > memoryLimit || memory.count > memoryCount,
                  let oldest = memory.min(by: { $0.value.tick < $1.value.tick }) {
                memoryBytes -= oldest.value.bytes
                memory[oldest.key] = nil
            }
        }
    }

    // MARK: Memory + disk

    /// Memory first, then disk (a disk hit is promoted to memory).
    func content(for key: MailBodyKey) -> (content: MailContent, source: Source)? {
        if let content = memoryContent(for: key) { return (content, .memory) }
        guard let url = fileURL(for: key), let account = accountFolder(key.account)?.path else { return nil }
        let name = Self.relative(key)
        guard lock.withLock({ index(account)[name] != nil }) else { return nil }
        guard let data = try? Data(contentsOf: url), let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            lock.withLock { disk[account]?[name] = nil }
            return nil
        }
        let content = MailContent(html: stored.html, text: stored.text)
        touch(url, name: name, account: account)
        remember(content, for: key)
        return (content, .disk)
    }

    func contains(_ key: MailBodyKey) -> Bool {
        if lock.withLock({ memory[key] != nil }) { return true }
        guard let account = accountFolder(key.account)?.path else { return false }
        return lock.withLock { index(account)[Self.relative(key)] != nil }
    }

    /// Stores in memory and, when a directory is set, on disk (atomic, 0600), then trims the account to its limits.
    func store(_ content: MailContent, for key: MailBodyKey) {
        remember(content, for: key)
        guard let url = fileURL(for: key), let account = accountFolder(key.account),
              let data = try? JSONEncoder().encode(Stored(html: content.html, text: content.text)) else { return }
        let folder = url.deletingLastPathComponent()
        guard Self.makePrivateDirectory(folder, excludeFrom: directory) else { return }
        let temporary = folder.appendingPathComponent(".\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else { return }
        guard rename(temporary.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            return
        }
        lock.withLock {
            var entries = index(account.path)
            entries[Self.relative(key)] = DiskEntry(bytes: data.count, used: now())
            disk[account.path] = entries
        }
        trim(account: account.path)
    }

    /// Forgets everything for an account (removed or disabled).
    func purge(account: String) {
        lock.withLock {
            for key in memory.keys where key.account == account { memoryBytes -= memory[key]!.bytes; memory[key] = nil }
            if let folder = accountFolder(account) { disk[folder.path] = [:] }
        }
        if let folder = accountFolder(account) { try? FileManager.default.removeItem(at: folder) }
    }

    /// The mailbox's UIDVALIDITY changed: bodies from every other epoch belong to different messages now.
    func purge(account: String, mailbox: String = "INBOX", keepingValidity validity: UInt32) {
        lock.withLock {
            for key in memory.keys where key.account == account && key.mailbox == mailbox && key.validity != validity {
                memoryBytes -= memory[key]!.bytes
                memory[key] = nil
            }
        }
        guard let box = mailboxFolder(account: account, mailbox: mailbox), let account = accountFolder(account) else { return }
        let keep = String(validity)
        let epochs = (try? FileManager.default.contentsOfDirectory(at: box, includingPropertiesForKeys: nil)) ?? []
        for epoch in epochs where epoch.lastPathComponent != keep { try? FileManager.default.removeItem(at: epoch) }
        let boxName = box.lastPathComponent + "/"
        lock.withLock {
            disk[account.path] = index(account.path).filter { !$0.key.hasPrefix(boxName) || $0.key.hasPrefix(boxName + keep + "/") }
        }
    }

    // MARK: Disk layout

    private static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func accountFolder(_ account: String) -> URL? {
        directory?.appendingPathComponent(Self.hash(account), isDirectory: true)
    }

    private func mailboxFolder(account: String, mailbox: String) -> URL? {
        accountFolder(account)?.appendingPathComponent(String(Self.hash(mailbox).prefix(32)), isDirectory: true)
    }

    /// Index key: "<mailbox hash>/<validity>/<uid>.v<format>.json", relative to the account folder.
    private static func relative(_ key: MailBodyKey) -> String {
        "\(hash(key.mailbox).prefix(32))/\(key.validity)/\(key.uid).v\(key.format).json"
    }

    func fileURL(for key: MailBodyKey) -> URL? {
        mailboxFolder(account: key.account, mailbox: key.mailbox)?
            .appendingPathComponent(String(key.validity), isDirectory: true)
            .appendingPathComponent("\(key.uid).v\(key.format).json")
    }

    /// Creates `folder` and its parents up to (and including) `root` with mode 0700; marks `root` excluded from backup.
    private static func makePrivateDirectory(_ folder: URL, excludeFrom root: URL?) -> Bool {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch { return false }
        guard let root else { return true }
        var current = folder
        while current.path.count >= root.path.count {
            try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: current.path)
            if current.path == root.path { break }
            current = current.deletingLastPathComponent()
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var excluded = root
        try? excluded.setResourceValues(values)
        return true
    }

    /// Caller holds `lock`. Lists the account's files once (size and modification date = last use).
    private func index(_ account: String) -> [String: DiskEntry] {
        if let entries = disk[account] { return entries }
        var entries: [String: DiskEntry] = [:]
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        if let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: account), includingPropertiesForKeys: keys) {
            for case let url as URL in walker where url.pathExtension == "json" {
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
                let parts = url.pathComponents.suffix(3)
                guard parts.count == 3 else { continue }
                entries[parts.joined(separator: "/")] = DiskEntry(bytes: values.fileSize ?? 0, used: values.contentModificationDate ?? .distantPast)
            }
        }
        disk[account] = entries
        return entries
    }

    private func touch(_ url: URL, name: String, account: String) {
        let date = now()
        try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        lock.withLock {
            var entries = index(account)
            entries[name]?.used = date
            disk[account] = entries
        }
    }

    /// Drops files older than `maxAge`, then the least recently used until the account is under `diskLimit`.
    func trim(account folder: String) {
        let doomed: [String] = lock.withLock {
            var entries = index(folder)
            let cutoff = now().addingTimeInterval(-maxAge)
            var remove = entries.filter { $0.value.used < cutoff }.map(\.key)
            for name in remove { entries[name] = nil }
            var total = entries.values.reduce(0) { $0 + $1.bytes }
            if total > diskLimit {
                for (name, entry) in entries.sorted(by: { $0.value.used < $1.value.used }) {
                    guard total > diskLimit * 9 / 10 else { break }
                    remove.append(name)
                    entries[name] = nil
                    total -= entry.bytes
                }
            }
            disk[folder] = entries
            return remove
        }
        for name in doomed { try? FileManager.default.removeItem(atPath: folder + "/" + name) }
    }

    /// Disk bytes used by an account (for checks and logs).
    func diskBytes(account: String) -> Int {
        guard let folder = accountFolder(account)?.path else { return 0 }
        return lock.withLock { index(folder).values.reduce(0) { $0 + $1.bytes } }
    }
}

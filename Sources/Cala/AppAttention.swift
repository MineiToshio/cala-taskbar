import AppKit

/// Running apps asking for attention (NSApplication.requestUserAttention sets LaunchServices' LSWantsAttention).
/// The hidden native Dock no longer bounces (DockControl writes `no-bouncing` so it never opens itself), so the bar
/// shows that cue instead. Read through LaunchServices' private SPI, which needs no permission and keeps reporting
/// with `no-bouncing` on. If the symbols are missing it does nothing (logged once). Polls only while the bar runs.
final class AppAttention: ObservableObject {
    static let shared = AppAttention()

    /// Process ids whose bar icon shows the cue (see AttentionCue for how long it lasts).
    @Published private(set) var pids: Set<pid_t> = []

    private typealias CopyRunning = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias CopyItem = @convention(c) (Int32, CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
    private struct SPI { let running: CopyRunning; let item: CopyItem }

    private static let session: Int32 = -2 // kLSDefaultSessionID
    private static let spi: SPI? = {
        guard let cs = dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_LAZY),
              let running = dlsym(cs, "_LSCopyRunningApplicationArray"),
              let item = dlsym(cs, "_LSCopyApplicationInformationItem") else {
            log("attention: LaunchServices SPI unavailable, bar attention cue off")
            return nil
        }
        return SPI(running: unsafeBitCast(running, to: CopyRunning.self), item: unsafeBitCast(item, to: CopyItem.self))
    }()

    private let queue = DispatchQueue(label: "cala.attention", qos: .utility)
    private var timer: DispatchSourceTimer?
    /// Bumped on every start/stop so a poll still in flight cannot publish into a later run.
    private var generation = 0
    private var cue = AttentionCue.State()

    /// Main thread.
    func start() {
        guard timer == nil, let spi = Self.spi else { return }
        generation += 1
        let gen = generation
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 0.3, leeway: .milliseconds(50))
        t.setEventHandler { [weak self] in
            let wanting = Self.wanting(spi)
            DispatchQueue.main.async { self?.publish(wanting, gen: gen) }
        }
        timer = t
        t.resume()
    }

    /// Main thread.
    func stop() {
        timer?.cancel()
        timer = nil
        generation += 1
        cue = AttentionCue.State()
        if !pids.isEmpty { pids = [] }
    }

    /// One read, outside polling (DockControl: decide whether a Dock restart is needed to stop a bounce already going).
    static func anyAppWantsAttention() -> Bool {
        guard let spi else { return false }
        return !wanting(spi).isEmpty
    }

    /// Regular apps that want attention right now. The app list is read every poll (about 0.2 ms for 70 processes),
    /// so launches, quits and activation-policy changes are always current. Values are type-checked before use:
    /// the SPI returns untyped CF objects.
    private static func wanting(_ spi: SPI) -> Set<pid_t> {
        func item(_ asn: CFTypeRef, _ key: String) -> CFTypeRef? { spi.item(session, asn, key as CFString)?.takeRetainedValue() }
        func string(_ v: CFTypeRef?) -> String? {
            guard let v, CFGetTypeID(v) == CFStringGetTypeID() else { return nil }
            return (v as! CFString) as String
        }
        func number(_ v: CFTypeRef?) -> Int32? {
            guard let v, CFGetTypeID(v) == CFNumberGetTypeID() else { return nil }
            var out: Int32 = 0
            return CFNumberGetValue((v as! CFNumber), .sInt32Type, &out) ? out : nil
        }
        func isTrue(_ v: CFTypeRef?) -> Bool {
            guard let v, CFGetTypeID(v) == CFBooleanGetTypeID() else { return false }
            return CFBooleanGetValue((v as! CFBoolean))
        }
        guard let list = spi.running(session)?.takeRetainedValue() else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        var out = Set<pid_t>()
        for i in 0..<CFArrayGetCount(list) {
            guard let raw = CFArrayGetValueAtIndex(list, i) else { continue }
            let asn = Unmanaged<CFTypeRef>.fromOpaque(raw).takeUnretainedValue()
            guard string(item(asn, "ApplicationType")) == "Foreground",
                  let pid = number(item(asn, "pid")), pid != me,
                  isTrue(item(asn, "LSWantsAttention")) else { continue }
            out.insert(pid)
        }
        return out
    }

    private func publish(_ wanting: Set<pid_t>, gen: Int) {
        guard gen == generation else { return }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let next = AttentionCue.update(&cue, wanting: wanting, frontmost: front, now: ProcessInfo.processInfo.systemUptime)
        guard next != pids else { return }
        let change = AttentionCue.changes(from: pids, to: next)
        for pid in change.started { log("attention: \(name(pid)) on") }
        for pid in change.stopped { log("attention: \(name(pid)) off") }
        pids = next
    }

    private func name(_ pid: pid_t) -> String {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "pid \(pid)"
    }
}

import AppKit
import IOKit.ps
import CoreAudio
import CoreWLAN
import CoreLocation
import OpenDirectory

let trayBatt = "__t_batt", trayWifi = "__t_wifi", trayVol = "__t_vol"
let trayMail = "__t_mail"

enum SystemTray {
    /// `charging` = on AC power; `isCharging` = actually taking charge (false when full on AC).
    static func battery() -> (pct: Int, charging: Bool, isCharging: Bool)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  let cur = d[kIOPSCurrentCapacityKey] as? Int, let mx = d[kIOPSMaxCapacityKey] as? Int, mx > 0
            else { continue }
            let state = d[kIOPSPowerSourceStateKey] as? String
            return (cur * 100 / mx, state == kIOPSACPowerValue, (d[kIOPSIsChargingKey] as? Bool) ?? false)
        }
        return nil
    }

    static func rssi() -> Int { CWWiFiClient.shared().interface()?.rssiValue() ?? 0 }
    /// -50 dBm or better = full, -90 dBm or worse = empty.
    static func signal(_ rssi: Int) -> Double { rssi == 0 ? 0 : max(0, min(1, Double(rssi + 90) / 40)) }
    static func wifiOn() -> Bool? { CWWiFiClient.shared().interface()?.powerOn() }
    static func wifiConnected() -> Bool {
        guard let i = CWWiFiClient.shared().interface() else { return false }
        return i.powerOn() && (i.ssid() != nil || i.rssiValue() != 0)
    }

    private static func device() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                           mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id) == noErr else { return nil }
        return id
    }
    private static func addr(_ sel: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }
    static func volume() -> Float? {
        guard let d = device() else { return nil }
        var v: Float32 = 0; var size = UInt32(4); var a = addr(AudioObjectPropertySelector(0x766D7663))
        return AudioObjectGetPropertyData(d, &a, 0, nil, &size, &v) == noErr ? v : nil
    }
    static func setVolume(_ v: Float) {
        guard let d = device() else { return }
        var x = max(0, min(1, v)); var a = addr(AudioObjectPropertySelector(0x766D7663))
        AudioObjectSetPropertyData(d, &a, 0, nil, 4, &x)
        if x > 0 && muted() { setMuted(false) }
    }
    static func muted() -> Bool {
        guard let d = device() else { return false }
        var m: UInt32 = 0; var size = UInt32(4); var a = addr(kAudioDevicePropertyMute)
        return AudioObjectGetPropertyData(d, &a, 0, nil, &size, &m) == noErr && m != 0
    }
    static func setMuted(_ on: Bool) {
        guard let d = device() else { return }
        var m: UInt32 = on ? 1 : 0; var a = addr(kAudioDevicePropertyMute)
        AudioObjectSetPropertyData(d, &a, 0, nil, 4, &m)
    }
}

final class WifiInfo {
    static let shared = WifiInfo()
    var nearby: [(ssid: String, rssi: Int, secure: Bool)] = []
    var objects: [String: CWNetwork] = [:]
    let loc = CLLocationManager()
    private let scanQueue = DispatchQueue(label: "local.cala.wifi.scan", qos: .utility)
    private var scanning = false
    private var runID: UUID?

    func start() {
        guard runID == nil else { return }
        runID = UUID()
        scan()
    }

    func stop() {
        runID = nil
        nearby.removeAll()
        objects.removeAll()
    }

    func requestLocation() {
        if loc.authorizationStatus == .notDetermined { loc.requestWhenInUseAuthorization() }
    }
    var current: String? { CWWiFiClient.shared().interface()?.ssid() }
    var known: [String] {
        let profiles = CWWiFiClient.shared().interface()?.configuration()?.networkProfiles.array as? [CWNetworkProfile] ?? []
        return profiles.compactMap(\.ssid)
    }
    func scan() {
        guard let runID, !scanning, let i = CWWiFiClient.shared().interface(), i.powerOn() else { return }
        scanning = true
        scanQueue.async {
            let nets = (try? i.scanForNetworks(withSSID: nil)) ?? []
            var seen = Set<String>(); var out: [(String, Int, Bool)] = []; var objs: [String: CWNetwork] = [:]
            for n in nets.sorted(by: { $0.rssiValue > $1.rssiValue }) {
                guard let s = n.ssid, !s.isEmpty, seen.insert(s).inserted else { continue }
                out.append((s, n.rssiValue, !n.supportsSecurity(.none))); objs[s] = n
            }
            DispatchQueue.main.async {
                self.scanning = false
                guard self.runID == runID else { self.scan(); return }
                self.nearby = out; self.objects = objs
            }
        }
    }
    func connect(_ ssid: String) {
        guard let runID, let i = CWWiFiClient.shared().interface() else { return }
        let n = objects[ssid]
        DispatchQueue.global(qos: .userInitiated).async {
            let connected = n.map { (try? i.associate(to: $0, password: nil)) != nil } ?? false
            DispatchQueue.main.async {
                if self.runID == runID, !connected { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.wifi-settings-extension")!) }
            }
        }
    }
}

// MARK: - Bluetooth / brillo / teclado / usuarios

import IOBluetooth
import CoreBluetooth
import Carbon

enum Bluetooth {
    private final class ConnectionTarget: NSObject {
        @objc func connectionComplete(_ device: IOBluetoothDevice, status: IOReturn) {}
    }
    private static let connectionTarget = ConnectionTarget()
    private typealias GetFn = @convention(c) () -> Int32
    private typealias SetFn = @convention(c) (Int32) -> Void
    private static let h = dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_LAZY)
    /// IOBluetooth can block the calling thread for as long as macOS has no answer for the Bluetooth permission (a fresh
    /// install, or right after the permission was reset). Called on the main thread, that froze the whole app at launch.
    /// So it is only used on its own serial queue, results are cached, and nothing runs before the permission is granted.
    static var allowed: Bool { CBManager.authorization == .allowedAlways }
    private static let queue = DispatchQueue(label: "Cala.bluetooth", qos: .utility)
    private static var inFlight = false                      // main thread only
    private static var cachedOn = false                      // main thread only
    private static var cachedDevices: [(name: String, addr: String, connected: Bool)] = []

    /// Last known power state; asks for a fresh one in the background.
    static var on: Bool { refresh(); return cachedOn }
    /// Last known paired devices; asks for a fresh list in the background.
    static func devices() -> [(name: String, addr: String, connected: Bool)] { refresh(); return cachedDevices }

    private static func refresh() {
        guard allowed else { cachedOn = false; cachedDevices = []; return }
        guard !inFlight else { return }
        inFlight = true
        queue.async {
            var power = false
            if let h, let f = dlsym(h, "IOBluetoothPreferenceGetControllerPowerState") { power = unsafeBitCast(f, to: GetFn.self)() != 0 }
            let d = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
            let list = d.map { ($0.name ?? $0.addressString ?? tx("Device", "Dispositivo"), $0.addressString ?? "", $0.isConnected()) }
            DispatchQueue.main.async { cachedOn = power; cachedDevices = list; inFlight = false }
        }
    }
    static func set(_ v: Bool) {
        guard allowed else { return }
        cachedOn = v
        queue.async {
            guard let h, let f = dlsym(h, "IOBluetoothPreferenceSetControllerPowerState") else { return }
            unsafeBitCast(f, to: SetFn.self)(v ? 1 : 0)
        }
    }
    static func toggle(addr: String) {
        guard allowed else { return }
        DispatchQueue.main.async {
            guard let d = IOBluetoothDevice(addressString: addr) else { return }
            // closeConnection() is synchronous: keep it off the main thread. Opening is async, with its callback on main.
            if d.isConnected() { DispatchQueue.global().async { d.closeConnection() } } else { d.openConnection(connectionTarget) }
        }
    }
}

enum Brightness {
    private typealias GetFn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (UInt32, Float) -> Int32
    private static let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    static func get() -> Float? {
        guard let h, let f = dlsym(h, "DisplayServicesGetBrightness") else { return nil }
        var v: Float = 0
        return unsafeBitCast(f, to: GetFn.self)(CGMainDisplayID(), &v) == 0 ? v : nil
    }
    static func set(_ v: Float) {
        guard let h, let f = dlsym(h, "DisplayServicesSetBrightness") else { return }
        _ = unsafeBitCast(f, to: SetFn.self)(CGMainDisplayID(), max(0.02, min(1, v)))
    }
}

enum Keyboard {
    struct Src: Identifiable { let id: String; let name: String; let code: String; let ref: TISInputSource }

    private static func prop(_ s: TISInputSource, _ k: CFString) -> AnyObject? {
        TISGetInputSourceProperty(s, k).map { Unmanaged<AnyObject>.fromOpaque($0).takeUnretainedValue() }
    }
    private static func make(_ s: TISInputSource) -> Src {
        let id = prop(s, kTISPropertyInputSourceID) as? String ?? UUID().uuidString
        let name = prop(s, kTISPropertyLocalizedName) as? String ?? id
        let lang = (prop(s, kTISPropertyInputSourceLanguages) as? [String])?.first ?? "??"
        return Src(id: id, name: name, code: String(lang.prefix(2)).uppercased(), ref: s)
    }
    static func all() -> [Src] {
        let f = [kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource!,
                 kTISPropertyInputSourceIsSelectCapable: true] as CFDictionary
        guard let l = TISCreateInputSourceList(f, false)?.takeRetainedValue() as? [TISInputSource] else { return [] }
        return l.map(make)
    }
    static func current() -> Src? { TISCopyCurrentKeyboardInputSource().map { make($0.takeRetainedValue()) } }
    static func select(_ s: Src) { TISSelectInputSource(s.ref) }
}

enum Users {
    struct U { let name: String; let full: String; let photo: NSImage? }

    private static func run(_ args: [String]) -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/dscl"); p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return String(data: d, encoding: .utf8) ?? ""
    }

    private static func record(_ name: String, _ attrs: [String]) -> ODRecord? {
        guard let node = try? ODNode(session: ODSession.default(), type: ODNodeType(kODNodeTypeLocalNodes)) else { return nil }
        return try? node.record(withRecordType: kODRecordTypeUsers, name: name, attributes: attrs)
    }

    /// Reads the account picture straight from OpenDirectory as bytes (JPEGPhoto), or the Picture file as a fallback.
    static func photo(_ name: String) -> NSImage? {
        guard let r = record(name, [kODAttributeTypeJPEGPhoto, kODAttributeTypePicture]) else { return nil }
        if let data = (try? r.values(forAttribute: kODAttributeTypeJPEGPhoto))?.first as? Data,
           let img = NSImage(data: data), img.isValid { return img }
        if let path = (try? r.values(forAttribute: kODAttributeTypePicture))?.first as? String,
           let img = NSImage(contentsOfFile: path), img.isValid { return img }
        return nil
    }

    private static let cacheLock = NSLock()
    private static var cachedList: [U]?
    private static var photoCache: [String: NSImage] = [:]

    /// Last loaded list, so the panel can draw at its final size the moment it opens.
    static var cached: [U]? { cacheLock.lock(); defer { cacheLock.unlock() }; return cachedList }

    /// Cached photo; on a miss it is read again, so a transient failure is retried next time.
    static func cachedPhoto(_ name: String) -> NSImage? {
        cacheLock.lock(); let hit = photoCache[name]; cacheLock.unlock()
        if let hit { return hit }
        guard let img = photo(name) else { return nil }
        cacheLock.lock(); photoCache[name] = img; cacheLock.unlock()
        return img
    }

    static func list() -> [U] {
        let loaded: [U] = run([".", "list", "/Users", "UniqueID"]).components(separatedBy: "\n").compactMap { line in
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count == 2, let uid = Int(f[1]), uid >= 500 else { return nil }
            let name = String(f[0])
            let real = (try? record(name, [kODAttributeTypeFullName])?.values(forAttribute: kODAttributeTypeFullName))??.first as? String
            let full = real?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return U(name: name, full: full.isEmpty ? name : full, photo: cachedPhoto(name))
        }
        if !loaded.isEmpty { cacheLock.lock(); cachedList = loaded; cacheLock.unlock() }
        return loaded
    }
    // Accessed only on the main queue; kept set through verification and any lock fallback.
    private static var switchAttempt: ModuleCancellation?
    private static var switchSucceeded = false

    static func cancelSwitch() {
        switchAttempt?.cancel()
        switchAttempt = nil
    }

    /// Ask loginwindow to show the target user's login screen, then verify that our session left the console.
    static func switchTo(_ name: String) {
        guard Thread.isMainThread else { DispatchQueue.main.async { switchTo(name) }; return }
        guard ModuleRegistry.shared.isRunning(.tray) else { return }
        guard switchAttempt == nil else { log("switch user: request ignored, switch in progress"); return }
        let attempt = ModuleCancellation()
        switchAttempt = attempt
        switchSucceeded = false
        DispatchQueue.global(qos: .userInitiated).async {
            defer {
                DispatchQueue.main.async {
                    if switchAttempt === attempt { switchAttempt = nil }
                }
            }
            func elapsed(_ start: ContinuousClock.Instant) -> Double {
                let d = start.duration(to: .now).components
                return Double(d.seconds) + Double(d.attoseconds) / 1e18
            }
            func unknown() { log("switch user: unknown, probably switched after delayed verification; not locking") }
            func fail(_ reason: String, since start: ContinuousClock.Instant? = nil) {
                DispatchQueue.main.async {
                    guard switchAttempt === attempt, !attempt.isCancelled, !switchSucceeded else { return }
                    if let start, elapsed(start) > 6 { unknown(); return }
                    switchAttempt = nil // Consume this attempt before firing the fallback.
                    log("switch user: \(reason), locking instead")
                    lockScreen()
                }
            }
            guard !attempt.isCancelled else { return }
            guard let login = dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_NOW) else {
                fail("login.framework unavailable"); return
            }
            defer { dlclose(login) }
            guard let switchSym = dlsym(login, "SACSwitchToUser") else {
                fail("SACSwitchToUser unavailable"); return
            }
            guard let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW) else {
                fail("SkyLight unavailable for verification"); return
            }
            defer { dlclose(sky) }
            guard let listSym = dlsym(sky, "SLSCopySessionList") else {
                fail("SLSCopySessionList unavailable for verification"); return
            }
            typealias SwitchFn = @convention(c) (CFDictionary) -> Int32
            typealias ListFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
            let cid = CGSMainConnectionID()
            let list = unsafeBitCast(listSym, to: ListFn.self)
            func sessions() -> [[String: Any]] { list(cid)?.takeRetainedValue() as? [[String: Any]] ?? [] }
            guard let own = sessions().first(where: {
                ($0["kCGSSessionUserIDKey"] as? Int) == Int(getuid()) && ($0["kCGSSessionOnConsoleKey"] as? Bool) == true
            }), let sid = own["kCGSSessionIDKey"] as? Int else {
                fail("could not identify own console session"); return
            }

            // ControlCenter passes an OD attribute dump: dsAttrTypeStandard keys, array values.
            let wanted: [String] = [kODAttributeTypeMetaNodeLocation, kODAttributeTypeGUID, kODAttributeTypeJPEGPhoto,
                                   kODAttributeTypeNFSHomeDirectory, kODAttributeTypePassword, kODAttributeTypePrimaryGroupID,
                                   kODAttributeTypeFullName, kODAttributeTypeRecordName, kODAttributeTypeRecordType,
                                   kODAttributeTypeUniqueID, kODAttributeTypeUserShell]
            var dict: [String: Any] = [:]
            do {
                let node = try ODNode(session: ODSession.default(), type: ODNodeType(kODNodeTypeLocalNodes))
                let record = try node.record(withRecordType: kODRecordTypeUsers, name: name, attributes: wanted)
                for (key, value) in try record.recordDetails(forAttributes: wanted) {
                    guard let key = key as? String, key.hasPrefix("dsAttrTypeStandard:"), value is NSArray else {
                        fail("invalid OpenDirectory attribute"); return
                    }
                    dict[key] = value
                }
            } catch { fail("OpenDirectory lookup for \(name) failed: \(error)"); return }
            guard let names = dict[kODAttributeTypeRecordName] as? [String],
                  let first = names.first, !first.isEmpty, first == name else {
                fail("invalid OpenDirectory RecordName for \(name)"); return
            }
            do {
                _ = try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)
            } catch { fail("OpenDirectory record is not plist-serializable: \(error)"); return }

            guard !attempt.isCancelled else { return }
            let start = ContinuousClock.now
            let result = unsafeBitCast(switchSym, to: SwitchFn.self)(dict as CFDictionary)
            log("switch user: \(name) via SACSwitchToUser -> \(result)")
            guard result == 0 else { fail("SACSwitchToUser rejected request"); return }
            // Zero means accepted, not switched. A delayed wake may have missed the entire switch.
            repeat {
                Thread.sleep(forTimeInterval: 0.25)
                guard !attempt.isCancelled else { return }
                let own = sessions().first { ($0["kCGSSessionIDKey"] as? Int) == sid }
                if (own?["kCGSSessionOnConsoleKey"] as? Bool) == false {
                    DispatchQueue.main.sync {
                        if switchAttempt === attempt { switchSucceeded = true }
                    }
                    log("switch user: switched after \(String(format: "%.2f", elapsed(start))) s")
                    return
                }
                if elapsed(start) > 6 { unknown(); return }
            } while elapsed(start) < 3
            fail("switch not verified after 3 s (still on console or session data unavailable)", since: start)
        }
    }

    /// Ctrl+Cmd+Q: lock screen, where "Switch User" lives.
    static func lockScreen() {
        guard ModuleRegistry.shared.isRunning(.tray) else { return }
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: 12, keyDown: down)
            e?.flags = [.maskControl, .maskCommand]
            e?.post(tap: .cghidEventTap)
        }
    }
}

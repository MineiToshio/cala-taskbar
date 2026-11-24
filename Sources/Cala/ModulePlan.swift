import Foundation

enum ModuleID: String, CaseIterable, Codable {
    case bar, switcher, tray, zones
}

struct ModuleSet: Equatable {
    var bar: Bool
    var switcher: Bool
    var tray: Bool
    var zones: Bool

    static let none = ModuleSet(bar: false, switcher: false, tray: false, zones: false)

    subscript(id: ModuleID) -> Bool {
        switch id {
        case .bar: bar
        case .switcher: switcher
        case .tray: tray
        case .zones: zones
        }
    }
}

protocol CalaModule: AnyObject {
    var id: ModuleID { get }
    var isRunning: Bool { get }
    func start()
    func stop()
}

enum ModulePlan {
    enum Source: String { case stored, migrated, provisional }
    enum Permission { case accessibility, screenRecording }

    struct Resolution: Equatable {
        let set: ModuleSet
        let source: Source
        let persist: Bool
        let needsOnboarding: Bool
    }

    static func resolve(_ stored: ModuleSet, chosen: Bool, onboardingCompleted: Bool, configExisted: Bool,
                        axTrusted: Bool) -> Resolution {
        let existing = onboardingCompleted || (configExisted && axTrusted)
        if chosen {
            return Resolution(set: stored, source: .stored, persist: false, needsOnboarding: !existing)
        }
        if existing {
            let migrated = ModuleSet(bar: true, switcher: stored.switcher, tray: true, zones: false)
            return Resolution(set: migrated, source: .migrated, persist: true, needsOnboarding: false)
        }
        let provisional = ModuleSet(bar: true, switcher: true, tray: true, zones: false)
        return Resolution(set: provisional, source: .provisional, persist: false, needsOnboarding: true)
    }

    static func effective(_ desired: ModuleSet) -> ModuleSet {
        var set = desired
        set.tray = desired.tray && desired.bar
        return set
    }

    static func startOrder(from old: ModuleSet, to new: ModuleSet) -> (stop: [ModuleID], start: [ModuleID]) {
        let old = effective(old), new = effective(new)
        let stop: [ModuleID] = [.zones, .tray, .switcher, .bar]
        let start: [ModuleID] = [.bar, .tray, .switcher, .zones]
        return (stop.filter { old[$0] && !new[$0] }, start.filter { new[$0] && !old[$0] })
    }

    static func needsThumbnails(_ set: ModuleSet) -> Bool { set.bar || set.switcher }
    static func showsStatusItem(_ set: ModuleSet) -> Bool { !set.bar || set.zones }

    static func requiredPermissions(_ set: ModuleSet) -> [Permission] {
        if needsThumbnails(set) { return [.accessibility, .screenRecording] }
        return set.zones ? [.accessibility] : []
    }

    static func running(_ modules: some Sequence<any CalaModule>) -> ModuleSet {
        let active = Set(modules.filter(\.isRunning).map(\.id))
        return ModuleSet(bar: active.contains(.bar), switcher: active.contains(.switcher),
                         tray: active.contains(.tray), zones: active.contains(.zones))
    }

    static func startupLine(running: ModuleSet, source: Source) -> String {
        "modules: \(summary(running)) source=\(source.rawValue)"
    }

    static func summary(_ set: ModuleSet) -> String {
        let active = ModuleID.allCases.filter { set[$0] }.map(\.rawValue).joined(separator: ",")
        let off = ModuleID.allCases.filter { !set[$0] }.map(\.rawValue).joined(separator: ",")
        return "active=\(active.isEmpty ? "none" : active) off=\(off.isEmpty ? "none" : off)"
    }
}

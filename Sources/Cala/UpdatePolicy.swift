import Foundation

enum UpdatePolicy {
    enum Blocker: String, Equatable {
        case inactiveSession = "inactive session"
        case drag = "drag in progress"
        case zonesEditor = "Zones editor open"
        case settings = "Settings open"
        case onboarding = "onboarding in progress"
        case modal = "modal window open"
        case updater = "update in progress"
    }

    enum Decision: Equatable {
        case none
        case deferred(Blocker)
        case relaunch
    }

    static func decide(running: String?, disk: String?, blockers: [Blocker]) -> Decision {
        guard let running = components(running), let disk = components(disk),
              running.lexicographicallyPrecedes(disk) else { return .none }
        return blockers.first.map(Decision.deferred) ?? .relaunch
    }

    private static func components(_ version: String?) -> [UInt64]? {
        guard let version else { return nil }
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { part -> UInt64? in
            guard part.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
            return UInt64(part)
        }
        guard (1...3).contains(parts.count), numbers.count == parts.count else { return nil }
        return numbers + Array(repeating: 0, count: 3 - numbers.count)
    }
}

enum LoginItemPolicy {
    enum Status { case enabled, requiresApproval, missing, unknown }
    enum Rebind: Equatable { case none, register, replace }
    enum Issue: Equatable { case approval, registration, removal }

    struct Preference: Equatable {
        let desired: Bool
        let issue: Issue?
    }

    static func preference(saved: Bool?, registeredPath: String?, status: Status,
                           pointsToPreviousBundle: Bool = false) -> Preference {
        let desired = saved ?? (registeredPath != nil || status == .enabled || status == .requiresApproval)
        let issue: Issue?
        if desired {
            switch status {
            case .enabled: issue = pointsToPreviousBundle ? .registration : nil
            case .requiresApproval: issue = .approval
            case .missing, .unknown: issue = .registration
            }
        } else {
            issue = status == .enabled || status == .requiresApproval ? .removal : nil
        }
        return Preference(desired: desired, issue: issue)
    }

    static func rebind(desired: Bool, status: Status, registeredPath: String?, bundlePath: String,
                       firstSharedLaunch: Bool) -> Rebind {
        guard desired, registeredPath != bundlePath else { return .none }
        switch status {
        case .missing:
            return .register
        case .enabled where registeredPath != nil || firstSharedLaunch:
            return .replace
        default:
            return .none
        }
    }
}

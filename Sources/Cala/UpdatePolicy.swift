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

    static func version(_ plist: [String: Any]?) -> AppVersion? {
        guard let version = plist?["CFBundleShortVersionString"] as? String,
              let build = plist?["CFBundleVersion"] as? String else { return nil }
        return AppVersion(version: version, build: build)
    }

    static func decide(running: AppVersion?, disk: AppVersion?, blockers: [Blocker]) -> Decision {
        guard let running, let disk, running < disk else { return .none }
        return blockers.first.map(Decision.deferred) ?? .relaunch
    }

    static func restart(force: Bool, userStarted: Bool, blockers: [Blocker], autoAllowed: @autoclosure () -> Bool) -> Decision {
        if force { return .relaunch }
        if let blocker = blockers.first(where: { $0 != .updater && !(userStarted && $0 == .settings) }) {
            return .deferred(blocker)
        }
        if !userStarted && !autoAllowed() { return .deferred(.inactiveSession) }
        return .relaunch
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

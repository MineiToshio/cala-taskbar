import Foundation

func check<T: Equatable>(_ name: String, _ actual: T, _ expected: T) {
    guard actual == expected else {
        print("FAIL \(name): expected \(expected), got \(actual)")
        exit(1)
    }
    print("PASS \(name)")
}

check("higher numeric build", UpdatePolicy.decide(running: "9", disk: "10", blockers: []), .relaunch)
check("same build after relaunch", UpdatePolicy.decide(running: "10", disk: "10", blockers: []), .none)
check("older build", UpdatePolicy.decide(running: "10", disk: "9", blockers: []), .none)
check("dotted build", UpdatePolicy.decide(running: "10.1.9", disk: "10.2", blockers: []), .relaunch)
check("equivalent dotted build", UpdatePolicy.decide(running: "10", disk: "010.0.0", blockers: []), .none)
check("invalid disk build", UpdatePolicy.decide(running: "10", disk: "11..2", blockers: []), .none)
check("invalid running build", UpdatePolicy.decide(running: "+10", disk: "11", blockers: []), .none)
check("missing or incomplete bundle", UpdatePolicy.decide(running: "10", disk: nil, blockers: []), .none)
let blockers: [UpdatePolicy.Blocker] = [.inactiveSession, .drag, .zonesEditor, .settings, .onboarding, .modal, .updater]
for blocker in blockers {
    check(blocker.rawValue, UpdatePolicy.decide(running: "10", disk: "11", blockers: [blocker]), .deferred(blocker))
}
check("idle after deferral", UpdatePolicy.decide(running: "10", disk: "11", blockers: []), .relaunch)

let legacy = "/Users/example/Applications/Cala.app"
let shared = "/Applications/Cala.app"
let pending = LoginItemPolicy.Preference(desired: true, issue: .registration)
check("saved login intent survives a missing registration",
      LoginItemPolicy.preference(saved: true, registeredPath: nil, status: .missing), pending)
check("old registration path supplies intent for upgraded builds",
      LoginItemPolicy.preference(saved: nil, registeredPath: legacy, status: .missing), pending)
check("explicit off wins over a historical registration",
      LoginItemPolicy.preference(saved: false, registeredPath: legacy, status: .missing),
      LoginItemPolicy.Preference(desired: false, issue: nil))
check("a missing registration with no evidence defaults to off",
      LoginItemPolicy.preference(saved: nil, registeredPath: nil, status: .missing),
      LoginItemPolicy.Preference(desired: false, issue: nil))
check("the OS can require approval while the desired state stays on",
      LoginItemPolicy.preference(saved: true, registeredPath: legacy, status: .requiresApproval),
      LoginItemPolicy.Preference(desired: true, issue: .approval))
check("a failed replacement of an enabled old item offers a retry",
      LoginItemPolicy.preference(saved: true, registeredPath: legacy, status: .enabled, pointsToPreviousBundle: true),
      pending)
check("missing item after moving registers without unregistering",
      LoginItemPolicy.rebind(desired: true, status: .missing, registeredPath: legacy, bundlePath: shared,
                            firstSharedLaunch: true), .register)
check("enabled item at old path is replaced",
      LoginItemPolicy.rebind(desired: true, status: .enabled, registeredPath: legacy, bundlePath: shared,
                            firstSharedLaunch: true), .replace)
check("first shared launch can replace an enabled registration from an older build",
      LoginItemPolicy.rebind(desired: true, status: .enabled, registeredPath: nil, bundlePath: shared,
                            firstSharedLaunch: true), .replace)
check("an enabled item at the current path is left in place",
      LoginItemPolicy.rebind(desired: true, status: .enabled, registeredPath: shared, bundlePath: shared,
                            firstSharedLaunch: true), .none)
check("an item switched off in System Settings is left for the user to approve",
      LoginItemPolicy.rebind(desired: true, status: .requiresApproval, registeredPath: legacy, bundlePath: shared,
                            firstSharedLaunch: true), .none)
check("explicitly disabled items are never re-registered on a move",
      LoginItemPolicy.rebind(desired: false, status: .missing, registeredPath: legacy, bundlePath: shared,
                            firstSharedLaunch: true), .none)
check("an active item with a saved off preference offers a removal retry",
      LoginItemPolicy.preference(saved: false, registeredPath: shared, status: .enabled),
      LoginItemPolicy.Preference(desired: false, issue: .removal))
check("unknown Service Management status keeps the preference pending",
      LoginItemPolicy.preference(saved: true, registeredPath: legacy, status: .unknown), pending)
check("a registered path that has not moved does not trigger automatic registration",
      LoginItemPolicy.rebind(desired: true, status: .missing, registeredPath: shared, bundlePath: shared,
                            firstSharedLaunch: true), .none)

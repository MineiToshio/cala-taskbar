import Foundation

func check<T: Equatable>(_ name: String, _ actual: T, _ expected: T) {
    guard actual == expected else {
        print("FAIL \(name): expected \(expected), got \(actual)")
        exit(1)
    }
    print("PASS \(name)")
}

func version(_ marketing: String, _ build: String) -> AppVersion? {
    UpdatePolicy.version(["CFBundleShortVersionString": marketing, "CFBundleVersion": build])
}
let running = version("1.0.0", "999")
let next = version("1.1.0", "2")
check("marketing version outranks developer build", UpdatePolicy.decide(running: running, disk: next, blockers: []), .relaunch)
check("build tie breaker", UpdatePolicy.decide(running: running, disk: version("1.0.0", "1000"), blockers: []), .relaunch)
check("same build", UpdatePolicy.decide(running: next, disk: next, blockers: []), .none)
check("older marketing version", UpdatePolicy.decide(running: next, disk: running, blockers: []), .none)
check("invalid disk build", UpdatePolicy.decide(running: running, disk: version("1.1.0", "x"), blockers: []), .none)
check("incomplete bundle", UpdatePolicy.decide(running: running, disk: nil, blockers: []), .none)
let blockers: [UpdatePolicy.Blocker] = [.inactiveSession, .drag, .zonesEditor, .settings, .onboarding, .modal, .updater]
for blocker in blockers {
    check(blocker.rawValue, UpdatePolicy.decide(running: running, disk: next, blockers: [blocker]), .deferred(blocker))
}

var eligible = true
func restartGate() -> UpdatePolicy.Decision {
    UpdatePolicy.restart(force: false, userStarted: false, blockers: [.updater], autoAllowed: eligible)
}
check("automatic restart initially eligible", restartGate(), .relaunch)
eligible = false
check("automatic restart rechecks current eligibility after swap", restartGate(), .deferred(.inactiveSession))
check("late presentation or settings defers restart",
      UpdatePolicy.restart(force: false, userStarted: false, blockers: [.settings], autoAllowed: true), .deferred(.settings))
check("explicit restart while automatic installation is off",
      UpdatePolicy.restart(force: true, userStarted: false, blockers: [], autoAllowed: false), .relaunch)

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

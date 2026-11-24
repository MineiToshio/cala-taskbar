import Foundation

var passed = 0
var failed = 0
func check(_ result: Bool, _ name: String) {
    if result { passed += 1; print("PASS \(name)") }
    else { failed += 1; print("FAIL \(name)") }
}

let defaults = ModuleSet(bar: true, switcher: true, tray: true, zones: false)
let all = ModuleSet(bar: true, switcher: true, tray: true, zones: true)
let zonesOnly = ModuleSet(bar: false, switcher: false, tray: false, zones: true)
let switcherOnly = ModuleSet(bar: false, switcher: true, tray: false, zones: false)
let barOnly = ModuleSet(bar: true, switcher: false, tray: false, zones: false)
let orphanTray = ModuleSet(bar: false, switcher: false, tray: true, zones: false)

let fresh = ModulePlan.resolve(defaults, chosen: false, onboardingCompleted: false, configExisted: false, axTrusted: false)
check(fresh.set == .none && fresh.source == .provisional && !fresh.persist && fresh.needsOnboarding,
      "fresh install starts no module until onboarding is answered")
check(ModulePlan.startupLine(running: .none, source: .provisional) ==
      "modules: active=none off=bar,switcher,tray,zones source=provisional (waiting for onboarding)", "provisional startup log format")
// A fresh user who quit before choosing: config.json now exists and Accessibility may be on, but the welcome is pending.
let quitBeforeChoosing = ModulePlan.resolve(defaults, chosen: false, onboardingCompleted: false, onboardingPending: true,
                                            configExisted: true, axTrusted: true)
check(quitBeforeChoosing.set == .none && quitBeforeChoosing.source == .provisional && !quitBeforeChoosing.persist &&
      quitBeforeChoosing.needsOnboarding, "quitting before choosing shows the welcome again and starts nothing")
let pendingThenChosen = ModulePlan.resolve(zonesOnly, chosen: true, onboardingCompleted: true, onboardingPending: false,
                                           configExisted: true, axTrusted: false)
check(pendingThenChosen.set == zonesOnly && pendingThenChosen.source == .stored && !pendingThenChosen.needsOnboarding,
      "a saved choice is used as stored on the next launch")
let legacy = ModulePlan.resolve(defaults, chosen: false, onboardingCompleted: true, configExisted: true, axTrusted: false)
check(legacy.set == defaults && legacy.source == .migrated && legacy.persist && !legacy.needsOnboarding,
      "user from before the feature (onboardingCompleted, no modulesChosen) is migrated with bar, switcher and tray on")
let migrated = ModulePlan.resolve(zonesOnly, chosen: false, onboardingCompleted: true, configExisted: false, axTrusted: false)
check(migrated.set == ModuleSet(bar: true, switcher: false, tray: true, zones: false) &&
      migrated.source == .migrated && migrated.persist && !migrated.needsOnboarding, "migration preserves disabled switcher and enables bar and tray")
let provisional = ModulePlan.resolve(zonesOnly, chosen: false, onboardingCompleted: false, configExisted: true, axTrusted: false)
check(provisional.set == .none && provisional.source == .provisional && !provisional.persist && provisional.needsOnboarding,
      "prior config without Accessibility or completed onboarding waits for onboarding")
let completed = ModulePlan.resolve(all, chosen: false, onboardingCompleted: true, configExisted: false, axTrusted: false)
check(completed.set == defaults && completed.source == .migrated && completed.persist && !completed.needsOnboarding,
      "completed onboarding migrates bar, switcher and tray on and zones off")

for chosen in [false, true] {
    for done in [false, true] {
        for pending in [false, true] {
            for existed in [false, true] {
                for trusted in [false, true] {
                    let result = ModulePlan.resolve(all, chosen: chosen, onboardingCompleted: done, onboardingPending: pending,
                                                    configExisted: existed, axTrusted: trusted)
                    let existing = done || (!pending && existed && trusted)
                    let set = chosen ? all : existing ? defaults : ModuleSet.none
                    check(result.set == set && result.needsOnboarding == !existing &&
                          result.persist == (!chosen && existing) && result.source == (chosen ? .stored : existing ? .migrated : .provisional),
                          "resolution chosen=\(chosen) completed=\(done) pending=\(pending) configExisted=\(existed) axTrusted=\(trusted)")
                }
            }
        }
    }
}

check(ModulePlan.effective(orphanTray) == .none, "tray requires bar")
check(ModulePlan.startOrder(from: .none, to: all).start == [.bar, .tray, .switcher, .zones], "start order")
check(ModulePlan.startOrder(from: all, to: .none).stop == [.zones, .tray, .switcher, .bar], "stop order")
check(ModulePlan.startOrder(from: all, to: all).start.isEmpty && ModulePlan.startOrder(from: all, to: all).stop.isEmpty,
      "unchanged modules do not restart")
check(ModulePlan.needsThumbnails(barOnly) && ModulePlan.needsThumbnails(switcherOnly) && !ModulePlan.needsThumbnails(zonesOnly),
      "bar and switcher share thumbnails")
check(!ModulePlan.showsStatusItem(defaults) && ModulePlan.showsStatusItem(all) && ModulePlan.showsStatusItem(.none),
      "status item when bar is off or zones is on")
check(ModulePlan.requiredPermissions(barOnly) == [.accessibility, .screenRecording], "bar permissions")
check(ModulePlan.requiredPermissions(switcherOnly) == [.accessibility, .screenRecording], "switcher permissions")
check(ModulePlan.requiredPermissions(zonesOnly) == [.accessibility], "zones permissions")
check(ModulePlan.requiredPermissions(all) == [.accessibility, .screenRecording], "permission union")
check(ModulePlan.requiredPermissions(.none).isEmpty, "no module permissions")
check(ModulePlan.startupLine(running: defaults, source: .migrated) == "modules: active=bar,switcher,tray off=zones source=migrated",
      "migrated startup log format")
check(ModulePlan.startupLine(running: zonesOnly, source: .stored) == "modules: active=zones off=bar,switcher,tray source=stored",
      "running zones-only startup log format")

// Onboarding "What do you want to use?" → the module keys it writes.
let onlyZones = ModulePlan.onboardingChoice(bar: false, zones: true, current: defaults, chosen: false)
check(onlyZones == zonesOnly, "onboarding only Zones writes bar, switcher and tray off, zones on")
check(onlyZones.map(ModulePlan.requiredPermissions) == [.accessibility], "onboarding only Zones asks for Accessibility only")
check(onlyZones.map(ModulePlan.showsStatusItem) == true && onlyZones.map { ModulePlan.effective($0).bar } == false,
      "onboarding only Zones lives in the status item without a bar")
check(onlyZones.map(ModulePlan.onboardingPages) == [.welcome, .modules, .essentials, .ready], "onboarding only Zones skips the tray extras")
let onlyBar = ModulePlan.onboardingChoice(bar: true, zones: false, current: defaults, chosen: false)
check(onlyBar == defaults, "onboarding only Bar writes today's bar, switcher and tray, zones off")
check(onlyBar.map(ModulePlan.requiredPermissions) == [.accessibility, .screenRecording], "onboarding only Bar asks for today's permissions")
check(onlyBar.map(ModulePlan.showsStatusItem) == false, "onboarding only Bar shows no status item")
check(onlyBar.map(ModulePlan.onboardingPages) == [.welcome, .modules, .essentials, .optional, .ready], "onboarding only Bar keeps every page")
let both = ModulePlan.onboardingChoice(bar: true, zones: true, current: defaults, chosen: false)
check(both == all, "onboarding both writes every module on")
check(both.map(ModulePlan.requiredPermissions) == [.accessibility, .screenRecording] && both.map(ModulePlan.showsStatusItem) == true,
      "onboarding both asks for the bar's permissions and shows the status item")
check(ModulePlan.onboardingChoice(bar: false, zones: false, current: defaults, chosen: false) == nil, "onboarding needs at least one choice")
let customized = ModuleSet(bar: true, switcher: false, tray: false, zones: false)
check(ModulePlan.onboardingChoice(bar: true, zones: true, current: customized, chosen: true) ==
      ModuleSet(bar: true, switcher: false, tray: false, zones: true), "reopened welcome keeps the user's tray and switcher")
check(ModulePlan.onboardingChoice(bar: true, zones: false, current: zonesOnly, chosen: true) == defaults,
      "reopened welcome turning the bar on brings its tray and switcher")
check(ModulePlan.onboardingChoice(bar: true, zones: false, current: customized, chosen: false) == defaults,
      "first welcome ignores provisional tray and switcher values")
check(ModulePlan.requiredPermissions(for: .zones) == [.accessibility] && ModulePlan.requiredPermissions(for: .tray).isEmpty &&
      ModulePlan.requiredPermissions(for: .bar) == [.accessibility, .screenRecording], "permissions per module")
check(ModulePlan.dependency(of: .tray) == .bar && ModulePlan.dependency(of: .switcher) == nil && ModulePlan.dependency(of: .zones) == nil,
      "only the tray depends on the bar")

final class TestModule: CalaModule {
    let id: ModuleID
    private(set) var isRunning = false

    init(_ id: ModuleID) { self.id = id }
    func start() { isRunning = true }
    func stop() { isRunning = false }
}

let bar = TestModule(.bar)
let zones = TestModule(.zones)
let registered: [any CalaModule] = [bar, zones]
let requested = ModulePlan.effective(zonesOnly)
check(requested.zones && ModulePlan.showsStatusItem(requested) &&
      ModulePlan.startupLine(running: ModulePlan.running(registered), source: .stored) == "modules: active=none off=bar,switcher,tray,zones source=stored",
      "requesting an inactive module shows the status item and reports no active modules")
zones.start()
check(ModulePlan.running(registered) == zonesOnly, "running set reflects only modules that started")

print("\(passed) PASS, \(failed) FAIL")
exit(failed == 0 ? 0 : 1)

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
check(fresh.set == defaults && fresh.source == .provisional && !fresh.persist && fresh.needsOnboarding, "fresh install needs onboarding")
let migrated = ModulePlan.resolve(zonesOnly, chosen: false, onboardingCompleted: true, configExisted: false, axTrusted: false)
check(migrated.set == ModuleSet(bar: true, switcher: false, tray: true, zones: false) &&
      migrated.source == .migrated && migrated.persist && !migrated.needsOnboarding, "migration preserves disabled switcher and enables bar and tray")
let provisional = ModulePlan.resolve(zonesOnly, chosen: false, onboardingCompleted: false, configExisted: true, axTrusted: false)
check(provisional.set == defaults && provisional.source == .provisional && !provisional.persist && provisional.needsOnboarding,
      "prior config without Accessibility or completed onboarding gets provisional switcher on")
let completed = ModulePlan.resolve(all, chosen: false, onboardingCompleted: true, configExisted: false, axTrusted: false)
check(completed.set == defaults && completed.source == .migrated && completed.persist && !completed.needsOnboarding,
      "completed onboarding migrates bar, switcher and tray on and zones off")

for chosen in [false, true] {
    for done in [false, true] {
        for existed in [false, true] {
            for trusted in [false, true] {
                let result = ModulePlan.resolve(all, chosen: chosen, onboardingCompleted: done, configExisted: existed, axTrusted: trusted)
                let existing = done || (existed && trusted)
                check(result.set == (chosen ? all : defaults) && result.needsOnboarding == !existing &&
                      result.persist == (!chosen && existing) && result.source == (chosen ? .stored : existing ? .migrated : .provisional),
                      "resolution chosen=\(chosen) completed=\(done) configExisted=\(existed) axTrusted=\(trusted)")
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

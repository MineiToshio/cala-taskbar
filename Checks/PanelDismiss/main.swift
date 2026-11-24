import Foundation

var failures = 0
func check(_ ok: Bool, _ name: String) {
    if !ok { failures += 1; print("FAIL \(name)") }
}

// Auto-hide with nothing open behaves as before: hides after the delay, not before, not under the pointer.
check(PanelPolicy.barShouldHide(autoHide: true, barHidden: false, pointerNearBar: false, panelPinsBar: false, secondsSinceInside: 0.6, delay: 0.5), "hides after delay")
check(!PanelPolicy.barShouldHide(autoHide: true, barHidden: false, pointerNearBar: false, panelPinsBar: false, secondsSinceInside: 0.4, delay: 0.5), "waits for delay")
check(!PanelPolicy.barShouldHide(autoHide: true, barHidden: false, pointerNearBar: true, panelPinsBar: false, secondsSinceInside: 9, delay: 0.5), "stays under pointer")
check(!PanelPolicy.barShouldHide(autoHide: false, barHidden: false, pointerNearBar: false, panelPinsBar: false, secondsSinceInside: 9, delay: 0.5), "no auto-hide setting")
check(!PanelPolicy.barShouldHide(autoHide: true, barHidden: true, pointerNearBar: false, panelPinsBar: false, secondsSinceInside: 9, delay: 0.5), "already hidden")

// An open panel pins its bar even with the pointer far away for a long time.
check(!PanelPolicy.barShouldHide(autoHide: true, barHidden: false, pointerNearBar: false, panelPinsBar: true, secondsSinceInside: 99, delay: 0.5), "panel pins bar")
check(PanelPolicy.keepsBarVisible(panelOpen: true, panelBarIsThisBar: true), "owner bar pinned")
check(!PanelPolicy.keepsBarVisible(panelOpen: true, panelBarIsThisBar: false), "other bar not pinned")
check(!PanelPolicy.keepsBarVisible(panelOpen: false, panelBarIsThisBar: true), "closed panel pins nothing")

// Only a press elsewhere closes; the pointer leaving is not even an input.
check(PanelPolicy.pressClosesPanel(panelOpen: true, .elsewhere), "outside press closes")
check(!PanelPolicy.pressClosesPanel(panelOpen: true, .inPanel), "inside press keeps")
check(!PanelPolicy.pressClosesPanel(panelOpen: true, .onBar), "bar press left to the bar (toggle / switch)")
check(!PanelPolicy.pressClosesPanel(panelOpen: true, .onMenu), "menu press keeps")
check(!PanelPolicy.pressClosesPanel(panelOpen: false, .elsewhere), "nothing open")

if failures > 0 { print("\(failures) panel policy check(s) failed"); exit(1) }
print("panel policy checks passed")

import Foundation

var failures = 0
func check(_ ok: Bool, _ name: String) {
    if !ok { failures += 1; print("FAIL \(name)") }
}
typealias B = DockNoBouncing.Backup

// Key absent: the backup records "absent", Cala writes true, giving it back deletes the key.
var step = DockNoBouncing.apply(current: nil, backup: B())
check(step.backup == B(saved: true, value: nil) && step.write == .set(true), "absent key backed up as nil, true written")
var back = DockNoBouncing.restore(current: true, backup: step.backup)
check(back.write == .remove && back.backup == B(), "absent key restored by deleting it")

// The user already had no-bouncing on: nothing to write either way, and it stays on.
step = DockNoBouncing.apply(current: true, backup: B())
check(step.backup == B(saved: true, value: true) && step.write == .keep, "user's true recorded, no write")
back = DockNoBouncing.restore(current: true, backup: step.backup)
check(back.write == .keep && back.backup == B(), "user's true kept on restore")

// The user had it explicitly off: restored to false, not deleted.
step = DockNoBouncing.apply(current: false, backup: B())
check(step.backup == B(saved: true, value: false) && step.write == .set(true), "user's false recorded")
back = DockNoBouncing.restore(current: true, backup: step.backup)
check(back.write == .set(false), "user's false restored")

// Applying again (relaunch, re-hide) never overwrites the first record with Cala's own value.
step = DockNoBouncing.apply(current: true, backup: B(saved: true, value: nil))
check(step.backup == B(saved: true, value: nil) && step.write == .keep, "re-apply keeps the original record")
step = DockNoBouncing.apply(current: false, backup: B(saved: true, value: nil))
check(step.backup == B(saved: true, value: nil) && step.write == .set(true), "re-apply after user turned it off keeps the record")

// Upgrade: a backup from a version that never wrote no-bouncing records the current value then.
step = DockNoBouncing.apply(current: nil, backup: B(saved: false, value: nil))
check(step.backup == B(saved: true, value: nil) && step.write == .set(true), "upgrade with key absent")
step = DockNoBouncing.apply(current: true, backup: B(saved: false, value: nil))
check(step.backup == B(saved: true, value: true) && step.write == .keep, "upgrade with user's true")

// Nothing recorded (old backup, never applied): restore leaves the key alone.
back = DockNoBouncing.restore(current: true, backup: B())
check(back.write == .keep && back.backup == B(), "no record, no restore")
// The user changed it since Cala wrote it: theirs to keep, record dropped.
back = DockNoBouncing.restore(current: false, backup: B(saved: true, value: nil))
check(back.write == .keep && back.backup == B(), "user's later change kept")
back = DockNoBouncing.restore(current: nil, backup: B(saved: true, value: false))
check(back.write == .keep && back.backup == B(), "user's later delete kept")

// Cala's hidden values with no backup (config lost or failed to load): a true found is Cala's own, recorded as absent.
step = DockNoBouncing.apply(current: true, backup: B(), calaHidDockUnrecorded: true)
check(step.backup == B(saved: true, value: nil) && step.write == .keep, "unrecorded Cala true recorded as absent")
step = DockNoBouncing.apply(current: false, backup: B(), calaHidDockUnrecorded: true)
check(step.backup == B(saved: true, value: false), "unrecorded Cala hide keeps an explicit false")
step = DockNoBouncing.apply(current: true, backup: B(saved: true, value: true), calaHidDockUnrecorded: true)
check(step.backup == B(saved: true, value: true), "an existing record is never replaced")

// Restore plans.
func input(_ hide: Bool = true, pending: Bool? = true, adopted: Bool = true, hidden: Bool = true, cala: Bool = true,
           bounce: Bool? = true, record: B = B(saved: true, value: nil)) -> DockRestore.Input {
    .init(hideBackupSaved: hide, overridePending: pending, includeAdopted: adopted, isHidden: hidden, hasCalaValues: cala,
          noBouncing: bounce, noBouncingRecord: record)
}
check(DockRestore.plan(input(false, record: B())) == nil, "nothing recorded, nothing to do")
var plan = DockRestore.plan(input())!
check(plan.restoreHide && plan.noBouncing == .remove && plan.needsSync && plan.restartDock, "full restore")
// Only no-bouncing changes (crash restore of a user-hidden Dock): still restarts so bouncing comes back.
plan = DockRestore.plan(input(pending: false, adopted: false))!
check(!plan.restoreHide && plan.noBouncing == .remove && plan.restartDock, "no-bouncing-only restore restarts the Dock")
plan = DockRestore.plan(input(false, record: B(saved: true, value: false)))!
check(!plan.restoreHide && plan.noBouncing == .set(false) && plan.restartDock, "restoring false restarts the Dock")
// Restoring the user's own true changes nothing: no restart needed.
plan = DockRestore.plan(input(false, record: B(saved: true, value: true)))!
check(plan.noBouncing == .keep && !plan.needsSync && !plan.restartDock, "user's true: no write, no restart")
// The user unhid the Dock themselves: their Dock settings stay, Cala's no-bouncing goes.
plan = DockRestore.plan(input(cala: false))!
check(!plan.restoreHide && plan.noBouncing == .remove && plan.restartDock, "user unhid: only no-bouncing restored")
// A failed synchronize keeps every backup for the next try; nothing written needs no sync.
plan = DockRestore.plan(input())!
check(!DockRestore.clearsRecords(plan, synced: false), "failed sync keeps backups")
check(DockRestore.clearsRecords(plan, synced: true), "synced restore clears backups")
plan = DockRestore.plan(input(cala: false, bounce: false))!
check(!plan.needsSync && DockRestore.clearsRecords(plan, synced: false), "nothing to write clears without sync")

// Attention cue: shown while wanted, held a minimum so a ~1 s request is noticed, dropped on activation.
var cue = AttentionCue.State()
check(AttentionCue.update(&cue, wanting: [], frontmost: 1, now: 0).isEmpty, "nothing wanted, no cue")
check(AttentionCue.update(&cue, wanting: [7], frontmost: 1, now: 10) == [7], "cue starts")
check(AttentionCue.update(&cue, wanting: [], frontmost: 1, now: 11) == [7], "short request held")
check(AttentionCue.update(&cue, wanting: [], frontmost: 1, now: 11.7).isEmpty, "cue ends after the minimum")
check(AttentionCue.update(&cue, wanting: [7, 8], frontmost: 1, now: 20) == [7, 8], "two apps")
check(AttentionCue.update(&cue, wanting: [7, 8], frontmost: 1, now: 60) == [7, 8], "critical request stays")
check(AttentionCue.update(&cue, wanting: [8], frontmost: 7, now: 60.1) == [8], "activating the app ends its cue at once")
check(AttentionCue.update(&cue, wanting: [8], frontmost: 7, now: 60.2) == [8] && cue.since[8] == 20, "start time kept while wanted")
check(AttentionCue.update(&cue, wanting: [9], frontmost: 9, now: 61) == [], "frontmost app never cues")
let diff = AttentionCue.changes(from: [1, 2], to: [2, 3])
check(diff.started == [3] && diff.stopped == [1], "start/stop changes")

if failures > 0 { print("\(failures) dock rules check(s) failed"); exit(1) }
print("dock rules checks passed")

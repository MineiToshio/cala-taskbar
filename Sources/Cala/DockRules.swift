import Foundation

/// Pure decisions for the Dock's `no-bouncing` override (DockControl) and the bar's attention cue (AppAttention).
/// The hidden Dock opens itself, whatever its auto-hide delay, when an app asks for attention. `no-bouncing` stops that.
enum DockNoBouncing {
    /// What Cala remembers of the user's own `no-bouncing`.
    struct Backup: Equatable {
        /// False: nothing recorded (never applied, or a backup from a version that did not write `no-bouncing`).
        var saved = false
        /// The original value; nil means the key was absent.
        var value: Bool?
    }

    enum Write: Equatable { case keep, set(Bool), remove }

    /// Applying the override: record the user's value once (never over an earlier record), then make it true.
    /// `calaHidDockUnrecorded`: the Dock holds Cala's exact hidden values but no backup says so (the config was lost or
    /// failed to load). A `true` found then is Cala's own write, so the original is recorded as absent, never as true.
    static func apply(current: Bool?, backup: Backup, calaHidDockUnrecorded: Bool = false) -> (backup: Backup, write: Write) {
        let original = calaHidDockUnrecorded && current == true ? nil : current
        let recorded = backup.saved ? backup : Backup(saved: true, value: original)
        return (recorded, current == true ? .keep : .set(true))
    }

    /// A restored value other than true means bouncing should come back, which the Dock only does after a restart.
    static func needsRestart(_ w: Write) -> Bool { w == .remove || w == .set(false) }

    /// Giving it back: only while Cala's value is still there. A value the user changed since is theirs to keep.
    static func restore(current: Bool?, backup: Backup) -> (backup: Backup, write: Write) {
        guard backup.saved, current == true else { return (Backup(), .keep) }
        switch backup.value {
        case nil: return (Backup(), .remove)
        case true?: return (Backup(), .keep)
        case false?: return (Backup(), .set(false))
        }
    }
}

/// Giving the Dock back: what to write, and what to keep when the write cannot be saved.
enum DockRestore {
    struct Input {
        var hideBackupSaved: Bool
        /// Whether Cala wrote the hidden values (nil: legacy backup from before ownership was recorded).
        var overridePending: Bool?
        var includeAdopted: Bool
        var isHidden: Bool
        var hasCalaValues: Bool
        var noBouncing: Bool?
        var noBouncingRecord: DockNoBouncing.Backup
    }

    struct Plan: Equatable {
        /// Write the backed-up autohide / delay.
        var restoreHide: Bool
        var noBouncing: DockNoBouncing.Write
        /// The `no-bouncing` record once the restore is saved.
        var noBouncingRecord: DockNoBouncing.Backup
        /// Something was written: synchronize before forgetting any backup.
        var needsSync: Bool
        var restartDock: Bool
    }

    /// nil: nothing recorded, nothing to do.
    static func plan(_ i: Input) -> Plan? {
        guard i.hideBackupSaved || i.noBouncingRecord.saved else { return nil }
        // Legacy backups have no ownership flag. Match the values Cala wrote before using one.
        let restoreHide = i.hideBackupSaved && (i.overridePending == false ? i.includeAdopted && i.isHidden : i.hasCalaValues)
        // `no-bouncing` goes back whenever Cala's value is still there, even if the Dock stays hidden by the user:
        // with the bar gone, nothing else would show attention requests.
        let bounce = DockNoBouncing.restore(current: i.noBouncing, backup: i.noBouncingRecord)
        let wrote = restoreHide || bounce.write != .keep
        return Plan(restoreHide: restoreHide, noBouncing: bounce.write, noBouncingRecord: bounce.backup,
                    needsSync: wrote, restartDock: restoreHide || DockNoBouncing.needsRestart(bounce.write))
    }

    /// Forget the backups only once the restore is on disk; a failed synchronize keeps them for the next try.
    static func clearsRecords(_ p: Plan, synced: Bool) -> Bool { !p.needsSync || synced }
}

/// Which bar icons show the attention cue. A request shows while the app wants attention and at least `minimum`
/// seconds, so a short (informational, ~1 s) request is still noticed; activating the app ends it at once.
enum AttentionCue {
    struct State: Equatable {
        /// Process id -> when its cue started.
        var since: [Int32: Double] = [:]
    }

    static func update(_ state: inout State, wanting: Set<Int32>, frontmost: Int32?, now: Double, minimum: Double = 1.6) -> Set<Int32> {
        var next: [Int32: Double] = [:]
        for pid in wanting where pid != frontmost { next[pid] = state.since[pid] ?? now }
        for (pid, start) in state.since where next[pid] == nil && pid != frontmost && now - start < minimum { next[pid] = start }
        state.since = next
        return Set(next.keys)
    }

    /// Cues that started and stopped between two published sets.
    static func changes(from old: Set<Int32>, to new: Set<Int32>) -> (started: Set<Int32>, stopped: Set<Int32>) {
        (new.subtracting(old), old.subtracting(new))
    }
}

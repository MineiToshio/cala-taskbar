import Foundation

/// Shared on-disk locations. The app used to be called MacTaskbar; its data folder is migrated once.
enum AppPaths {
    private static let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]

    /// Former data folder. After migration it is a symlink to `supportDirectory`, so a statusLine command
    /// already saved in Claude's settings.json (which points here) keeps working.
    static let legacySupportDirectory = base.appendingPathComponent("MacTaskbar", isDirectory: true)

    /// `~/Library/Application Support/Cala`. First access moves the old MacTaskbar folder here if the new one
    /// does not exist yet, then leaves a symlink at the old path.
    static let supportDirectory: URL = {
        let fm = FileManager.default
        let new = base.appendingPathComponent("Cala", isDirectory: true)
        let old = legacySupportDirectory
        var isDirectory: ObjCBool = false
        let oldIsRealFolder = fm.fileExists(atPath: old.path, isDirectory: &isDirectory) && isDirectory.boolValue
            && (try? fm.destinationOfSymbolicLink(atPath: old.path)) == nil
        if oldIsRealFolder && !fm.fileExists(atPath: new.path) {
            do {
                try fm.moveItem(at: old, to: new)
                try? fm.createSymbolicLink(at: old, withDestinationURL: new)
            } catch {
                // Keep using the old folder rather than losing the user's settings.
                return old
            }
        }
        return new
    }()
}

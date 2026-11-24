import Foundation

/// Owned by the Zones module on its main thread. Each edit is written before it becomes live.
final class ZonesStore {
    enum SaveError: Error { case recoveryFailed, editorDraftOutdated }

    let fileURL: URL
    private(set) var state: ZonesState
    private(set) var recoveryError: Error?

    init(fileURL: URL = AppPaths.supportDirectory.appendingPathComponent("zones.json"),
         templateName: (String) -> String = ZoneTemplates.name) throws {
        self.fileURL = fileURL
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            state = ZoneTemplates.seedState(names: templateName)
            try write(state)
            return
        }

        do {
            state = try JSONDecoder().decode(ZonesState.self, from: data).repaired(names: templateName)
        } catch {
            state = ZoneTemplates.seedState(names: templateName)
            let backup = fileURL.appendingPathExtension("bad")
            let fm = FileManager.default
            do {
                if fm.fileExists(atPath: backup.path) { try fm.removeItem(at: backup) }
                try fm.moveItem(at: fileURL, to: backup)
            } catch {
                recoveryError = error
                return
            }
            try write(state)
        }
    }

    func layout(forDisplay key: String) -> ZoneLayout? {
        state.layout(forDisplay: key)
    }

    /// Commits layout edits and display assignments together, without replacing a newer store state.
    func saveEditorDraft(_ draft: ZonesState, basedOn original: ZonesState) throws {
        guard draft != original else { return }
        guard original == state else { throw SaveError.editorDraftOutdated }
        try commit(draft)
    }

    @discardableResult
    func save(_ layout: ZoneLayout) throws -> UUID {
        var updated = state
        if let index = updated.layouts.firstIndex(where: { $0.id == layout.id }) {
            updated.layouts[index] = layout
        } else {
            updated.layouts.append(layout)
        }
        try commit(updated)
        return layout.id
    }

    @discardableResult
    func duplicate(_ id: UUID, name: String) throws -> UUID? {
        guard state.layouts.contains(where: { $0.id == id }) else { return nil }
        var updated = state
        let copy = updated.duplicate(id, name: name)
        try commit(updated)
        return copy
    }

    @discardableResult
    func delete(_ id: UUID) throws -> Bool {
        var updated = state
        guard updated.delete(id) else { return false }
        try commit(updated)
        return true
    }

    @discardableResult
    func setActiveLayout(_ id: UUID?, forDisplay key: String) throws -> Bool {
        if let id, !state.layouts.contains(where: { $0.id == id }) { return false }
        var updated = state
        updated.activeByDisplay[key] = id?.uuidString ?? ZonesState.off
        try commit(updated)
        return true
    }

    func useDefaultLayout(forDisplay key: String) throws {
        var updated = state
        updated.activeByDisplay.removeValue(forKey: key)
        try commit(updated)
    }

    @discardableResult
    func setDefaultLayout(_ id: UUID) throws -> Bool {
        guard state.layouts.contains(where: { $0.id == id }) else { return false }
        var updated = state
        updated.defaultLayout = id
        try commit(updated)
        return true
    }

    private func commit(_ updated: ZonesState) throws {
        let repaired = updated.repaired()
        guard repaired != state else { return }
        try write(repaired)
        state = repaired
    }

    private func write(_ state: ZonesState) throws {
        guard recoveryError == nil else { throw SaveError.recoveryFailed }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(state).write(to: fileURL, options: .atomic)
    }
}

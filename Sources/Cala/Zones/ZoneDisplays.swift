import AppKit

enum ZoneDisplays {
    static func keys(for screens: [NSScreen]) -> [CGDirectDisplayID: String] {
        let displays = screens.compactMap { screen -> ZoneDisplayKeys.Display? in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            else { return nil }
            // Use the same CG display UUID and numeric fallback as Cala's existing display preferences.
            return ZoneDisplayKeys.Display(id: id, frame: screen.frame, key: screen.key)
        }
        return ZoneDisplayKeys.keys(for: displays)
    }
}

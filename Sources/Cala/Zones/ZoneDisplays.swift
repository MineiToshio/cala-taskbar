import AppKit

enum ZoneDisplays {
    static func id(for screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    static func keys(for screens: [NSScreen]) -> [CGDirectDisplayID: String] {
        let displays = screens.compactMap { screen -> ZoneDisplayKeys.Display? in
            guard let id = id(for: screen) else { return nil }
            // Use the same CG display UUID and numeric fallback as Cala's existing display preferences.
            return ZoneDisplayKeys.Display(id: id, frame: screen.frame, key: screen.key)
        }
        return ZoneDisplayKeys.keys(for: displays)
    }

    /// Names that tell the screens apart (see `ZoneMonitorNames`), in `screens` order.
    static func labels(for screens: [NSScreen]) -> [String] {
        ZoneMonitorNames.labels(screens.map { .init(name: $0.localizedName, frame: $0.frame) }, localize: tx)
    }

    /// "3840 × 1080", the size macOS reports for the screen in points.
    static func sizeText(_ screen: NSScreen) -> String {
        "\(Int(screen.frame.width)) × \(Int(screen.frame.height))"
    }
}

import Foundation
import CoreGraphics

enum ZoneDisplayKeys {
    struct Display {
        var id: CGDirectDisplayID
        var frame: CGRect
        var key: String
    }

    static func keys(for displays: [Display]) -> [CGDirectDisplayID: String] {
        // Hardware with identical UUIDs is distinguished by arrangement. Suffixes are stable
        // while that arrangement is unchanged. The display ID resolves identical origins.
        let sorted = displays.sorted {
            if $0.frame.minX != $1.frame.minX { return $0.frame.minX < $1.frame.minX }
            if $0.frame.minY != $1.frame.minY { return $0.frame.minY < $1.frame.minY }
            return $0.id < $1.id
        }
        var counts: [String: Int] = [:]
        var keys: [CGDirectDisplayID: String] = [:]
        for display in sorted {
            let count = counts[display.key, default: 0] + 1
            counts[display.key] = count
            keys[display.id] = count == 1 ? display.key : "\(display.key)#\(count)"
        }
        return keys
    }
}

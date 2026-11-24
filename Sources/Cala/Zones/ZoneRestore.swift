import Foundation
import CoreGraphics

enum ZoneRestore {
    struct WindowKey: Hashable {
        var pid: Int32
        var windowID: CGWindowID
    }

    struct SnapRecord {
        var originalFrameAX: CGRect
        var snappedFrameAX: CGRect
    }

    struct Records {
        private var records: [WindowKey: SnapRecord] = [:]
        private var order: [WindowKey] = []

        mutating func recordSnap(_ key: WindowKey, originalFrameAX: CGRect, snappedFrameAX: CGRect) {
            let original = records[key]?.originalFrameAX ?? originalFrameAX
            records[key] = SnapRecord(originalFrameAX: original, snappedFrameAX: snappedFrameAX)
            order.removeAll { $0 == key }
            order.append(key)
            if order.count > 200 { records.removeValue(forKey: order.removeFirst()) }
        }

        // Confirm the window was still snapped at mouse-down, then restore from its live drag position.
        mutating func restoreOnDrag(_ key: WindowKey, current: CGRect, cursorX: CGFloat,
                                    initialFrameAX: CGRect? = nil) -> CGRect? {
            guard let record = records.removeValue(forKey: key) else { return nil }
            order.removeAll { $0 == key }
            guard ZoneRestore.isStillSnapped(current: initialFrameAX ?? current, snapped: record.snappedFrameAX) else { return nil }
            return ZoneRestore.restoredFrame(current: current, originalSize: record.originalFrameAX.size, cursorX: cursorX)
        }
    }

    static func isStillSnapped(current: CGRect, snapped: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(current.minX - snapped.minX) <= tolerance && abs(current.minY - snapped.minY) <= tolerance
            && abs(current.width - snapped.width) <= tolerance && abs(current.height - snapped.height) <= tolerance
    }

    static func restoredFrame(current: CGRect, originalSize: CGSize, cursorX: CGFloat) -> CGRect {
        let grab = current.width > 0 ? (cursorX - current.minX) / current.width : 0
        return CGRect(x: cursorX - grab * originalSize.width, y: current.minY,
                      width: originalSize.width, height: originalSize.height)
    }
}

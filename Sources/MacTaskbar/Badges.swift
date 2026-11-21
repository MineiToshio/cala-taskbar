import AppKit
import ApplicationServices

enum DockBadges {
    /// Reads the notification badges the Dock shows (AXStatusLabel). Keys: app name and "path:<bundle path>".
    static func read() -> [String: String] {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return [:] }
        let ax = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 0.5)
        var out: [String: String] = [:]
        guard let lists = axAttr(ax, kAXChildrenAttribute) as? [AXUIElement] else { return out }
        for list in lists {
            guard let items = axAttr(list, kAXChildrenAttribute) as? [AXUIElement] else { continue }
            for it in items {
                guard let label = axAttr(it, "AXStatusLabel") as? String, !label.isEmpty else { continue }
                if let t = axAttr(it, kAXTitleAttribute) as? String { out[t] = label }
                if let u = axAttr(it, kAXURLAttribute) as? URL { out["path:" + u.path] = label }
            }
        }
        return out
    }
}

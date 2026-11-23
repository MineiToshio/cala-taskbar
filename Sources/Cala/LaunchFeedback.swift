import AppKit
import QuartzCore
import SwiftUI

/// Visual feedback when a click on the bar starts something that takes a while (launching an app, reopening it,
/// New Window / New Tab): a translucent copy of the icon zooms out and fades right away ("ghost zoom"), then the
/// icon on the bar keeps breathing until a new window of that app shows up, so a slow app never looks like a
/// click that did nothing.
final class LaunchFeedback {
    static let shared = LaunchFeedback()

    /// Item ids currently waiting for a window, read by the bar to pulse their icon.
    weak var model: TaskbarModel?
    private var watches: [String: Timer] = [:]
    private var panels: [NSPanel] = []

    /// `center` is the icon's center in screen coordinates, `size` its side in points.
    func play(_ item: AppItem, center: NSPoint, size: CGFloat) {
        ghost(item.icon, center: center, size: size)
        watch(item)
    }

    // MARK: Ghost zoom

    private func ghost(_ icon: NSImage, center: NSPoint, size: CGFloat) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return }
        let scale: CGFloat = 2.6
        let side = size * scale + 8
        let panel = NSPanel(contentRect: NSRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let view = NSView(frame: NSRect(x: 0, y: 0, width: side, height: side))
        view.wantsLayer = true
        let layer = CALayer()
        layer.frame = NSRect(x: (side - size) / 2, y: (side - size) / 2, width: size, height: size)
        layer.contents = icon.cgImage(forProposedRect: nil, context: nil, hints: nil)
        layer.contentsGravity = .resizeAspect
        layer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        layer.opacity = 0
        view.layer?.addSublayer(layer)
        panel.contentView = view
        panel.orderFrontRegardless()
        panels.append(panel)

        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 1.0
        grow.toValue = scale
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.55
        fade.toValue = 0.0
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = 0.45
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak panel] in
            guard let panel else { return }
            panel.orderOut(nil)
            self?.panels.removeAll { $0 === panel }
        }
        layer.add(group, forKey: "ghost")
        CATransaction.commit()
    }

    // MARK: Waiting pulse

    /// Pulses the icon until the app has more on-screen windows than it had at the click, or 8 s pass.
    private func watch(_ item: AppItem) {
        guard let model else { return }
        let id = item.id
        let bundle = item.url.flatMap { Bundle(url: $0)?.bundleIdentifier } ?? item.id
        let baseline = windowCount(pid: item.pid, bundle: bundle)
        watches[id]?.invalidate()
        model.launching.insert(id)
        let started = Date()
        watches[id] = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let elapsed = Date().timeIntervalSince(started)
            // A minimum so the pulse is noticed even when the window shows up at once.
            let done = elapsed > 0.5 && self.windowCount(pid: nil, bundle: bundle, fallbackPID: item.pid) > baseline
            if done || elapsed > 8 { self.finish(id) }
        }
    }

    private func finish(_ id: String) {
        watches[id]?.invalidate()
        watches[id] = nil
        model?.launching.remove(id)
    }

    /// Normal-layer, on-screen windows owned by the app (by pid, or by bundle id while it is still launching).
    private func windowCount(pid: pid_t?, bundle: String, fallbackPID: pid_t? = nil) -> Int {
        var pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundle).map(\.processIdentifier))
        if let pid { pids.insert(pid) }
        if let fallbackPID { pids.insert(fallbackPID) }
        guard !pids.isEmpty,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return 0 }
        return list.filter {
            ($0[kCGWindowLayer as String] as? Int) == 0 && pids.contains(($0[kCGWindowOwnerPID as String] as? pid_t) ?? -1)
        }.count
    }
}

/// Gentle breathing of a bar icon while its app is opening.
struct LaunchPulse: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        if active && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            content.phaseAnimator([false, true]) { view, up in
                view.scaleEffect(up ? 0.86 : 1).opacity(up ? 0.55 : 1)
            } animation: { _ in .easeInOut(duration: 0.45) }
        } else {
            content
        }
    }
}

import AppKit
import SwiftUI

/// With auto-hide on, the bar is usually out of sight when an app asks for attention (and the native Dock no longer
/// bounces). This shows a small accent glow at the bottom edge, under where the app's icon sits, while the bar is
/// hidden and the request lasts. It never reveals the bar, never takes mouse events and never becomes key or active,
/// so EdgeIntent (which reads only the pointer) is unaffected. Reduce Motion: a steady glow instead of a pulse.
final class AttentionEdgeCue {
    struct Target: Equatable {
        /// The screen's frame (global coordinates) and the icon's center x on it.
        let screen: CGRect
        let x: CGFloat
    }

    private static let size = CGSize(width: 64, height: 12)
    private let targets: () -> [Target]
    private var timer: Timer?
    private var panels: [NSPanel] = []
    private var shown: [Target] = []

    init(targets: @escaping () -> [Target]) { self.targets = targets }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        show([])
    }

    private func refresh() {
        let next = AppAttention.shared.pids.isEmpty ? [] : targets()
        if next != shown { show(next) }
    }

    private func show(_ next: [Target]) {
        shown = next
        while panels.count > next.count { panels.removeLast().orderOut(nil) }
        while panels.count < next.count { panels.append(Self.makePanel()) }
        for (panel, t) in zip(panels, next) {
            let w = Self.size.width, h = Self.size.height
            let x = min(max(t.x - w / 2, t.screen.minX), t.screen.maxX - w)
            panel.setFrame(NSRect(x: x, y: t.screen.minY, width: w, height: h), display: true)
            panel.orderFrontRegardless()
        }
    }

    private static func makePanel() -> NSPanel {
        let panel = BarPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: EdgeGlow())
        return panel
    }
}

private struct EdgeGlow: View {
    @ObservedObject private var store = ConfigStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        let accent = BarTheme.named(store.config.theme).accent
        Capsule()
            .fill(accent)
            .frame(width: 40, height: 4)
            // A dark rim keeps pale theme accents visible over light windows.
            .overlay(Capsule().strokeBorder(Color.black.opacity(0.25), lineWidth: 0.5))
            .shadow(color: accent.opacity(0.9), radius: 4)
            .opacity(dim ? 0.45 : 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}

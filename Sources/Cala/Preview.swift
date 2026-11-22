import SwiftUI
import AppKit

final class PreviewModel: ObservableObject {
    @Published var name = ""
    @Published var icon = NSImage()
    @Published var windows: [WinRef] = []
    @Published var cardWidth: CGFloat = 260
    @Published var images: [CGWindowID: NSImage] = [:]
    var onPeek: ((WinRef?, NSImage?) -> Void)?
    var onCommit: (() -> Void)?
}

struct PreviewView: View {
    @ObservedObject var pm: PreviewModel
    var onAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !AXIsProcessTrusted() {
                note(tx("Accessibility permission is missing", "Falta el permiso de Accesibilidad"))
            } else if !CGPreflightScreenCaptureAccess() {
                note(tx("Screen Recording permission is missing", "Falta el permiso de Grabación de pantalla"))
            }
            if pm.windows.isEmpty {
                HStack(spacing: 8) {
                    Image(nsImage: pm.icon).resizable().frame(width: 22, height: 22)
                    Text(pm.name).font(.system(size: 14, weight: .medium))
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
            } else {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(pm.windows.prefix(6)) { w in
                        WindowCard(w: w, width: pm.cardWidth, image: pm.images[w.id], icon: pm.icon, onPeek: { pm.onPeek?($0 ? w : nil, nil) }, onCommit: { pm.onCommit?() }, onAction: onAction)
                    }
                }
            }
        }
        .themedPanel()
        .fixedSize()
    }

    func note(_ t: String) -> some View {
        Text(t).font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 6)
    }
}

struct WindowCard: View {
    let w: WinRef
    let width: CGFloat
    let image: NSImage?
    let icon: NSImage
    var onPeek: (Bool) -> Void
    var onCommit: () -> Void
    var onAction: () -> Void
    @State private var hovering = false
    @State private var overClose = false
    var W: CGFloat { width }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                Text(w.title.isEmpty ? tx("Untitled", "Sin título") : w.title)
                    .font(.system(size: 14, weight: .medium)).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(overClose ? 0.16 : 0.06)))
                    .contentShape(Rectangle())
                    .onHover { overClose = $0 }
                    .onTapGesture { WindowService.close(w); onAction() }
            }
            .frame(width: W, height: 28).padding(.horizontal, 0)
            ZStack {
                if let image {
                    Image(nsImage: image).resizable().scaledToFit().opacity(w.minimized ? 0.55 : 1)
                } else {
                    Image(nsImage: icon).resizable().frame(width: 40, height: 40).opacity(0.45)
                }
            }
            .frame(width: W, height: W * 0.62)
            .background(Color.black.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(hovering ? 0.1 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0; onPeek($0) }
        .onTapGesture { onCommit(); WindowService.raise(w); onAction() }
    }
}

final class PreviewController {
    let panel: NSPanel
    let pm = PreviewModel()
    private(set) var shownID: String?
    private var host: NSHostingView<PreviewView>!
    private var captureTask: Task<Void, Never>?
    private var captureGeneration = UUID()

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        host = NSHostingView(rootView: PreviewView(pm: pm, onAction: { [weak self] in self?.hide() }))
        panel.contentView = host
        pm.onPeek = { [weak self] w, img in self?.peek(w, img) }
        pm.onCommit = { [weak self] in self?.commitPeek() }
    }

    // MARK: Peek: temporarily bring the real window to the front, restore on leave
    private var peekWork: DispatchWorkItem?
    private var restoreWork: DispatchWorkItem?
    private var saved: (app: NSRunningApplication?, win: AXUIElement?, peekedPID: pid_t, peekedWin: AXUIElement?)?

    func peek(_ w: WinRef?, _ img: NSImage?) {
        peekWork?.cancel()
        guard let w, !w.minimized, w.ax != nil, onScreen(w.id) else { scheduleRestore(); return }
        restoreWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.startPeek(w) }
        peekWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: work)
    }

    /// Only peek windows on the current Space (raising others would switch Spaces).
    private func onScreen(_ id: CGWindowID) -> Bool {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.contains { ($0[kCGWindowNumber as String] as? CGWindowID) == id }
    }

    private func startPeek(_ w: WinRef) {
        if saved == nil {
            let front = NSWorkspace.shared.frontmostApplication
            saved = (front, front.flatMap { WindowService.focusedWindow(pid: $0.processIdentifier) },
                     w.pid, WindowService.focusedWindow(pid: w.pid))
        }
        WindowService.raise(w)
    }

    private func scheduleRestore() {
        guard saved != nil else { return }
        restoreWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.restore() }
        restoreWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func restore() {
        guard let s = saved else { return }
        saved = nil
        if let pw = s.peekedWin, s.app?.processIdentifier != s.peekedPID {
            AXUIElementPerformAction(pw, kAXRaiseAction as CFString)
        }
        if let app = s.app {
            bringFront(app)
            if let win = s.win { AXUIElementPerformAction(win, kAXRaiseAction as CFString) }
        }
    }

    /// The user clicked a thumbnail: keep the peeked window.
    func commitPeek() {
        peekWork?.cancel(); restoreWork?.cancel(); saved = nil
    }

    func hidePeek() {
        peekWork?.cancel()
        scheduleRestore()
    }

    /// Middle click on a thumbnail closes that window.
    func middleClick(_ m: NSPoint) {
        guard panel.isVisible, panel.frame.contains(m) else { return }
        let col = pm.cardWidth + 16
        let i = Int((m.x - panel.frame.minX) / col)
        let wins = Array(pm.windows.prefix(6))
        guard i >= 0, i < wins.count else { return }
        WindowService.close(wins[i])
        hide()
    }

    var isVisible: Bool { panel.isVisible }

    func contains(_ p: NSPoint) -> Bool {
        panel.isVisible && panel.frame.insetBy(dx: -6, dy: -14).contains(p)
    }

    func show(item: AppItem, barTop: CGFloat, mouseX: CGFloat, screen: NSScreen) {
        captureTask?.cancel()
        captureGeneration = UUID()
        let generation = captureGeneration
        shownID = item.id
        pm.name = item.name
        pm.icon = item.icon
        let wins = item.pid.map { WindowService.windows(for: $0) } ?? []
        pm.windows = wins
        let count = max(1, min(wins.count, 6))
        pm.cardWidth = min(CGFloat(ConfigStore.shared.config.previewWidth),
                           max(1, (screen.visibleFrame.width - 16) / CGFloat(count) - 16))
        var imgs: [CGWindowID: NSImage] = [:]
        for w in wins { if let i = ThumbCache.shared.cached(w.id) { imgs[w.id] = i } }
        pm.images = imgs
        place(barTop: barTop, mouseX: mouseX, screen: screen)
        panel.orderFrontRegardless()

        // Live view: resolve the windows once, then keep re-capturing the visible ones while the preview is open.
        // Minimized windows cannot be drawn by macOS, so they keep their last thumbnail.
        let visibleIDs = wins.filter { !$0.minimized }.map(\.id)
        captureTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let live = await ThumbCache.shared.scWindows(ids: visibleIDs)
            let canCapture: @MainActor (CGWindowID) -> Bool = { [weak self] id in
                guard let self, self.captureGeneration == generation, self.shownID == item.id,
                      let w = self.pm.windows.first(where: { $0.id == id }), !w.minimized else { return false }
                if let ax = w.ax { return (WindowService.attr(ax, kAXMinimizedAttribute) as? Bool) == false }
                return self.onScreen(id)
            }
            var width: CGFloat = 720
            while !Task.isCancelled, self.captureGeneration == generation, !live.isEmpty {
                await ThumbCache.shared.capture(live, width: width, shouldCapture: canCapture)
                guard !Task.isCancelled, self.captureGeneration == generation else { return }
                self.pm.images = ThumbCache.shared.images
                width = 640
                do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
            }
        }
    }

    private func place(barTop: CGFloat, mouseX: CGFloat, screen: NSScreen) {
        host.layoutSubtreeIfNeeded()
        var size = host.fittingSize
        let visible = screen.visibleFrame
        size.width = min(size.width, visible.width - 16)
        var x = mouseX - size.width / 2
        x = max(visible.minX + 8, min(x, visible.maxX - size.width - 8))
        panel.setFrame(NSRect(x: x, y: barTop + 4, width: size.width, height: size.height), display: true)
    }

    func hide() {
        captureTask?.cancel()
        captureTask = nil
        captureGeneration = UUID()
        hidePeek()
        shownID = nil
        panel.orderOut(nil)
    }
}

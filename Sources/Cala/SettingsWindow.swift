import SwiftUI
import AppKit

final class SettingsWindowController {
    static let shared = SettingsWindowController()
    static let defaultSize = NSSize(width: 880, height: 640)
    static let minimumSize = NSSize(width: 780, height: 540)
    static let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    private(set) var window: NSWindow?
    private let navigation = SettingsNavigation()
    private var pendingRoute: SettingsRoute?
    private var sheetObserver: NSObjectProtocol?

    func show(pane: SettingsPane? = nil) { show(route: pane.map(SettingsRoute.pane)) }

    func show(detail: SettingsDetail) { show(route: .detail(detail)) }

    private func show(route: SettingsRoute?) {
        if let route {
            if window?.attachedSheet == nil { navigation.select(route) }
            else { pendingRoute = route }
        }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: Self.defaultSize),
                             styleMask: Self.style,
                             backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            // Background dragging interferes with SwiftUI sliders on macOS 26.
            w.isReleasedWhenClosed = false
            w.title = tx("Cala · Settings", "Cala · Configuración")
            w.contentView = NSHostingView(rootView: SettingsView(store: ConfigStore.shared, navigation: navigation))
            w.contentMinSize = Self.minimumSize
            w.center()
            window = w
            sheetObserver = NotificationCenter.default.addObserver(forName: NSWindow.didEndSheetNotification,
                                                                   object: w, queue: .main) { [weak self] _ in
                guard let self, let route = self.pendingRoute else { return }
                self.pendingRoute = nil
                self.navigation.select(route)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        (window?.attachedSheet ?? window)?.makeKeyAndOrderFront(nil)
    }
}

enum SettingsRoute {
    case pane(SettingsPane)
    case detail(SettingsDetail)
}

final class SettingsNavigation: ObservableObject {
    struct Request: Equatable {
        var pane: SettingsPane
        var sequence: UInt64 = 0
    }
    @Published private(set) var request = Request(pane: .general)
    @Published var path: [SettingsDetail] = []
    var selection: SettingsPane { request.pane }

    func select(_ route: SettingsRoute) {
        switch route {
        case let .pane(pane): select(pane)
        case let .detail(detail): select(detail.home); path = [detail]
        }
    }

    func select(_ pane: SettingsPane) {
        if let detail = pane.legacyDetail {
            select(.detail(detail))
            return
        }
        request = Request(pane: pane, sequence: request.sequence &+ 1)
        path = []
    }
}

enum SettingsPane: String, Identifiable {
    case general, zones, bar, switcher, tray, integrations, permissions, help
    case appearance, screens, about, barStyle, mail, calendar, usage

    static let modules: [Self] = [.zones, .bar, .switcher, .tray]
    static let pages = [.general] + modules + [.integrations, .permissions, .help]
    var id: String { rawValue }

    var page: Self {
        switch self {
        case .appearance: .general
        case .screens, .barStyle: .bar
        case .about: .help
        case .mail, .calendar, .usage: .integrations
        default: self
        }
    }

    var legacyDetail: SettingsDetail? {
        switch self {
        case .mail: .mail
        case .calendar: .calendar
        case .usage: .usage
        default: nil
        }
    }

    var sectionAnchor: String? {
        switch self {
        case .appearance: "theme"
        case .screens: "displays"
        case .barStyle: "barStyle"
        default: nil
        }
    }

    var title: String {
        switch page {
        case .general: tx("General", "General")
        case .zones: tx("Zones", "Zonas")
        case .bar: tx("Taskbar", "Barra de tareas")
        case .switcher: tx("Window switcher", "Selector de ventanas")
        case .tray: tx("Tray", "Bandeja")
        case .integrations: tx("Integrations", "Integraciones")
        case .permissions: tx("Permissions", "Permisos")
        case .help: tx("Help and diagnostics", "Ayuda y diagnóstico")
        case .appearance, .screens, .about, .barStyle, .mail, .calendar, .usage: ""
        }
    }

    var subtitle: String? {
        switch self {
        case .zones: tx("Snap windows into zones while you drag them.", "Encaja ventanas en zonas mientras las arrastras.")
        case .bar: tx("See and manage open apps at the bottom of each display.", "Ve y gestiona tus apps abiertas al pie de cada pantalla.")
        case .switcher: tx("Switch between open windows with Option + Tab.", "Cambia entre ventanas abiertas con Opción + Tab.")
        case .tray: tx("Controls and widgets on the right of the taskbar.", "Controles y widgets a la derecha de la barra de tareas.")
        default: nil
        }
    }

    var module: ModuleID? {
        switch self {
        case .zones: .zones
        case .bar: .bar
        case .switcher: .switcher
        case .tray: .tray
        default: nil
        }
    }

    var icon: String {
        switch self {
        case .zones: "rectangle.split.2x2.fill"
        case .bar: "rectangle.bottomthird.inset.filled"
        case .switcher: "macwindow.on.rectangle"
        case .tray: "square.grid.2x2"
        case .integrations: "puzzlepiece.extension"
        case .permissions: "lock.shield.fill"
        case .help: "wrench.and.screwdriver.fill"
        default: "gearshape.fill"
        }
    }

    var color: Color {
        switch self {
        case .zones: .indigo
        case .bar: .blue
        case .switcher: .pink
        case .tray: .teal
        case .integrations: .purple
        case .permissions: .green
        case .help: .orange
        default: .gray
        }
    }
}

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView(); v.material = material; v.blendingMode = .behindWindow; v.state = .active; return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
}

struct SettingsView: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var navigation: SettingsNavigation
    @FocusState private var focusedDetail: SettingsDetail?
    @State private var returnFocus: (detail: SettingsDetail, sequence: UInt64)?
    private let sidebarWidth: CGFloat = 228

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: sidebarWidth)
            NavigationStack(path: $navigation.path) {
                ScrollViewReader { proxy in
                    ScrollView {
                        SettingsPage(pane: navigation.selection.page, store: store, open: navigation.select,
                                     openDetail: openDetail)
                            .padding(.horizontal, 28).padding(.top, 44).padding(.bottom, 28)
                            .id("pageTop")
                    }
                    .id(navigation.selection.page)
                    .onAppear {
                        if navigation.request.pane.sectionAnchor != nil { scroll(to: navigation.request, using: proxy) }
                        if navigation.path.isEmpty { restoreDetailFocus() }
                    }
                    .onChange(of: navigation.request) { _, request in scroll(to: request, using: proxy) }
                }
                .environment(\.settingsDetailFocus, $focusedDetail)
                .navigationDestination(for: SettingsDetail.self) { detail in
                    ScrollView {
                        SettingsDetailPage(detail: detail, origin: navigation.selection.page, store: store,
                                           back: { navigation.path.removeAll() })
                            .padding(.horizontal, 28).padding(.top, 44).padding(.bottom, 28)
                    }
                    .navigationBarBackButtonHidden()
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: SettingsWindowController.minimumSize.width, minHeight: SettingsWindowController.minimumSize.height)
    }

    private func scroll(to request: SettingsNavigation.Request, using proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            guard navigation.request == request else { return }
            proxy.scrollTo(request.pane.sectionAnchor ?? "pageTop", anchor: .top)
        }
    }

    private func openDetail(_ detail: SettingsDetail) {
        returnFocus = (detail, navigation.request.sequence)
        navigation.path.append(detail)
    }

    private func restoreDetailFocus() {
        guard let target = returnFocus else { return }
        returnFocus = nil
        DispatchQueue.main.async {
            guard navigation.path.isEmpty, navigation.request.sequence == target.sequence else { return }
            focusedDetail = target.detail
        }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high)
                        .frame(width: 32, height: 32).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Cala").font(.system(size: 13, weight: .semibold))
                        Text(tx("Settings", "Configuración")).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 5).padding(.bottom, 9)
                ForEach(SettingsPane.pages) { pane in
                    SidebarItem(pane: pane, selected: navigation.selection.page == pane) { navigation.select(pane) }
                }
            }
            .padding(.horizontal, 9).padding(.top, 36).padding(.bottom, 12)
        }
        .background(VisualEffect(material: .sidebar))
        .overlay(alignment: .trailing) { Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 0.5) }
    }
}

struct SettingsPage: View {
    let pane: SettingsPane
    @ObservedObject var store: ConfigStore
    let open: (SettingsPane) -> Void
    let openDetail: (SettingsDetail) -> Void
    @Environment(\.settingsSnapshot) private var snapshot

    var body: some View {
        let modules = snapshot?.modules ?? store.config.modules
        let module = pane.module
        let inactive = module.map { !ModulePlan.effective(modules)[$0] } ?? false
        VStack(alignment: .leading, spacing: 22) {
            if let module {
                ModuleHeader(pane: pane, module: module, store: store)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(pane.title).font(.system(size: 28, weight: .bold)).accessibilityAddTraits(.isHeader)
                    if let subtitle = pane.subtitle {
                        Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                }
            }
            if inactive { InactiveSettingsNote() }
            if pane == .zones { ZonesEditorAction() }
            contents
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { if snapshot == nil { PermissionCenter.shared.beginWatching() } }
        .onDisappear { if snapshot == nil { PermissionCenter.shared.endWatching() } }
    }

    @ViewBuilder private var contents: some View {
        switch pane {
        case .general: GeneralPane(store: store, open: open)
        case .zones: ZonesSettingsPane(store: store)
        case .bar: BarSettingsPane(store: store, open: open)
        case .switcher: SwitcherSettingsPane(store: store)
        case .tray: TrayPane(store: store, mail: snapshot?.mail ?? MailService.shared, open: openDetail)
        case .integrations: IntegrationsPane(open: openDetail)
        case .permissions: PermissionsPane()
        case .help: AdvancedPane(store: store)
        case .appearance, .screens, .about, .barStyle, .mail, .calendar, .usage: EmptyView()
        }
    }
}

private struct SidebarItem: View {
    let pane: SettingsPane
    let selected: Bool
    let action: () -> Void
    @ObservedObject private var updates = UpdateService.shared
    @Environment(\.settingsSnapshot) private var snapshot
    @State private var hover = false

    private var indicatedVersion: String? {
        if let snapshot {
            if case .available(let version) = snapshot.update.state { return version }
            return nil
        }
        return updates.available?.version
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                SettingsIcon(pane: pane, size: 24)
                Text(pane.title).font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                if pane == .help, let version = indicatedVersion {
                    Circle().fill(Color.accentColor).frame(width: 5, height: 5)
                        .accessibilityLabel(tx("Cala \(version) update available", "Actualización de Cala \(version) disponible"))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.16) : (hover ? Color.primary.opacity(0.05) : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct SettingsSnapshot {
    var modules: ModuleSet
    var ready = true
    var language: String? = nil
    var layouts: ZonesState
    var mail: MailService
    var update = UpdateSettingsSnapshot(state: .idle, ready: false)
}

private struct SettingsSnapshotKey: EnvironmentKey { static let defaultValue: SettingsSnapshot? = nil }

extension EnvironmentValues {
    var settingsSnapshot: SettingsSnapshot? {
        get { self[SettingsSnapshotKey.self] }
        set { self[SettingsSnapshotKey.self] = newValue }
    }
}

import SwiftUI
import AppKit

final class SettingsWindowController {
    static let shared = SettingsWindowController()
    static let defaultSize = NSSize(width: 880, height: 640)
    static let minimumSize = NSSize(width: 780, height: 540)
    static let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    private(set) var window: NSWindow?
    private let navigation = SettingsNavigation()
    private var pendingPane: SettingsPane?
    private var sheetObserver: NSObjectProtocol?

    func show(pane: SettingsPane? = nil) {
        if let pane {
            if window?.attachedSheet == nil { navigation.select(pane) }
            else { pendingPane = pane }
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
                guard let self, let pane = self.pendingPane else { return }
                self.pendingPane = nil
                self.navigation.select(pane)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        (window?.attachedSheet ?? window)?.makeKeyAndOrderFront(nil)
    }
}

final class SettingsNavigation: ObservableObject {
    struct Request: Equatable {
        var pane: SettingsPane
        var sequence: UInt64 = 0
    }
    @Published private(set) var request = Request(pane: .general)
    var selection: SettingsPane { request.pane }

    func select(_ pane: SettingsPane) {
        request = Request(pane: pane, sequence: request.sequence &+ 1)
    }
}

enum SettingsPane: String, Identifiable {
    case general, zones, bar, switcher, tray, mail, calendar, usage, permissions, help
    case appearance, screens, about, barStyle

    static let modules: [Self] = [.zones, .bar, .switcher, .tray]
    static let trayDetails: [Self] = [.mail, .calendar, .usage]
    static let appPages: [Self] = [.permissions, .help]
    static let pages = [.general] + modules + trayDetails + appPages
    var id: String { rawValue }

    var page: Self {
        switch self {
        case .appearance: .general
        case .screens, .barStyle: .bar
        case .about: .help
        default: self
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
        case .mail: tx("Mail", "Correo")
        case .calendar: tx("Calendar", "Calendario")
        case .usage: TrayItems.usage.title
        case .permissions: tx("Permissions", "Permisos")
        case .help: tx("Help and diagnostics", "Ayuda y diagnóstico")
        case .appearance, .screens, .about, .barStyle: ""
        }
    }

    var subtitle: String? {
        switch self {
        case .zones: tx("Snap windows into zones while you drag them.", "Encaja ventanas en zonas mientras las arrastras.")
        case .bar: tx("See and manage open apps at the bottom of each display.", "Ve y gestiona tus apps abiertas al pie de cada pantalla.")
        case .switcher: tx("Switch between open windows with Option + Tab.", "Cambia entre ventanas abiertas con Opción + Tab.")
        case .tray: tx("Controls and widgets on the right of the taskbar.", "Controles y widgets a la derecha de la barra de tareas.")
        case .calendar: tx("Upcoming events from the calendars in the taskbar clock.", "Próximos eventos de los calendarios del reloj de la barra de tareas.")
        case .mail: tx("Connect Gmail, iCloud Mail, or Yahoo Mail with an app password stored in the Keychain. Google Workspace works if your administrator allows IMAP and app passwords. Cala doesn’t support Outlook or Hotmail.", "Conecta Gmail, Mail de iCloud o Yahoo Mail con una contraseña de aplicación guardada en el Llavero. Google Workspace funciona si tu administrador permite IMAP y las contraseñas de aplicación. Cala no admite Outlook ni Hotmail.")
        case .usage: tx("Claude and Codex plan usage in one tray control.", "El uso de tus planes de Claude y Codex en un solo control de la bandeja.")
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
        case .mail: "envelope.fill"
        case .calendar: "calendar"
        case .usage: "chart.bar.fill"
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
        case .mail: .blue
        case .calendar: .red
        case .usage: .purple
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
    private let sidebarWidth: CGFloat = 228

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: sidebarWidth)
            ScrollViewReader { proxy in
                ScrollView {
                    SettingsPage(pane: navigation.selection.page, store: store, open: select)
                        .padding(.horizontal, 28).padding(.top, 44).padding(.bottom, 28)
                        .id("pageTop")
                }
                .id(navigation.selection.page)
                .onChange(of: navigation.request, initial: true) { _, request in
                    scroll(to: request, using: proxy)
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

    private func select(_ pane: SettingsPane) { navigation.select(pane) }

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
                    SidebarItem(pane: pane, selected: navigation.selection.page == pane) { select(pane) }
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
    @Environment(\.settingsSnapshot) private var snapshot

    var body: some View {
        let modules = snapshot?.modules ?? store.config.modules
        let module = pane.module
        let trayDetail = SettingsPane.trayDetails.contains(pane)
        let inactive = module.map { !ModulePlan.effective(modules)[$0] } ?? (trayDetail && !ModulePlan.effective(modules).tray)
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
            if trayDetail {
                if inactive { TrayDependencyCard(store: store) }
                Button { open(.tray) } label: {
                    Label(tx("Tray", "Bandeja"), systemImage: "chevron.left")
                }.buttonStyle(.link)
            }
            if inactive {
                Text(tx("You can change these settings now. They’ll take effect when you enable the module.",
                        "Puedes cambiar estos ajustes ahora. Se aplicarán al activar el módulo."))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
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
        case .tray: TrayPane(store: store, open: open)
        case .mail: MailSettingsPane()
        case .calendar: CalendarSettingsPane(store: store)
        case .usage: UsageSettingsPane(store: store)
        case .permissions: PermissionsPane()
        case .help: AdvancedPane(store: store)
        case .appearance, .screens, .about, .barStyle: EmptyView()
        }
    }
}

private struct SidebarItem: View {
    let pane: SettingsPane
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                SettingsIcon(pane: pane, size: 24)
                Text(pane.title).font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .lineLimit(1).fixedSize(horizontal: true, vertical: false)
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
}

private struct SettingsSnapshotKey: EnvironmentKey { static let defaultValue: SettingsSnapshot? = nil }

extension EnvironmentValues {
    var settingsSnapshot: SettingsSnapshot? {
        get { self[SettingsSnapshotKey.self] }
        set { self[SettingsSnapshotKey.self] = newValue }
    }
}

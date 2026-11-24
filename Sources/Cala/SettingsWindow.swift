import SwiftUI
import AppKit
import CoreLocation
import CoreBluetooth

// MARK: - Window

final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private(set) var window: NSWindow?

    func show(pane: SettingsPane? = nil) {
        UsageService.shared.settingsOpened()
        if let pane, let window { window.contentView = NSHostingView(rootView: SettingsView(store: ConfigStore.shared, pane: pane)) }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 840, height: 600),
                             styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.title = tx("Cala · Settings", "Cala · Configuración")
            w.contentView = NSHostingView(rootView: SettingsView(store: ConfigStore.shared, pane: pane ?? .general))
            w.contentMinSize = NSSize(width: 780, height: 540)
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Structure

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, appearance, screens, tray, usage, calendar, mail, permissions, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: tx("General", "General"); case .appearance: tx("Appearance", "Apariencia"); case .screens: tx("Screens", "Pantallas"); case .tray: tx("Tray", "Bandeja")
        case .calendar: tx("Calendar", "Calendario")
        case .mail: tx("Mail", "Correo")
        case .usage: tx("Usage", "Uso")
        case .permissions: tx("Permissions", "Permisos"); case .about: tx("Advanced", "Avanzado")
        }
    }
    var subtitle: String {
        switch self {
        case .general: tx("How the bar and startup behave.", "Comportamiento de la barra y del inicio.")
        case .appearance: tx("Colors, transparency and sizes.", "Colores, transparencia y tamaños.")
        case .screens: tx("How the bar is laid out on each screen.", "Cómo se acomoda la barra en cada pantalla.")
        case .tray: tx("What shows on the right of the bar, what sits behind the ^ arrow and what is hidden.", "Qué se ve a la derecha de la barra, qué queda detrás de la flecha ^ y qué se oculta.")
        case .calendar: tx("Upcoming events from your macOS calendar accounts.", "Próximos eventos de las cuentas de calendario de tu macOS.")
        case .mail: tx("Connect Gmail, iCloud Mail, or Yahoo Mail with an app password stored in the Keychain. Google Workspace works if your administrator allows IMAP and app passwords. Cala doesn’t support Outlook or Hotmail.", "Conecta Gmail, Mail de iCloud o Yahoo Mail con una contraseña de aplicación guardada en el Llavero. Google Workspace funciona si tu administrador permite IMAP y las contraseñas de aplicación. Cala no admite Outlook ni Hotmail.")
        case .usage: tx("Claude and Codex plan usage in one tray control.", "El uso de tus planes de Claude y Codex en un solo control de la bandeja.")
        case .permissions: tx("What macOS needs to allow so everything works.", "Lo que macOS debe permitir para que todo funcione.")
        case .about: tx("Files, log and factory defaults.", "Archivos, registro y valores de fábrica.")
        }
    }
    var icon: String {
        switch self {
        case .general: "gearshape.fill"; case .appearance: "paintpalette.fill"; case .screens: "display"; case .tray: "square.grid.2x2"
        case .calendar: "calendar"
        case .mail: "envelope.fill"
        case .usage: "chart.bar.fill"
        case .permissions: "lock.shield.fill"; case .about: "wrench.and.screwdriver.fill"
        }
    }
    var color: Color {
        switch self {
        case .general: Color(red: 0.55, green: 0.57, blue: 0.62); case .appearance: Color(red: 0.95, green: 0.35, blue: 0.55)
        case .screens: Color(red: 0.25, green: 0.52, blue: 0.98); case .tray: Color(red: 0.2, green: 0.65, blue: 0.7); case .permissions: Color(red: 0.2, green: 0.72, blue: 0.4)
        case .calendar: .red
        case .mail: .blue
        case .usage: .purple
        case .about: Color(red: 0.98, green: 0.6, blue: 0.2)
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
    @State private var pane: SettingsPane
    init(store: ConfigStore, pane: SettingsPane = .general) { self.store = store; _pane = State(initialValue: pane) }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 220)
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(pane.title).font(.system(size: 28, weight: .bold))
                        Text(pane.subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    PaneBody(pane: pane, store: store)
                    .id(pane)
                    .transition(.opacity.combined(with: .offset(y: 8)))
                }
                .padding(.horizontal, 34).padding(.top, 46).padding(.bottom, 32)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .animation(.easeOut(duration: 0.22), value: pane)
        .frame(minWidth: 780, minHeight: 540)
    }

    var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Aligned with the rows below: the visible logo starts at the icons' left edge (18 pt) and the
            // title at the rows' text column (52 pt). The app icon has a transparent margin (824/1024 body).
            HStack(spacing: 2.6) {
                Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high)
                    .frame(width: 34.8, height: 34.8)
                    .padding(.leading, -3.4)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Cala").font(.system(size: 13, weight: .semibold))
                    Text(tx("Settings", "Configuración")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8).padding(.top, 40).padding(.bottom, 14)
            ForEach(SettingsPane.allCases) { p in
                SidebarItem(pane: p, selected: pane == p) { pane = p }
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .background(VisualEffect(material: .sidebar))
        .overlay(alignment: .trailing) { Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 0.5) }
    }
}

struct PaneBody: View {
    let pane: SettingsPane
    @ObservedObject var store: ConfigStore
    var body: some View {
        switch pane {
        case .general: GeneralPane(store: store)
        case .appearance: AppearancePane(store: store)
        case .screens: ScreensPane(store: store)
        case .tray: TrayPane(store: store)
        case .calendar: CalendarSettingsPane(store: store)
        case .mail: MailSettingsPane()
        case .usage: UsageSettingsPane(store: store)
        case .permissions: PermissionsPane()
        case .about: AdvancedPane(store: store)
        }
    }
}

struct SidebarItem: View {
    let pane: SettingsPane
    let selected: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: pane.icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(RoundedRectangle(cornerRadius: 6).fill(LinearGradient(colors: [pane.color.opacity(0.85), pane.color], startPoint: .top, endPoint: .bottom)))
                Text(pane.title).font(.system(size: 13, weight: selected ? .semibold : .regular))
                Spacer()
            }
            .padding(.horizontal, 8).frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 9).fill(selected ? Color.primary.opacity(0.1) : (hover ? Color.primary.opacity(0.05) : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - Building blocks

struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).tracking(0.6)
            .padding(.leading, 4).padding(.bottom, -14)
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.04), radius: 3, y: 1)
    }
}

struct SettingRow<Control: View>: View {
    let title: String
    var caption: String? = nil
    @ViewBuilder var control: Control
    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                if let caption { Text(caption).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }
}

struct RowDivider: View { var body: some View { Divider().padding(.leading, 16) } }

struct SliderControl: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0.01
    let label: (Double) -> String
    var body: some View {
        HStack(spacing: 10) {
            Slider(value: $value, in: range, step: step).frame(width: 200)
            Text(label(value)).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
        }
    }
}

// MARK: - General

struct GeneralPane: View {
    @ObservedObject var store: ConfigStore
    @State private var login = LoginItem.enabled
    @State private var diskFolders = ""
    private func applyDiskFolders() {
        store.config.diskFolders = diskFolders.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    @State private var languageChanged = false
    private var systemLanguageName: String {
        let code = Locale.preferredLanguages.first?.split(separator: "-").first.map(String.init) == "es" ? "es" : "en"
        return code == "es" ? "Español" : "English"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tx("Language", "Idioma")).font(.system(size: 13, weight: .medium))
                        Text(languageChanged
                             ? tx("Some texts (menus, tray names) change after reopening Cala.", "Algunos textos (menús, nombres de la bandeja) cambian al reabrir Cala.")
                             : tx("By default Cala uses your Mac's language.", "Por defecto Cala usa el idioma de tu Mac."))
                            .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 12) {
                        Picker("", selection: Binding(get: { store.config.language }, set: { store.config.language = $0; languageChanged = true })) {
                            Text(tx("System", "Sistema") + " (" + systemLanguageName + ")").tag("system")
                            Text("English").tag("en")
                            Text("Español").tag("es")
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 360)
                        .accessibilityLabel(tx("Language", "Idioma"))
                        Spacer(minLength: 0)
                        if languageChanged {
                            Button(tx("Reopen Cala", "Reabrir Cala")) { Relaunch.open() }.fixedSize()
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Card {
                SettingRow(title: tx("Hide the bar automatically", "Ocultar la barra automáticamente"), caption: tx("It hides, and shows again when you move the mouse to the bottom edge of the screen.", "Se esconde y aparece al llevar el mouse al borde inferior de la pantalla.")) {
                    Toggle("", isOn: Binding(get: { store.config.autoHide }, set: { store.config.autoHide = $0 })).toggleStyle(.switch).labelsHidden()
                        .accessibilityLabel(tx("Hide the bar automatically", "Ocultar la barra automáticamente"))
                }
                RowDivider()
                SettingRow(title: tx("Open at login", "Abrir al iniciar sesión"),
                           caption: LoginItem.needsApproval
                            ? tx("Switched off in System Settings → General → Login Items. Turn Cala on there.", "Desactivado en Ajustes del Sistema → General → Ítems de inicio. Activa Cala allí.")
                            : tx("The bar starts by itself every time you log in.", "La barra arranca sola cada vez que entras a tu usuario.")) {
                    HStack(spacing: 8) {
                        if LoginItem.needsApproval { Button(tx("Open Login Items", "Abrir Ítems de inicio")) { LoginItem.openSystemSettings() }.controlSize(.small) }
                        Toggle("", isOn: Binding(get: { login }, set: { LoginItem.set($0); login = LoginItem.enabled })).toggleStyle(.switch).labelsHidden()
                            .accessibilityLabel(tx("Open at login", "Abrir al iniciar sesión"))
                            // Can change outside this view (the welcome, System Settings → Login Items): re-read it.
                            .onAppear { login = LoginItem.enabled }
                            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in login = LoginItem.enabled }
                            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in login = LoginItem.enabled }
                    }
                }
            }
            SectionTitle(text: tx("Disk", "Disco"))
            Card {
                VStack(alignment: .leading, spacing: 6) {
                    Text(tx("Extra folders to measure", "Carpetas extra a medir")).font(.system(size: 13, weight: .medium))
                    Text(tx("Separated by commas, for example where your projects or worktrees live. They are added to the list of caches and developer tools.", "Separadas por coma, por ejemplo donde viven tus proyectos o worktrees. Se suman a la lista de caches y herramientas de desarrollo."))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    TextField("~/Projects, ~/worktrees", text: $diskFolders).textFieldStyle(.roundedBorder).onSubmit { applyDiskFolders() }
                        .onAppear { diskFolders = store.config.diskFolders.joined(separator: ", ") }
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
            SectionTitle(text: tx("CPU and memory", "CPU y memoria"))
            Card {
                SettingRow(title: tx("Show in bar", "Mostrar en la barra"), caption: tx("What the tray item shows while everything is fine. If something needs attention (memory, energy or processor), it always shows that first.", "Lo que muestra el ícono de la bandeja mientras todo va bien. Si algo necesita atención (memoria, energía o procesador), siempre muestra eso primero.")) {
                    Picker("", selection: Binding(get: { store.config.monitorBarMetric }, set: { store.config.monitorBarMetric = $0; SystemMonitor.shared.tick() })) {
                        Text("CPU").tag("cpu")
                        Text(tx("Memory", "Memoria")).tag("memory")
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 180)
                    .accessibilityLabel(tx("Show in bar", "Mostrar en la barra"))
                }
            }
            SectionTitle(text: tx("macOS Dock", "Dock de macOS"))
            Card {
                SettingRow(title: tx("Hide the macOS Dock", "Ocultar el Dock de macOS"), caption: tx("This bar replaces it. It hides completely and does not come back when you move the mouse near it. Turn it off and it is left exactly as it was.", "Esta barra lo reemplaza. Se esconde por completo y no vuelve a aparecer al acercar el mouse. Al apagarlo, queda exactamente como estaba.")) {
                    Toggle("", isOn: Binding(get: { store.config.hideNativeDock }, set: { DockControl.setHidden($0, store) })).toggleStyle(.switch).labelsHidden()
                        .accessibilityLabel(tx("Hide the macOS Dock", "Ocultar el Dock de macOS"))
                }
                if store.config.hideNativeDock {
                    RowDivider()
                    SettingRow(title: tx("Bring the Dock back when the bar closes", "Devolver el Dock al cerrar la barra"), caption: tx("If you quit Cala, the macOS Dock comes back on its own. It hides again when you reopen it.", "Si sales de Cala, el Dock de macOS vuelve solo. Al abrirla otra vez se oculta de nuevo.")) {
                        Toggle("", isOn: Binding(get: { store.config.restoreDockOnQuit }, set: { store.config.restoreDockOnQuit = $0 })).toggleStyle(.switch).labelsHidden()
                            .accessibilityLabel(tx("Bring the Dock back when the bar closes", "Devolver el Dock al cerrar la barra"))
                    }
                }
            }
            .animation(.easeOut(duration: 0.2), value: store.config.hideNativeDock)
            SectionTitle(text: tx("macOS menu bar", "Barra de menús de macOS"))
            Card {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tx("macOS icons that Cala already shows", "Iconos de macOS que ya muestra Cala")).font(.system(size: 13, weight: .medium))
                    Text(tx("Hides, on the right side of the macOS menu bar, the icons Cala already has. App menus (File, Edit…) are left alone. macOS does not allow hiding the clock, and icons from other apps (Claude, Slack…) are controlled by each app.", "Oculta, en la parte derecha de la barra de macOS, los iconos que Cala ya tiene. Los menús de las apps (Archivo, Edición…) no se tocan. macOS no permite ocultar el reloj, y los iconos de otras apps (Claude, Slack…) los controla cada app."))
                        .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                ForEach(MenuBarIcons.all) { icon in
                    RowDivider()
                    SettingRow(title: icon.title, caption: icon.note) {
                        Toggle("", isOn: Binding(get: { store.config.menuBarHiddenIcons.contains(icon.id) }, set: { on in
                            var set = Set(store.config.menuBarHiddenIcons)
                            if on { set.insert(icon.id) } else { set.remove(icon.id) }
                            store.config.menuBarHiddenIcons = MenuBarIcons.all.map(\.id).filter { set.contains($0) }
                            MenuBarIcons.apply(store)
                        })).toggleStyle(.switch).labelsHidden()
                            .accessibilityLabel(icon.title)
                    }
                }
                RowDivider()
                OtherMenuBarIcons()
                RowDivider()
                SettingRow(title: tx("Bring them back when Cala closes", "Devolverlos al cerrar Cala"), caption: tx("If you quit Cala, the icons show again on their own. They hide again when you reopen it.", "Si sales de Cala, los iconos vuelven a mostrarse solos. Al abrirla otra vez se ocultan de nuevo.")) {
                    Toggle("", isOn: Binding(get: { store.config.restoreMenuBarOnQuit }, set: { store.config.restoreMenuBarOnQuit = $0 })).toggleStyle(.switch).labelsHidden()
                        .accessibilityLabel(tx("Bring them back when Cala closes", "Devolverlos al cerrar Cala"))
                }
            }
            Card {
                SettingRow(title: tx("Hide the whole menu bar", "Ocultar toda la barra de menús"), caption: tx("It hides completely and reappears when you move the mouse to the top edge of the screen. macOS does not allow removing it entirely. Turn it off and it is left exactly as it was.", "Se esconde por completo y reaparece al llevar el mouse al borde superior de la pantalla. macOS no permite quitarla del todo. Al apagarlo, queda exactamente como estaba.")) {
                    Toggle("", isOn: Binding(get: { store.config.hideMenuBar }, set: { MenuBarControl.setHidden($0, store) })).toggleStyle(.switch).labelsHidden()
                        .accessibilityLabel(tx("Hide the whole menu bar", "Ocultar toda la barra de menús"))
                }
            }
            SectionTitle(text: tx("Switch windows", "Cambiar de ventana"))
            Card {
                SettingRow(title: tx("Window switcher (Option + Tab)", "Selector de ventanas (Opción + Tab)"), caption: tx("Hold Option and press Tab: you see all your windows, not just apps. Tab moves forward, Shift+Tab goes back, Esc cancels; when you release Option the chosen one opens.", "Mantén Opción y pulsa Tab: ves todas tus ventanas, no solo las apps. Tab avanza, Mayús+Tab retrocede, Esc cancela; al soltar Opción se abre la elegida.")) {
                    Toggle("", isOn: Binding(get: { store.config.switcherEnabled }, set: { store.config.switcherEnabled = $0 })).toggleStyle(.switch).labelsHidden()
                        .accessibilityLabel(tx("Window switcher (Option + Tab)", "Selector de ventanas (Opción + Tab)"))
                }
                if store.config.switcherEnabled {
                    RowDivider()
                    SettingRow(title: tx("Also use Cmd + Tab", "Usar también Cmd + Tab"), caption: tx("Replaces the macOS app switcher with this one. Needs the Accessibility permission.", "Reemplaza el cambiador de apps de macOS por este. Necesita el permiso de Accesibilidad.")) {
                        Toggle("", isOn: Binding(get: { store.config.switcherReplaceCmdTab }, set: { store.config.switcherReplaceCmdTab = $0 })).toggleStyle(.switch).labelsHidden()
                            .accessibilityLabel(tx("Also use Cmd + Tab", "Usar también Cmd + Tab"))
                    }
                }
            }
            .animation(.easeOut(duration: 0.2), value: store.config.switcherEnabled)
            SectionTitle(text: tx("Previews", "Vistas previas"))
            Card {
                SettingRow(title: tx("Preview delay", "Retardo de la vista previa"), caption: tx("Time before the windows show when you hover over an icon.", "Tiempo antes de mostrar las ventanas al pasar el mouse por un icono.")) {
                    SliderControl(value: Binding(get: { store.config.previewDelay }, set: { store.config.previewDelay = $0 }),
                                  range: 0...0.6, step: 0.01) { $0 < 0.01 ? tx("None", "Ninguno") : "\(Int($0 * 1000)) ms" }
                }
            }
        }
    }
}

// MARK: - Appearance

struct BarPreview: View {
    @ObservedObject var store: ConfigStore
    @Environment(\.colorScheme) private var sys

    private let apps: [(String, [Color])] = [
        ("safari.fill", [BarTheme.hex(0x5AC8FA), BarTheme.hex(0x0A84FF)]),
        ("folder.fill", [BarTheme.hex(0x64D2FF), BarTheme.hex(0x30A0E0)]),
        ("terminal.fill", [BarTheme.hex(0x5E5E66), BarTheme.hex(0x2C2C30)]),
        ("message.fill", [BarTheme.hex(0x6EE07F), BarTheme.hex(0x28B84A)]),
        ("music.note", [BarTheme.hex(0xFF6B8B), BarTheme.hex(0xE0245E)]),
    ]

    var body: some View {
        let t = BarTheme.named(store.config.theme)
        let size = CGFloat(store.config.iconSize)
        ZStack(alignment: .bottom) {
            LinearGradient(colors: [BarTheme.hex(0x7CB7FF), BarTheme.hex(0xA78BFA), BarTheme.hex(0xF0ABFC)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(.white.opacity(0.18)).frame(width: 150).offset(x: 220, y: -40)
            RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.4)).frame(width: 220, height: 64).offset(x: -150, y: -70)
            HStack(spacing: 4) {
                Image(systemName: "square.grid.2x2.fill").font(.system(size: 16)).foregroundStyle(t.accent).frame(width: 34)
                ForEach(Array(apps.enumerated()), id: \.offset) { i, a in
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: size * 0.24)
                            .fill(LinearGradient(colors: a.1, startPoint: .top, endPoint: .bottom))
                            .overlay(Image(systemName: a.0).font(.system(size: size * 0.5)).foregroundStyle(.white))
                            .frame(width: size, height: size)
                            .frame(maxHeight: .infinity)
                        Capsule().fill(i == 0 ? t.accent : Color.secondary).frame(width: i == 0 ? 14 : 5, height: 2.5).padding(.bottom, 1)
                    }
                    .frame(width: size + 10)
                }
                Spacer()
                HStack(spacing: 8) {
                    Image(systemName: "wifi"); Image(systemName: "speaker.wave.2.fill"); Image(systemName: "battery.75")
                }.font(.system(size: 11))
                VStack(alignment: .trailing, spacing: 0) { Text("9:41"); Text("20/11/2026") }.font(.system(size: 9)).padding(.leading, 6)
            }
            .foregroundStyle(.primary.opacity(0.85))
            .padding(.horizontal, 10)
            .frame(height: size + 20)
            .background(t.background.opacity(store.config.barOpacity))
            .environment(\.colorScheme, t.dark.map { $0 ? .dark : .light } ?? sys)
        }
        .frame(height: 150)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        .animation(.easeInOut(duration: 0.25), value: store.config.theme)
        .animation(.easeInOut(duration: 0.2), value: store.config.iconSize)
    }
}

struct ThemeTile: View {
    let theme: BarTheme
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(LinearGradient(colors: theme.colors.isEmpty ? [BarTheme.hex(0xF1F3F6), BarTheme.hex(0x3A3D44)] : theme.colors,
                                             startPoint: .leading, endPoint: .trailing))
                    HStack(spacing: 4) {
                        Circle().fill(theme.accent).frame(width: 7, height: 7)
                        Capsule().fill(.white.opacity(0.55)).frame(width: 14, height: 4)
                        Capsule().fill(.white.opacity(0.35)).frame(width: 10, height: 4)
                    }.padding(.bottom, 9)
                }
                .frame(height: 58)
                .overlay(alignment: .topTrailing) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 16))
                            .foregroundStyle(.white, Color.accentColor).padding(5)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
                .padding(3)
                .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.accentColor, lineWidth: selected ? 2.5 : 0))
                Text(theme.name).font(.system(size: 11.5, weight: selected ? .semibold : .regular))
            }
            .scaleEffect(hover ? 1.03 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.spring(response: 0.28, dampingFraction: 0.75), value: selected)
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}

struct AppearancePane: View {
    @ObservedObject var store: ConfigStore

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            BarPreview(store: store)
            SectionTitle(text: tx("Theme", "Tema"))
            Card {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 14) {
                    ForEach(BarTheme.all) { t in
                        ThemeTile(theme: t, selected: store.config.theme == t.id) { store.config.theme = t.id }
                    }
                }
                .padding(16)
            }
            SectionTitle(text: tx("Settings", "Ajustes"))
            Card {
                SettingRow(title: tx("Transparency", "Transparencia"), caption: tx("Only affects the background; icons and text stay sharp.", "Solo afecta al fondo; los iconos y textos se mantienen nítidos.")) {
                    SliderControl(value: Binding(get: { 1 - store.config.barOpacity }, set: { store.config.barOpacity = 1 - $0 }),
                                  range: 0...0.8, step: 0.02) { "\(Int(($0 * 100).rounded())) %" }
                }
                RowDivider()
                SettingRow(title: tx("Icon size", "Tamaño de los iconos")) {
                    SliderControl(value: Binding(get: { store.config.iconSize }, set: { store.config.iconSize = $0 }),
                                  range: 20...44, step: 2) { "\(Int($0)) pt" }
                }
                RowDivider()
                SettingRow(title: tx("Preview size", "Tamaño de la vista previa"), caption: tx("Width of each window in the preview.", "Ancho de cada ventana en la vista previa.")) {
                    SliderControl(value: Binding(get: { store.config.previewWidth }, set: { store.config.previewWidth = $0 }),
                                  range: 300...560, step: 20) { "\(Int($0)) pt" }
                }
            }
        }
    }
}

// MARK: - Screens

struct AlignOption: View {
    let label: String
    let center: Bool
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06))
                    HStack(spacing: 4) {
                        if center { Spacer(minLength: 0) }
                        ForEach(0..<4) { _ in RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.45)).frame(width: 12, height: 12) }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8).frame(height: 22)
                    .background(Color.primary.opacity(0.08))
                    .environment(\.layoutDirection, .leftToRight)
                }
                .frame(width: 140, height: 62)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(3)
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(selected ? Color.accentColor : Color.primary.opacity(hover ? 0.2 : 0.1), lineWidth: selected ? 2.5 : 1))
                Text(label).font(.system(size: 12, weight: selected ? .semibold : .regular))
            }
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: selected)
    }
}

struct ScreensPane: View {
    @ObservedObject var store: ConfigStore
    @State private var tick = 0

    var body: some View {
        let screens = NSScreen.screens
        VStack(alignment: .leading, spacing: 20) {
            ForEach(Array(screens.enumerated()), id: \.offset) { i, sc in
                let key = sc.key
                let cur = store.config.alignments[key] ?? "left"
                Card {
                    HStack(spacing: 12) {
                        Image(systemName: "display").font(.system(size: 18)).foregroundStyle(.secondary).frame(width: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(sc.localizedName).font(.system(size: 13, weight: .semibold))
                            Text("\(Int(sc.frame.width)) × \(Int(sc.frame.height))").font(.system(size: 11.5)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if i == 0 {
                            Text(tx("Main", "Principal")).font(.system(size: 11, weight: .medium)).foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                        }
                    }
                    .padding(16)
                    RowDivider()
                    VStack(alignment: .leading, spacing: 10) {
                        Text(tx("Icon alignment", "Alineación de los iconos")).font(.system(size: 13, weight: .medium))
                        HStack(spacing: 18) {
                            AlignOption(label: tx("Left", "Izquierda"), center: false, selected: cur == "left") { store.config.alignments[key] = "left" }
                            AlignOption(label: tx("Center", "Centro"), center: true, selected: cur == "center") { store.config.alignments[key] = "center" }
                        }
                    }
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if screens.count > 1 {
                Text(tx("Each screen remembers its own alignment, even if you unplug it.", "Cada pantalla recuerda su propia alineación, aunque la desconectes."))
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).padding(.leading, 4)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in tick += 1 }
    }
}

// MARK: - Permissions

struct PermissionsPane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SectionTitle(text: tx("For the bar", "Para la barra"))
            Card {
                PermissionCard(kind: .accessibility)
                RowDivider()
                PermissionCard(kind: .screenRecording)
            }
            SectionTitle(text: tx("Optional", "Opcionales"))
            Card {
                ForEach(Array([PermissionKind.calendar, .location, .bluetooth, .automation, .notifications].enumerated()), id: \.element) { i, kind in
                    if i > 0 { RowDivider() }
                    PermissionCard(kind: kind)
                }
            }
            HStack(alignment: .top) {
                Text(tx("Cala never changes these by itself: it asks, or opens the right pane of System Settings. Status updates on its own.",
                        "Cala nunca los cambia por su cuenta: los pide, o abre el panel justo de Ajustes del Sistema. El estado se actualiza solo."))
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Button(tx("Show the welcome again", "Ver la bienvenida otra vez")) { OnboardingWindowController.shared.show() }
            }
            .padding(.leading, 4)
        }
        .onAppear { PermissionCenter.shared.beginWatching() }
        .onDisappear { PermissionCenter.shared.endWatching() }
    }
}

// MARK: - Advanced

struct AdvancedPane: View {
    @ObservedObject var store: ConfigStore
    @State private var confirmReset = false
    @State private var confirmQuit = false

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            Card {
                SettingRow(title: tx("Configuration file", "Archivo de configuración"), caption: tx("All settings in JSON format.", "Todos los ajustes en formato JSON.")) {
                    Button(tx("Open", "Abrir")) { NSWorkspace.shared.open(store.fileURL) }
                }
                RowDivider()
                SettingRow(title: tx("Debug log", "Registro de depuración"), caption: tx("Useful if something goes wrong.", "Útil si algo falla.")) {
                    Button(tx("Show in Finder", "Mostrar en Finder")) {
                        let log = store.fileURL.deletingLastPathComponent().appendingPathComponent("debug.log")
                        NSWorkspace.shared.activateFileViewerSelecting([log])
                    }
                }
            }
            Card {
                SettingRow(title: tx("Report a problem", "Reportar un problema"), caption: tx("Tell us what is broken or what you would like. You will see exactly what is sent before it goes out.", "Cuéntanos qué falla o qué te gustaría. Verás exactamente qué se envía antes de enviarlo.")) {
                    Button(tx("Report…", "Reportar…")) { FeedbackWindowController.shared.show() }
                }
                RowDivider()
                SettingRow(title: tx("Suggest restarting the Mac", "Recomendar reiniciar el Mac"), caption: tx("In the CPU and memory panel, tells you when a restart is a good idea and explains why: a pending update, many days powered on, heavy swap or memory under pressure.", "En el panel de CPU y memoria, avisa cuando conviene reiniciar y explica los motivos: actualización pendiente, muchos días encendido, mucho swap o memoria bajo presión.")) {
                    Toggle("", isOn: Binding(get: { store.config.restartAdvice }, set: { store.config.restartAdvice = $0 })).toggleStyle(.switch).labelsHidden()
                        .accessibilityLabel(tx("Suggest restarting the Mac", "Recomendar reiniciar el Mac"))
                }
                RowDivider()
                SettingRow(title: tx("Reopen Cala if it quits on its own", "Volver a abrir Cala si se cierra sola"), caption: tx("If Cala crashes, it opens again within a few seconds so you are never left without a bar. If it crashes three times in a row, it stops to avoid a loop.", "Si Cala falla, se abre otra vez en unos segundos para que nunca te quedes sin barra. Si falla tres veces seguidas, se detiene para no entrar en un bucle.")) {
                    Toggle("", isOn: Binding(get: { store.config.relaunchOnCrash }, set: { store.config.relaunchOnCrash = $0; Watchdog.sync(store) })).toggleStyle(.switch).labelsHidden()
                        .accessibilityLabel(tx("Reopen Cala if it quits on its own", "Volver a abrir Cala si se cierra sola"))
                }
                RowDivider()
                SettingRow(title: tx("If Cala quits on its own", "Si Cala se cierra sola"), caption: tx("When you open it again it can offer to send a crash report. It does not include your files, windows or passwords.", "Al abrirla de nuevo puede ofrecerte enviar un informe del fallo. No incluye tus archivos, ventanas ni contraseñas.")) {
                    Picker("", selection: Binding(get: { store.config.crashReports }, set: { store.config.crashReports = $0 })) {
                        Text(tx("Ask me", "Preguntarme")).tag("ask")
                        Text(tx("Send without asking", "Enviar sin preguntar")).tag("auto")
                        Text(tx("Never send", "No enviar nunca")).tag("never")
                    }.labelsHidden().frame(width: 190)
                    .accessibilityLabel(tx("If Cala quits on its own", "Si Cala se cierra sola"))
                }
            }
            Card {
                SettingRow(title: tx("Reset appearance", "Restablecer apariencia"), caption: tx("Returns the theme, transparency and sizes to their original values. Your pinned apps are not touched.", "Vuelve el tema, la transparencia y los tamaños a sus valores originales. No toca tus apps ancladas.")) {
                    Button(tx("Reset…", "Restablecer…"), role: .destructive) { confirmReset = true }
                }
            }
            .confirmationDialog(tx("Reset the appearance?", "¿Restablecer la apariencia?"), isPresented: $confirmReset) {
                Button(tx("Reset", "Restablecer"), role: .destructive) {
                    let d = Config()
                    store.config.theme = d.theme; store.config.barOpacity = d.barOpacity
                    store.config.iconSize = d.iconSize; store.config.previewWidth = d.previewWidth
                    store.config.previewDelay = d.previewDelay
                }
            }
            Card {
                SettingRow(title: tx("Quit Cala", "Salir de Cala"), caption: tx("To open it again, search for \u{201C}Cala\u{201D} in Launchpad or Spotlight.", "Para volver a abrirla, busca \u{201C}Cala\u{201D} en Launchpad o Spotlight.")) {
                    Button(tx("Quit…", "Salir…"), role: .destructive) { confirmQuit = true }
                }
            }
            .confirmationDialog(tx("Quit Cala?", "¿Salir de Cala?"), isPresented: $confirmQuit) {
                Button(tx("Quit", "Salir"), role: .destructive) { NSApp.terminate(nil) }
            } message: { Text(tx("The bar will disappear until you open the app again.", "La barra desaparecerá hasta que vuelvas a abrir la app.")) }
            Card {
                SettingRow(title: tx("Uninstall Cala", "Desinstalar Cala"),
                           caption: tx("Puts the Dock and menu bar back, stops opening at login, deletes Cala's settings and moves the app to the Trash.",
                                       "Devuelve el Dock y la barra de menús, deja de abrirse al iniciar sesión, borra los ajustes de Cala y mueve la app a la Papelera.")) {
                    Button(tx("Uninstall…", "Desinstalar…"), role: .destructive) { Uninstaller.confirmAndRun(store: store) }
                }
            }
        }
    }
}

struct UsageSettingsPane: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject private var usage = UsageService.shared
    private enum FolderField: Hashable { case claude, codex }
    @State private var claudeFolder = ""
    @State private var codexFolder = ""
    @FocusState private var focusedFolder: FolderField?
    private func applyFolder(_ field: FolderField) {
        if field == .claude { store.config.usageClaudeConfigDir = claudeFolder }
        else { store.config.usageCodexHome = codexFolder }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            Card {
                SettingRow(title: tx("Usage", "Uso"), caption: tx("Show remaining AI plan usage to the left of the battery.", "Muestra lo que te queda de tus planes de IA a la izquierda de la batería.")) {
                    Toggle(tx("Usage", "Uso"), isOn: $store.config.usageEnabled).labelsHidden().toggleStyle(.switch)
                }
            }
            Card {
                SettingRow(title: calendarText("Quota alerts", "Alertas de cuota"), caption: calendarText("Notify when a quota is low or, at the current pace, will run out before it resets.", "Avisa cuando una cuota está baja o, al ritmo actual, se agotará antes del reinicio.")) {
                    Toggle(calendarText("Quota alerts", "Alertas de cuota"), isOn: Binding(get: { store.config.usageAlertsEnabled }, set: { on in
                        store.config.usageAlertsEnabled = on
                        if on { UsagePace.shared.requestAuthorization() }
                    })).labelsHidden().toggleStyle(.switch)
                }
                if store.config.usageAlertsEnabled {
                    RowDivider()
                    SettingRow(title: calendarText("Alert when left is", "Avisar cuando quede"), caption: calendarText("Remaining share of a quota at or below which you are notified.", "Porcentaje restante de una cuota a partir del cual se te avisa.")) {
                        Picker("", selection: $store.config.usageAlertThreshold) {
                            ForEach([10, 15, 20, 30], id: \.self) { Text("\($0)%").tag($0) }
                        }.labelsHidden().frame(width: 90)
                        .accessibilityLabel(calendarText("Alert when left is", "Avisar cuando quede"))
                    }
                }
            }
            .animation(.easeOut(duration: 0.2), value: store.config.usageAlertsEnabled)
            Card {
                SettingRow(title: "Claude", caption: usage.providers.first { $0.provider == .claude }?.detection) {
                    Toggle("Claude", isOn: $store.config.usageClaudeEnabled).labelsHidden().toggleStyle(.switch)
                }
                RowDivider()
                SettingRow(title: "Codex", caption: usage.providers.first { $0.provider == .codex }?.detection) {
                    Toggle("Codex", isOn: $store.config.usageCodexEnabled).labelsHidden().toggleStyle(.switch)
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Text(tx("Custom folders (optional)", "Carpetas personalizadas (opcional)")).font(.system(size: 13, weight: .medium))
                    Text(tx("Leave blank to use your login shell configuration, then ~/.claude or ~/.codex.", "Déjalo vacío para usar la configuración de tu shell de inicio de sesión y luego ~/.claude o ~/.codex.")).font(.system(size: 11)).foregroundStyle(.secondary)
                    TextField(tx("Claude config dir", "Carpeta de configuración de Claude"), text: $claudeFolder).textFieldStyle(.roundedBorder)
                        .focused($focusedFolder, equals: .claude).onSubmit { applyFolder(.claude) }
                    TextField(tx("Codex home", "Carpeta de Codex"), text: $codexFolder).textFieldStyle(.roundedBorder)
                        .focused($focusedFolder, equals: .codex).onSubmit { applyFolder(.codex) }
                }.padding(16)
            }
            Card {
                SettingRow(title: tx("Claude Code live updates (statusLine)", "Actualizaciones en vivo de Claude Code (statusLine)"), caption: tx("Opt in to local updates. Backs up settings.json and preserves existing statusLine commands.", "Actívalo para recibir datos locales. Hace una copia de settings.json y conserva los comandos statusLine que ya tengas.")) {
                    Toggle(tx("Claude Code live updates", "Actualizaciones en vivo de Claude Code"), isOn: $store.config.usageClaudeStatusLine).labelsHidden().toggleStyle(.switch)
                }
                if !usage.statusLineMessage.isEmpty {
                    Text(usage.statusLineMessage).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled).padding(16)
                }
            }
        }
        .onAppear {
            claudeFolder = store.config.usageClaudeConfigDir; codexFolder = store.config.usageCodexHome
            usage.settingsOpened()
        }
        .onChange(of: focusedFolder) { old, _ in if let old { applyFolder(old) } }
        .onDisappear { applyFolder(.claude); applyFolder(.codex) }
    }
}

// MARK: - Tray pane

struct TrayPane: View {
    @ObservedObject var store: ConfigStore

    private func place(_ id: String) -> Binding<TrayPlace> {
        Binding(get: { store.config.place(id) }, set: { p in
            var layout = store.config.trayLayout
            layout[id] = p.rawValue
            store.config.trayLayout = layout
        })
    }
    var body: some View {
        let ids = store.config.orderedTrayIDs
        VStack(alignment: .leading, spacing: 20) {
            Card {
                VStack(alignment: .leading, spacing: 6) {
                    Text(tx("Choose where each thing goes", "Elige dónde va cada cosa")).font(.system(size: 13, weight: .semibold))
                    Text(LocalizedStringKey(tx("**On the bar**: always visible. **In ^**: shows when you click the ^ arrow at the start of the tray. **Hidden**: not shown. Top to bottom is the order from left to right on the bar.", "**En la barra**: siempre visible. **En ^**: aparece al pulsar la flecha ^ al inicio de la bandeja. **Oculto**: no se muestra. De arriba hacia abajo es el orden de izquierda a derecha en la barra.")))
                        .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 8) {
                List {
                    ForEach(ids, id: \.self) { id in
                        if let info = TrayItems.info(id) {
                            HStack(spacing: 12) {
                                Image(systemName: "line.3.horizontal").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary).frame(width: 14)
                                Group {
                                    if id == trayMail { MailTrayGlyph(unread: 0) }
                                    else { TrayGlyph(id: id, model: (NSApp.delegate as? AppDelegate)?.bar?.model) }
                                }.frame(width: 26, height: 22).foregroundStyle(.secondary)
                                Text(info.title).font(.system(size: 13, weight: .medium))
                                Spacer()
                                Picker("", selection: place(id)) {
                                    ForEach(TrayPlace.allCases) { Text($0.title).tag($0) }
                                }.pickerStyle(.segmented).labelsHidden().frame(width: 250)
                                    .accessibilityLabel(info.title)
                            }
                            .frame(height: 46)
                            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                        }
                    }
                    .onMove { from, to in
                        var order = ids
                        order.move(fromOffsets: from, toOffset: to)
                        store.config.trayOrder = order
                    }
                }
                .listStyle(.plain).scrollContentBackground(.hidden).scrollDisabled(true)
                .frame(height: CGFloat(ids.count) * 46 + 12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                Text(tx("Drag a row to change the order.", "Arrastra una fila para cambiar el orden.")).font(.system(size: 11)).foregroundStyle(.secondary).padding(.leading, 4)
            }
            Button(tx("Reset values", "Restablecer valores")) { store.config.trayLayout = [:]; store.config.trayOrder = [] }
        }
    }
}


/// Icons from other apps currently on the right of the menu bar. Cala cannot hide them (each app owns its icon), but it
/// tells you which app each one is and opens the system pane where macOS lets you switch them off.
struct OtherMenuBarIcons: View {
    @State private var items: [MenuBarDiagnostics.Extra] = []
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tx("Other icons that are still there", "Otros iconos que siguen ahí")).font(.system(size: 13, weight: .medium))
            if !loaded {
                Text(tx("Searching…", "Buscando…")).font(.system(size: 11.5)).foregroundStyle(.secondary)
            } else if items.isEmpty {
                Text(tx("There are no icons from other apps.", "No hay iconos de otras apps.")).font(.system(size: 11.5)).foregroundStyle(.secondary)
            } else {
                ForEach(items) { item in
                    HStack(spacing: 8) {
                        Image(systemName: "circle.fill").font(.system(size: 4)).foregroundStyle(.tertiary)
                        Text(item.app).font(.system(size: 12))
                        if !item.detail.isEmpty && item.detail != item.app { Text("· " + item.detail).font(.system(size: 11.5)).foregroundStyle(.secondary) }
                    }
                }
            }
            Text(tx("Each app decides its own icon: turn it off in that app's settings, or from System Settings → Menu Bar, where macOS lets you choose which are allowed.", "Cada app decide su icono: apágalo en los ajustes de esa app, o desde Ajustes del Sistema → Barra de menús, donde macOS deja elegir cuáles se permiten."))
                .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(tx("Open Settings → Menu Bar", "Abrir Ajustes → Barra de menús")) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension")!)
                }
                Button(tx("Search again", "Volver a buscar")) { reload() }
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { reload() }
    }

    private func reload() {
        loaded = false
        DispatchQueue.global(qos: .userInitiated).async {
            let found = MenuBarDiagnostics.extras()
            DispatchQueue.main.async { items = found; loaded = true }
        }
    }
}

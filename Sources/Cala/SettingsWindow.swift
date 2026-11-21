import SwiftUI
import AppKit
import CoreLocation
import CoreBluetooth

// MARK: - Window

final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        UsageService.shared.settingsOpened()
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 840, height: 600),
                             styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.title = "Cala · Configuración"
            w.contentView = NSHostingView(rootView: SettingsView(store: ConfigStore.shared))
            w.contentMinSize = NSSize(width: 780, height: 540)
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Launch-at-login, implemented as a user LaunchAgent owned by this app.
enum LoginItem {
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/local.cala.plist")
    }
    /// Launch agent written by the app under its former name (MacTaskbar).
    static var legacyURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/local.mactaskbar.plist")
    }
    /// One-time move of the old launch-at-login agent to the new label, keeping the on/off state.
    /// Only re-enabled from ~/Applications, never from a build folder.
    static func migrateLegacy() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacyURL.path) else { return }
        try? fm.removeItem(at: legacyURL)
        if Bundle.main.bundlePath.hasPrefix(fm.homeDirectoryForCurrentUser.path + "/Applications/") { set(true) }
    }
    static var enabled: Bool { FileManager.default.fileExists(atPath: url.path) }
    static func set(_ on: Bool) {
        if on {
            let dict: [String: Any] = ["Label": "local.cala",
                                       "ProgramArguments": ["/usr/bin/open", "-a", Bundle.main.bundlePath],
                                       "RunAtLoad": true]
            guard let data = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

// MARK: - Structure

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, appearance, screens, usage, calendar, permissions, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "General"; case .appearance: "Apariencia"; case .screens: "Pantallas"
        case .calendar: "Calendar"
        case .usage: "Usage"
        case .permissions: "Permisos"; case .about: "Avanzado"
        }
    }
    var subtitle: String {
        switch self {
        case .general: "Comportamiento de la barra y del inicio."
        case .appearance: "Colores, transparencia y tamaños."
        case .screens: "Cómo se acomoda la barra en cada pantalla."
        case .calendar: "Upcoming events from your macOS calendar accounts."
        case .usage: "Claude and Codex plan usage in one tray control."
        case .permissions: "Lo que macOS debe permitir para que todo funcione."
        case .about: "Archivos, registro y valores de fábrica."
        }
    }
    var icon: String {
        switch self {
        case .general: "gearshape.fill"; case .appearance: "paintpalette.fill"; case .screens: "display"
        case .calendar: "calendar"
        case .usage: "chart.bar.fill"
        case .permissions: "lock.shield.fill"; case .about: "wrench.and.screwdriver.fill"
        }
    }
    var color: Color {
        switch self {
        case .general: Color(red: 0.55, green: 0.57, blue: 0.62); case .appearance: Color(red: 0.95, green: 0.35, blue: 0.55)
        case .screens: Color(red: 0.25, green: 0.52, blue: 0.98); case .permissions: Color(red: 0.2, green: 0.72, blue: 0.4)
        case .calendar: .red
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
                    Text("Configuración").font(.system(size: 11)).foregroundStyle(.secondary)
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
        case .calendar: CalendarSettingsPane(store: store)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            Card {
                SettingRow(title: "Ocultar la barra automáticamente", caption: "Se esconde y aparece al llevar el mouse al borde inferior de la pantalla.") {
                    Toggle("", isOn: Binding(get: { store.config.autoHide }, set: { store.config.autoHide = $0 })).toggleStyle(.switch).labelsHidden()
                }
                RowDivider()
                SettingRow(title: "Abrir al iniciar sesión", caption: "La barra arranca sola cada vez que entras a tu usuario.") {
                    Toggle("", isOn: Binding(get: { login }, set: { login = $0; LoginItem.set($0) })).toggleStyle(.switch).labelsHidden()
                }
            }
            SectionTitle(text: "Sistema")
            Card {
                SettingRow(title: "Monitor del sistema", caption: "Muestra el uso de CPU en la barra. Al hacer clic ves memoria, qué apps usan más y por qué el Mac puede estar lento.") {
                    Toggle("", isOn: Binding(get: { store.config.monitorEnabled }, set: { store.config.monitorEnabled = $0 })).toggleStyle(.switch).labelsHidden()
                }
            }
            SectionTitle(text: "Disco")
            Card {
                SettingRow(title: "Espacio libre en la barra", caption: "Muestra el porcentaje libre del disco junto a la batería. Al hacer clic ves el detalle y dónde se va el espacio.") {
                    Toggle("", isOn: Binding(get: { store.config.diskEnabled }, set: { store.config.diskEnabled = $0 })).toggleStyle(.switch).labelsHidden()
                }
                if store.config.diskEnabled {
                    RowDivider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Carpetas extra a medir").font(.system(size: 13, weight: .medium))
                        Text("Separadas por coma, por ejemplo donde viven tus proyectos o worktrees. Se suman a la lista de caches y herramientas de desarrollo.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        TextField("~/Projects, ~/worktrees", text: $diskFolders).textFieldStyle(.roundedBorder).onSubmit { applyDiskFolders() }
                            .onAppear { diskFolders = store.config.diskFolders.joined(separator: ", ") }
                    }
                    .padding(.vertical, 6)
                }
            }
            .animation(.easeOut(duration: 0.2), value: store.config.diskEnabled)
            SectionTitle(text: "Dock de macOS")
            Card {
                SettingRow(title: "Ocultar el Dock de macOS", caption: "Esta barra lo reemplaza. Se esconde por completo y no vuelve a aparecer al acercar el mouse. Al apagarlo, queda exactamente como estaba.") {
                    Toggle("", isOn: Binding(get: { store.config.hideNativeDock }, set: { DockControl.setHidden($0, store) })).toggleStyle(.switch).labelsHidden()
                }
                if store.config.hideNativeDock {
                    RowDivider()
                    SettingRow(title: "Devolver el Dock al cerrar la barra", caption: "Si sales de Cala, el Dock de macOS vuelve solo. Al abrirla otra vez se oculta de nuevo.") {
                        Toggle("", isOn: Binding(get: { store.config.restoreDockOnQuit }, set: { store.config.restoreDockOnQuit = $0 })).toggleStyle(.switch).labelsHidden()
                    }
                }
            }
            .animation(.easeOut(duration: 0.2), value: store.config.hideNativeDock)
            SectionTitle(text: "Cambiar de ventana")
            Card {
                SettingRow(title: "Selector de ventanas (Opción + Tab)", caption: "Mantén Opción y pulsa Tab: ves todas tus ventanas, no solo las apps. Tab avanza, Mayús+Tab retrocede, Esc cancela; al soltar Opción se abre la elegida.") {
                    Toggle("", isOn: Binding(get: { store.config.switcherEnabled }, set: { store.config.switcherEnabled = $0 })).toggleStyle(.switch).labelsHidden()
                }
                if store.config.switcherEnabled {
                    RowDivider()
                    SettingRow(title: "Usar también Cmd + Tab", caption: "Reemplaza el cambiador de apps de macOS por este. Necesita el permiso de Accesibilidad.") {
                        Toggle("", isOn: Binding(get: { store.config.switcherReplaceCmdTab }, set: { store.config.switcherReplaceCmdTab = $0 })).toggleStyle(.switch).labelsHidden()
                    }
                }
            }
            .animation(.easeOut(duration: 0.2), value: store.config.switcherEnabled)
            SectionTitle(text: "Previews")
            Card {
                SettingRow(title: "Retardo del preview", caption: "Tiempo antes de mostrar las ventanas al pasar el mouse por un icono.") {
                    SliderControl(value: Binding(get: { store.config.previewDelay }, set: { store.config.previewDelay = $0 }),
                                  range: 0...0.6, step: 0.01) { $0 < 0.01 ? "Ninguno" : "\(Int($0 * 1000)) ms" }
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
            SectionTitle(text: "Tema")
            Card {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 14) {
                    ForEach(BarTheme.all) { t in
                        ThemeTile(theme: t, selected: store.config.theme == t.id) { store.config.theme = t.id }
                    }
                }
                .padding(16)
            }
            SectionTitle(text: "Ajustes")
            Card {
                SettingRow(title: "Transparencia", caption: "Solo afecta al fondo; los iconos y textos se mantienen nítidos.") {
                    SliderControl(value: Binding(get: { 1 - store.config.barOpacity }, set: { store.config.barOpacity = 1 - $0 }),
                                  range: 0...0.8, step: 0.02) { "\(Int(($0 * 100).rounded())) %" }
                }
                RowDivider()
                SettingRow(title: "Tamaño de los iconos") {
                    SliderControl(value: Binding(get: { store.config.iconSize }, set: { store.config.iconSize = $0 }),
                                  range: 20...44, step: 2) { "\(Int($0)) pt" }
                }
                RowDivider()
                SettingRow(title: "Tamaño del preview", caption: "Ancho de cada ventana en la vista previa.") {
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
                            Text("Principal").font(.system(size: 11, weight: .medium)).foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                        }
                    }
                    .padding(16)
                    RowDivider()
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Alineación de los iconos").font(.system(size: 13, weight: .medium))
                        HStack(spacing: 18) {
                            AlignOption(label: "Izquierda", center: false, selected: cur == "left") { store.config.alignments[key] = "left" }
                            AlignOption(label: "Centro", center: true, selected: cur == "center") { store.config.alignments[key] = "center" }
                        }
                    }
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if screens.count > 1 {
                Text("Cada pantalla recuerda su propia alineación, aunque la desconectes.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).padding(.leading, 4)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in tick += 1 }
    }
}

// MARK: - Permissions

struct PermissionRow: View {
    let icon: String, title: String, caption: String, granted: Bool, pane: String
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(granted ? Color.green.gradient : Color.orange.gradient))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(caption).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if granted {
                Label("Concedido", systemImage: "checkmark.circle.fill").font(.system(size: 12, weight: .medium)).foregroundStyle(.green)
            } else {
                Button("Abrir ajustes") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
                }.controlSize(.small)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }
}

struct PermissionsPane: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.5)) { _ in
            let loc = CLLocationManager().authorizationStatus
            VStack(alignment: .leading, spacing: 20) {
                Card {
                    PermissionRow(icon: "hand.raised.fill", title: "Accesibilidad", caption: "Leer y controlar las ventanas de otras apps (preview, cerrar, enfocar).",
                                  granted: AXIsProcessTrusted(), pane: "Privacy_Accessibility")
                    RowDivider()
                    PermissionRow(icon: "rectangle.dashed.badge.record", title: "Grabación de pantalla", caption: "Capturar las miniaturas de las ventanas.",
                                  granted: CGPreflightScreenCaptureAccess(), pane: "Privacy_ScreenCapture")
                    RowDivider()
                    PermissionRow(icon: "location.fill", title: "Ubicación", caption: "macOS la exige para mostrar los nombres de las redes Wi-Fi.",
                                  granted: loc == .authorizedAlways, pane: "Privacy_LocationServices")
                    RowDivider()
                    PermissionRow(icon: "dot.radiowaves.left.and.right", title: "Bluetooth", caption: "Mostrar y conectar tus dispositivos desde la bandeja.",
                                  granted: CBManager.authorization == .allowedAlways, pane: "Privacy_Bluetooth")
                }
                Text("La barra nunca cambia ajustes del sistema por su cuenta: aquí solo se muestra el estado y se abre el panel correspondiente.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).padding(.leading, 4)
            }
        }
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
                SettingRow(title: "Archivo de configuración", caption: "Todos los ajustes en formato JSON.") {
                    Button("Abrir") { NSWorkspace.shared.open(store.fileURL) }
                }
                RowDivider()
                SettingRow(title: "Registro de depuración", caption: "Útil si algo falla.") {
                    Button("Mostrar en Finder") {
                        let log = store.fileURL.deletingLastPathComponent().appendingPathComponent("debug.log")
                        NSWorkspace.shared.activateFileViewerSelecting([log])
                    }
                }
            }
            Card {
                SettingRow(title: "Restablecer apariencia", caption: "Vuelve el tema, la transparencia y los tamaños a sus valores originales. No toca tus apps ancladas.") {
                    Button("Restablecer…", role: .destructive) { confirmReset = true }
                }
            }
            .confirmationDialog("¿Restablecer la apariencia?", isPresented: $confirmReset) {
                Button("Restablecer", role: .destructive) {
                    let d = Config()
                    store.config.theme = d.theme; store.config.barOpacity = d.barOpacity
                    store.config.iconSize = d.iconSize; store.config.previewWidth = d.previewWidth
                    store.config.previewDelay = d.previewDelay
                }
            }
            Card {
                SettingRow(title: "Salir de Cala", caption: "Para volver a abrirla, busca \u{201C}Cala\u{201D} en Launchpad o Spotlight.") {
                    Button("Salir…", role: .destructive) { confirmQuit = true }
                }
            }
            .confirmationDialog("¿Salir de Cala?", isPresented: $confirmQuit) {
                Button("Salir", role: .destructive) { NSApp.terminate(nil) }
            } message: { Text("La barra desaparecerá hasta que vuelvas a abrir la app.") }
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
                SettingRow(title: "Usage", caption: "Show remaining AI plan usage to the left of the battery.") {
                    Toggle("Usage", isOn: $store.config.usageEnabled).labelsHidden().toggleStyle(.switch)
                }
            }
            Card {
                SettingRow(title: calendarText("Quota alerts", "Alertas de cuota"), caption: calendarText("Notify when a quota is low or, at the current pace, will run out before it resets.", "Avisa cuando una cuota está baja o, al ritmo actual, se agotará antes del reinicio.")) {
                    Toggle("Quota alerts", isOn: Binding(get: { store.config.usageAlertsEnabled }, set: { on in
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
                    Text("Custom folders (optional)").font(.system(size: 13, weight: .medium))
                    Text("Leave blank to use your login shell configuration, then ~/.claude or ~/.codex.").font(.system(size: 11)).foregroundStyle(.secondary)
                    TextField("Claude config dir", text: $claudeFolder).textFieldStyle(.roundedBorder)
                        .focused($focusedFolder, equals: .claude).onSubmit { applyFolder(.claude) }
                    TextField("Codex home", text: $codexFolder).textFieldStyle(.roundedBorder)
                        .focused($focusedFolder, equals: .codex).onSubmit { applyFolder(.codex) }
                }.padding(16)
            }
            Card {
                SettingRow(title: "Claude Code live updates (statusLine)", caption: "Opt in to local updates. Backs up settings.json and preserves existing statusLine commands.") {
                    Toggle("Claude Code live updates", isOn: $store.config.usageClaudeStatusLine).labelsHidden().toggleStyle(.switch)
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

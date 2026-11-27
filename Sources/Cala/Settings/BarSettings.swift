import SwiftUI
import AppKit

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
        let _ = tick
        let screens = NSScreen.screens
        VStack(alignment: .leading, spacing: 20) {
            if screens.isEmpty { Text(tx("No displays connected", "No hay pantallas conectadas")).foregroundStyle(.secondary) }
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

struct BarSettingsPane: View {
    @ObservedObject var store: ConfigStore
    let open: (SettingsPane) -> Void
    @State private var confirmReset = false

    var body: some View {
        let attentionEdgeTitle = tx("Glow at the edge when an app needs attention", "Avisar en el borde cuando una app pide atención")
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                Button(tx("Style and previews", "Aspecto y vistas previas")) { open(.barStyle) }
                Button(tx("Displays", "Pantallas")) { open(.screens) }
            }.buttonStyle(.link)
            SectionTitle(text: tx("Hiding", "Ocultación"))
            Card {
                SettingRow(title: tx("Hide the bar automatically", "Ocultar la barra automáticamente"), caption: tx("It hides, and shows again when you move the mouse to the bottom edge of the screen.", "Se esconde y aparece al llevar el mouse al borde inferior de la pantalla.")) {
                    Toggle("", isOn: Binding(get: { store.config.autoHide }, set: { store.config.autoHide = $0 })).toggleStyle(.switch).labelsHidden()
                        .accessibilityLabel(tx("Hide the bar automatically", "Ocultar la barra automáticamente"))
                }
                RowDivider()
                SettingRow(title: attentionEdgeTitle,
                           caption: tx("A glow appears below the app’s icon only while the bar is hidden.",
                                       "Muestra un resplandor debajo del icono de la app solo mientras la barra está oculta.")) {
                    Toggle("", isOn: Binding(get: { store.config.attentionEdgeCue }, set: { store.config.attentionEdgeCue = $0 }))
                        .toggleStyle(.switch).labelsHidden()
                        .accessibilityLabel(attentionEdgeTitle)
                }
                .disabled(!store.config.autoHide)
            }
            SectionTitle(text: tx("macOS Dock", "Dock de macOS"))
            dock
            SectionTitle(text: tx("macOS menu bar", "Barra de menús de macOS"))
            menuBar
            SectionTitle(text: tx("Taskbar style and previews", "Aspecto de la barra y vistas previas"))
                .id("barStyle")
            BarPreview(store: store)
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
                SettingRow(title: tx("Preview delay", "Retardo de la vista previa"), caption: tx("Time before the windows show when you hover over an icon.", "Tiempo antes de mostrar las ventanas al pasar el mouse por un icono.")) {
                    SliderControl(value: Binding(get: { store.config.previewDelay }, set: { store.config.previewDelay = $0 }),
                                  range: 0...0.6, step: 0.01) { $0 < 0.01 ? tx("None", "Ninguno") : "\(Int($0 * 1000)) ms" }
                }
                RowDivider()
                SettingRow(title: tx("Preview width", "Ancho de la vista previa"), caption: tx("Width of each window in the preview.", "Ancho de cada ventana en la vista previa.")) {
                    SliderControl(value: Binding(get: { store.config.previewWidth }, set: { store.config.previewWidth = $0 }),
                                  range: 300...560, step: 20) { "\(Int($0)) pt" }
                }
                RowDivider()
                SettingRow(title: tx("Cala theme", "Tema de Cala")) {
                    Button(tx("Change theme", "Cambiar tema")) { open(.appearance) }
                }
                RowDivider()
                SettingRow(title: tx("Restore default appearance", "Recuperar el aspecto predeterminado")) {
                    Button(tx("Reset taskbar appearance…", "Restablecer aspecto de la barra…")) { confirmReset = true }
                }
            }
            .alert(tx("Reset taskbar appearance?", "¿Restablecer aspecto de la barra?"), isPresented: $confirmReset) {
                Button(tx("Reset", "Restablecer"), role: .destructive, action: resetAppearance)
                Button(tx("Cancel", "Cancelar"), role: .cancel) {}
            } message: {
                Text(tx("Resets Cala’s shared theme, taskbar transparency, icon size, and window preview width and delay.",
                        "Restablece el tema compartido de Cala, la transparencia de la barra, el tamaño de los iconos y el ancho y retardo de las vistas previas."))
            }
            SectionTitle(text: tx("Displays", "Pantallas"))
                .id("displays")
            ScreensPane(store: store)
            Text(tx("Right-click an app icon to pin or unpin it. Drag app icons to reorder them.",
                    "Haz clic derecho en el icono de una app para anclarla o desanclarla. Arrastra los iconos para cambiar su orden."))
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
    }

    private var dock: some View {
        Card {
            SettingRow(title: tx("Hide the macOS Dock", "Ocultar el Dock de macOS"), caption: tx("This bar replaces it. It hides completely and does not come back when you move the mouse near it. Turn it off and it is left exactly as it was.", "Esta barra lo reemplaza. Se esconde por completo y no vuelve a aparecer al acercar el mouse. Al apagarlo, queda exactamente como estaba.")) {
                Toggle("", isOn: Binding(get: { store.config.hideNativeDock }, set: { DockControl.setHidden($0, store) })).toggleStyle(.switch).labelsHidden()
                    .accessibilityLabel(tx("Hide the macOS Dock", "Ocultar el Dock de macOS"))
            }
            RowDivider()
            SettingRow(title: tx("Restore the Dock when quitting Cala", "Restaurar el Dock al salir de Cala"), caption: tx("Restores the original Dock settings when you quit. Turning the taskbar off restores them immediately.", "Recupera los ajustes originales del Dock al salir. Si apagas la barra de tareas, se restauran en el momento.")) {
                Toggle("", isOn: Binding(get: { store.config.restoreDockOnQuit }, set: { store.config.restoreDockOnQuit = $0 })).toggleStyle(.switch).labelsHidden()
                    .accessibilityLabel(tx("Restore the Dock when quitting Cala", "Restaurar el Dock al salir de Cala"))
            }
        }
    }

    private var menuBar: some View {
        Card {
            SettingRow(title: tx("Hide the whole menu bar", "Ocultar toda la barra de menús"), caption: tx("It hides completely and reappears when you move the mouse to the top edge of the screen. macOS does not allow removing it entirely. Turn it off and it is left exactly as it was.", "Se esconde por completo y reaparece al llevar el mouse al borde superior de la pantalla. macOS no permite quitarla del todo. Al apagarlo, queda exactamente como estaba.")) {
                Toggle("", isOn: Binding(get: { store.config.hideMenuBar }, set: { MenuBarControl.setHidden($0, store) })).toggleStyle(.switch).labelsHidden()
                    .accessibilityLabel(tx("Hide the whole menu bar", "Ocultar toda la barra de menús"))
            }
            RowDivider()
            SettingRow(title: tx("Restore the menu bar when quitting Cala", "Restaurar la barra de menús al salir de Cala"),
                       caption: tx("Restores the original visibility of the menu bar and its icons when you quit. Turning off the taskbar restores the menu bar immediately. Turning off the tray restores its macOS icons.",
                                   "Recupera la visibilidad original de la barra de menús y sus iconos al salir. Apagar la barra de tareas restaura la barra de menús al instante. Apagar la Bandeja restaura sus iconos de macOS.")) {
                Toggle(tx("Restore the menu bar when quitting Cala", "Restaurar la barra de menús al salir de Cala"), isOn: $store.config.restoreMenuBarOnQuit)
                    .toggleStyle(.switch).labelsHidden()
            }
            RowDivider()
            DisclosureGroup(tx("macOS icons shown by Cala", "Iconos de macOS que muestra Cala")) {
                Text(tx("These choices apply while the tray is running.", "Estos ajustes se aplican mientras la Bandeja está activa."))
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                ForEach(MenuBarIcons.all) { icon in
                    let title = tx("Hide the macOS icon: \(icon.title)", "Ocultar icono de macOS: \(icon.title)")
                    SettingRow(title: title, caption: placement(icon)) {
                        Toggle("", isOn: Binding(get: { store.config.menuBarHiddenIcons.contains(icon.id) }, set: { on in
                            var set = Set(store.config.menuBarHiddenIcons)
                            if on { set.insert(icon.id) } else { set.remove(icon.id) }
                            store.config.menuBarHiddenIcons = MenuBarIcons.all.map(\.id).filter { set.contains($0) }
                            MenuBarIcons.apply(store)
                        })).toggleStyle(.switch).labelsHidden()
                            .accessibilityLabel(title)
                    }
                }
                Button(tx("Open Tray", "Abrir Bandeja")) { open(.tray) }.buttonStyle(.link)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            RowDivider()
            DisclosureGroup(tx("Icons from other apps", "Iconos de otras apps")) {
                OtherMenuBarIcons()
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func placement(_ icon: MenuBarIcons.Icon) -> String {
        let trayID: String
        switch icon.id {
        case "wifi": trayID = trayWifi
        case "battery": trayID = trayBatt
        case "user": trayID = trayUser
        case "input": trayID = trayKB
        default: return icon.note
        }
        let place = store.config.place(trayID)
        let location = place == .hidden
            ? tx("Also hidden in Cala.", "También está oculto en Cala.")
            : tx("Location in Cala: \(place.title).", "Ubicación en Cala: \(place.title).")
        return icon.note + " " + location
    }

    private func resetAppearance() {
        let defaults = Config()
        var config = store.config
        config.theme = defaults.theme
        config.barOpacity = defaults.barOpacity
        config.iconSize = defaults.iconSize
        config.previewWidth = defaults.previewWidth
        config.previewDelay = defaults.previewDelay
        store.config = config
    }
}

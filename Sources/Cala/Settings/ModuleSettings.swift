import SwiftUI

enum ModuleSwitch {
    static func binding(_ id: ModuleID, store: ConfigStore) -> Binding<Bool> {
        Binding(get: { store.config.modules[id] }, set: { on in
            switch id {
            case .bar: store.config.barEnabled = on
            case .switcher: store.config.switcherEnabled = on
            case .tray: store.config.trayEnabled = on
            case .zones: store.config.zonesEnabled = on
            }
            log("settings: module \(id.rawValue) \(on ? "on" : "off")")
        })
    }

    static func enableTray(store: ConfigStore) {
        var config = store.config
        config.barEnabled = true
        config.trayEnabled = true
        store.config = config
    }
}

struct ModulesCard: View {
    @ObservedObject var store: ConfigStore
    let open: (SettingsPane) -> Void

    var body: some View {
        Card {
            ForEach(SettingsPane.modules) { pane in
                if let module = pane.module {
                    if pane != .zones { RowDivider() }
                    HStack(spacing: 12) {
                        SettingsIcon(pane: pane, size: 28)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(pane.title).font(.system(size: 13, weight: .semibold))
                            if let description = pane.subtitle {
                                Text(description).font(.system(size: 11.5)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            ModuleStatus(module: module, store: store)
                        }
                        Spacer(minLength: 4)
                        ModuleToggle(pane: pane, module: module, store: store)
                        Button(tx("Open", "Abrir")) { open(pane) }
                            .accessibilityLabel(tx("Open settings for \(pane.title)", "Abrir ajustes de \(pane.title)"))
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                }
            }
        }
    }
}

struct ModuleHeader: View {
    let pane: SettingsPane
    let module: ModuleID
    @ObservedObject var store: ConfigStore
    @ObservedObject private var permissions = PermissionCenter.shared
    @ObservedObject private var zones = ModuleRegistry.shared.zones
    @Environment(\.settingsSnapshot) private var snapshot

    var body: some View {
        let modules = snapshot?.modules ?? store.config.modules
        let enabled = ModulePlan.effective(modules)[module]
        Card {
            HStack(alignment: .top, spacing: 12) {
                SettingsIcon(pane: pane, size: 34)
                VStack(alignment: .leading, spacing: 5) {
                    Text(pane.title).font(.system(size: 23, weight: .bold)).accessibilityAddTraits(.isHeader)
                    if let description = pane.subtitle {
                        Text(description).font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ModuleStatus(module: module, store: store)
                    if !enabled {
                        if module == .tray, !modules.bar {
                            TrayActivation(store: store)
                        } else {
                            Button(tx("Enable \(pane.title)", "Activar \(pane.title)")) {
                                ModuleSwitch.binding(module, store: store).wrappedValue = true
                            }.buttonStyle(.borderedProminent).padding(.top, 4)
                        }
                    } else if module == .zones, zones.layoutLoadFailed {
                        Button(tx("Retry loading layouts", "Volver a cargar las distribuciones")) {
                            ModuleRegistry.shared.apply(store.config.modules, reason: "retry zones")
                        }.padding(.top, 4)
                    }
                }
                Spacer(minLength: 8)
                ModuleToggle(pane: pane, module: module, store: store)
            }
            .padding(16)
            if enabled && snapshot == nil {
                ForEach(ModulePlan.requiredPermissions(for: module).map(PermissionKind.init)) { kind in
                    if !permissions.granted(kind) {
                        RowDivider()
                        PermissionCard(kind: kind, why: module == .zones ? PermissionKind.zonesAccessibilityWhy : nil)
                    }
                }
            }
        }
    }
}

struct TrayDependencyCard: View {
    @ObservedObject var store: ConfigStore

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                ModuleStatus(module: .tray, store: store)
                TrayActivation(store: store)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }
    }
}

private struct TrayActivation: View {
    @ObservedObject var store: ConfigStore
    @Environment(\.settingsSnapshot) private var snapshot

    var body: some View {
        let needsBar = !(snapshot?.modules ?? store.config.modules).bar
        VStack(alignment: .leading, spacing: 6) {
            Button(needsBar ? tx("Enable Taskbar and Tray", "Activar Barra y Bandeja") : tx("Enable Tray", "Activar Bandeja")) {
                if needsBar { ModuleSwitch.enableTray(store: store) }
                else { ModuleSwitch.binding(.tray, store: store).wrappedValue = true }
            }.buttonStyle(.borderedProminent)
            if needsBar && store.config.hideNativeDock {
                Text(tx("Your saved preference will hide the macOS Dock.", "Tu preferencia guardada ocultará el Dock de macOS."))
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        }.padding(.top, 4)
    }
}

private struct ModuleToggle: View {
    let pane: SettingsPane
    let module: ModuleID
    @ObservedObject var store: ConfigStore
    @Environment(\.settingsSnapshot) private var snapshot

    var body: some View {
        let title = tx("Enable \(pane.title)", "Activar \(pane.title)")
        if let snapshot {
            Toggle(title, isOn: .constant(snapshot.modules[module])).toggleStyle(FlyoutSwitchStyle()).labelsHidden()
        } else {
            Toggle(title, isOn: ModuleSwitch.binding(module, store: store)).toggleStyle(.switch).labelsHidden()
        }
    }
}

private struct ModuleStatus: View {
    let module: ModuleID
    @ObservedObject var store: ConfigStore
    @ObservedObject private var permissions = PermissionCenter.shared
    @ObservedObject private var registry = ModuleRegistry.shared
    @ObservedObject private var switcher = WindowSwitcher.shared
    @ObservedObject private var zones = ModuleRegistry.shared.zones
    @Environment(\.settingsSnapshot) private var snapshot

    var body: some View {
        Text(status).font(.system(size: 11.5)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var status: String {
        let modules = snapshot?.modules ?? store.config.modules
        if module == .tray, !modules.bar {
            return modules.tray
                ? tx("Tray is enabled and paused because the taskbar is off.",
                     "Bandeja activada, en pausa porque la barra de tareas está apagada.")
                : tx("Tray needs the taskbar. The taskbar is off.",
                     "La Bandeja necesita la barra de tareas, que está apagada.")
        }
        guard modules[module] else {
            let off = switch module {
            case .zones: "Desactivadas"
            case .bar, .tray: "Desactivada"
            case .switcher: "Desactivado"
            }
            return tx("Off", off)
        }
        if let snapshot {
            guard snapshot.ready else { return tx("Starting…", "Iniciando…") }
            return module == .switcher ? tx("Option + Tab available", "Opción + Tab disponible") : onStatus
        }
        if registry.waitingForOnboarding {
            return tx("Waiting for the welcome setup.", "Esperando a que termine la bienvenida.")
        }
        if module == .zones, zones.layoutLoadFailed {
            return tx("Cala couldn’t load the zone layouts.", "Cala no pudo cargar las distribuciones de zonas.")
        }
        if module == .zones, zones.layoutSaveFailed {
            return tx("Cala couldn’t save the zone layouts.", "Cala no pudo guardar las distribuciones de zonas.")
        }
        if module != .tray, !permissions.granted(.accessibility) {
            if module == .bar { return tx("Accessibility is needed to control windows.", "Hace falta Accesibilidad para controlar las ventanas.") }
            return tx("Waiting for macOS access", "Esperando acceso de macOS")
        }
        let ready: Bool
        switch module {
        case .switcher: ready = switcher.keyTapReady
        case .zones: ready = zones.dragTapReady
        case .tray, .bar: ready = registry.runningModules[module]
        }
        guard ready else {
            if module == .switcher {
                return tx("Starting… Cala will retry the shortcut.", "Iniciando… Cala volverá a intentar activar el atajo.")
            }
            return tx("Starting…", "Iniciando…")
        }
        if module == .switcher {
            return permissions.granted(.screenRecording)
                ? tx("Option + Tab available", "Opción + Tab disponible")
                : tx("Option + Tab available · No thumbnails", "Opción + Tab disponible · Sin miniaturas")
        }
        if module == .bar, !permissions.granted(.screenRecording) {
            return tx("On · No window thumbnails", "Activada · Sin miniaturas de ventanas")
        }
        return onStatus
    }

    private var onStatus: String { tx("On", module == .zones ? "Activadas" : "Activada") }
}

struct SwitcherSettingsPane: View {
    @ObservedObject var store: ConfigStore

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Card {
                SettingRow(title: tx("Keyboard shortcut", "Atajo de teclado"),
                           caption: tx("Hold Option and press Tab. Add Shift to go backwards.", "Mantén Opción y pulsa Tab. Añade Mayús para retroceder.")) {
                    Text(tx("Option + Tab", "Opción + Tab")).font(.system(size: 21, weight: .semibold))
                }
                RowDivider()
                SettingRow(title: tx("Also use Command + Tab", "Usar también Comando + Tab"),
                           caption: tx("Replaces the macOS app switcher while Cala’s window switcher is available.",
                                       "Sustituye el selector de apps de macOS mientras el selector de ventanas de Cala está disponible.")) {
                    Toggle(tx("Also use Command + Tab", "Usar también Comando + Tab"), isOn: $store.config.switcherReplaceCmdTab)
                        .toggleStyle(.switch).labelsHidden()
                }
            }
            SectionTitle(text: tx("How to use the switcher", "Cómo usar el selector"))
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    helpSection(tx("Move", "Moverse")) {
                        Text(tx("Hold Option. Use Tab, Shift + Tab or the arrow keys. Release Option, press Return or click to open the selected window.",
                                "Mantén Opción pulsada. Usa Tab, Mayús + Tab o las flechas. Suelta Opción, pulsa Intro o haz clic para abrir la ventana elegida."))
                    }
                    helpSection(tx("Search", "Buscar")) {
                        Text(tx("Press / before typing. Esc clears the search or closes the switcher.", "Pulsa / antes de escribir. Esc limpia la búsqueda o cierra el selector."))
                    }
                    helpSection(tx("Actions", "Acciones")) {
                        Text(tx("Outside search, W closes the window and Q quits the app.", "Fuera de la búsqueda, W cierra la ventana y Q cierra la app."))
                            .fontWeight(.medium)
                        Text(tx("M minimizes or restores the selected window.", "M minimiza o restaura la ventana elegida."))
                        Text(tx("With the switcher closed, Command + M can capture a thumbnail before minimizing the current window.",
                                "Con el selector cerrado, Comando + M puede capturar una miniatura antes de minimizar la ventana actual."))
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }
        }
    }

    private func helpSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).fontWeight(.semibold).accessibilityAddTraits(.isHeader)
            content()
        }
    }

}

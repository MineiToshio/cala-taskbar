import AppKit
import SwiftUI

/// Settings → Zones: the module switch, how zones mode starts, the gap, the layout shown on each monitor, the editor
/// and a note about macOS's own edge tiling. Layout choices go through the running module; with Zones off they are
/// shown disabled (zones.json is not read), while the editor still opens and loads the file on its own.
struct ZonesSettingsPane: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject private var center = PermissionCenter.shared
    /// Bumped when layouts, the module or the screens change: ZonesStore is not observable.
    @State private var tick = 0
    @State private var editorDisplay = ""
    @State private var tilingOn = ZonesModule.nativeTilingOn

    private var module: ZonesModule { ModuleRegistry.shared.zones }
    /// Set only by `--snapshot`: a store loaded straight from zones.json so the layout menus can be pictured without
    /// starting the module (no event tap). Nothing is written through it.
    static var snapshotStore: ZonesStore?
    /// The store the layout menus read: the running module's, else the snapshot one.
    private var layoutStore: ZonesStore? { module.isRunning ? module.store : Self.snapshotStore }

    private struct Monitor {
        var screen: NSScreen
        var key: String
        var name: String
    }

    private var monitors: [Monitor] {
        let screens = NSScreen.screens
        let keys = ZoneDisplays.keys(for: screens)
        return screens.enumerated().map { position, screen in
            let name = screen.localizedName
            let duplicate = screens.filter { $0.localizedName == name }.count > 1
            return Monitor(screen: screen, key: ZonesModule.displayKey(screen, keys: keys),
                           name: duplicate ? "\(name) (\(position + 1))" : name)
        }
    }

    var body: some View {
        let _ = tick
        let enabled = store.config.zonesEnabled
        let layoutStore = layoutStore
        let running = layoutStore != nil
        let monitors = monitors
        VStack(alignment: .leading, spacing: 26) {
            Card {
                SettingRow(title: tx("Zones", "Zonas"),
                           caption: tx("Drag a window and drop it into a zone of the layout shown on that monitor. Off: no event tap and no zones.",
                                       "Arrastra una ventana y suéltala en una zona de la distribución de esa pantalla. Apagado: sin captura de eventos ni zonas.")) {
                    Toggle("", isOn: Binding(get: { enabled }, set: { ModuleSwitch.set(.zones, $0, store: store) }))
                        .toggleStyle(.switch).labelsHidden()
                        .accessibilityLabel(tx("Zones", "Zonas"))
                }
                if enabled && !center.granted(.accessibility) {
                    RowDivider()
                    PermissionCard(kind: .accessibility, why: PermissionKind.zonesAccessibilityWhy)
                }
            }
            Card {
                SettingRow(title: tx("Activate zones with", "Activar zonas con"),
                           caption: tx("While dragging a window, right-click or hold Shift to show your zones; release over one to snap the window.",
                                       "Mientras arrastras una ventana, haz clic derecho o mantén Mayús para ver tus zonas; suéltala sobre una para encajarla.")) {
                    Picker("", selection: Binding(get: { ZoneActivation(config: store.config.zonesActivation).rawValue },
                                                  set: { store.config.zonesActivation = $0 })) {
                        Text(tx("Right-click", "Clic derecho")).tag(ZoneActivation.rightClick.rawValue)
                        Text(tx("Hold Shift", "Mantener Mayús")).tag(ZoneActivation.shift.rawValue)
                        Text(tx("Both", "Ambos")).tag(ZoneActivation.both.rawValue)
                    }
                    .labelsHidden().frame(width: 190)
                    .accessibilityLabel(tx("Activate zones with", "Activar zonas con"))
                }
                RowDivider()
                SettingRow(title: tx("Gap between zones", "Separación entre zonas"),
                           caption: tx("Space left around each snapped window.", "Espacio que queda alrededor de cada ventana encajada.")) {
                    SliderControl(value: Binding(get: { store.config.zonesGap }, set: { store.config.zonesGap = $0.rounded() }),
                                  range: 0...40, step: 1) { "\(Int($0)) pt" }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(tx("Gap between zones", "Separación entre zonas"))
                }
            }
            SectionTitle(text: tx("Layout per monitor", "Distribución por pantalla"))
            Card {
                ForEach(Array(monitors.enumerated()), id: \.offset) { index, monitor in
                    if index > 0 { RowDivider() }
                    SettingRow(title: monitor.name,
                               caption: "\(Int(monitor.screen.frame.width)) × \(Int(monitor.screen.frame.height))") {
                        if let layouts = layoutStore?.state.layouts {
                            Picker("", selection: layoutBinding(monitor.key)) {
                                ForEach(layouts) { Text($0.name).tag($0.id.uuidString) }
                                Divider()
                                Text(tx("Off", "Desactivadas")).tag(ZonesState.off)
                            }
                            .labelsHidden().frame(width: 220)
                            .accessibilityLabel(tx("Layout on \(monitor.name)", "Distribución en \(monitor.name)"))
                        } else {
                            Text(tx("Zones is off", "Zonas está apagado")).font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                }
                if !running {
                    RowDivider()
                    Text(tx("Turn on Zones to choose the layout of each monitor. The same choice is in the Cala menu-bar icon.",
                            "Activa Zonas para elegir la distribución de cada pantalla. La misma elección está en el icono de Cala en la barra de menús."))
                        .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Card {
                SettingRow(title: tx("Edit zones", "Editar zonas"),
                           caption: tx("Draw, move and resize zones, or start from a template. It opens full screen on the monitor you choose; Esc closes it.",
                                       "Dibuja, mueve y cambia el tamaño de las zonas, o parte de una plantilla. Se abre a pantalla completa en la pantalla que elijas; Esc lo cierra.")) {
                    HStack(spacing: 8) {
                        if monitors.count > 1 {
                            Picker("", selection: Binding(get: { selectedEditorDisplay(monitors) }, set: { editorDisplay = $0 })) {
                                ForEach(monitors, id: \.key) { Text($0.name).tag($0.key) }
                            }
                            .labelsHidden().frame(width: 170)
                            .accessibilityLabel(tx("Monitor to edit", "Pantalla a editar"))
                        }
                        Button(tx("Edit zones…", "Editar zonas…")) {
                            ZonesModule.openEditor?(selectedEditorDisplay(monitors))
                        }
                        .fixedSize()
                        .disabled(ZonesModule.openEditor == nil || monitors.isEmpty)
                    }
                }
            }
            Card {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(StatusColor.color(.attention))
                        .font(.system(size: 14)).frame(width: 20).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(tx("macOS tiling can also move the window", "El acomodo de macOS también puede mover la ventana"))
                            .font(.system(size: 13, weight: .medium))
                        Text(tilingOn
                             ? tx("“Drag windows to screen edges to tile” is on. Dropping a window near an edge can make macOS tile it too. If that gets in the way, turn it off in Desktop & Dock → Windows.",
                                  "“Arrastrar ventanas a los bordes de la pantalla para acomodarlas” está activado. Al soltar una ventana cerca de un borde macOS también puede acomodarla. Si molesta, desactívalo en Escritorio y Dock → Ventanas.")
                             : tx("macOS's own edge tiling is off, so it won't compete with zones.",
                                  "El acomodo por bordes de macOS está desactivado, así que no compite con las zonas."))
                            .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button(tx("Open Desktop & Dock", "Abrir Escritorio y Dock")) {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension")!)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: ZonesModule.didChange)) { _ in tick += 1 }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in tick += 1 }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            tilingOn = ZonesModule.nativeTilingOn
        }
        .onAppear { center.beginWatching() }
        .onDisappear { center.endWatching() }
    }

    private func selectedEditorDisplay(_ monitors: [Monitor]) -> String {
        monitors.contains { $0.key == editorDisplay } ? editorDisplay : monitors.first?.key ?? ""
    }

    private func layoutBinding(_ key: String) -> Binding<String> {
        Binding(get: {
                    guard let store = layoutStore, store.state.activeByDisplay[key] != ZonesState.off else { return ZonesState.off }
                    return store.layout(forDisplay: key)?.id.uuidString ?? ZonesState.off
                },
                set: { module.setLayout(UUID(uuidString: $0), forDisplay: key) })
    }
}

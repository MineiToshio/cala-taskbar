import AppKit
import SwiftUI

/// Settings → Zones: the module switch, how zones mode starts, the gap, each monitor's layout picked from pictures
/// (with that monitor's editor one click away) and a note about macOS's own edge tiling. Layout choices go through
/// the running module; with Zones off the pictures are hidden (zones.json is not read), while the editor still
/// opens and loads the file on its own.
struct ZonesSettingsPane: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject private var center = PermissionCenter.shared
    /// Bumped when layouts, the module or the screens change: ZonesStore is not observable.
    @State private var tick = 0
    /// The monitor whose layout gallery is open in a popover.
    @State private var choosingFor: String?
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
        let labels = ZoneDisplays.labels(for: screens)
        return screens.indices.map { index in
            Monitor(screen: screens[index], key: ZonesModule.displayKey(screens[index], keys: keys), name: labels[index])
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
                RowDivider()
                SettingRow(title: tx("Show layouts while dragging", "Mostrar layouts al arrastrar"),
                           caption: tx("In zones mode, a strip at the top of the screen lists that monitor's layouts. Hold the pointer on one to switch to it, then drop the window into one of its zones.",
                                       "En modo zonas, una franja arriba de la pantalla muestra las distribuciones de esa pantalla. Deja el puntero sobre una para cambiar a ella y suelta la ventana en una de sus zonas.")) {
                    Toggle("", isOn: Binding(get: { store.config.zonesLayoutStrip }, set: { store.config.zonesLayoutStrip = $0 }))
                        .toggleStyle(.switch).labelsHidden()
                        .accessibilityLabel(tx("Show layouts while dragging", "Mostrar layouts al arrastrar"))
                }
            }
            SectionTitle(text: tx("Layout per monitor", "Distribución por pantalla"))
            Card {
                ForEach(Array(monitors.enumerated()), id: \.offset) { index, monitor in
                    if index > 0 { RowDivider() }
                    monitorSection(monitor, layoutStore: layoutStore)
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

    /// One compact row per monitor: its current layout pictured at its shape, its name and size, **Change…**
    /// (a popover with every layout as a picture, plus Off) and **Edit Zones…** for that monitor. The full gallery
    /// appears only on demand, so three or four monitors stay a short list.
    private func monitorSection(_ monitor: Monitor, layoutStore: ZonesStore?) -> some View {
        let aspect = ZoneThumbnailRenderer.aspect(of: monitor.screen.frame)
        let off = layoutStore?.state.activeByDisplay[monitor.key] == ZonesState.off
        let current = off ? nil : layoutStore?.layout(forDisplay: monitor.key)
        let currentName = current.map(ZoneEditorSession.displayName) ?? tx("Off", "Desactivadas")
        return HStack(spacing: 14) {
            Group {
                if let current {
                    ZoneThumbnailView(zones: current.zones, aspect: aspect, box: CGSize(width: 72, height: 40))
                } else {
                    Image(systemName: layoutStore == nil ? "display" : "nosign").font(.system(size: 18)).foregroundStyle(.secondary)
                        .frame(width: 72, height: 40)
                }
            }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.04)))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(monitor.name).font(.system(size: 13, weight: .medium))
                Text(layoutStore == nil ? ZoneDisplays.sizeText(monitor.screen)
                     : "\(currentName) · \(ZoneDisplays.sizeText(monitor.screen))")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if let store = layoutStore {
                Button(tx("Change…", "Cambiar…")) { choosingFor = monitor.key }
                    .accessibilityLabel(tx("Change the layout on \(monitor.name)", "Cambiar la distribución en \(monitor.name)"))
                    // Opens below the row, so the row's own buttons stay visible (Edit Zones… is right there).
                    .popover(isPresented: Binding(get: { choosingFor == monitor.key },
                                                  set: { if !$0 { choosingFor = nil } }), arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(tx("Layout on \(monitor.name)", "Distribución en \(monitor.name)")).font(.headline)
                            layoutGrid(monitor, store: store)
                        }
                        .padding(16)
                        .frame(width: 500)
                    }
            }
            Button(tx("Edit Zones…", "Editar zonas…")) { ZonesModule.openEditor?(monitor.key) }
                .disabled(ZonesModule.openEditor == nil)
                .accessibilityLabel(tx("Edit zones on \(monitor.name)", "Editar zonas en \(monitor.name)"))
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func layoutGrid(_ monitor: Monitor, store: ZonesStore) -> some View {
        let off = store.state.activeByDisplay[monitor.key] == ZonesState.off
        let active = off ? nil : store.layout(forDisplay: monitor.key)?.id
        let aspect = ZoneThumbnailRenderer.aspect(of: monitor.screen.frame)
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 96, maximum: 120), spacing: 10, alignment: .top)],
                         alignment: .leading, spacing: 10) {
            ForEach(store.state.layouts) { layout in
                LayoutTile(name: ZoneEditorSession.displayName(layout), selected: layout.id == active) {
                    ZoneThumbnailView(zones: layout.zones, aspect: aspect, box: LayoutTileMetrics.box)
                } action: {
                    module.setLayout(layout.id, forDisplay: monitor.key)
                    choosingFor = nil
                }
            }
            LayoutTile(name: tx("Off", "Desactivadas"), selected: off) {
                Image(systemName: "nosign").font(.system(size: 18)).foregroundStyle(.secondary)
                    .frame(width: LayoutTileMetrics.box.width, height: LayoutTileMetrics.box.height)
            } action: {
                module.setLayout(nil, forDisplay: monitor.key)
                choosingFor = nil
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tx("Layout on \(monitor.name)", "Distribución en \(monitor.name)"))
    }
}

private enum LayoutTileMetrics {
    static let box = CGSize(width: 84, height: 44)
}

/// A clickable picture with its name under it; the chosen one is ringed in the accent colour.
private struct LayoutTile<Picture: View>: View {
    let name: String
    let selected: Bool
    @ViewBuilder var picture: Picture
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                picture
                    .padding(5)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.04)))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: selected ? 2 : 1)
                    }
                // Two lines, so names like "Principal + dos apiladas" are read whole.
                Text(name)
                    .font(.system(size: 10.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2).truncationMode(.tail)
                    .frame(width: LayoutTileMetrics.box.width + 10, height: 28, alignment: .top)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

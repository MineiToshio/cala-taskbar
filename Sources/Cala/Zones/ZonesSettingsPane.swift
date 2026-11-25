import AppKit
import SwiftUI

/// Layout choices are available with Zones paused, using the same file as the running module and the editor.
struct ZonesSettingsPane: View {
    @ObservedObject var store: ConfigStore
    @Environment(\.settingsSnapshot) private var snapshot
    @State private var savedLayouts: ZonesStore?
    @State private var layoutError: String?
    /// Bumped when layouts, the module or the screens change: ZonesStore is not observable.
    @State private var tick = 0
    /// The monitor whose layout gallery is open in a popover.
    @State private var choosingFor: String?
    @State private var tilingOn = ZonesModule.nativeTilingOn

    @ObservedObject private var module = ModuleRegistry.shared.zones
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
        let layouts = snapshot?.layouts ?? module.store?.state ?? savedLayouts?.state
        let monitors = monitors
        VStack(alignment: .leading, spacing: 26) {
            SectionTitle(text: tx("Layout per display", "Distribución por pantalla"))
            Card {
                ForEach(Array(monitors.enumerated()), id: \.element.key) { index, monitor in
                    if index > 0 { RowDivider() }
                    monitorSection(monitor, layouts: layouts, showEditor: monitors.count > 1)
                }
                if monitors.isEmpty {
                    SettingRow(title: tx("No displays connected", "No hay pantallas conectadas")) { EmptyView() }
                }
                if let error = module.isRunning && module.layoutSaveFailed
                    ? tx("Cala couldn’t save the layouts.", "Cala no pudo guardar las distribuciones.") : layoutError {
                    RowDivider()
                    SettingRow(title: error) {
                        Button(tx("Reopen layouts", "Volver a abrir distribuciones"), action: reopenLayouts)
                    }
                }
            }
            SectionTitle(text: tx("Window snapping", "Encaje de ventanas"))
            Card {
                SettingRow(title: tx("Activate zones with", "Activar zonas con"),
                           caption: ZonesHowTo.dragText(ZoneActivation(config: store.config.zonesActivation))) {
                    Picker("", selection: Binding(get: { ZoneActivation(config: store.config.zonesActivation).rawValue },
                                                  set: { store.config.zonesActivation = $0 })) {
                        Text(tx("Right-click", "Clic derecho")).tag(ZoneActivation.rightClick.rawValue)
                        Text(tx("Hold Shift", "Mantener Mayús")).tag(ZoneActivation.shift.rawValue)
                        Text(tx("Either gesture", "Cualquiera de los dos")).tag(ZoneActivation.both.rawValue)
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
                SettingRow(title: tx("Show layouts while dragging", "Mostrar distribuciones al arrastrar"),
                           caption: tx("In zones mode, a strip at the top of the screen lists that monitor's layouts. Hold the pointer on one to switch to it, then drop the window into one of its zones.",
                                       "En modo zonas, una franja arriba de la pantalla muestra las distribuciones de esa pantalla. Deja el puntero sobre una para cambiar a ella y suelta la ventana en una de sus zonas.")) {
                    Toggle("", isOn: Binding(get: { store.config.zonesLayoutStrip }, set: { store.config.zonesLayoutStrip = $0 }))
                        .toggleStyle(.switch).labelsHidden()
                        .accessibilityLabel(tx("Show layouts while dragging", "Mostrar distribuciones al arrastrar"))
                }
            }
            SectionTitle(text: tx("How to use Zones", "Cómo usar las zonas"))
            Card {
                ZonesHowTo(activation: ZoneActivation(config: store.config.zonesActivation),
                           strip: store.config.zonesLayoutStrip, compact: true)
                    .padding(.horizontal, 16).padding(.vertical, 12)
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
        .onAppear { if snapshot == nil { loadLayouts() } }
        .onReceive(NotificationCenter.default.publisher(for: ZonesModule.didChange)) { _ in loadLayouts() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in tick += 1 }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            tilingOn = ZonesModule.nativeTilingOn
        }
    }

    private func loadLayouts() {
        defer { tick += 1 }
        layoutError = nil
        guard module.store == nil else { savedLayouts = nil; return }
        do {
            savedLayouts = try ZonesStore(templateName: ZonesModule.templateName, readOnly: true)
        } catch {
            savedLayouts = nil
            layoutError = tx("Cala couldn’t read the saved distributions.", "Cala no pudo leer las distribuciones guardadas.")
        }
    }

    private func reopenLayouts() {
        if module.isRunning {
            module.reopenLayoutStore()
            return
        }
        do {
            let editable = try ZonesStore(templateName: ZonesModule.templateName)
            if let error = editable.recoveryError { throw error }
            loadLayouts()
        } catch {
            layoutError = tx("Cala couldn’t reopen the layout file.", "Cala no pudo volver a abrir el archivo de distribuciones.")
        }
    }

    private func selectLayout(_ layout: ZoneLayout?, for key: String) {
        choosingFor = nil
        guard snapshot == nil else { return }
        if module.isRunning { module.setLayout(layout?.id, forDisplay: key); return }
        do {
            let editable = try ZonesStore(templateName: ZonesModule.templateName)
            guard try editable.setActiveLayout(layout?.id, forDisplay: key) else {
                loadLayouts()
                return
            }
            NotificationCenter.default.post(name: ZonesModule.didChange, object: nil)
        } catch {
            layoutError = tx("Cala couldn’t save the layout choice.", "Cala no pudo guardar la distribución elegida.")
        }
    }

    private func monitorSection(_ monitor: Monitor, layouts: ZonesState?, showEditor: Bool) -> some View {
        let aspect = ZoneThumbnailRenderer.aspect(of: monitor.screen.frame)
        let off = layouts?.activeByDisplay[monitor.key] == ZonesState.off
        let current = off ? nil : layouts?.layout(forDisplay: monitor.key)
        let currentName = current.map(ZoneEditorSession.displayName) ?? tx("Off on this display", "Desactivadas en esta pantalla")
        return HStack(spacing: 14) {
            Group {
                if let current {
                    ZoneThumbnailView(zones: current.zones, aspect: aspect, box: CGSize(width: 72, height: 40))
                } else {
                    Image(systemName: layouts == nil ? "display" : "nosign").font(.system(size: 18)).foregroundStyle(.secondary)
                        .frame(width: 72, height: 40)
                }
            }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.04)))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(monitor.name).font(.system(size: 13, weight: .medium))
                Text(layouts == nil ? ZoneDisplays.sizeText(monitor.screen)
                     : "\(currentName) · \(ZoneDisplays.sizeText(monitor.screen))")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if let layouts {
                Button(tx("Change layout…", "Cambiar distribución…")) { choosingFor = monitor.key }
                    .accessibilityLabel(tx("Change the layout on \(monitor.name)", "Cambiar la distribución en \(monitor.name)"))
                    .popover(isPresented: Binding(get: { choosingFor == monitor.key },
                                                  set: { if !$0 { choosingFor = nil } }), arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(tx("Layout on \(monitor.name)", "Distribución en \(monitor.name)")).font(.headline)
                            layoutGrid(monitor, layouts: layouts)
                        }
                        .padding(16)
                        .frame(width: 500)
                    }
            }
            if showEditor {
                Button(tx("Edit zones…", "Editar zonas…")) { if snapshot == nil { ZonesModule.openEditor?(monitor.key) } }
                    .disabled(snapshot == nil && ZonesModule.openEditor == nil)
                    .accessibilityLabel(tx("Edit zones on \(monitor.name)", "Editar zonas en \(monitor.name)"))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func layoutGrid(_ monitor: Monitor, layouts: ZonesState) -> some View {
        let off = layouts.activeByDisplay[monitor.key] == ZonesState.off
        let active = off ? nil : layouts.layout(forDisplay: monitor.key)?.id
        let aspect = ZoneThumbnailRenderer.aspect(of: monitor.screen.frame)
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 96, maximum: 120), spacing: 10, alignment: .top)],
                         alignment: .leading, spacing: 10) {
            ForEach(layouts.layouts) { layout in
                LayoutTile(name: ZoneEditorSession.displayName(layout), selected: layout.id == active) {
                    ZoneThumbnailView(zones: layout.zones, aspect: aspect, box: LayoutTileMetrics.box)
                } action: {
                    selectLayout(layout, for: monitor.key)
                }
            }
            LayoutTile(name: tx("Off on this display", "Desactivadas en esta pantalla"), selected: off) {
                Image(systemName: "nosign").font(.system(size: 18)).foregroundStyle(.secondary)
                    .frame(width: LayoutTileMetrics.box.width, height: LayoutTileMetrics.box.height)
            } action: {
                selectLayout(nil, for: monitor.key)
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

struct ZonesEditorAction: View {
    @Environment(\.settingsSnapshot) private var snapshot

    var body: some View {
        Button(tx("Edit zones…", "Editar zonas…")) {
            guard snapshot == nil else { return }
            let screen = SettingsWindowController.shared.window?.screen ?? NSScreen.main
            if let screen {
                let key = ZonesModule.displayKey(screen, keys: ZoneDisplays.keys(for: NSScreen.screens))
                ZonesModule.openEditor?(key)
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(snapshot == nil && ZonesModule.openEditor == nil)
    }
}

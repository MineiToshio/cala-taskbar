import SwiftUI

/// Names for the two layout models. Stored values stay `linked` / `free`; people see "Tiles" / "Free".
enum ZoneModeText {
    static func name(_ mode: ZoneLayoutMode) -> String {
        mode == .linked ? tx("Tiles", "Mosaico") : tx("Free", "Libre")
    }

    static func symbol(_ mode: ZoneLayoutMode) -> String {
        mode == .linked ? "square.grid.2x2" : "square.on.square.dashed"
    }

    /// One line under the mode control.
    static func summary(_ mode: ZoneLayoutMode) -> String {
        mode == .linked ? tx("Zones cover the screen without overlapping.", "Las zonas cubren la pantalla sin solaparse.")
            : tx("Place zones anywhere; they can overlap.", "Coloca zonas donde quieras; pueden solaparse.")
    }
}

/// The editor's panel, in three bands: which layout (name, its menu, the monitor, help); the gallery of every
/// layout pictured at this monitor's shape; and how to edit it (the mode and its tools) next to Cancel and Save.
/// Actions on the selected zones float next to them on the canvas (`ZoneSelectionBar`). Rarely used commands
/// (rename, duplicate, delete, restore, undo, redo, grid) live in the layout's "…" menu and keep their shortcuts.
struct ZoneEditorHUD: View {
    let session: ZoneEditorSession
    @Environment(\.colorScheme) private var scheme
    @FocusState private var nameFocused: Bool
    @State private var showsHelp = false

    var body: some View {
        if session.hudCollapsed {
            HStack(spacing: 8) {
                collapseButton
                saveButton
            }
            .padding(7)
            .themedPanel(radius: 12, theme: session.theme)
        } else {
            expanded
        }
    }

    private var expanded: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            ZoneEditorGallery(session: session)
            Divider()
            footer
        }
        .controlSize(.small)
        .buttonStyle(.bordered)
        .frame(maxWidth: 1000)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .themedPanel(radius: 16, theme: session.theme)
        .onChange(of: session.renameRequest) {
            nameFocused = true
        }
    }

    // MARK: Which layout

    private var header: some View {
        HStack(spacing: 6) {
            nameField
            layoutMenu
            Spacer(minLength: 12)
            if session.monitors.count > 1 { monitorPicker }
            helpButton
            collapseButton
        }
    }

    private var nameField: some View {
        let title = tx("Layout name", "Nombre de la distribución")
        return TextField(title, text: Binding(get: { session.layoutName }, set: { session.layoutName = $0 }),
                         prompt: Text(ZoneEditorSession.untitled))
            .textFieldStyle(.plain)
            .font(.system(size: 17, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(nameFocused ? 0.08 : 0)))
            .frame(width: 240)   // fixed, so nothing beside it shifts as the name changes
            .focused($nameFocused)
            .onSubmit {
                nameFocused = false
                session.focusCanvas()
            }
            .help(tx("Click to rename", "Haz clic para cambiar el nombre"))
            .accessibilityLabel(title)
    }

    /// The layout's quieter commands, each with its shortcut where it has one.
    private var layoutMenu: some View {
        Menu {
            Button(tx("Rename", "Cambiar nombre")) { session.rename(session.layoutID ?? UUID()) }
            Button(tx("Duplicate Layout", "Duplicar distribución")) { session.duplicateLayout() }
            if let layout = session.layout, ZoneTemplates.isModified(layout) {
                Button(tx("Restore Original Zones", "Restaurar las zonas originales")) { session.restoreOriginal(layout.id) }
            }
            Button(tx("Delete Layout…", "Eliminar distribución…"), role: .destructive) { session.requestDeleteLayout() }
                .disabled(session.draft.layouts.count <= 1)
            Divider()
            Button(tx("Undo", "Deshacer")) { session.undo() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!session.canUndo)
            Button(tx("Redo", "Rehacer")) { session.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!session.canRedo)
            Divider()
            Toggle(tx("Snap to a 12 × 12 Grid", "Ajustar a una cuadrícula de 12 × 12"),
                   isOn: Binding(get: { session.gridEnabled }, set: session.changeGrid))
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(tx("Layout: rename, duplicate, delete, undo, grid", "Distribución: renombrar, duplicar, eliminar, deshacer, cuadrícula"))
        .accessibilityLabel(tx("Layout actions", "Acciones de la distribución"))
    }

    private var monitorPicker: some View {
        Picker(tx("Monitor", "Pantalla"), selection: Binding(get: { session.displayKey }, set: session.selectDisplay)) {
            ForEach(session.monitors) { monitor in
                Label("\(monitor.name) — \(monitor.size)", systemImage: "display").tag(monitor.key)
            }
        }
        .labelsHidden()
        .fixedSize()
        .help(tx("Edit the zones of another monitor", "Editar las zonas de otra pantalla"))
        .accessibilityLabel(tx("Monitor", "Pantalla"))
    }

    private var helpButton: some View {
        Button { showsHelp.toggle() } label: {
            Image(systemName: "questionmark")
        }
        .buttonStyle(.bordered)
        .clipShape(Circle())
        .help(tx("Mouse and keyboard shortcuts", "Atajos de ratón y teclado"))
        .accessibilityLabel(tx("Shortcuts", "Atajos"))
        .popover(isPresented: $showsHelp, arrowEdge: .bottom) { ZoneEditorShortcuts() }
    }

    private var collapseButton: some View {
        let title = session.hudCollapsed ? tx("Show editor controls", "Mostrar controles del editor")
            : tx("Hide editor controls", "Ocultar controles del editor")
        return Button {
            session.hudCollapsed.toggle()
            session.focusCanvas()
        } label: {
            Label(title, systemImage: session.hudCollapsed ? "chevron.down" : "chevron.up")
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.bordered)
        .help(title)
    }

    // MARK: How to edit it, and finishing

    private var footer: some View {
        HStack(alignment: .center, spacing: 12) {
            modePicker
            VStack(alignment: .leading, spacing: 2) {
                Label(ZoneModeText.summary(session.mode), systemImage: ZoneModeText.symbol(session.mode))
                    .font(.callout.weight(.medium))
                Text(session.notice ?? hint)
                    .font(.caption)
                    .foregroundStyle(session.notice == nil ? FlyoutStyle.secondary(dark: scheme == .dark)
                                     : StatusColor.color(.attention, dark: scheme == .dark))
                    .lineLimit(2)
                    .animation(.easeOut(duration: 0.15), value: session.notice)
            }
            .fixedSize(horizontal: false, vertical: true)
            if !session.linked {
                Button { session.addZone() } label: {
                    Label(tx("Add Zone", "Añadir zona"), systemImage: "plus.rectangle")
                }
                .controlSize(.regular)
                .disabled(session.layout == nil)
                .help(tx("A new zone in the largest empty space", "Una zona nueva en el mayor espacio libre"))
            }
            Spacer(minLength: 12)
            if session.isOff {
                Label(tx("Off on this monitor", "Desactivadas en esta pantalla"), systemImage: "pause.circle")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(StatusColor.color(.attention, dark: scheme == .dark))
                    .help(tx("Zones are off on this monitor: click a layout to turn them on",
                             "Las zonas están desactivadas en esta pantalla: haz clic en una distribución para activarlas"))
            }
            Button(session.hasChanges ? tx("Cancel", "Cancelar") : tx("Close", "Cerrar"), action: session.requestCancel)
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
            saveButton
        }
    }

    private var saveButton: some View {
        Button(action: session.save) {
            Text(tx("Save", "Guardar")).frame(minWidth: 72)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(session.hudCollapsed ? .small : .large)
        .help(tx("Save and close (Return or ⌘S)", "Guardar y cerrar (Retorno o ⌘S)"))
    }

    /// Tiles (FancyZones' grid) or Free (its canvas), stored per layout.
    private var modePicker: some View {
        Picker(tx("Layout type", "Tipo de distribución"), selection: Binding(get: { session.mode }, set: session.setMode)) {
            ForEach([ZoneLayoutMode.linked, .free], id: \.self) { mode in
                Label(ZoneModeText.name(mode), systemImage: ZoneModeText.symbol(mode)).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.regular)
        .fixedSize()
        .id(session.modeRefusals)
        .help(tx("Tiles: zones cover the screen; split, merge and drag the lines between them. Free: place zones anywhere, overlapping allowed.",
                 "Mosaico: las zonas cubren la pantalla; divide, une y arrastra las líneas entre ellas. Libre: coloca zonas donde quieras, pueden solaparse."))
        .accessibilityLabel(tx("Layout type", "Tipo de distribución"))
    }

    private var hint: String {
        if session.linked {
            return session.selectedZone == nil
                ? tx("Click a zone to select it. Drag the line between two zones to resize them.",
                     "Haz clic en una zona para seleccionarla. Arrastra la línea entre dos zonas para cambiar su tamaño.")
                : tx("Click inside the selected zone to split it there. ⇧-click other zones to merge them.",
                     "Haz clic dentro de la zona seleccionada para dividirla ahí. ⇧-clic en otras zonas para unirlas.")
        }
        if session.layout?.zones.isEmpty ?? true {
            return tx("Drag on the screen to draw a zone.", "Arrastra sobre la pantalla para dibujar una zona.")
        }
        return tx("Drag on empty space to draw a zone; drag a zone or its edges to move or resize it.",
                  "Arrastra en un espacio vacío para dibujar una zona; arrastra una zona o sus bordes para moverla o cambiar su tamaño.")
    }
}

/// The "?" popover: everything the mouse and keyboard can do, grouped.
private struct ZoneEditorShortcuts: View {
    var body: some View {
        let rows: [(String, [(String, String)])] = [
            (tx("Both types", "Ambos tipos"), [
                (tx("Click", "Clic"), tx("Select a zone", "Seleccionar una zona")),
                (tx("⇧-click", "⇧-clic"), tx("Add a zone to the selection", "Añadir una zona a la selección")),
                (tx("Right-click", "Clic derecho"), tx("The selected zone's actions", "Acciones de la zona seleccionada")),
                ("⌥", tx("While dragging: no snapping", "Al arrastrar: sin ajuste")),
                ("⌘Z  ⇧⌘Z", tx("Undo, redo", "Deshacer, rehacer")),
                ("⌫", tx("Delete the selected zone", "Eliminar la zona seleccionada")),
                (tx("Return  Esc", "Retorno  Esc"), tx("Save, cancel", "Guardar, cancelar"))
            ]),
            (ZoneModeText.name(.linked), [
                (tx("Click the selected zone", "Clic en la zona seleccionada"), tx("Split it at the dashed line (⇧ turns it)", "Dividirla por la línea discontinua (⇧ la gira)")),
                (tx("Drag a line between zones", "Arrastrar una línea entre zonas"), tx("Resize the zones on both sides", "Cambiar el tamaño de las zonas de ambos lados")),
                (tx("Drop a zone on another", "Soltar una zona sobre otra"), tx("Swap them", "Intercambiarlas"))
            ]),
            (ZoneModeText.name(.free), [
                (tx("Drag on empty space", "Arrastrar en un espacio vacío"), tx("Draw a zone (⇧ also over zones)", "Dibujar una zona (con ⇧ también sobre zonas)")),
                (tx("Arrow keys", "Flechas"), tx("Move 8 pt (⇧ a twelfth of the screen)", "Mover 8 pt (⇧ una doceava parte)")),
                (tx("Double-click", "Doble clic"), tx("Type an exact size", "Escribir un tamaño exacto")),
                ("⌘D", tx("Duplicate the zone", "Duplicar la zona"))
            ])
        ]
        VStack(alignment: .leading, spacing: 12) {
            ForEach(rows, id: \.0) { section in
                VStack(alignment: .leading, spacing: 5) {
                    Text(section.0).font(.headline)
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                        ForEach(section.1, id: \.0) { row in
                            GridRow {
                                Text(row.0).font(.callout.weight(.medium))
                                Text(row.1).font(.callout).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 470, alignment: .leading)
    }
}

/// Every layout as a picture of this monitor's shape. The one on the canvas (and used by this monitor) is ringed.
private struct ZoneEditorGallery: View {
    let session: ZoneEditorSession
    @Environment(\.colorScheme) private var scheme
    @Environment(\.themeAccent) private var accent
    private static let box = CGSize(width: 104, height: 54)

    var body: some View {
        // "+" stays in view at the start; the pictures scroll when they do not fit.
        HStack(alignment: .top, spacing: 8) {
            addTile
                .padding(.vertical, 2)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(session.draft.layouts) { layout in
                            tile(layout).id(layout.id)
                        }
                    }
                    .padding(.vertical, 2)
                    .padding(.horizontal, 2)
                }
                .onAppear { scroll(proxy, animated: false) }
                .onChange(of: session.layoutID) { scroll(proxy, animated: true) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tx("Layouts", "Distribuciones"))
    }

    private func scroll(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let id = session.layoutID else { return }
        if animated { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id) } } else { proxy.scrollTo(id) }
    }

    private func tile(_ layout: ZoneLayout) -> some View {
        let selected = layout.id == session.layoutID
        let name = ZoneEditorSession.displayName(layout)
        let dark = scheme == .dark
        return Button {
            session.select(layout.id)
            session.focusCanvas()
        } label: {
            VStack(spacing: 5) {
                ZoneThumbnailView(zones: layout.zones, aspect: session.aspect, box: Self.box, accent: accent)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(FlyoutStyle.card(dark: dark)))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(selected ? accent : Color.primary.opacity(0.10),
                                          style: StrokeStyle(lineWidth: selected ? 2 : 1, dash: selected && session.isOff ? [4, 3] : []))
                    }
                Text(name)
                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.primary : FlyoutStyle.secondary(dark: dark))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: Self.box.width + 12)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name)
        .accessibilityValue(tx("\(layout.zones.count) zones", "\(layout.zones.count) zonas"))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            Button(tx("Rename", "Cambiar nombre")) { session.rename(layout.id) }
            Button(tx("Duplicate", "Duplicar")) { session.duplicateLayout(layout.id) }
            if ZoneTemplates.isModified(layout) {
                Button(tx("Restore original zones", "Restaurar las zonas originales")) { session.restoreOriginal(layout.id) }
            }
            Divider()
            Button(tx("Delete…", "Eliminar…"), role: .destructive) { session.requestDeleteLayout(layout.id) }
                .disabled(session.draft.layouts.count <= 1)
        }
    }

    /// "+": a new blank layout. Built-in layouts the user deleted can be added back from the same button.
    @ViewBuilder private var addTile: some View {
        let missing = ZoneTemplates.missing(in: session.draft)
        let title = tx("New layout", "Nueva distribución")
        if missing.isEmpty {
            Button(action: session.createBlankLayout) { addLabel(title) }
                .buttonStyle(.plain)
                .help(title)
                .accessibilityLabel(title)
        } else {
            Menu {
                Button(tx("Blank layout", "Distribución en blanco"), action: session.createBlankLayout)
                Section(tx("Add back a built-in layout", "Recuperar una distribución incluida")) {
                    ForEach(missing, id: \.self) { id in
                        Button(ZoneEditor.templateName(id)) { session.addBuiltIn(id) }
                    }
                }
            } label: { addLabel(title) }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(title)
                .accessibilityLabel(title)
        }
    }

    private func addLabel(_ title: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: "plus")
                .font(.system(size: 18, weight: .medium))
                .frame(width: 56, height: Self.box.height + 12)
                .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.22),
                                                                          style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            Text(tx("New", "Nueva"))
                .font(.system(size: 11))
                .flyoutSecondary()
        }
        .contentShape(Rectangle())
    }
}

struct ZoneEditorDialog: View {
    let session: ZoneEditorSession
    let dialog: ZoneEditorSession.Dialog
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if case let .zoneSize(id) = dialog {
            ZoneSizeDialog(session: session, id: id)
        } else {
            message
        }
    }

    private var message: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            if let detail {
                Text(detail).font(.callout).flyoutSecondary()
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                if confirmation != nil {
                    Button(tx("Keep editing", "Seguir editando"), action: session.dismissDialog)
                        .keyboardShortcut(.cancelAction)
                }
                if let confirmation {
                    Button(confirmation, role: .destructive, action: session.confirmDialog)
                        .tint(StatusColor.color(.critical, dark: scheme == .dark))
                } else {
                    Button(tx("OK", "Aceptar"), action: session.dismissDialog)
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .buttonStyle(.bordered)
        .padding(16)
        .frame(maxWidth: 400, alignment: .leading)
        .themedPanel(radius: 14, theme: session.theme)
        .accessibilityElement(children: .contain)
    }

    private var title: String {
        switch dialog {
        case .discard: tx("Discard changes to zones?", "¿Descartar los cambios en las zonas?")
        case .deleteLayout: tx("Delete layout?", "¿Eliminar la distribución?")
        case .saveError: tx("Couldn’t save zones", "No se pudieron guardar las zonas")
        case .zoneSize: ""
        case .cannotLink: tx("This layout can’t be Tiles yet", "Esta distribución aún no puede ser Mosaico")
        }
    }

    private var detail: String? {
        switch dialog {
        case .discard: nil
        case let .deleteLayout(_, name):
            tx("“\(name)” will be removed when you save.", "«\(name)» se eliminará al guardar.")
        case let .saveError(message): message
        case .zoneSize: nil
        case .cannotLink:
            tx("Its zones overlap or leave gaps, and Tiles must cover the screen exactly. In Free, make the zones meet edge to edge (snapping helps), then switch to Tiles; or start a new layout with +.",
               "Sus zonas se solapan o dejan huecos, y un Mosaico debe cubrir la pantalla exactamente. En Libre, haz que las zonas se toquen borde con borde (el ajuste ayuda) y cambia a Mosaico; o crea una distribución nueva con +.")
        }
    }

    private var confirmation: String? {
        switch dialog {
        case .discard: tx("Discard changes", "Descartar cambios")
        case .deleteLayout: tx("Delete layout", "Eliminar distribución")
        case .saveError, .zoneSize, .cannotLink: nil
        }
    }
}

/// "Zone size": width and height in the monitor's points, applied around the zone's centre.
private struct ZoneSizeDialog: View {
    let session: ZoneEditorSession
    let id: UUID
    @State private var width = ""
    @State private var height = ""
    @FocusState private var widthFocused: Bool

    var body: some View {
        let zones = session.layout?.zones ?? []
        let number = (zones.firstIndex { $0.id == id } ?? 0) + 1
        VStack(alignment: .leading, spacing: 12) {
            Text(tx("Size of zone \(number)", "Tamaño de la zona \(number)")).font(.headline).accessibilityAddTraits(.isHeader)
            HStack(spacing: 8) {
                field(tx("Width", "Ancho"), text: $width).focused($widthFocused)
                Text("×").flyoutSecondary()
                field(tx("Height", "Alto"), text: $height)
                Text(tx("pt", "pt")).flyoutSecondary()
            }
            Text(tx("The size macOS uses for this monitor (\(Int(session.usable.width)) × \(Int(session.usable.height)) usable). The zone keeps its centre.",
                    "El tamaño que macOS usa en esta pantalla (\(Int(session.usable.width)) × \(Int(session.usable.height)) útiles). La zona mantiene su centro."))
                .font(.caption).flyoutSecondary().fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(tx("Cancel", "Cancelar"), action: session.dismissDialog).keyboardShortcut(.cancelAction)
                Button(tx("Apply", "Aplicar"), action: apply)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(Double(width) == nil || Double(height) == nil)
            }
        }
        .buttonStyle(.bordered)
        .padding(16)
        .frame(width: 330, alignment: .leading)
        .themedPanel(radius: 14, theme: session.theme)
        .onAppear {
            if let zone = zones.first(where: { $0.id == id }) {
                let size = session.pointSize(of: zone.rect)
                width = String(size.w)
                height = String(size.h)
            }
            widthFocused = true
        }
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text)
            .textFieldStyle(.roundedBorder)
            .frame(width: 80)
            .multilineTextAlignment(.trailing)
            .onSubmit(apply)
            .accessibilityLabel(title)
    }

    private func apply() {
        guard let w = Double(width.trimmingCharacters(in: .whitespaces)),
              let h = Double(height.trimmingCharacters(in: .whitespaces)) else { NSSound.beep(); return }
        session.setSize(id, width: w, height: h)
    }
}

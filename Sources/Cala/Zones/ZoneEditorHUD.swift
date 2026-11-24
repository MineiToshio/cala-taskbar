import SwiftUI

/// The editor's single panel: the layout's name, a gallery of every layout pictured at this monitor's shape,
/// the zone tools and Cancel / Save. Clicking a picture puts that layout on the canvas and makes it the one this
/// monitor uses; there is no separate "layout" picker or "use on this monitor" step.
struct ZoneEditorHUD: View {
    let session: ZoneEditorSession
    @Environment(\.colorScheme) private var scheme
    @FocusState private var nameFocused: Bool

    var body: some View {
        if session.hudCollapsed {
            collapseButton
                .padding(7)
                .themedPanel(radius: 10, theme: session.theme)
        } else {
            expanded
        }
    }

    private var expanded: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            ZoneEditorGallery(session: session)
            Divider()
            footer
        }
        .controlSize(.small)
        .buttonStyle(.bordered)
        .frame(maxWidth: 980)
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .themedPanel(radius: 14, theme: session.theme)
        .onChange(of: session.renameRequest) {
            nameFocused = true
        }
    }

    // MARK: Header: name and layout actions, then monitor, grid, Cancel and Save

    private var header: some View {
        HStack(spacing: 8) {
            nameField
            iconButton(tx("Duplicate layout", "Duplicar distribución"), "plus.square.on.square") { session.duplicateLayout() }
            iconButton(tx("Delete layout…", "Eliminar distribución…"), "trash") { session.requestDeleteLayout() }
                .disabled(session.draft.layouts.count <= 1)
            iconButton(tx("Undo (⌘Z)", "Deshacer (⌘Z)"), "arrow.uturn.backward") { session.undo() }
                .disabled(!session.canUndo)
            iconButton(tx("Redo (⇧⌘Z)", "Rehacer (⇧⌘Z)"), "arrow.uturn.forward") { session.redo() }
                .disabled(!session.canRedo)
            Spacer(minLength: 12)
            if session.monitors.count > 1 { monitorPicker }
            linkPicker
            Toggle(isOn: Binding(get: { session.gridEnabled }, set: session.changeGrid)) {
                Label(tx("Grid", "Cuadrícula"), systemImage: "grid").labelStyle(.iconOnly)
            }
            .toggleStyle(.button)
            .accessibilityLabel(tx("12 × 12 grid", "Cuadrícula de 12 × 12"))
            .help(tx("Grid: also snap to a 12 × 12 grid", "Cuadrícula: ajustar también a una cuadrícula de 12 × 12"))
            Button(session.hasChanges ? tx("Cancel", "Cancelar") : tx("Close", "Cerrar"), action: session.requestCancel)
                .keyboardShortcut(.cancelAction)
            Button(tx("Save", "Guardar"), action: session.save)
                .buttonStyle(.borderedProminent)
            collapseButton
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var nameField: some View {
        let title = tx("Layout name", "Nombre de la distribución")
        return TextField(title, text: Binding(get: { session.layoutName }, set: { session.layoutName = $0 }),
                         prompt: Text(ZoneEditorSession.untitled))
            .textFieldStyle(.plain)
            .font(.system(size: 16, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(nameFocused ? 0.08 : 0.04)))
            .frame(width: 230)   // fixed, so the buttons beside it never shift as the name changes
            .focused($nameFocused)
            .onSubmit {
                nameFocused = false
                session.focusCanvas()
            }
            .help(tx("Click to rename", "Haz clic para cambiar el nombre"))
            .accessibilityLabel(title)
    }

    /// The layout's model. Linked (FancyZones' "grid"): zones tile the screen; split, merge, drag dividers.
    /// Free ("canvas"): rectangles anywhere, overlaps allowed. Stored per layout.
    private var linkPicker: some View {
        Picker(tx("Zones", "Zonas"), selection: Binding(get: { session.mode }, set: session.setMode)) {
            Text(tx("Linked", "Unidas")).tag(ZoneLayoutMode.linked)
            Text(tx("Free", "Libres")).tag(ZoneLayoutMode.free)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .id(session.modeRefusals)
        .help(session.linked
              ? tx("Linked: zones tile the screen. Split, merge, drag dividers.",
                   "Unidas: las zonas cubren la pantalla. Divide, une, arrastra divisores.")
              : tx("Free: place rectangles anywhere. Overlap allowed.",
                   "Libres: coloca rectángulos donde quieras. Se pueden superponer."))
        .accessibilityLabel(tx("How this layout is edited", "Cómo se edita esta distribución"))
    }

    private var monitorPicker: some View {
        Picker(tx("Monitor", "Pantalla"), selection: Binding(get: { session.displayKey }, set: session.selectDisplay)) {
            ForEach(session.monitors) { monitor in
                Text("\(monitor.name) — \(monitor.size)").tag(monitor.key)
            }
        }
        .labelsHidden()
        .fixedSize()
        .help(tx("Edit the zones of another monitor", "Editar las zonas de otra pantalla"))
        .accessibilityLabel(tx("Monitor", "Pantalla"))
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

    private func iconButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .help(title)
    }

    // MARK: Footer: zone tools and how to draw

    private var footer: some View {
        HStack(spacing: 8) {
            if session.linked {
                Button { session.addZone(flip: NSEvent.modifierFlags.contains(.shift)) } label: {
                    Label(tx("Split", "Dividir"), systemImage: "rectangle.split.2x1")
                }
                .disabled(session.layout == nil || !session.canSplitSelection)
                .help(tx("Split the selected zone (or the largest) along its longer side; ⇧ splits the other way",
                         "Divide la zona seleccionada (o la mayor) por su lado largo; con ⇧, en el otro sentido"))
                Button { session.mergeSelection() } label: {
                    Label(tx("Merge", "Unir"), systemImage: "rectangle.compress.vertical")
                }
                .disabled(!session.canMerge)
                .help(session.selection.count < 2
                      ? tx("⇧-click zones to select two or more, then merge them", "Haz ⇧-clic en dos o más zonas y únelas")
                      : session.canMerge ? tx("Merge the selected zones into one", "Une las zonas seleccionadas en una")
                      : tx("The selected zones must form a rectangle", "Las zonas seleccionadas deben formar un rectángulo"))
            } else {
                Button { session.addZone() } label: {
                    Label(tx("Add zone", "Añadir zona"), systemImage: "plus.rectangle")
                }
                .disabled(session.layout == nil)
                .help(tx("A new zone in the largest empty space", "Una zona nueva en el mayor espacio libre"))
            }
            Button(role: .destructive) { session.deleteZone() } label: {
                Label(tx("Delete zone", "Eliminar zona"), systemImage: "minus.rectangle")
            }
            .disabled(!session.canDeleteZone)
            .help(session.linked
                  ? tx("Its space goes to a neighbour that shares a whole side", "Su espacio pasa a una vecina que comparte un lado entero")
                  : tx("Delete the selected zone", "Elimina la zona seleccionada"))
            Text(session.notice ?? hint)
                .font(.caption.weight(session.notice == nil ? .regular : .medium))
                .foregroundStyle(session.notice == nil ? FlyoutStyle.secondary(dark: scheme == .dark) : StatusColor.color(.attention, dark: scheme == .dark))
                .lineLimit(2)
                .padding(.leading, 6)
                .animation(.easeOut(duration: 0.15), value: session.notice)
            Spacer(minLength: 0)
            if session.isOff {
                Label(tx("Zones are off on this monitor: click a layout to turn them on",
                         "Las zonas están desactivadas en esta pantalla: haz clic en una distribución para activarlas"),
                      systemImage: "pause.circle")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(StatusColor.color(.attention, dark: scheme == .dark))
                    .lineLimit(2)
            }
        }
    }

    private var hint: String {
        if session.linked {
            if session.selectedZone == nil {
                return tx("Click a zone to select it · Drag a divider to resize · ⇧-click several to merge · Drop a zone on another to swap",
                          "Haz clic en una zona para seleccionarla · Arrastra un divisor para cambiar tamaños · ⇧-clic en varias para unirlas · Suelta una zona sobre otra para intercambiarlas")
            }
            return tx("Click inside the selected zone to split it there (⇧ turns the cut) · Drag dividers · ⌥ no snapping · Right-click: more",
                      "Haz clic dentro de la zona seleccionada para dividirla ahí (⇧ gira el corte) · Arrastra divisores · ⌥ sin ajuste · Clic derecho: más")
        }
        if session.layout?.zones.isEmpty ?? true {
            return tx("Drag on the screen to draw a zone · Hold ⌥ to turn off snapping",
                      "Arrastra sobre la pantalla para dibujar una zona · Mantén ⌥ para desactivar el ajuste")
        }
        return tx("Drag a zone or its edges · Empty space or ⇧ draws · ⌥ no snapping · Arrows nudge · Double-click: exact size · Right-click: more",
                  "Arrastra una zona o sus bordes · Espacio vacío o ⇧ dibuja · ⌥ sin ajuste · Flechas: mover · Doble clic: tamaño exacto · Clic derecho: más")
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
        case .cannotLink: tx("This layout can’t be Linked yet", "Esta distribución aún no puede ser Unidas")
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
            tx("Its zones overlap or leave gaps, and Linked zones must cover the screen exactly. In Free mode, make them meet edge to edge (snapping helps), then switch to Linked; or start a new layout with +.",
               "Sus zonas se superponen o dejan huecos, y las zonas Unidas deben cubrir la pantalla exactamente. En Libres, haz que se toquen borde con borde (el ajuste ayuda) y cambia a Unidas; o crea una distribución nueva con +.")
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

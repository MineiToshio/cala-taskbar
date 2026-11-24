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
            Spacer(minLength: 12)
            if session.monitors.count > 1 { monitorPicker }
            Toggle(isOn: Binding(get: { session.gridEnabled }, set: session.changeGrid)) {
                Label(tx("Grid", "Cuadrícula"), systemImage: "grid")
            }
            .toggleStyle(.button)
            .help(tx("Also snap to a 12 × 12 grid", "Ajustar también a una cuadrícula de 12 × 12"))
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
            .frame(minWidth: 140, maxWidth: 260)
            .focused($nameFocused)
            .onSubmit {
                nameFocused = false
                session.focusCanvas()
            }
            .help(tx("Click to rename", "Haz clic para cambiar el nombre"))
            .accessibilityLabel(title)
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
            Button { session.addZone() } label: {
                Label(tx("Add zone", "Añadir zona"), systemImage: "plus.rectangle")
            }
            .disabled(session.layout == nil)
            Button(role: .destructive) { session.deleteZone() } label: {
                Label(tx("Delete zone", "Eliminar zona"), systemImage: "minus.rectangle")
            }
            .disabled(session.selectedZone == nil)
            Text(hint)
                .font(.caption)
                .flyoutSecondary()
                .lineLimit(2)
                .padding(.leading, 6)
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
        if session.layout?.zones.isEmpty ?? true {
            return tx("Drag on the screen to draw a zone · Hold ⌥ to turn off snapping",
                      "Arrastra sobre la pantalla para dibujar una zona · Mantén ⌥ para desactivar el ajuste")
        }
        return tx("Drag a zone to move it, its edges to resize · Drag empty space, or hold ⇧ over zones, to draw · ⌥ turns off snapping",
                  "Arrastra una zona para moverla, sus bordes para cambiar su tamaño · Arrastra en un espacio vacío, o mantén ⇧ sobre las zonas, para dibujar · ⌥ desactiva el ajuste")
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
        }
    }

    private var detail: String? {
        switch dialog {
        case .discard: nil
        case let .deleteLayout(_, name):
            tx("“\(name)” will be removed when you save.", "«\(name)» se eliminará al guardar.")
        case let .saveError(message): message
        }
    }

    private var confirmation: String? {
        switch dialog {
        case .discard: tx("Discard changes", "Descartar cambios")
        case .deleteLayout: tx("Delete layout", "Eliminar distribución")
        case .saveError: nil
        }
    }
}

import SwiftUI

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
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(tx("Zones editor", "Editor de zonas"))
                    .font(.system(size: 18, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                collapseButton
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { monitorPicker; layoutPicker; renameField }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) { monitorPicker; layoutPicker }
                    renameField
                }
            }
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { layoutTools; snappingTools }
                VStack(alignment: .leading, spacing: 8) { layoutTools; snappingTools }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { help; Spacer(minLength: 0); actions }
                VStack(alignment: .leading, spacing: 8) { help; actions }
            }
        }
        .controlSize(.small)
        .buttonStyle(.bordered)
        .frame(maxWidth: 590)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .themedPanel(radius: 14, theme: session.theme)
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

    private var monitorPicker: some View {
        let title = tx("Monitor", "Monitor")
        return labeled(title) {
            Picker(title, selection: Binding(get: { session.displayKey }, set: session.selectDisplay)) {
                ForEach(session.monitors) { Text($0.name).tag($0.key) }
            }
            .labelsHidden()
            .frame(width: 165, alignment: .leading)
        }
    }

    private var layoutPicker: some View {
        let title = tx("Layout", "Diseño")
        return labeled(title) {
            Picker(title, selection: Binding(get: { session.layoutID }, set: session.chooseLayout)) {
                ForEach(session.draft.layouts) { layout in
                    Text(layout.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                         ? ZoneEditorSession.untitled : layout.name).tag(Optional(layout.id))
                }
            }
            .labelsHidden()
            .frame(width: 155, alignment: .leading)
        }
    }

    private var renameField: some View {
        let title = tx("Layout name", "Nombre del diseño")
        return labeled(title) {
            TextField(title, text: Binding(get: { session.layoutName }, set: { session.layoutName = $0 }))
                .textFieldStyle(.roundedBorder)
                .frame(width: 195)
                .focused($nameFocused)
                .onSubmit {
                    nameFocused = false
                    session.focusCanvas()
                }
        }
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.medium))
                .flyoutSecondary()
                .accessibilityHidden(true)
            content()
        }
    }

    private var layoutTools: some View {
        HStack(spacing: 6) {
            Menu(tx("New layout", "Nuevo diseño")) {
                Button(tx("Blank", "En blanco")) { session.createLayout() }
                Divider()
                ForEach(ZoneTemplates.ids, id: \.self) { id in
                    Button(ZoneEditor.templateName(id)) { session.createLayout(template: id) }
                }
            }
            .fixedSize()
            Button(tx("Duplicate", "Duplicar"), action: session.duplicateLayout)
                .accessibilityLabel(tx("Duplicate layout", "Duplicar diseño"))
            Button(tx("Delete layout", "Eliminar diseño"), role: .destructive, action: session.requestDeleteLayout)
                .tint(StatusColor.color(.critical, dark: scheme == .dark))
                .disabled(session.draft.layouts.count <= 1)
        }
        .fixedSize()
    }

    private var snappingTools: some View {
        HStack(spacing: 8) {
            Button(session.drawArmed ? tx("Stop drawing", "Dejar de dibujar") : tx("Draw zone", "Dibujar zona")) {
                session.drawArmed.toggle()
            }
            .help(tx("Draw a zone over existing zones", "Dibuja una zona sobre las existentes"))
            Toggle(tx("12×12 grid", "Cuadrícula 12×12"),
                   isOn: Binding(get: { session.gridEnabled }, set: session.changeGrid))
                .toggleStyle(.checkbox)
                .help(tx("Snap to the 12-division grid", "Ajustar a la cuadrícula de 12 divisiones"))
        }
        .fixedSize()
    }

    private var help: some View {
        Text(session.drawArmed
             ? tx("Drag anywhere on the canvas to draw.", "Arrastra en el lienzo para dibujar.")
             : tx("Drag to draw or edit · Hold ⌥ to turn off snapping", "Arrastra para dibujar o editar · Mantén ⌥ para desactivar el ajuste"))
            .font(.caption)
            .flyoutSecondary()
    }

    private var actions: some View {
        HStack(spacing: 6) {
            if session.isAssigned {
                Label(tx("In use on this monitor", "En uso en este monitor"), systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(StatusColor.color(.ok, dark: scheme == .dark))
                    .padding(.trailing, 4)
            } else {
                Button(tx("Use on this monitor", "Usar en este monitor"), action: session.assignToDisplay)
            }
            Button(tx("Cancel", "Cancelar"), action: session.requestCancel)
                .keyboardShortcut(.cancelAction)
            Button(tx("Save", "Guardar"), action: session.save)
                .buttonStyle(.borderedProminent)
        }
        .fixedSize()
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
        case .deleteLayout: tx("Delete layout?", "¿Eliminar el diseño?")
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
        case .deleteLayout: tx("Delete layout", "Eliminar diseño")
        case .saveError: nil
        }
    }
}

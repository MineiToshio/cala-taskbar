import SwiftUI

struct TrayPane: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var mail: MailService
    @ObservedObject private var usage = UsageService.shared
    let open: (SettingsDetail) -> Void
    @Environment(\.settingsSnapshot) private var snapshot
    @State private var confirmReset = false

    var body: some View {
        let groups = itemGroups
        VStack(alignment: .leading, spacing: 22) {
            SectionTitle(text: tx("Item order and placement", "Orden y ubicación"))
            Text(tx("Drag the handle to reorder items or move them between groups.",
                    "Arrastra desde el asa para ordenar los elementos o moverlos entre grupos."))
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
            Card {
                ForEach(groups) { group in
                    groupRows(group)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            Button(tx("Reset order and placement…", "Restablecer orden y ubicación…")) { confirmReset = true }
                .alert(tx("Reset tray order and placement?", "¿Restablecer orden y ubicación de la Bandeja?"), isPresented: $confirmReset) {
                    Button(tx("Reset", "Restablecer"), role: .destructive) {
                        var config = store.config
                        let defaults = resettingTrayItems(Set(TrayItems.all.map(\.id)),
                                                          layout: config.trayLayout, order: config.trayOrder)
                        config.trayLayout = defaults.layout
                        config.trayOrder = defaults.order
                        store.config = config
                    }
                    Button(tx("Cancel", "Cancelar"), role: .cancel) {}
                } message: {
                    Text(tx("Returns the icons to their default order and locations, including any older visibility preferences for Disk and CPU and memory.",
                            "Devuelve los iconos a su orden y ubicación predeterminados, incluidas las preferencias antiguas de visibilidad de Disco y CPU y memoria."))
                }
        }
    }

    private var itemGroups: [TrayItemGroup] {
        var seen = Set<String>()
        let ids = store.config.orderedTrayIDs.filter { seen.insert($0).inserted }
        return TrayPlace.allCases.map { place in
            TrayItemGroup(place: place, items: ids.filter { store.config.place($0) == place })
        }
    }

    @ViewBuilder private func groupRows(_ group: TrayItemGroup) -> some View {
        HStack(spacing: 8) {
            Text(placementHeading(group.place)).font(.system(size: 13, weight: .semibold))
            Text(group.items.count.formatted()).font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 24)
        .frame(height: 36)
        .overlay(alignment: .top) {
            if group.place != .bar { RowDivider().allowsHitTesting(false) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .modifier(TrayDropTarget(place: group.place, index: 0, surface: .header, move: move))

        if group.items.isEmpty {
            Text(tx("Drop items here", "Suelta elementos aquí"))
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 24)
                .frame(height: SettingsDetailRowLayout.height)
                .modifier(TrayDropTarget(place: group.place, index: 0, surface: .empty, move: move))
        }
        ForEach(Array(group.items.enumerated()), id: \.element) { index, id in
            if let info = TrayItems.info(id) {
                itemRow(info, group: group, index: index)
                    .overlay(alignment: .top) {
                        RowDivider().padding(.leading, index == 0 ? 8 : 74).allowsHitTesting(false)
                    }
                    .modifier(TrayDropTarget(place: group.place, index: index, surface: .item, move: move))
            }
        }
    }

    private func itemRow(_ info: TrayItemInfo, group: TrayItemGroup, index: Int) -> some View {
        let id = info.id
        let detail = detailForItem(id)
        let caption = itemCaption(id)
        let canMoveUp = index > 0
        let canMoveDown = index + 1 < group.items.count
        return GeometryReader { geometry in
            HStack(spacing: 0) {
                dragHandle
                    .contentShape(Rectangle())
                    .help(tx("Drag to move", "Arrastrar para mover"))
                    .onDrag { TrayItemDrag.provider(for: id) } preview: {
                        HStack(spacing: 0) {
                            dragHandle
                            itemLabel(info, detail: detail, caption: caption)
                        }
                        .frame(width: geometry.size.width, height: SettingsDetailRowLayout.height)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(.dragPreview, RoundedRectangle(cornerRadius: 8))
                    }
                    .accessibilityHidden(true)

                if let detail {
                    SettingsDetailLink(detail: detail, open: open) {
                        itemLabel(info, detail: detail, caption: caption)
                    }
                    .buttonStyle(TrayDetailButtonStyle())
                } else {
                    itemLabel(info, detail: nil, caption: caption)
                        .focusable()
                }
            }
        }
        .frame(height: SettingsDetailRowLayout.height)
        .contentShape(Rectangle())
        .contextMenu {
            Button(tx("Move up", "Subir")) { move(id, to: group.place, at: index - 1) }.disabled(!canMoveUp)
            Button(tx("Move down", "Bajar")) { move(id, to: group.place, at: index + 2) }.disabled(!canMoveDown)
            Divider()
            ForEach(TrayPlace.allCases.filter { $0 != group.place }) { target in
                Button(moveTitle(target)) { append(id, to: target) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(info.title)
        .accessibilityValue(placementHeading(group.place))
        .accessibilityActions {
            ForEach(TrayPlace.allCases.filter { $0 != group.place }) { target in
                Button(moveTitle(target)) { append(id, to: target) }
            }
            if canMoveUp { Button(tx("Move up", "Subir")) { move(id, to: group.place, at: index - 1) } }
            if canMoveDown { Button(tx("Move down", "Bajar")) { move(id, to: group.place, at: index + 2) } }
        }
    }

    private var dragHandle: some View {
        Image(systemName: "line.3.horizontal").font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: TrayDetailButtonStyle.handleWidth, height: SettingsDetailRowLayout.height)
    }

    private func itemLabel(_ info: TrayItemInfo, detail: SettingsDetail?, caption: String?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: info.symbol).frame(width: 22).foregroundStyle(.secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(info.title).font(.system(size: 13, weight: .medium))
                if let caption { Text(caption).font(.system(size: 11.5)).foregroundStyle(.secondary) }
            }
            .lineLimit(1)
            Spacer(minLength: 4)
            if detail != nil { SettingsDetailChevron() }
        }
        .padding(.trailing, SettingsDetailRowLayout.trailingInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func detailForItem(_ id: String) -> SettingsDetail? {
        switch id {
        case traySystem: .cpuMemory
        case trayDisk: .disk
        case trayMail: .mail
        case trayUsage: .usage
        default: nil
        }
    }

    private func itemCaption(_ id: String) -> String? {
        if id == trayMail && !mail.accountsLoadFailed && mail.accounts.isEmpty { return tx("No accounts", "Sin cuentas") }
        if id == trayMail && store.config.place(id) == .hidden {
            return tx("Enabled accounts still sync when the tray is on.", "Las cuentas siguen sincronizándose con la bandeja activa")
        }
        if id == trayUsage {
            let config = store.config
            if !config.usageEnabled { return tx("Usage is off", "El uso está desactivado") }
            let enabled = UsageProvider.allCases.filter { $0 == .claude ? config.usageClaudeEnabled : config.usageCodexEnabled }
            if enabled.isEmpty { return tx("Providers are off", "Claude y Codex están desactivados") }
            let providers = usage.providers.filter { enabled.contains($0.provider) }
            if !ModulePlan.effective(snapshot?.modules ?? config.modules).tray {
                return tx("Detection paused", "Detección en pausa")
            }
            if providers.count != enabled.count || providers.contains(where: { !$0.didDetectSession }) {
                return tx("Checking for sessions…", "Comprobando sesiones…")
            }
            if providers.allSatisfy({ !$0.signedIn }) { return tx("No Claude or Codex session", "Sin sesión de Claude o Codex") }
        }
        return nil
    }

    private func placementHeading(_ place: TrayPlace) -> String {
        switch place {
        case .bar: tx("In the bar", "En la barra")
        case .more: tx("In More", "En Más")
        case .hidden: tx("Hidden", "Ocultos")
        }
    }

    private func moveTitle(_ place: TrayPlace) -> String {
        switch place {
        case .bar: tx("Move to “In the bar”", "Mover a la barra")
        case .more: tx("Move to “In More”", "Mover a Más")
        case .hidden: tx("Move to “Hidden”", "Mover a «Ocultos»")
        }
    }

    private func append(_ id: String, to place: TrayPlace) {
        guard let group = itemGroups.first(where: { $0.place == place }) else { return }
        move(id, to: place, at: group.items.count)
    }

    private func move(_ id: String, to place: TrayPlace, at index: Int) {
        var config = store.config
        guard let updated = movingTrayItem(id, to: place, at: index, in: itemGroups,
                                           savedLayout: config.trayLayout, savedOrder: config.trayOrder) else { return }
        config.trayLayout = updated.layout
        config.trayOrder = updated.order
        store.config = config
    }
}

private struct TrayDetailButtonStyle: ButtonStyle {
    static let handleWidth: CGFloat = 58

    func makeBody(configuration: Configuration) -> some View {
        HighlightedLabel(label: configuration.label, pressed: configuration.isPressed)
    }

    private struct HighlightedLabel: View {
        let label: Configuration.Label
        let pressed: Bool
        @State private var hovered = false

        var body: some View {
            label
                .foregroundStyle(Color.primary)
                .onHover { hovered = $0 }
                .background {
                    Rectangle()
                        .fill(Color.primary.opacity(pressed ? 0.12 : (hovered ? 0.06 : 0)))
                        .padding(.leading, -TrayDetailButtonStyle.handleWidth)
                        .allowsHitTesting(false)
                }
        }
    }
}

private enum TrayItemDrag {
    static let typeIdentifier = "local.cala.settings.tray-item"

    static func provider(for id: String) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: typeIdentifier, visibility: .ownProcess) { completion in
            completion(Data(id.utf8), nil)
            return nil
        }
        return provider
    }
}

private struct TrayDropTarget: ViewModifier {
    enum Surface { case header, item, empty }
    let place: TrayPlace
    let index: Int
    let surface: Surface
    let move: (String, TrayPlace, Int) -> Void
    @State private var edge: VerticalEdge?

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .overlay(alignment: edge == .bottom ? .bottom : .top) {
                if edge != nil {
                    Rectangle().fill(Color.accentColor).frame(height: 2).padding(.horizontal, 12)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .onDrop(of: [TrayItemDrag.typeIdentifier], delegate: Delegate(place: place, index: index, surface: surface,
                                                                         edge: $edge, move: move))
    }

    private struct Delegate: DropDelegate {
        let place: TrayPlace
        let index: Int
        let surface: Surface
        @Binding var edge: VerticalEdge?
        let move: (String, TrayPlace, Int) -> Void

        private func target(at info: DropInfo) -> (edge: VerticalEdge, index: Int) {
            switch surface {
            case .header: (.bottom, 0)
            case .empty: (.top, 0)
            case .item:
                info.location.y < SettingsDetailRowLayout.height / 2 ? (.top, index) : (.bottom, index + 1)
            }
        }

        func dropEntered(info: DropInfo) { edge = target(at: info).edge }

        func dropUpdated(info: DropInfo) -> DropProposal? {
            edge = target(at: info).edge
            return DropProposal(operation: .move)
        }

        func dropExited(info: DropInfo) { edge = nil }

        func performDrop(info: DropInfo) -> Bool {
            edge = nil
            guard let provider = info.itemProviders(for: [TrayItemDrag.typeIdentifier]).first else { return false }
            let insertionIndex = target(at: info).index
            provider.loadDataRepresentation(forTypeIdentifier: TrayItemDrag.typeIdentifier) { data, _ in
                guard let data, let id = String(data: data, encoding: .utf8) else { return }
                DispatchQueue.main.async { move(id, place, insertionIndex) }
            }
            return true
        }
    }
}

struct CPUSettingsPane: View {
    @ObservedObject var store: ConfigStore

    var body: some View {
        Card {
            SettingRow(title: tx("Default indicator", "Indicador habitual"),
                       caption: tx("Alerts take priority over this choice.", "Los avisos tienen prioridad sobre esta elección.")) {
                Picker(tx("Default indicator", "Indicador habitual"),
                       selection: Binding(get: { store.config.monitorBarMetric }, set: { store.config.monitorBarMetric = $0; SystemMonitor.shared.tick() })) {
                    Text("CPU").tag("cpu")
                    Text(tx("Memory", "Memoria")).tag("memory")
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 142)
            }
            RowDivider()
            SettingRow(title: tx("Suggest restarting the Mac", "Recomendar reiniciar el Mac"),
                       caption: tx("Shows reasons to restart in the CPU and memory panel.", "Muestra los motivos para reiniciar en el panel de CPU y memoria.")) {
                Toggle(tx("Suggest restarting the Mac", "Recomendar reiniciar el Mac"), isOn: $store.config.restartAdvice)
                    .toggleStyle(.switch).labelsHidden()
            }
        }
    }
}

struct DiskFolderSettings: View {
    @ObservedObject var store: ConfigStore
    @State private var folders = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tx("Extra folders to measure", "Carpetas extra a medir")).font(.system(size: 13, weight: .medium))
            Text(tx("Separate folders with commas.", "Separa las carpetas con comas."))
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
            HStack {
                TextField(tx("Extra folders to measure", "Carpetas extra a medir"),
                          text: $folders, prompt: Text("~/Projects, ~/worktrees"))
                    .labelsHidden().textFieldStyle(.roundedBorder).onSubmit(applyFolders)
                Button(tx("Save", "Guardar"), action: applyFolders)
                    .disabled(folders == store.config.diskFolders.joined(separator: ", "))
            }
        }
        .onAppear { folders = store.config.diskFolders.joined(separator: ", ") }
    }

    private func applyFolders() {
        let parsed = folders.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if parsed != store.config.diskFolders { store.config.diskFolders = parsed }
        folders = parsed.joined(separator: ", ")
    }
}

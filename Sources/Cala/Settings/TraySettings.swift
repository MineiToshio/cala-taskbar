import SwiftUI

struct TrayPane: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var mail: MailService
    @ObservedObject private var usage = UsageService.shared
    let open: (SettingsDetail) -> Void
    @Environment(\.settingsSnapshot) private var snapshot
    @State private var confirmReset = false

    private let headingHeight: CGFloat = 36
    private let handleWidth: CGFloat = 42

    var body: some View {
        let groups = itemGroups
        VStack(alignment: .leading, spacing: 22) {
            SectionTitle(text: tx("Item order and placement", "Orden y ubicación"))
            Text(tx("Drag the handle to reorder items or move them between groups.",
                    "Arrastra desde el asa para ordenar los elementos o moverlos entre grupos."))
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
            itemList(groups)
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

    private func itemList(_ groups: [TrayItemGroup]) -> some View {
        let rows = groups.flatMap(\.rows)
        let height = rows.reduce(CGFloat.zero) { height, row in
            if case .heading = row { return height + headingHeight }
            return height + SettingsDetailRowLayout.height
        }

        // Keep all rows in one native move source so AppKit supplies the preview and insertion line.
        return List {
            ForEach(rows, id: \.self) { row in
                Group {
                    switch row {
                    case let .heading(place):
                        groupHeading(place, count: groups.first { $0.place == place }?.items.count ?? 0)
                    case .empty:
                        Text(tx("Drop items here", "Suelta elementos aquí"))
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(height: SettingsDetailRowLayout.height)
                    case let .item(id):
                        if let info = TrayItems.info(id),
                           let group = groups.first(where: { $0.place == store.config.place(id) }),
                           let index = group.items.firstIndex(of: id) {
                            itemRow(info, group: group, index: index)
                        }
                    }
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0,
                                          trailing: SettingsDetailRowLayout.listTrailingInset))
                // No .moveDisabled on headers/placeholder: on macOS it also refuses drops next to those rows,
                // which blocked the first slot of a group and empty groups. Dragging a header is ignored in onMove.
            }
            .onMove { from, to in
                guard from.count == 1, let source = from.first,
                      let target = trayMoveTarget(in: rows, source: source, destination: to),
                      let id = rows[source].itemID else { return }
                move(id, to: target.place, at: target.index)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden).scrollDisabled(true)
        .frame(height: height + 12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func groupHeading(_ place: TrayPlace, count: Int) -> some View {
        HStack(spacing: 8) {
            Text(placementHeading(place)).font(.system(size: 13, weight: .semibold))
            Text(count.formatted()).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: headingHeight)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func itemRow(_ info: TrayItemInfo, group: TrayItemGroup, index: Int) -> some View {
        let id = info.id
        let detail = detailForItem(id)
        let caption = itemCaption(id)
        let canMoveUp = index > 0
        let canMoveDown = index + 1 < group.items.count
        return HStack(spacing: 0) {
            dragHandle
            if let detail {
                TrayDetailTapTarget(detail: detail, handleWidth: handleWidth, open: { open(detail) }) {
                    itemLabel(info, detail: detail, caption: caption)
                }
            } else {
                itemLabel(info, detail: nil, caption: caption)
                    .focusable()
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
            .frame(width: handleWidth, height: SettingsDetailRowLayout.height)
            .help(tx("Drag to move", "Arrastrar para mover"))
            .accessibilityHidden(true)
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

private struct TrayDetailTapTarget<Label: View>: View {
    let detail: SettingsDetail
    let handleWidth: CGFloat
    let open: () -> Void
    @ViewBuilder var label: Label
    @Environment(\.settingsDetailFocus) private var focus
    @State private var hovered = false

    var body: some View {
        if let focus { target.focused(focus, equals: detail) }
        else { target }
    }

    private var target: some View {
        let title = tx("Configure \(detail.title)", "Configurar \(detail.title)")
        return label
            .onHover { hovered = $0 }
            .background {
                Rectangle().fill(Color.primary.opacity(hovered ? 0.06 : 0))
                    .padding(.leading, -handleWidth)
                    .allowsHitTesting(false)
            }
            // Recognize a completed click alongside the List's drag, leaving the handle gesture-free.
            .simultaneousGesture(TapGesture().onEnded { open() })
            .focusable(interactions: .activate)
            .onKeyPress(keys: [.return, .space]) { _ in open(); return .handled }
            .help(title)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(title)
            .accessibilityAction { open() }
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

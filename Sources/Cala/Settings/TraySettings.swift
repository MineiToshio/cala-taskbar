import SwiftUI

struct TrayPane: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var mail: MailService
    @ObservedObject private var usage = UsageService.shared
    let open: (SettingsDetail) -> Void
    @Environment(\.settingsSnapshot) private var snapshot
    @State private var confirmReset = false

    private let headingHeight: CGFloat = 26

    private enum Row: Hashable {
        case heading(TrayPlace)
        case item(String)
        case empty(TrayPlace)

        var itemID: String? {
            if case let .item(id) = self { return id }
            return nil
        }
    }

    var body: some View {
        let rows = itemRows
        VStack(alignment: .leading, spacing: 22) {
            SectionTitle(text: tx("Item order and placement", "Orden y ubicación"))
            Text(tx("Drag the handle to reorder items or move them between groups.",
                    "Arrastra desde el asa para ordenar los elementos o moverlos entre grupos."))
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
            itemList(rows)
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

    private var itemRows: [Row] {
        var seen = Set<String>()
        let ids = store.config.orderedTrayIDs.filter { seen.insert($0).inserted }
        return TrayPlace.allCases.flatMap { place -> [Row] in
            let items = ids.filter { store.config.place($0) == place }
            return [.heading(place)] + (items.isEmpty ? [.empty(place)] : items.map(Row.item))
        }
    }

    private func itemList(_ rows: [Row]) -> some View {
        let height = rows.reduce(CGFloat.zero) { height, row in
            if case .heading = row { return height + headingHeight }
            return height + SettingsDetailRowLayout.height
        }
        // A single movable List supplies the full-row drag preview and insertion indicator. The
        // headings mark the placement boundaries, and empty rows keep those destinations reachable.
        return List {
            ForEach(rows, id: \.self) { row in
                Group {
                    switch row {
                    case let .heading(place):
                        Text(placementHeading(place))
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                            .accessibilityAddTraits(.isHeader)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(height: headingHeight)
                    case .empty:
                        Text(tx("Drop items here", "Suelta elementos aquí"))
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(height: SettingsDetailRowLayout.height)
                    case let .item(id):
                        if let info = TrayItems.info(id) { itemRow(info, rows: rows) }
                    }
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0,
                                          trailing: SettingsDetailRowLayout.listTrailingInset))
                .moveDisabled(row.itemID == nil)
            }
            .onMove { from, to in move(rows, from: from, to: to) }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden).scrollDisabled(true)
        .frame(height: height + 12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func itemRow(_ info: TrayItemInfo, rows: [Row]) -> some View {
        let id = info.id
        let place = store.config.place(id)
        let index = rows.firstIndex(of: .item(id))
        let canMoveUp = index.map { $0 > 0 && rows[$0 - 1].itemID != nil } ?? false
        let canMoveDown = index.map { $0 + 1 < rows.count && rows[$0 + 1].itemID != nil } ?? false
        return HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary).frame(width: 24, height: 28)
                .help(tx("Drag to move", "Arrastrar para mover"))
                .accessibilityHidden(true)
            Image(systemName: info.symbol).frame(width: 22).foregroundStyle(.secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(info.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                if let caption = itemCaption(id) {
                    Text(caption).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let detail = detailForItem(id) {
                SettingsDetailLink(detail: detail, open: open) { SettingsDetailChevron() }
                    .buttonStyle(.borderless)
            } else {
                Color.clear.frame(width: 28, height: 28).accessibilityHidden(true)
            }
        }
        .frame(height: SettingsDetailRowLayout.height)
        .contentShape(Rectangle())
        .focusable()
        .contextMenu {
            Button(tx("Move up", "Subir")) { moveStep(index, up: true, in: rows) }.disabled(!canMoveUp)
            Button(tx("Move down", "Bajar")) { moveStep(index, up: false, in: rows) }.disabled(!canMoveDown)
            Divider()
            ForEach(TrayPlace.allCases.filter { $0 != place }) { target in
                Button(moveTitle(target)) { move(id, to: target, in: rows) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(info.title)
        .accessibilityValue(placementHeading(place))
        .accessibilityActions {
            ForEach(TrayPlace.allCases.filter { $0 != place }) { target in
                Button(moveTitle(target)) { move(id, to: target, in: rows) }
            }
            if canMoveUp { Button(tx("Move up", "Subir")) { moveStep(index, up: true, in: rows) } }
            if canMoveDown { Button(tx("Move down", "Bajar")) { moveStep(index, up: false, in: rows) } }
        }
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

    private func move(_ id: String, to place: TrayPlace, in rows: [Row]) {
        guard let from = rows.firstIndex(of: .item(id)),
              let heading = rows.firstIndex(of: .heading(place)) else { return }
        // Append to the destination group, before the next heading.
        let end = rows.indices.dropFirst(heading + 1).first { index in
            if case .heading = rows[index] { return true }
            return false
        } ?? rows.endIndex
        move(rows, from: IndexSet(integer: from), to: end)
    }

    private func moveStep(_ index: Int?, up: Bool, in rows: [Row]) {
        guard let index else { return }
        let neighbor = index + (up ? -1 : 1)
        guard rows.indices.contains(neighbor), rows[neighbor].itemID != nil else { return }
        move(rows, from: IndexSet(integer: index), to: up ? neighbor : neighbor + 1)
    }

    private func move(_ rows: [Row], from: IndexSet, to: Int) {
        let moved = Set(from.compactMap { rows[$0].itemID })
        guard !moved.isEmpty, moved.count == from.count else { return }
        var reordered = rows
        reordered.move(fromOffsets: from, toOffset: to)
        guard reordered != rows else { return }

        var config = store.config
        var place = TrayPlace.bar
        for row in reordered {
            if case let .heading(next) = row { place = next }
            if let id = row.itemID, moved.contains(id), config.place(id) != place {
                config.trayLayout[id] = place.rawValue
            }
        }
        config.trayOrder = mergingTrayOrder(config.trayOrder, with: reordered.compactMap(\.itemID))
        store.config = config
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

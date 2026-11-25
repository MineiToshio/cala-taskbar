import SwiftUI
import AppKit

struct TrayPane: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject private var mail = MailService.shared
    @ObservedObject private var usage = UsageService.shared
    let open: (SettingsPane) -> Void
    @Environment(\.settingsSnapshot) private var snapshot
    @State private var confirmReset = false

    var body: some View {
        let ids = itemIDs
        VStack(alignment: .leading, spacing: 22) {
            Card {
                ForEach(SettingsPane.trayDetails) { pane in
                    if pane != .mail { RowDivider() }
                    SettingRow(title: pane.title,
                               caption: pane == .calendar ? tx("Upcoming events in the taskbar clock.", "Próximos eventos en el reloj de la barra de tareas.") : nil) {
                        Button(tx("Open", "Abrir")) { open(pane) }
                            .accessibilityLabel(tx("Open settings for \(pane.title)", "Abrir ajustes de \(pane.title)"))
                    }
                }
            }
            SectionTitle(text: tx("Item order and placement", "Orden y ubicación de los elementos"))
            Text(tx("Drag an item by its handle or use its reorder menu. Order applies within each location.",
                    "Arrastra un elemento por su tirador o usa su menú para cambiar el orden dentro de cada ubicación."))
                .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(TrayPlace.allCases) { place in
                let group = ids.filter { store.config.place($0) == place }
                SectionTitle(text: placementHeading(place))
                Card {
                    if group.isEmpty {
                        SettingRow(title: tx("No items", "Sin elementos")) { EmptyView() }
                    }
                    ForEach(Array(group.enumerated()), id: \.element) { index, id in
                        if let info = TrayItems.info(id) {
                            if index > 0 { RowDivider() }
                            itemRow(info, index: index, ids: group)
                            if id == traySystem { monitorSettings }
                            if id == trayDisk { DiskFolderSettings(store: store) }
                        }
                    }
                }
            }
            Button(tx("Reset order and placement…", "Restablecer orden y ubicación…")) { confirmReset = true }
                .alert(tx("Reset tray order and placement?", "¿Restablecer orden y ubicación de la Bandeja?"), isPresented: $confirmReset) {
                    Button(tx("Reset", "Restablecer"), role: .destructive) {
                        var config = store.config
                        config.trayLayout = [:]
                        config.trayOrder = []
                        store.config = config
                    }
                    Button(tx("Cancel", "Cancelar"), role: .cancel) {}
                } message: {
                    Text(tx("Returns the icons to their default order and locations, including any older visibility preferences for Disk and CPU and memory.",
                            "Devuelve los iconos a su orden y ubicación predeterminados, incluidas las preferencias antiguas de visibilidad de Disco y CPU y memoria."))
                }
        }
    }

    private func itemRow(_ info: TrayItemInfo, index: Int, ids: [String]) -> some View {
        let id = info.id
        let caption = itemCaption(id)
        let title = id == trayUsage ? SettingsPane.usage.title : info.title
        return HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary).frame(width: 20, height: 28)
                .contentShape(Rectangle()).draggable(id).accessibilityHidden(true)
            Image(systemName: info.symbol).frame(width: 22).foregroundStyle(.secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                if let caption {
                    Text(caption).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            if id == trayMail || id == trayUsage {
                let pane: SettingsPane = id == trayMail ? .mail : .usage
                Button { open(pane) } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel(tx("Open settings for \(pane.title)", "Abrir ajustes de \(pane.title)"))
            }
            Menu(tx("Move", "Mover")) {
                Button(tx("Move up", "Subir")) { move(ids, from: index, to: index - 1) }.disabled(index == 0)
                Button(tx("Move down", "Bajar")) { move(ids, from: index, to: index + 1) }.disabled(index == ids.count - 1)
                Divider()
                Picker(tx("Placement", "Ubicación"), selection: place(id)) {
                    ForEach(TrayPlace.allCases) { Text(placementHeading($0)).tag($0) }
                }.pickerStyle(.inline)
            }
            .fixedSize()
            .accessibilityLabel(tx("Move \(title)", "Mover \(title)"))
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { items, _ in
            guard let source = items.first, let from = ids.firstIndex(of: source), from != index else { return false }
            move(ids, from: from, to: index)
            return true
        }
        .accessibilityAction(named: Text(tx("Move up", "Subir"))) { move(ids, from: index, to: index - 1) }
        .accessibilityAction(named: Text(tx("Move down", "Bajar"))) { move(ids, from: index, to: index + 1) }
    }

    private var itemIDs: [String] {
        var seen = Set<String>()
        return store.config.orderedTrayIDs.filter { seen.insert($0).inserted }
    }

    private func itemCaption(_ id: String) -> String? {
        if id == trayMail && !mail.accountsLoadFailed && mail.accounts.isEmpty { return tx("No accounts", "Sin cuentas") }
        if id == trayMail && store.config.place(id) == .hidden {
            return tx("Enabled accounts still sync when the tray is on.", "Las cuentas activadas se siguen sincronizando cuando la Bandeja está activa.")
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

    private func place(_ id: String) -> Binding<TrayPlace> {
        Binding(get: { store.config.place(id) }, set: { store.config.trayLayout[id] = $0.rawValue })
    }

    private func move(_ ids: [String], from: Int, to: Int) {
        guard ids.indices.contains(to), from != to else { return }
        var order = ids
        let item = order.remove(at: from)
        order.insert(item, at: to)
        let members = Set(ids)
        var reordered = order.makeIterator()
        store.config.trayOrder = itemIDs.map { id in members.contains(id) ? (reordered.next() ?? id) : id }
    }

    private var monitorSettings: some View {
        Group {
            SettingRow(title: tx("Default indicator", "Indicador habitual"),
                       caption: tx("Alerts take priority over this choice.", "Los avisos tienen prioridad sobre esta elección.")) {
                Picker(tx("Default indicator", "Indicador habitual"),
                       selection: Binding(get: { store.config.monitorBarMetric }, set: { store.config.monitorBarMetric = $0; SystemMonitor.shared.tick() })) {
                    Text("CPU").tag("cpu")
                    Text(tx("Memory", "Memoria")).tag("memory")
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 142)
            }.padding(.leading, 32)
            SettingRow(title: tx("Suggest restarting the Mac", "Recomendar reiniciar el Mac"),
                       caption: tx("Shows reasons to restart in the CPU and memory panel.", "Muestra los motivos para reiniciar en el panel de CPU y memoria.")) {
                Toggle(tx("Suggest restarting the Mac", "Recomendar reiniciar el Mac"), isOn: $store.config.restartAdvice)
                    .toggleStyle(.switch).labelsHidden()
            }.padding(.leading, 32)
        }
    }
}

private struct DiskFolderSettings: View {
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
        .padding(.leading, 48).padding(.trailing, 16).padding(.bottom, 12)
        .onAppear { folders = store.config.diskFolders.joined(separator: ", ") }
    }

    private func applyFolders() {
        let parsed = folders.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if parsed != store.config.diskFolders { store.config.diskFolders = parsed }
        folders = parsed.joined(separator: ", ")
    }
}

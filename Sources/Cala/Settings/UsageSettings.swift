import SwiftUI

struct UsageSettingsPane: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject private var usage = UsageService.shared
    @ObservedObject private var permissions = PermissionCenter.shared
    private enum FolderField: Hashable { case claude, codex }
    @State private var claudeFolder = ""
    @State private var codexFolder = ""
    @FocusState private var focusedFolder: FolderField?
    private func applyFolder(_ field: FolderField) {
        switch field {
        case .claude where store.config.usageClaudeConfigDir != claudeFolder:
            store.config.usageClaudeConfigDir = claudeFolder
        case .codex where store.config.usageCodexHome != codexFolder:
            store.config.usageCodexHome = codexFolder
        default: break
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            Card {
                SettingRow(title: tx("Check Claude and Codex quotas", "Consultar cuotas de Claude y Codex"),
                           caption: tx("Choose where the indicator appears in Tray.", "Elige en Bandeja dónde aparece el indicador.")) {
                    Toggle(tx("Check Claude and Codex quotas", "Consultar cuotas de Claude y Codex"), isOn: $store.config.usageEnabled).labelsHidden().toggleStyle(.switch)
                }
            }
            SectionTitle(text: tx("Providers", "Proveedores"))
            Card {
                SettingRow(title: "Claude", caption: usage.providers.first { $0.provider == .claude }?.detection) {
                    Toggle("Claude", isOn: $store.config.usageClaudeEnabled).labelsHidden().toggleStyle(.switch)
                }
                RowDivider()
                SettingRow(title: "Codex", caption: usage.providers.first { $0.provider == .codex }?.detection) {
                    Toggle("Codex", isOn: $store.config.usageCodexEnabled).labelsHidden().toggleStyle(.switch)
                }
                if ModulePlan.effective(store.config.modules).tray && store.config.place(trayUsage) != .hidden {
                    RowDivider()
                    SettingRow(title: tx("Provider detection", "Detección de proveedores")) {
                        Button(tx("Refresh", "Actualizar")) { usage.settingsOpened() }
                    }
                }
            }
            SectionTitle(text: tx("Notifications", "Notificaciones"))
            Card {
                SettingRow(title: calendarText("Quota alerts", "Alertas de cuota"), caption: calendarText("Notify when a quota is low or, at the current pace, will run out before it resets.", "Avisa cuando una cuota está baja o, al ritmo actual, se agotará antes del reinicio.")) {
                    Toggle(calendarText("Quota alerts", "Alertas de cuota"), isOn: $store.config.usageAlertsEnabled).labelsHidden().toggleStyle(.switch)
                }
                RowDivider()
                SettingRow(title: calendarText("Alert when left is", "Avisar cuando quede"), caption: calendarText("Remaining share of a quota at or below which you are notified.", "Porcentaje restante de una cuota a partir del cual se te avisa.")) {
                    Picker("", selection: $store.config.usageAlertThreshold) {
                        ForEach([10, 15, 20, 30], id: \.self) { Text("\($0)%").tag($0) }
                    }.labelsHidden().frame(width: 90)
                    .accessibilityLabel(calendarText("Alert when left is", "Avisar cuando quede"))
                }
                .disabled(!store.config.usageAlertsEnabled)
                if store.config.usageAlertsEnabled && !permissions.granted(.notifications) {
                    RowDivider()
                    PermissionCard(kind: .notifications)
                }
            }
            .animation(.easeOut(duration: 0.2), value: store.config.usageAlertsEnabled)
            SectionTitle(text: tx("Folders and Claude Code", "Carpetas y conexión con Claude Code"))
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Text(tx("Custom folders (optional)", "Carpetas personalizadas (opcional)")).font(.system(size: 13, weight: .medium))
                    Text(tx("Leave blank to use your login shell configuration, then ~/.claude or ~/.codex.", "Déjalo vacío para usar la configuración de tu shell de inicio de sesión y luego ~/.claude o ~/.codex.")).font(.system(size: 11)).foregroundStyle(.secondary)
                    TextField(tx("Claude config dir", "Carpeta de configuración de Claude"), text: $claudeFolder).textFieldStyle(.roundedBorder)
                        .focused($focusedFolder, equals: .claude).onSubmit { applyFolder(.claude) }
                    TextField(tx("Codex home", "Carpeta de Codex"), text: $codexFolder).textFieldStyle(.roundedBorder)
                        .focused($focusedFolder, equals: .codex).onSubmit { applyFolder(.codex) }
                }.padding(16)
            }
            Card {
                SettingRow(title: tx("Claude Code live updates (statusLine)", "Actualizaciones en vivo de Claude Code (statusLine)"), caption: tx("Opt in to local updates. Backs up settings.json and preserves existing statusLine commands.", "Actívalo para recibir datos locales. Hace una copia de settings.json y conserva los comandos statusLine que ya tengas.")) {
                    Toggle(tx("Claude Code live updates", "Actualizaciones en vivo de Claude Code"), isOn: Binding(get: { store.config.usageClaudeStatusLine ?? false },
                                                                                         set: { usage.setStatusLineEnabled($0, store: store) })).labelsHidden().toggleStyle(.switch)
                }
                if !usage.statusLineMessage.isEmpty {
                    Text(usage.statusLineMessage).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled).padding(16)
                }
            }
        }
        .onAppear {
            claudeFolder = store.config.usageClaudeConfigDir; codexFolder = store.config.usageCodexHome
        }
        .onChange(of: focusedFolder) { old, _ in if let old { applyFolder(old) } }
        .onDisappear { applyFolder(.claude); applyFolder(.codex) }
    }
}

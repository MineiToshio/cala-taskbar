import SwiftUI

enum SettingsDetail: String, Identifiable {
    case cpuMemory, disk, mail, calendar, usage

    static let integrations: [Self] = [.mail, .calendar, .usage]
    var id: String { rawValue }

    var home: SettingsPane {
        switch self {
        case .cpuMemory, .disk: .tray
        case .mail, .calendar, .usage: .integrations
        }
    }

    var title: String {
        switch self {
        case .cpuMemory: tx("CPU and memory", "CPU y memoria")
        case .disk: tx("Disk", "Disco")
        case .mail: tx("Mail", "Correo")
        case .calendar: tx("Calendar", "Calendario")
        case .usage: TrayItems.usage.title
        }
    }

    var icon: String {
        switch self {
        case .cpuMemory: "cpu"
        case .disk: "internaldrive"
        case .mail: "envelope.fill"
        case .calendar: "calendar"
        case .usage: TrayItems.usage.symbol
        }
    }

    var integrationDescription: String {
        switch self {
        case .mail: tx("Mail accounts and sync", "Cuentas de correo y sincronización")
        case .calendar: tx("Upcoming events in the taskbar clock", "Próximos eventos en el reloj de la barra")
        case .usage: tx("Local sessions and quota alerts", "Sesiones locales y alertas de cuota")
        case .cpuMemory, .disk: ""
        }
    }

    var subtitle: String? {
        switch self {
        case .mail:
            tx("Connect Gmail, iCloud Mail, or Yahoo Mail with an app password stored in the Keychain. Google Workspace works if your administrator allows IMAP and app passwords. Cala doesn’t support Outlook or Hotmail.",
               "Conecta Gmail, Mail de iCloud o Yahoo Mail con una contraseña de aplicación guardada en el Llavero. Google Workspace funciona si tu administrador permite IMAP y las contraseñas de aplicación. Cala no admite Outlook ni Hotmail.")
        case .calendar:
            tx("Upcoming events from the calendars in the taskbar clock.", "Próximos eventos de los calendarios del reloj de la barra de tareas.")
        case .usage:
            tx("Claude and Codex plan usage in one tray control.", "El uso de tus planes de Claude y Codex en un solo control de la bandeja.")
        case .cpuMemory, .disk: nil
        }
    }
}

struct IntegrationsPane: View {
    let open: (SettingsDetail) -> Void

    var body: some View {
        Card {
            ForEach(SettingsDetail.integrations) { detail in
                SettingsDetailLink(detail: detail, open: open) {
                    HStack(spacing: 12) {
                        Image(systemName: detail.icon).frame(width: 22).foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(detail.title).font(.system(size: 13, weight: .medium))
                            Text(detail.integrationDescription).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        SettingsDetailChevron()
                    }
                    .padding(.leading, 16)
                    .padding(.trailing, SettingsDetailRowLayout.trailingInset)
                    .frame(height: SettingsDetailRowLayout.height)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .overlay(alignment: .top) {
                    if detail != .mail { RowDivider().allowsHitTesting(false) }
                }
            }
        }
    }
}

struct SettingsDetailPage: View {
    let detail: SettingsDetail
    let origin: SettingsPane
    @ObservedObject var store: ConfigStore
    let back: () -> Void
    @Environment(\.settingsSnapshot) private var snapshot

    var body: some View {
        let modules = snapshot?.modules ?? store.config.modules
        VStack(alignment: .leading, spacing: 22) {
            Button(action: back) { Label(origin.title, systemImage: "chevron.left") }
                .buttonStyle(.link)
                .accessibilityLabel(tx("Back to \(origin.title)", "Volver a \(origin.title)"))
            VStack(alignment: .leading, spacing: 4) {
                Text(detail.title).font(.system(size: 28, weight: .bold)).accessibilityAddTraits(.isHeader)
                if let subtitle = detail.subtitle {
                    Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            if !ModulePlan.effective(modules).tray {
                TrayDependencyCard(store: store)
                InactiveSettingsNote()
            }
            contents
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { if snapshot == nil { PermissionCenter.shared.beginWatching() } }
        .onDisappear { if snapshot == nil { PermissionCenter.shared.endWatching() } }
    }

    @ViewBuilder private var contents: some View {
        switch detail {
        case .cpuMemory: CPUSettingsPane(store: store)
        case .disk: Card { DiskFolderSettings(store: store).padding(16) }
        case .mail: MailSettingsPane(service: snapshot?.mail ?? MailService.shared)
        case .calendar: CalendarSettingsPane(store: store)
        case .usage: UsageSettingsPane(store: store)
        }
    }
}

struct InactiveSettingsNote: View {
    var body: some View {
        Text(tx("You can change these settings now. They’ll take effect when you enable the module.",
                "Puedes cambiar estos ajustes ahora. Se aplicarán al activar el módulo."))
            .font(.system(size: 12)).foregroundStyle(.secondary)
    }
}

enum SettingsDetailRowLayout {
    static let height: CGFloat = 44
    static let trailingInset: CGFloat = 25
    // A plain macOS List adds padding outside its explicit row insets.
    static let listTrailingInset = trailingInset - 9
}

struct SettingsDetailChevron: View {
    var body: some View {
        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.secondary).frame(width: 28, height: 28)
            .contentShape(Rectangle())
    }
}

struct SettingsDetailLink<LinkLabel: View>: View {
    let detail: SettingsDetail
    let open: (SettingsDetail) -> Void
    @ViewBuilder var label: LinkLabel
    @Environment(\.settingsDetailFocus) private var focus

    var body: some View {
        if let focus { button.focused(focus, equals: detail) }
        else { button }
    }

    private var button: some View {
        let title = tx("Configure \(detail.title)", "Configurar \(detail.title)")
        return Button { open(detail) } label: { label }
            .help(title)
            .accessibilityLabel(title)
    }
}

private struct SettingsDetailFocusKey: EnvironmentKey {
    static let defaultValue: FocusState<SettingsDetail?>.Binding? = nil
}

extension EnvironmentValues {
    var settingsDetailFocus: FocusState<SettingsDetail?>.Binding? {
        get { self[SettingsDetailFocusKey.self] }
        set { self[SettingsDetailFocusKey.self] = newValue }
    }
}

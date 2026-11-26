import AppKit
import SwiftUI

func mailTrayTitle(_ unread: Int) -> String {
    if unread == 1 { return tx("Mail · 1 unread message", "Correo · 1 mensaje sin leer") }
    return tx("Mail · \(unread) unread messages", "Correo · \(unread) mensajes sin leer")
}

struct MailTrayGlyph: View {
    let unread: Int

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: "envelope").font(.system(size: 14))
            if unread > 0 {
                Text(unread > 99 ? tx("99+", "99+") : String(unread))
                    .font(.system(size: 9.5, weight: .medium))
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Uses the standard overflow layout and navigation when Mail is included in the configured order.
struct MailOverflowPane: View {
    @ObservedObject var fm: FlyoutModel
    @ObservedObject var model: TaskbarModel
    @ObservedObject private var store = ConfigStore.shared
    @ObservedObject private var service = MailService.shared
    @State private var hover: String?

    var body: some View {
        let ids = store.config.moreTrayIDs.filter { $0 == trayMail ? !service.accounts.isEmpty : model.trayAvailable($0) }
        if store.config.moreTrayIDs.contains(trayMail) {
            VStack(alignment: .leading, spacing: 12) {
                Header(title: tx("More", "Más"))
                if ids.isEmpty {
                    Text(tx("Nothing here. Choose what to show in Settings → Tray.", "No hay nada aquí. Elige qué mostrar en Configuración → Bandeja."))
                        .font(.system(size: 12)).flyoutSecondary()
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                        ForEach(ids, id: \.self) { id in
                            if let info = TrayItems.info(id) { tile(info) }
                        }
                    }
                }
                Divider()
                Row(icon: "slider.horizontal.3", title: tx("Choose what to show…", "Elegir qué se muestra…")) {
                    NotificationCenter.default.post(name: .flyoutHide, object: nil)
                    SettingsWindowController.shared.show(pane: .tray)
                }
            }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { _ in
                NotificationCenter.default.post(name: .flyoutRefit, object: nil)
            }
        } else {
            MorePane(fm: fm, model: model)
        }
    }

    private func tile(_ info: TrayItemInfo) -> some View {
        let isMail = info.id == trayMail
        let title = isMail ? mailTrayTitle(service.unreadCount) : info.title
        return Button {
            fm.fromMore = true; fm.kind = info.id; fm.token += 1
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    if isMail {
                        MailTrayGlyph(unread: service.unreadCount)
                    } else {
                        TrayGlyph(id: info.id, model: model).scaleEffect(1.3)
                    }
                }
                .frame(height: 26)
                Text(info.title).font(.system(size: 11)).lineLimit(1)
            }
            .frame(maxWidth: .infinity).frame(height: 66)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(hover == info.id ? 0.12 : 0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 ? info.id : (hover == info.id ? nil : hover) }
        .help(title)
        .accessibilityLabel(title)
    }
}

private let mailColors: [Color] = [.blue, .purple, .pink, .orange, .green, .teal]

private func mailColor(_ index: Int) -> Color {
    mailColors.indices.contains(index) ? mailColors[index] : mailColors[0]
}

private func mailProblem(_ status: MailAccountStatus?) -> String? { status?.problem }

private func mailOpenSettings() {
    NotificationCenter.default.post(name: .flyoutHide, object: nil)
    SettingsWindowController.shared.show(detail: .mail)
}

private func mailSender(_ message: MailMessage) -> String {
    message.fromName.isEmpty ? message.fromAddress : message.fromName
}

private func mailSubject(_ message: MailMessage) -> String {
    message.subject.isEmpty ? tx("(No subject)", "(Sin asunto)") : message.subject
}

private extension MailProvider {
    var pickerTitle: String {
        switch self {
        case .gmail: tx("Gmail", "Gmail")
        case .icloud: tx("iCloud", "iCloud")
        case .yahoo: tx("Yahoo", "Yahoo")
        }
    }

    var localizedName: String { tx(displayName, displayName) }
}

private var mailLocale: Locale { Locale(identifier: tx("en_GB", "es_PE")) }

private func mailRelativeDate(_ date: Date, now: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDate(date, inSameDayAs: now) {
        return date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(mailLocale))
    }
    if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
        return tx("Yesterday", "Ayer")
    }
    let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day
    if let days, (2...6).contains(days) {
        return date.formatted(.dateTime.weekday(.wide).locale(mailLocale))
    }
    return date.formatted(.dateTime.day().month(.abbreviated).locale(mailLocale))
}

struct MailPane: View {
    let availableHeight: CGFloat
    let readerHeight: CGFloat
    @Binding var reading: MailMessage?
    @ObservedObject private var service = MailService.shared
    @State private var filter: String?

    private var enabledAccounts: [MailAccount] { service.accounts.filter(\.enabled) }
    private var selectedAccount: MailAccount? {
        guard enabledAccounts.count > 1 else { return nil }
        return enabledAccounts.first { $0.id == filter }
    }

    var body: some View {
        Group {
            if let reading, let account = enabledAccounts.first(where: { $0.id == reading.accountID }) {
                MailReader(message: reading, account: account, showAccount: enabledAccounts.count > 1,
                           height: readerHeight) {
                    self.reading = nil
                }
                .id(reading.id)
            } else {
                inbox
            }
        }
        .onAppear { service.refresh() }
        .onChange(of: service.messages) { _, messages in
            if let reading, !messages.contains(where: { $0.id == reading.id }) {
                self.reading = nil
            }
        }
        .onChange(of: service.accounts) { previous, accounts in
            if let reading {
                let oldProvider = previous.first { $0.id == reading.accountID }?.provider
                if !accounts.contains(where: { $0.id == reading.accountID && $0.enabled && $0.provider == oldProvider }) {
                    self.reading = nil
                }
            }
            let enabled = accounts.filter(\.enabled)
            if enabled.count < 2 || !enabled.contains(where: { $0.id == filter }) { filter = nil }
        }
    }

    private func emptyText(_ phase: MailInboxPhase) -> String {
        switch phase {
        case .noAccounts: tx("No enabled accounts.", "No hay cuentas activas.")
        case .paused: tx("Mail sync is paused.", "La sincronización del correo está en pausa.")
        case .empty: tx("No messages in your inbox.", "No hay mensajes en Recibidos.")
        default: tx("Loading inbox…", "Cargando recibidos…")
        }
    }

    /// The Keychain explanation window can end up behind other windows; the flyout lets the person go on from here.
    private func continueMail() {
        MailKeychainNoticeController.shared.dismiss()
        service.continueAfterKeychainNotice()
    }

    private var inbox: some View {
        let accountID = selectedAccount?.id
        let unread = accountID.map { service.unread(for: $0) } ?? service.unreadCount
        let messages = Array(service.messages.lazy.filter { accountID == nil || $0.accountID == accountID }.prefix(8))
        let visibleAccounts = enabledAccounts.filter { accountID == nil || $0.id == accountID }
        let problems = visibleAccounts.filter { mailProblem(service.status[$0.id]) != nil }
        let phase = MailInboxPhase.of(accounts: visibleAccounts.map(\.id), status: service.status,
                                      synced: service.syncedAccounts, hasMessages: !messages.isEmpty,
                                      awaitingKeychainNotice: service.awaitingKeychainNotice)
        let webAccount = selectedAccount ?? enabledAccounts.first
        let providerName = (webAccount?.provider ?? .gmail).localizedName
        // Account colors only tell messages apart when the list mixes accounts.
        let colorsAccounts = enabledAccounts.count > 1 && accountID == nil
        return VStack(alignment: .leading, spacing: 10) {
            MailInboxHeader(unread: unread, refresh: {
                if service.awaitingKeychainNotice { continueMail() } else { service.refresh() }
            }, settings: mailOpenSettings)
            if enabledAccounts.count > 1 {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        filterChip(tx("All", "Todas"), count: service.unreadCount, account: nil)
                        ForEach(enabledAccounts) { account in
                            filterChip(account.label, count: service.unread(for: account.id), account: account)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            if !messages.isEmpty || !problems.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(problems) { account in
                            if let problem = mailProblem(service.status[account.id]) {
                                Row(icon: "exclamationmark.triangle", title: account.label, subtitle: problem, action: mailOpenSettings)
                                    .lineLimit(1)
                                    .frame(height: 42)
                                    .help(problem)
                            }
                        }
                        MailMessageList(messages: messages, accountColor: { message in
                            guard colorsAccounts else { return nil }
                            return enabledAccounts.first { $0.id == message.accountID }.map { mailColor($0.colorIndex) }
                        }) { message in
                            reading = message
                            if message.unread { service.markRead(message) }
                        }
                    }
                }
                .frame(height: min(max(90, availableHeight - 132),
                                   CGFloat(problems.count * 42) + MailMessageList.height(messages.count)))
            }
            switch phase {
            case .messages, .problem:
                EmptyView()
            case .waitingForKeychainNotice:
                Row(icon: "lock.shield",
                    title: tx("Mail is waiting for you", "El correo te está esperando"),
                    subtitle: tx("Click to continue. macOS will ask for your Mac password: choose “Always Allow”.",
                                 "Haz clic para continuar. macOS te pedirá la contraseña de tu Mac: elige «Permitir siempre»."),
                    action: continueMail)
                    .lineLimit(2)
            case .loading:
                MailInboxSkeleton(label: emptyText(phase))
            case .noAccounts, .paused, .empty:
                MailInboxNote(phase: phase, text: emptyText(phase))
            }
            Divider()
            HStack(spacing: 6) {
                MailToolbarButton(title: tx("Mark all as read", "Marcar todo como leído"), symbol: "envelope.open") {
                    service.markAllRead(accountID: accountID)
                }
                .disabled(unread == 0)
                Spacer(minLength: 4)
                MailToolbarButton(title: tx("Open \(providerName)", "Abrir \(providerName)"), symbol: "arrow.up.right") {
                    if let webAccount {
                        NSWorkspace.shared.open(webAccount.provider.webInboxURL(accountID: webAccount.id))
                    }
                }
                .disabled(webAccount == nil)
            }
        }
    }

    private func filterChip(_ title: String, count: Int, account: MailAccount?) -> some View {
        let selected = selectedAccount?.id == account?.id
        return Button { filter = account?.id } label: {
            MailChip(title: title, count: count, color: account.map { mailColor($0.colorIndex) }, selected: selected)
        }
        .buttonStyle(MailHoverStyle(radius: 12))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Sender avatar hues, two stops each (top, bottom). White initials stay at 3:1 or better on the bottom stop in both
/// appearances; there is no yellow or lime because white text disappears on them.
private let mailAvatarPalette: [(top: UInt32, bottom: UInt32)] = [
    (0x62A0F8, 0x2F6BDB),   // blue
    (0x8F8BF6, 0x5951D2),   // indigo
    (0xB98CEF, 0x8549C6),   // violet
    (0xF08AB5, 0xC93C78),   // pink
    (0xF49C86, 0xCC4E39),   // coral
    (0xF2AE66, 0xC4641A),   // orange
    (0x63C98F, 0x1E8A50),   // green
    (0x5BC4CB, 0x15808A),   // teal
]

private struct MailInboxHeader: View {
    let unread: Int
    let refresh: () -> Void
    let settings: () -> Void
    @Environment(\.themeAccent) private var accent

    var body: some View {
        HStack(spacing: 8) {
            MailAppIcon()
            Text(tx("Mail", "Correo")).font(.system(size: 14, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            if unread > 0 {
                Text(tx("\(unread.formatted()) unread", "\(unread.formatted()) sin leer"))
                    .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    .padding(.horizontal, 7).frame(height: 18)
                    .background(Capsule().fill(accent.opacity(0.16)))
                    .fixedSize()
            }
            Spacer(minLength: 4)
            HStack(spacing: 2) {
                MailToolbarButton(title: tx("Refresh", "Actualizar"), symbol: "arrow.clockwise", iconOnly: true,
                                  action: refresh)
                MailToolbarButton(title: tx("Mail Settings", "Configuración de correo"), symbol: "gearshape",
                                  iconOnly: true, action: settings)
            }
        }
    }
}

/// A small Mail-blue tile, the same family as the control blue used by switches and sliders.
private struct MailAppIcon: View {
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        Image(systemName: "envelope.fill")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background {
                if contrast == .increased {
                    shape.fill(BarTheme.hex(0x0060DF))
                } else {
                    shape.fill(LinearGradient(colors: [BarTheme.hex(0x4DA6FF), BarTheme.hex(0x0A6EF0)],
                                              startPoint: .top, endPoint: .bottom))
                }
            }
            .accessibilityHidden(true)
    }
}

private struct MailChip: View {
    let title: String
    var count: Int? = nil
    let color: Color?
    var selected = false
    @Environment(\.themeAccent) private var accent
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let tint = color ?? accent
        HStack(spacing: 5) {
            if let color { Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true) }
            Text(title).lineLimit(1).frame(maxWidth: 112, alignment: .leading)
            if let count, count > 0 { Text(count.formatted()).monospacedDigit().flyoutSecondary() }
        }
        .font(.system(size: 11, weight: selected ? .semibold : .medium))
        .padding(.horizontal, 9).frame(height: 24)
        .background {
            Capsule().fill(selected ? tint.opacity(0.2) : Color.primary.opacity(0.06))
            if selected && contrast == .increased { Capsule().strokeBorder(tint, lineWidth: 1) }
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .combine)
    }
}

/// A round sender picture: initials on a color that is always the same for the same address.
private struct MailSenderAvatar: View {
    let name: String
    let address: String
    var size: CGFloat = 34
    /// Which account the message belongs to, shown as a small dot when the list mixes accounts.
    var accountColor: Color? = nil
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let key = address.isEmpty ? name : address
        let stops = mailAvatarPalette[MailAvatar.paletteIndex(for: key, count: mailAvatarPalette.count)]
        let initials = MailAvatar.initials(name: name, address: address)
        ZStack {
            if contrast == .increased {
                Circle().fill(BarTheme.hex(stops.bottom))
            } else {
                Circle().fill(LinearGradient(colors: [BarTheme.hex(stops.top), BarTheme.hex(stops.bottom)],
                                             startPoint: .top, endPoint: .bottom))
            }
            if initials.isEmpty {
                Image(systemName: "person.fill").font(.system(size: size * 0.44))
            } else {
                Text(initials)
                    .font(.system(size: size * (initials.count > 1 ? 0.38 : 0.45), weight: .semibold, design: .rounded))
                    .minimumScaleFactor(0.7)
            }
        }
        .foregroundStyle(.white)
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            if let accountColor {
                Circle().fill(accountColor)
                    .frame(width: size * 0.32, height: size * 0.32)
                    .overlay(Circle().strokeBorder(FlyoutStyle.surface(dark: scheme == .dark), lineWidth: 2))
                    .offset(x: 2, y: 2)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The inbox rows. Unread rows sit on a soft accent card, so dividers are drawn only between two read rows.
private struct MailMessageList: View {
    static let spacing: CGFloat = 2
    let messages: [MailMessage]
    let accountColor: (MailMessage) -> Color?
    let open: (MailMessage) -> Void

    static func height(_ count: Int) -> CGFloat {
        CGFloat(count * MailMessageRow.height) + CGFloat(max(0, count - 1)) * spacing
    }

    var body: some View {
        VStack(spacing: Self.spacing) {
            ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                let next = messages.indices.contains(index + 1) ? messages[index + 1] : nil
                MailMessageRow(message: message, accountColor: accountColor(message),
                               showsDivider: next.map { !$0.unread && !message.unread } ?? false) {
                    open(message)
                }
            }
        }
    }
}

private struct MailMessageRow: View {
    static let height = 64
    let message: MailMessage
    var accountColor: Color? = nil
    let showsDivider: Bool
    let action: () -> Void
    @Environment(\.themeAccent) private var accent
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let unread = message.unread
        let dark = scheme == .dark
        Button(action: action) {
            HStack(alignment: .top, spacing: 0) {
                Circle().fill(unread ? accent : .clear)
                    .frame(width: 7, height: 7).padding(.top, 15)
                    .frame(width: 15, alignment: .leading)
                    .accessibilityHidden(true)
                MailSenderAvatar(name: message.fromName, address: message.fromAddress, accountColor: accountColor)
                    .padding(.top, 1)
                    .padding(.trailing, 10)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(mailSender(message)).font(.system(size: 13, weight: unread ? .semibold : .regular))
                        Spacer(minLength: 3)
                        Text(mailRelativeDate(message.date, now: .now))
                            .font(.system(size: 11, weight: unread ? .semibold : .regular)).monospacedDigit()
                            .foregroundStyle(unread ? accent : FlyoutStyle.secondary(dark: dark))
                            .fixedSize()
                    }
                    Text(mailSubject(message)).font(.system(size: 12, weight: unread ? .medium : .regular))
                    Text(message.snippet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                         ? tx("No preview", "Sin vista previa") : message.snippet)
                        .font(.system(size: 11.5)).flyoutSecondary()
                }
                .lineLimit(1)
            }
            .padding(.leading, 4).padding(.trailing, 9).padding(.vertical, 7)
            .frame(height: CGFloat(Self.height), alignment: .top)
            .background {
                if unread {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(accent.opacity(contrast == .increased ? (dark ? 0.24 : 0.16) : (dark ? 0.13 : 0.075)))
                }
            }
        }
        .buttonStyle(MailHoverStyle(radius: 9))
        .overlay(alignment: .bottom) {
            if showsDivider {
                Divider().padding(.leading, 63).padding(.trailing, 9).offset(y: MailMessageList.spacing / 2)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityValue(unread ? tx("Unread", "Sin leer") : tx("Read", "Leído"))
    }
}

/// Loading: the shape of the list, pulsing, instead of a spinner on an empty pane.
private struct MailInboxSkeleton: View {
    let label: String

    var body: some View {
        SystemLoadingPulse {
            VStack(spacing: MailMessageList.spacing) {
                ForEach(0..<3, id: \.self) { index in
                    HStack(alignment: .top, spacing: 10) {
                        Circle().fill(Color.primary.opacity(0.12)).frame(width: 34, height: 34)
                        VStack(alignment: .leading, spacing: 7) {
                            SystemSkeletonMark().frame(width: [120, 96, 136][index], height: 11)
                            SystemSkeletonMark().frame(width: [210, 180, 196][index], height: 9)
                            SystemSkeletonMark().frame(height: 9)
                        }
                        .padding(.top, 3)
                    }
                    .padding(.leading, 19).padding(.trailing, 9).padding(.vertical, 7)
                    .frame(height: CGFloat(MailMessageRow.height), alignment: .top)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}

/// Empty, paused or no accounts: a calm note with a tinted symbol.
private struct MailInboxNote: View {
    let phase: MailInboxPhase
    let text: String
    @Environment(\.themeAccent) private var accent

    private var symbol: String {
        switch phase {
        case .empty: "tray"
        case .paused: "pause"
        default: "envelope.badge.person.crop"
        }
    }

    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(accent)
                .frame(width: 40, height: 40)
                .background(Circle().fill(accent.opacity(0.14)))
                .accessibilityHidden(true)
            Text(text).font(.system(size: 12)).flyoutSecondary().multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }
}

private struct MailHoverStyle: ButtonStyle {
    var radius: CGFloat = 7

    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration, radius: radius)
    }

    private struct HoverBody: View {
        let configuration: Configuration
        let radius: CGFloat
        @Environment(\.isEnabled) private var enabled
        @State private var hovered = false

        var body: some View {
            configuration.label
                .background {
                    RoundedRectangle(cornerRadius: radius)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.14 : (hovered && enabled ? 0.08 : 0)))
                }
                .contentShape(Rectangle())
                .opacity(enabled ? 1 : 0.4)
                .onHover { hovered = $0 }
        }
    }
}

private struct MailToolbarButton: View {
    let title: String
    let symbol: String
    var iconOnly = false
    var role: ButtonRole? = nil
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(role: role, action: action) {
            Label(title, systemImage: symbol)
                .labelStyle(MailToolbarLabelStyle(iconOnly: iconOnly))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(role == .destructive ? FlyoutStyle.quotaText(0, dark: scheme == .dark) : .primary)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, iconOnly ? 6 : 9)
                .frame(minWidth: 28, minHeight: 30)
        }
        .buttonStyle(MailHoverStyle())
        .help(title)
        .accessibilityLabel(title)
    }
}

private struct MailToolbarLabelStyle: LabelStyle {
    let iconOnly: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon
            if !iconOnly { configuration.title }
        }
    }
}

private struct MailReader: View {
    let message: MailMessage
    let account: MailAccount
    let showAccount: Bool
    let height: CGFloat
    let close: () -> Void
    @ObservedObject private var service = MailService.shared
    @ObservedObject private var store = ConfigStore.shared
    @State private var state = LoadState.loading
    @State private var attempt = 0

    private enum LoadState {
        case loading
        case loaded(MailContent)
        case failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            toolbar
            Divider()
            messageHeader
            if case let .operationFailed(problem) = service.status[message.accountID] {
                Label(problem, systemImage: "exclamationmark.circle")
                    .font(.system(size: 11)).flyoutSecondary().lineLimit(2).help(problem)
            }
            GeometryReader { _ in
                messageBody
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.white)
                    .clipShape(.rect(cornerRadius: 11))
                    .overlay {
                        RoundedRectangle(cornerRadius: 11).strokeBorder(.black.opacity(0.08))
                            .allowsHitTesting(false)
                    }
            }
        }
        .frame(height: height, alignment: .top)
        .task(id: attempt) {
            state = .loading
            do {
                let content = try await service.content(of: message)
                if !Task.isCancelled { state = .loaded(content) }
            } catch {
                if !Task.isCancelled { state = .failed(error.localizedDescription) }
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            MailToolbarButton(title: tx("Back", "Volver"), symbol: "chevron.left", action: close)
            Spacer(minLength: 8)
            if service.canArchive(message) {
                MailToolbarButton(title: tx("Archive", "Archivar"), symbol: "archivebox") {
                    service.archive(message)
                    close()
                }
            }
            MailToolbarButton(title: tx("Delete", "Eliminar"), symbol: "trash", role: .destructive) {
                service.trash(message)
                close()
            }
            let provider = account.provider.localizedName
            MailToolbarButton(title: tx("Open in \(provider)", "Abrir en \(provider)"), symbol: "arrow.up.right") {
                NSWorkspace.shared.open(service.webURL(for: message))
            }
        }
    }

    private var messageHeader: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(mailSubject(message)).font(.system(size: 20, weight: .semibold))
                .lineLimit(2).accessibilityAddTraits(.isHeader)
            HStack(alignment: .center, spacing: 10) {
                MailSenderAvatar(name: message.fromName, address: message.fromAddress, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(mailSender(message)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if !message.fromName.isEmpty && message.fromName != message.fromAddress {
                        Text(message.fromAddress).font(.system(size: 11.5)).flyoutSecondary().lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(message.date.formatted(.dateTime.day().month(.abbreviated).year().hour().minute().locale(mailLocale)))
                        .font(.system(size: 11)).flyoutSecondary().fixedSize()
                    if showAccount { MailChip(title: account.label, color: mailColor(account.colorIndex)) }
                }
            }
        }
    }

    @ViewBuilder private var messageBody: some View {
        switch state {
        case .loading:
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(tx("Loading message…", "Cargando mensaje…")).font(.system(size: 12))
            }
            .foregroundStyle(.secondary)
            .environment(\.colorScheme, .light)
        case let .loaded(content):
            MailWebBody(content: content, loadsRemoteImages: store.config.mailLoadsRemoteImages) { error in
                state = .failed(error)
            }
            .id(store.config.mailLoadsRemoteImages)
        case let .failed(error):
            VStack(spacing: 9) {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 20)).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(tx("Couldn’t open this message", "No se pudo abrir este mensaje"))
                    .font(.system(size: 14, weight: .semibold))
                Text(error).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                    .multilineTextAlignment(.center)
                Button(tx("Retry", "Reintentar")) { attempt += 1 }
                    .buttonStyle(.bordered).padding(.top, 3)
            }
            .padding(20)
            .environment(\.colorScheme, .light)
        }
    }
}

struct MailSettingsPane: View {
    @Environment(\.openURL) private var openURL
    @ObservedObject var service: MailService
    @ObservedObject private var store = ConfigStore.shared
    @State private var email = ""
    @State private var label = ""
    @State private var password = ""
    @State private var providerOverride: MailProvider?
    @State private var connecting = false
    @State private var errorMessage: String?

    private var trimmedEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var provider: MailProvider { providerOverride ?? MailProvider.suggested(for: trimmedEmail) }
    private var canConnect: Bool {
        !connecting && !service.accountsLoadFailed && MailCredentialCheck.isEmail(trimmedEmail) && provider.looksLikeAppPassword(password)
    }

    private var defaultLabel: String {
        let parts = trimmedEmail.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, let domain = parts.last, !domain.isEmpty else { return tx("Personal", "Personal") }
        if domain.lowercased() == "gmail.com" { return tx("Personal", "Personal") }
        return String(domain.prefix { $0 != "." })
    }

    var body: some View {
        let hasAccounts = service.accountsLoadFailed || !service.accounts.isEmpty
        VStack(alignment: .leading, spacing: 24) {
            if hasAccounts {
                SectionTitle(text: tx("Accounts", "Cuentas"))
                Card {
                    if service.accountsLoadFailed {
                        SettingRow(title: tx("Cala couldn’t read the saved accounts. Check mail-accounts.json and reopen Cala.",
                                             "Cala no pudo leer las cuentas guardadas. Revisa mail-accounts.json y vuelve a abrir Cala.")) { EmptyView() }
                    } else {
                        ForEach(Array(service.accounts.enumerated()), id: \.element.id) { index, account in
                            if index > 0 { RowDivider() }
                            MailAccountSettingsRow(account: account, service: service)
                        }
                    }
                }
                readingSettings
            }
            SectionTitle(text: service.accounts.isEmpty && !service.accountsLoadFailed
                         ? tx("Connect your first account", "Conecta tu primera cuenta")
                         : tx("Add account", "Añadir cuenta"))
            Card {
                let providerTitle = tx("Mail provider", "Proveedor de correo")
                let emailTitle = tx("Email address", "Dirección de correo")
                let labelTitle = tx("Account label", "Nombre de la cuenta")
                accountFormRow(providerTitle) {
                    MailProviderPicker(title: providerTitle, selection: Binding(
                        get: { provider },
                        set: { providerOverride = $0; errorMessage = nil }
                    ))
                    .disabled(connecting)
                }
                RowDivider()
                accountFormRow(emailTitle) {
                    TextField(emailTitle, text: $email, prompt: Text(tx("you@example.com", "tu@ejemplo.com")))
                        .disabled(connecting)
                }
                RowDivider()
                accountFormRow(labelTitle) {
                    TextField(labelTitle, text: $label, prompt: Text(defaultLabel))
                        .disabled(connecting)
                }
                RowDivider()
                setupInstructions
                passwordRow
                RowDivider()
                MailKeychainNote()
                HStack(spacing: 10) {
                    Spacer()
                    if connecting {
                        ProgressView().controlSize(.small)
                            .accessibilityLabel(tx("Connecting", "Conectando"))
                    }
                    Button(action: connect) {
                        Text(connecting ? tx("Connecting…", "Conectando…") : tx("Connect", "Conectar"))
                            .frame(minWidth: 68)
                    }
                    .buttonStyle(.borderedProminent)
                    .flyoutControls()
                    .disabled(!canConnect)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .onSubmit(connect)
            if !hasAccounts { readingSettings }
        }
        .onDisappear { password = "" }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            if let window = note.object as? NSWindow, window === SettingsWindowController.shared.window { password = "" }
        }
    }

    private var readingSettings: some View {
        Group {
            SectionTitle(text: tx("Reading", "Lectura"))
            Card {
                let title = tx("Load images from the internet", "Cargar imágenes de internet")
                SettingRow(title: title, caption: tx("Senders may know when you open their email.",
                                                     "Los remitentes pueden saber cuándo abres su correo.")) {
                    Toggle(title, isOn: $store.config.mailLoadsRemoteImages)
                        .labelsHidden().toggleStyle(FlyoutSwitchStyle())
                }
            }
        }
    }

    private func accountFormRow<Control: View>(_ title: String, caption: String? = nil,
                                                @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: caption == nil ? .center : .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .medium))
                if let caption {
                    Text(caption).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 170, alignment: .leading)
            control()
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var setupInstructions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tx("How to get your app password", "Cómo obtener tu contraseña de aplicación"))
                .font(.system(size: 13, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            switch provider {
            case .gmail:
                guideStep(1, tx("Click “Turn on 2-Step Verification” and follow the prompts. If it’s already on, go to step 2.",
                                "Haz clic en «Activar la Verificación en 2 pasos» y sigue las indicaciones. Si ya está activa, pasa al paso 2."),
                          page: MailProvider.gmailTwoStepURL(for: trimmedEmail))
                guideStep(2, tx("Name the app “Cala” and click “Create” to see the 16-letter code.",
                                "Escribe «Cala» como nombre y haz clic en «Crear» para ver el código."),
                          page: provider.appPasswordsURL(for: trimmedEmail))
            case .icloud:
                guideStep(1, tx("Sign in to Apple. Under “Sign-In and Security”, open “App-Specific Passwords”.\nClick the generate button or “+”, name it “Cala” and confirm if prompted.",
                                "Inicia sesión en Apple. En «Inicio de sesión y seguridad», abre «Contraseñas específicas de la aplicación».\nElige «+» o la opción para generar una contraseña. Escribe «Cala» y confirma si Apple te lo pide."),
                          page: provider.appPasswordsURL())
            case .yahoo:
                guideStep(1, tx("Sign in to Yahoo. Under “External connections”, click “Create app password”. Enter “Cala” and click “Generate password”.",
                                "Inicia sesión en Yahoo. En «Conexiones externas», elige «Crear contraseña de aplicación». Escribe «Cala» y haz clic en «Generar contraseña»."),
                          page: provider.appPasswordsURL())
            }
            guideStep(provider == .gmail ? 3 : 2,
                      tx("Copy the code, return to Cala and paste it in “App password” below.",
                         "Copia el código, vuelve a Cala y pégalo abajo, en «Contraseña de aplicación»."))
            Divider()
            Text(setupTroubleshooting)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private func guideStep(_ number: Int, _ instruction: String, page: URL? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(tx("\(number).", "\(number)."))
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            Text(instruction)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let page {
                Button(tx("Open page", "Abrir página")) { openURL(page) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()
                    .accessibilityLabel(tx("Open page for step \(number)", "Abrir página del paso \(number)"))
                    .disabled(connecting)
            }
        }
        .font(.system(size: 11.5))
    }

    private var setupTroubleshooting: String {
        switch provider {
        case .gmail:
            tx("Can’t create a password? Check step 1. For work accounts, ask IT.",
               "¿No puedes crearla? Revisa el paso 1. Si es una cuenta del trabajo, pide ayuda a soporte.")
        case .icloud:
            tx("If the option is missing, turn on two-factor authentication in your Apple Account.",
               "Si falta la opción, activa «Autenticación de dos factores» en tu cuenta de Apple.")
        case .yahoo:
            tx("No code? Use a browser you’ve used for Yahoo several days in a row, outside private mode.",
               "¿Sin código? Entra a Yahoo varios días seguidos desde el mismo navegador, sin modo privado.")
        }
    }

    private var passwordRow: some View {
        let name = provider.pickerTitle
        let title = tx("App password", "Contraseña de aplicación")
        let caption = tx("Not your \(name) password.", "No es tu contraseña de \(name).")
        let example = provider == .icloud
            ? tx("xxxx-xxxx-xxxx-xxxx", "xxxx-xxxx-xxxx-xxxx")
            : tx("xxxx xxxx xxxx xxxx", "xxxx xxxx xxxx xxxx")
        return accountFormRow(title, caption: caption) {
            VStack(alignment: .leading, spacing: 8) {
                SecureField(title, text: $password, prompt: Text(example))
                    .accessibilityHint(caption)
                    .disabled(connecting)
                Text(tx("\(name) generates this 16-letter code just for Cala.",
                        "\(name) genera este código de 16 letras solo para Cala."))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 11.5))
                        .foregroundStyle(StatusColor.color(.critical))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func connect() {
        guard canConnect else { return }
        let address = trimmedEmail
        let selectedProvider = provider
        let secret = password
        let customLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let accountLabel = customLabel.isEmpty ? defaultLabel : customLabel
        errorMessage = nil
        connecting = true
        password = ""
        Task {
            defer { connecting = false }
            do {
                try await service.addAccount(email: address, label: accountLabel, appPassword: secret, provider: selectedProvider)
                email = ""
                label = ""
                providerOverride = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Explains the macOS Keychain prompt before it can look like a scam (see MailKeychainNoticeController for the
/// same message after an update).
private struct MailKeychainNote: View {
    @State private var showsWhy = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(tx("Cala saves this app password in the macOS Keychain, your Mac’s password safe.",
                        "Cala guarda esta contraseña en el Llavero de macOS, la caja fuerte de contraseñas de tu Mac."))
                    .fontWeight(.medium)
                Text(tx("If you saved this account with an older Cala, macOS may show up to two windows for “cala-keychain” once. Type your Mac password if asked and click “Always Allow” in both (Enter only allows it this once).",
                        "Si guardaste esta cuenta con una Cala anterior, macOS puede mostrar una vez hasta dos ventanas para «cala-keychain». Escribe la contraseña de tu Mac si te la pide y haz clic en «Permitir siempre» en ambas (Intro solo lo permite esta vez)."))
                Text(tx("Only macOS receives it; Cala never sees it.",
                        "Solo macOS la recibe; Cala nunca la ve."))
                Button {
                    showsWhy.toggle()
                } label: {
                    Label(tx("Why?", "¿Por qué?"), systemImage: showsWhy ? "chevron.down" : "chevron.right")
                        .labelStyle(MailToolbarLabelStyle(iconOnly: false))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isButton)
                .accessibilityValue(showsWhy ? tx("Expanded", "Expandido") : tx("Collapsed", "Contraído"))
                if showsWhy {
                    Text(tx("Cala’s Keychain helper (“cala-keychain”) copies the password once into its own Keychain entry. After that macOS trusts it without asking, also after updates.",
                            "El ayudante de Llavero de Cala («cala-keychain») copia la contraseña una vez a su propia entrada del Llavero. Después macOS confía en él sin preguntar, también tras las actualizaciones."))
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 11.5))
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }
}

/// While an account's password is still only in its pre-helper Keychain item, macOS asks (up to two windows) before
/// the helper can read it and copy it into its own item. This small
/// window comes first, so those prompts are expected. It is not modal: the bar and everything else is already running,
/// and only mail sync waits for "Got it" (or for the window to be closed).
@MainActor
final class MailKeychainNoticeController: NSObject, NSWindowDelegate {
    static let shared = MailKeychainNoticeController()
    private var window: NSWindow?
    private var proceed: (@MainActor () -> Void)?

    func show(prompts: Int, proceed: @escaping @MainActor () -> Void) {
        guard window == nil else { proceed(); return }
        self.proceed = proceed
        let controller = NSHostingController(rootView: MailKeychainNoticeView(prompts: prompts) { [weak self] in
            self?.window?.close()
        })
        controller.sizingOptions = [.preferredContentSize]
        let w = NSWindow(contentViewController: controller)
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.title = tx("Cala and your Keychain", "Cala y tu Llavero")
        w.delegate = self
        window = w
        log("mail: explaining the Keychain prompts (\(prompts))")
        DispatchQueue.main.async { [weak self] in
            guard let w = self?.window else { return }
            NSApp.activate(ignoringOtherApps: true)
            w.center()
            w.makeKeyAndOrderFront(nil)
        }
    }

    /// Closing the window is the same as "Got it": sync proceeds through `windowWillClose`.
    func dismiss() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        let next = proceed
        proceed = nil
        window = nil
        next?()
    }
}

private struct MailKeychainNoticeView: View {
    let prompts: Int
    let dismiss: () -> Void

    private var howMany: String {
        prompts <= 2
            ? tx("macOS may show up to two windows.", "macOS puede mostrar hasta dos ventanas.")
            : tx("macOS may show up to \(prompts) windows, two per account.",
                 "macOS puede mostrar hasta \(prompts) ventanas, dos por cuenta.")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 30))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    Text(tx("macOS will ask for permission", "macOS te pedirá permiso"))
                        .font(.system(size: 15, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(tx("Cala’s Keychain helper, “cala-keychain”, copies your saved app passwords once into its own Keychain entries. Until then macOS asks before letting it read them. Later launches and updates won’t ask.",
                            "El ayudante de Llavero de Cala, «cala-keychain», copia una vez tus contraseñas de aplicación guardadas a sus propias entradas del Llavero. Hasta entonces macOS pregunta antes de dejarle leerlas. Los próximos arranques y actualizaciones no preguntarán."))
                    Text("\(howMany) " + tx("Type your Mac password if asked, then click “Always Allow” in both: pressing Enter chooses “Allow”, which only works this once.",
                                           "Escribe la contraseña de tu Mac si te la pide y haz clic en «Permitir siempre» en ambas: pulsar Intro elige «Permitir», que solo vale esta vez."))
                    Text(tx("Only macOS receives your Mac password. Cala never sees it.",
                            "Tu contraseña de Mac la recibe solo macOS. Cala nunca la ve."))
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 12.5))
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(tx("Got it", "Entendido"), action: dismiss)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

private struct MailProviderPicker: NSViewRepresentable {
    let title: String
    let selection: Binding<MailProvider>

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: MailProvider.allCases.map(\.pickerTitle), trackingMode: .selectOne,
                                         target: context.coordinator, action: #selector(Coordinator.selectProvider(_:)))
        control.segmentDistribution = .fillEqually
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selection = selection
        control.selectedSegment = MailProvider.allCases.firstIndex(of: selection.wrappedValue) ?? 0
        control.isEnabled = context.environment.isEnabled
        control.setAccessibilityLabel(title)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        let size = nsView.intrinsicContentSize
        return CGSize(width: proposal.width ?? size.width, height: size.height)
    }

    func makeCoordinator() -> Coordinator { Coordinator(selection: selection) }

    final class Coordinator: NSObject {
        var selection: Binding<MailProvider>

        init(selection: Binding<MailProvider>) { self.selection = selection }

        @objc func selectProvider(_ control: NSSegmentedControl) {
            let options = MailProvider.allCases
            guard options.indices.contains(control.selectedSegment) else { return }
            selection.wrappedValue = options[control.selectedSegment]
        }
    }
}

private struct MailAccountSettingsRow: View {
    let account: MailAccount
    @ObservedObject var service: MailService
    @State private var editing = false
    @State private var confirmingRemoval = false

    private var problem: String? { account.enabled ? mailProblem(service.status[account.id]) : nil }

    private var statusText: String {
        if let problem { return problem }
        if !account.enabled { return tx("Paused", "En pausa") }
        switch service.status[account.id] {
        case .connected:
            let count = service.unread(for: account.id)
            return tx("Connected · \(count) unread", "Conectado · \(count) sin leer")
        case .connecting: return tx("Connecting…", "Conectando…")
        case .paused: return tx("Paused", "En pausa")
        default: return tx("Waiting to connect", "Esperando conexión")
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(mailColor(account.colorIndex)).frame(width: 9, height: 9)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(account.label).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                let provider = account.provider.localizedName
                Text(tx("\(account.id) · \(provider)", "\(account.id) · \(provider)"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Text(statusText).font(.system(size: 11.5))
                    .foregroundStyle(problem != nil ? StatusColor.color(.critical) : Color.secondary)
                    .lineLimit(2).help(statusText)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 4)
            Button(tx("Edit", "Editar")) { editing = true }
                .buttonStyle(.bordered)
                .accessibilityLabel(tx("Edit \(account.label)", "Editar \(account.label)"))
                .popover(isPresented: $editing, arrowEdge: .trailing) {
                    MailAccountEditor(account: account) { label, color in
                        updateAccount { $0.label = label; $0.colorIndex = color }
                        editing = false
                    } cancel: {
                        editing = false
                    } remove: {
                        editing = false
                        confirmingRemoval = true
                    }
                }
            Toggle(tx("Enable \(account.label)", "Activar \(account.label)"), isOn: Binding(
                get: { account.enabled }, set: { value in updateAccount { $0.enabled = value } }
            ))
            .labelsHidden().toggleStyle(FlyoutSwitchStyle())
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .alert(tx("Remove account?", "¿Quitar la cuenta?"), isPresented: $confirmingRemoval) {
            Button(tx("Remove", "Quitar"), role: .destructive) { service.removeAccount(account.id) }
            Button(tx("Cancel", "Cancelar"), role: .cancel) {}
        } message: {
            Text(tx("Cala will disconnect \(account.id).", "Cala desconectará \(account.id)."))
        }
    }

    private func updateAccount(_ edit: (inout MailAccount) -> Void) {
        guard let current = service.accounts.first(where: { $0.id == account.id }) else { return }
        var updated = current
        edit(&updated)
        if updated != current { service.updateAccount(updated) }
    }
}

private struct MailAccountEditor: View {
    let account: MailAccount
    let save: (String, Int) -> Void
    let cancel: () -> Void
    let remove: () -> Void
    @State private var label: String
    @State private var color: Int

    init(account: MailAccount, save: @escaping (String, Int) -> Void,
         cancel: @escaping () -> Void, remove: @escaping () -> Void) {
        self.account = account
        self.save = save
        self.cancel = cancel
        self.remove = remove
        _label = State(initialValue: account.label)
        _color = State(initialValue: account.colorIndex)
    }

    var body: some View {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let labelTitle = tx("Account name", "Nombre de la cuenta")
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(tx("Edit account", "Editar cuenta")).font(.system(size: 15, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(account.id).font(.system(size: 12)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(labelTitle).font(.system(size: 12, weight: .medium))
                TextField(labelTitle, text: $label).labelsHidden()
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(tx("Color", "Color")).font(.system(size: 12, weight: .medium))
                swatches
            }
            Divider()
            HStack(spacing: 8) {
                Button(tx("Remove…", "Quitar…"), role: .destructive, action: remove)
                    .buttonStyle(.borderless).foregroundStyle(.red)
                Spacer()
                Button(tx("Cancel", "Cancelar"), role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button(tx("Save", "Guardar")) { save(trimmedLabel, color) }
                    .buttonStyle(.borderedProminent)
                    .flyoutControls()
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedLabel.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 294)
    }

    private var swatches: some View {
        let names = [
            tx("Blue", "Azul"), tx("Purple", "Morado"), tx("Pink", "Rosa"),
            tx("Orange", "Naranja"), tx("Green", "Verde"), tx("Teal", "Turquesa")
        ]
        return HStack(spacing: 8) {
            ForEach(mailColors.indices, id: \.self) { index in
                let selected = color == index
                Button { color = index } label: {
                    Circle().fill(mailColors[index]).frame(width: 17, height: 17)
                        .padding(4)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(selected ? 0.7 : 0), lineWidth: 1.5))
                }
                .buttonStyle(MailHoverStyle(radius: 13))
                .help(names[index])
                .accessibilityLabel(names[index])
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

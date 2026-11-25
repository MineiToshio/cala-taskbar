import SwiftUI
import AppKit

extension CalendarTint {
    var color: Color { Color(red: red, green: green, blue: blue) }
}

struct CalendarPermissionView: View {
    @ObservedObject var agenda: CalendarService
    var inSettings = false
    var allow: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(agenda.permission.message, systemImage: agenda.permission == .granted ? "calendar.badge.checkmark" : "calendar.badge.exclamationmark")
                .font(.system(size: 11.5)).flyoutSecondary().fixedSize(horizontal: false, vertical: true)
            if let error = agenda.error { Text(error).font(.system(size: 11)).flyoutSecondary().fixedSize(horizontal: false, vertical: true) }
            if agenda.permission == .notRequested || (inSettings && agenda.permission == .writeOnly) {
                let title = agenda.permission == .writeOnly
                    ? tx("Allow full access", "Permitir acceso completo")
                    : tx("Allow calendar access", "Permitir acceso al calendario")
                permissionButton(title, action: allow)
            } else if agenda.permission != .requesting && agenda.permission != .granted {
                permissionButton(tx("Open Privacy Settings", "Abrir ajustes de privacidad"), action: CalendarNavigation.privacy)
            }
        }
    }

    @ViewBuilder private func permissionButton(_ title: String, action: @escaping () -> Void) -> some View {
        if inSettings {
            Button(title, action: action).buttonStyle(.borderedProminent)
        } else {
            Button(title, action: action).font(.system(size: 11))
        }
    }
}

struct UpcomingEventsView: View {
    @ObservedObject var agenda: CalendarService
    var days: Int
    var maxHeight: CGFloat = 240
    var allow: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(calendarText("Upcoming", "Próximos eventos")).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(calendarText("Next \(days) \(days == 1 ? "day" : "days")", days == 1 ? "Próximo día" : "Próximos \(days) días")).font(.system(size: 10)).flyoutSecondary()
            }
            if agenda.permission != .granted {
                CalendarPermissionView(agenda: agenda, allow: allow)
            } else {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    let end = Calendar.current.date(byAdding: .day, value: days, to: context.date)!
                    let events = CalendarLogic.visible(agenda.events, now: context.date, until: end)
                    let groups = CalendarLogic.groups(events, now: context.date)
                    if events.isEmpty {
                        Text(agenda.loading ? calendarText("Loading events…", "Cargando eventos…") : calendarText("No upcoming events", "No hay próximos eventos"))
                            .font(.system(size: 12)).flyoutSecondary().padding(.vertical, 12)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 6) {
                                ForEach(groups, id: \.day) { group in
                                    Text(dayTitle(group.day, now: context.date)).font(.system(size: 10, weight: .semibold))
                                        .flyoutSecondary().padding(.top, 4)
                                    ForEach(group.events) { event in
                                        CalendarEventRow(event: event, now: context.date,
                                                         next: event.id == CalendarLogic.nextID(events, now: context.date))
                                    }
                                }
                            }.padding(.trailing, 2)
                        }
                        .frame(height: min(maxHeight, CGFloat(events.count * 68 + groups.count * 24)))
                    }
                }
            }
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in agenda.refresh() }
    }
    private func dayTitle(_ day: Date, now: Date) -> String {
        let calendar = Calendar.current
        let today = calendar.isDate(day, inSameDayAs: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now).map { calendar.isDate(day, inSameDayAs: $0) } ?? false
        let formatter = DateFormatter()
        formatter.locale = .current; formatter.timeZone = .current
        if today || tomorrow {
            // Relative formatter words are suitable only when the current locale matches our UI language.
            if Locale.current.language.languageCode?.identifier == calendarText("en", "es") {
                formatter.dateStyle = .medium; formatter.doesRelativeDateFormatting = true
                return formatter.string(from: day).localizedCapitalized
            }
            return today ? calendarText("Today", "Hoy") : calendarText("Tomorrow", "Mañana")
        }
        formatter.setLocalizedDateFormatFromTemplate("EEEE MMM d")
        return formatter.string(from: day)
    }
}

struct CalendarEventRow: View {
    @Environment(\.themeAccent) private var accent
    let event: UpcomingEvent
    let now: Date
    let next: Bool
    private var ongoing: Bool { event.ongoing(at: now) }
    var body: some View {
        HStack(spacing: 8) {
            Button { CalendarNavigation.open(event) } label: {
                HStack(alignment: .top, spacing: 8) {
                    Circle().fill(event.tint.color).frame(width: 7, height: 7).padding(.top, 4)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(event.title).font(.system(size: 12, weight: ongoing ? .semibold : .medium)).lineLimit(1)
                            if ongoing || next {
                                Text(ongoing ? calendarText("Now", "Ahora") : calendarText("Next", "Siguiente")).font(.system(size: 9, weight: .semibold))
                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                    .background(Capsule().fill(accent.opacity(0.15))).fixedSize()
                            }
                        }
                        Text(timeRange).font(.system(size: 10.5)).flyoutSecondary().lineLimit(1)
                        if !event.location.isEmpty {
                            Text(shortLocation).font(.system(size: 10)).flyoutSecondary().lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(calendarText("Open in Calendar", "Abrir en Calendario"))
            if let url = event.joinURL {
                Button(calendarText("Join", "Unirse")) { NSWorkspace.shared.open(url) }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(accent.opacity(0.14)))
                    .help(calendarText("Join meeting at ", "Unirse a la reunión en ") + (url.host ?? calendarText("video link", "enlace de vídeo")))
            }
        }
        .padding(10)
        .flyoutSection()
        .overlay(alignment: .leading) {
            if ongoing || next { Capsule().fill(accent.opacity(ongoing ? 1 : 0.5)).frame(width: 3).padding(.vertical, 8) }
        }
    }
    private var shortLocation: String {
        if event.location.trimmingCharacters(in: .whitespaces).hasPrefix("http"), CalendarLogic.videoURL([event.location]) != nil { return calendarText("Online meeting", "Reunión en línea") }
        return event.location.components(separatedBy: .newlines).first ?? event.location
    }
    private var timeRange: String {
        if event.allDay { return calendarText("All day", "Todo el día") }
        let formatter = DateIntervalFormatter()
        formatter.locale = .current; formatter.timeZone = .current
        formatter.dateStyle = Calendar.current.isDate(event.start, inSameDayAs: event.end) ? .none : .short
        formatter.timeStyle = .short
        return formatter.string(from: event.start, to: event.end)
    }
}

struct CalendarSettingsPane: View {
    @ObservedObject var store: ConfigStore
    @StateObject private var agenda = CalendarService(catalogOnly: true)
    @Environment(\.settingsSnapshot) private var snapshot
    private var sources: [(id: String, title: String, choices: [CalendarChoice])] {
        Dictionary(grouping: agenda.calendars, by: \.sourceID).map { id, choices in
            (id, choices.first?.sourceTitle ?? tx("Calendars", "Calendarios"), choices)
        }.sorted { ($0.title, $0.id) < ($1.title, $1.id) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Card {
                SettingRow(title: tx("Show upcoming events", "Mostrar próximos eventos"), caption: tx("Read events from the accounts configured on this Mac.", "Lee los eventos de las cuentas configuradas en este Mac.")) {
                    Toggle(tx("Show upcoming events", "Mostrar próximos eventos"), isOn: $store.config.calendarEnabled).labelsHidden().toggleStyle(FlyoutSwitchStyle())
                }
                if store.config.calendarEnabled && agenda.permission != .granted {
                    RowDivider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text(tx("Allow access to see your events", "Permite el acceso para ver tus eventos"))
                            .font(.system(size: 13, weight: .medium))
                        CalendarPermissionView(agenda: agenda, inSettings: true) { agenda.open(config: store.config) }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                RowDivider()
                SettingRow(title: tx("Join button", "Botón Unirse"), caption: tx("Show a Join button in the bar for meetings with a Meet, Zoom, Teams or Webex link, from 5 minutes before they start.", "Muestra un botón Unirse en la barra para las reuniones con enlace de Meet, Zoom, Teams o Webex, desde 5 minutos antes de que empiecen.")) {
                    Toggle(tx("Join button", "Botón Unirse"), isOn: $store.config.calendarJoinEnabled).labelsHidden().toggleStyle(FlyoutSwitchStyle()).disabled(!store.config.calendarEnabled)
                }
                RowDivider()
                SettingRow(title: tx("Upcoming range", "Rango de próximos eventos"), caption: tx("Ongoing events are included.", "Se incluyen los eventos en curso.")) {
                    Picker(tx("Upcoming range", "Rango de próximos eventos"), selection: $store.config.calendarDays) {
                        ForEach([1, 3, 7, 14], id: \.self) { Text("\($0) " + ($0 == 1 ? tx("day", "día") : tx("days", "días"))).tag($0) }
                    }.labelsHidden().frame(width: 125).disabled(!store.config.calendarEnabled)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Button(tx("Add account… (Google, iCloud, Exchange)", "Añadir cuenta… (Google, iCloud, Exchange)"), action: CalendarNavigation.addAccount)
                Text(tx("Add your Google accounts there and enable Calendars; they appear here automatically.", "Añade ahí tus cuentas de Google y activa Calendarios; aparecerán aquí automáticamente."))
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(.horizontal, 4)
            if store.config.calendarEnabled && agenda.permission == .granted {
                if agenda.loading && sources.isEmpty {
                    ProgressView(tx("Loading calendars…", "Cargando calendarios…")).controlSize(.small)
                } else if sources.isEmpty {
                    Text(tx("No calendars found. Add an account or enable Calendars in Internet Accounts.", "No se encontraron calendarios. Añade una cuenta o activa Calendarios en Cuentas de Internet."))
                        .font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 4)
                }
                ForEach(sources, id: \.id) { source in
                    Card {
                        Text(source.title).font(.system(size: 12, weight: .semibold))
                            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                        ForEach(source.choices) { calendar in
                            RowDivider()
                            Toggle(isOn: included(calendar.id)) {
                                HStack(spacing: 8) {
                                    Circle().fill(calendar.tint.color).frame(width: 8, height: 8)
                                    Text(calendar.title).font(.system(size: 13)).lineLimit(1)
                                }
                            }
                            .toggleStyle(.checkbox).padding(.horizontal, 16).padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
        .onAppear {
            guard snapshot == nil else { return }
            agenda.start()
            agenda.refreshWithoutRequest(config: store.config)
        }
        .onDisappear { if snapshot == nil { agenda.stop() } }
        .onChange(of: store.config.calendarEnabled) { _, _ in
            agenda.refreshWithoutRequest(config: store.config)
            refreshActiveEvents()
        }
        .onChange(of: store.config.calendarDays) { _, _ in refreshActiveEvents() }
        .onChange(of: store.config.calendarExcludedIDs) { _, _ in refreshActiveEvents() }
        .onChange(of: agenda.permission) { old, permission in
            if permission == .granted && old != .notRequested { refreshActiveEvents() }
        }
    }

    private func refreshActiveEvents() {
        CalendarService.shared.refreshWithoutRequest(config: store.config)
    }

    private func included(_ id: String) -> Binding<Bool> {
        Binding(get: { !store.config.calendarExcludedIDs.contains(id) }, set: { included in
            if included { store.config.calendarExcludedIDs.removeAll { $0 == id } }
            else if !store.config.calendarExcludedIDs.contains(id) { store.config.calendarExcludedIDs.append(id) }
        })
    }
}

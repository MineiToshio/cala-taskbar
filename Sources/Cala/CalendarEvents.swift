import AppKit
import Combine
import EventKit

struct CalendarTint {
    var red: Double, green: Double, blue: Double
    static let blue = CalendarTint(red: 0.04, green: 0.52, blue: 1)
    init(red: Double, green: Double, blue: Double) { self.red = red; self.green = green; self.blue = blue }
    init(_ color: CGColor?) {
        guard let color, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let components = color.converted(to: space, intent: .defaultIntent, options: nil)?.components,
              components.count >= 3 else { self = .blue; return }
        self.init(red: Double(components[0]), green: Double(components[1]), blue: Double(components[2]))
    }
}

struct CalendarChoice: Identifiable {
    var id: String, title: String, sourceID: String, sourceTitle: String
    var tint: CalendarTint
}

struct UpcomingEvent: Identifiable {
    var id: String, eventIdentifier: String, title: String
    var start: Date, end: Date
    var allDay = false
    var location: String = ""
    var tint: CalendarTint = .blue
    var joinURL: URL?
    func ongoing(at now: Date) -> Bool { !allDay && start <= now && end > now }
}

enum CalendarPermission: Equatable {
    case notRequested, requesting, granted, denied, restricted, writeOnly
    var message: String {
        switch self {
        case .notRequested: return calendarText("Calendar access has not been requested.", "Aún no se ha solicitado acceso al calendario.")
        case .requesting: return calendarText("Waiting for calendar permission…", "Esperando permiso para acceder al calendario…")
        case .granted: return calendarText("Full calendar access allowed. Events stay on this Mac.", "Acceso completo al calendario permitido. Los eventos permanecen en este Mac.")
        case .denied: return calendarText("Calendar access is denied. Allow full access in Privacy & Security.", "Acceso al calendario denegado. Permite el acceso completo en Privacidad y seguridad.")
        case .restricted: return calendarText("Calendar access is restricted by this Mac’s policy.", "La política de este Mac restringe el acceso al calendario.")
        case .writeOnly: return calendarText("Full calendar access is needed to read upcoming events.", "Se necesita acceso completo al calendario para leer los próximos eventos.")
        }
    }
    static func from(_ status: EKAuthorizationStatus) -> CalendarPermission {
        switch status {
        case .fullAccess: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        case .writeOnly: return .writeOnly
        case .notDetermined: return .notRequested
        @unknown default: return .restricted
        }
    }
}

enum CalendarLogic {
    static func videoURL(_ fields: [String?]) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        for field in fields {
            guard let field else { continue }
            let text = String(field.prefix(20_000))
            let urls = detector?.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap(\.url) ?? []
            for url in urls {
                guard let host = url.host?.lowercased(), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { continue }
                if host == "meet.google.com" || host == "zoom.us" || host.hasSuffix(".zoom.us") || host == "teams.microsoft.com" || host == "teams.live.com" ||
                    host == "zoomgov.com" || host.hasSuffix(".zoomgov.com") || host.hasSuffix(".webex.com") {
                    return url
                }
            }
        }
        return nil
    }
    static func visible(_ events: [UpcomingEvent], now: Date, until end: Date) -> [UpcomingEvent] {
        events.filter { $0.end > now && $0.start < end }.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.id < $1.id
        }
    }
    static func groups(_ events: [UpcomingEvent], now: Date, calendar: Calendar = .current) -> [(day: Date, events: [UpcomingEvent])] {
        let today = calendar.startOfDay(for: now)
        let grouped = Dictionary(grouping: events) { max(today, calendar.startOfDay(for: $0.start)) }
        return grouped.keys.sorted().map { ($0, grouped[$0]!) }
    }
    /// The meeting to offer a "Join" button for: has a video link and is within `lead` seconds of starting, or is
    /// still running. If several qualify, the one whose start is closest to now.
    static func joinCandidate(_ events: [UpcomingEvent], now: Date, lead: TimeInterval = 300) -> UpcomingEvent? {
        events.filter { !$0.allDay && $0.joinURL != nil && $0.start.addingTimeInterval(-lead) <= now && $0.end > now }
            .min { abs($0.start.timeIntervalSince(now)) < abs($1.start.timeIntervalSince(now)) }
    }
    static func nextID(_ events: [UpcomingEvent], now: Date) -> String? {
        events.first { !$0.allDay && $0.start > now }?.id
    }
}

/// No EventKit store or access request is created at launch. Fetches and resets stay on one background queue.
final class CalendarService: ObservableObject {
    static let shared = CalendarService()
    @Published private(set) var permission: CalendarPermission = .notRequested
    @Published private(set) var calendars: [CalendarChoice] = []
    @Published private(set) var events: [UpcomingEvent] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?

    private let queue = DispatchQueue(label: "local.cala.calendar", qos: .utility)
    private var eventStore: EKEventStore? // queue only
    private var requestError: String? // queue only
    private let makeStore: () -> EKEventStore
    private var requesting = false      // queue only
    private var revision = 0            // main only
    private var config: Config?         // main only
    private var observers: [NSObjectProtocol] = []
    private var runID: UUID? // main only
    private let preview: Bool

    init(preview: Bool = false, permission: CalendarPermission = .notRequested,
         calendars: [CalendarChoice] = [], events: [UpcomingEvent] = [], makeStore: @escaping () -> EKEventStore = { EKEventStore() }) {
        self.makeStore = makeStore
        self.preview = preview; self.permission = permission; self.calendars = calendars; self.events = events
    }

    func start() {
        guard !preview, runID == nil else { return }
        let run = UUID()
        runID = run
        for name in [Notification.Name.EKEventStoreChanged, NSApplication.didBecomeActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self, self.runID == run else { return }
                self.refresh()
            })
        }
    }
    func stop() {
        runID = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        revision += 1
        config = nil
        permission = .notRequested
        events = []; calendars = []; loading = false; error = nil
        queue.async {
            self.eventStore = nil
            self.requesting = false
            self.requestError = nil
        }
    }

    /// Called only from the calendar flyout or its Settings section, including enabling it there.
    func open(config: Config) { load(config: config, mayRequest: true) }
    /// Keeps events fresh for the bar's Join button without opening the flyout. It only reads when full access
    /// was already granted, so it never shows a permission prompt.
    func backgroundRefresh(config: Config) {
        guard config.calendarEnabled, config.calendarJoinEnabled,
              EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return }
        load(config: config, mayRequest: false)
    }
    func refresh() {
        guard let config else { return }
        load(config: config, mayRequest: false)
    }
    private func load(config: Config, mayRequest: Bool) {
        precondition(Thread.isMainThread)
        guard let runID else { return }
        self.config = config; revision += 1
        let token = revision
        guard config.calendarEnabled else { events = []; calendars = []; loading = false; error = nil; return }
        let initialPermission = CalendarPermission.from(EKEventStore.authorizationStatus(for: .event))
        if permission != .requesting || initialPermission != .notRequested { permission = initialPermission }
        if initialPermission != .granted { calendars = []; events = [] }
        loading = true
        queue.async { [weak self] in
            guard let self else { return }
            let store = self.eventStore ?? self.makeStore()
            self.eventStore = store
            let status = EKEventStore.authorizationStatus(for: .event)
            if (status == .notDetermined || status == .writeOnly) && mayRequest && !self.requesting {
                self.requesting = true; self.requestError = nil
                self.publish(.requesting, token: token)
                DispatchQueue.main.async {
                    // Admission is checked on main immediately before the system prompt.
                    guard self.runID == runID, self.config?.calendarEnabled == true else {
                        self.queue.async { if self.eventStore === store { self.requesting = false } }
                        return
                    }
                    store.requestFullAccessToEvents { [weak self] granted, failure in
                        guard let self else { return }
                        self.queue.async {
                            guard self.eventStore === store else { return }
                            if granted { store.reset() }
                            self.requesting = false; self.requestError = failure?.localizedDescription
                            DispatchQueue.main.async { if self.runID == runID { self.refresh() } }
                        }
                    }
                }
                return
            }
            guard status == .fullAccess else {
                let permission: CalendarPermission = self.requesting ? .requesting :
                    CalendarPermission.from(status)
                self.publish(permission, failure: self.requestError, token: token)
                return
            }
            let calendars = store.calendars(for: .event)
            let choices = calendars.map { CalendarChoice(id: $0.calendarIdentifier, title: $0.title,
                sourceID: $0.source?.sourceIdentifier ?? "local", sourceTitle: $0.source?.title ?? calendarText("On My Mac", "En mi Mac"), tint: CalendarTint($0.cgColor)) }
                .sorted { ($0.sourceTitle, $0.title, $0.id) < ($1.sourceTitle, $1.title, $1.id) }
            let selected = calendars.filter { !config.calendarExcludedIDs.contains($0.calendarIdentifier) }
            let now = Date(), end = Calendar.current.date(byAdding: .day, value: config.calendarDays, to: Date())!
            var snapshots: [UpcomingEvent] = []
            if !selected.isEmpty {
                let predicate = store.predicateForEvents(withStart: Calendar.current.startOfDay(for: now), end: end, calendars: selected)
                snapshots = store.events(matching: predicate).filter { $0.status != .canceled }.compactMap { event -> UpcomingEvent? in
                    guard let start = event.startDate, let end = event.endDate, let calendar = event.calendar, end > start else { return nil }
                    let identifier = event.eventIdentifier ?? event.calendarItemIdentifier
                    return UpcomingEvent(id: calendar.calendarIdentifier + ":" + identifier + ":" + String(start.timeIntervalSince1970),
                        eventIdentifier: identifier, title: event.title?.isEmpty == false ? event.title! : calendarText("Untitled event", "Evento sin título"),
                        start: start, end: end, allDay: event.isAllDay,
                        location: event.location ?? "", tint: CalendarTint(calendar.cgColor),
                        joinURL: CalendarLogic.videoURL([event.url?.absoluteString, event.location, event.notes]))
                }
            }
            self.publish(.granted, calendars: choices, events: CalendarLogic.visible(snapshots, now: now, until: end), token: token)
        }
    }
    private func publish(_ permission: CalendarPermission, calendars: [CalendarChoice] = [], events: [UpcomingEvent] = [], failure: String? = nil, token: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self, token == self.revision else { return }
            self.permission = permission; self.calendars = calendars; self.events = events
            self.loading = permission == .requesting; self.error = failure
        }
    }
}

enum CalendarNavigation {
    static func privacy() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
    }
    static func addAccount() {
        for address in ["x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension", "x-apple.systempreferences:com.apple.preferences.internetaccounts"] {
            if NSWorkspace.shared.open(URL(string: address)!) { return }
        }
        let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences") ?? URL(fileURLWithPath: "/System/Applications/System Settings.app")
        NSWorkspace.shared.open(app)
    }
    static func open(_ event: UpcomingEvent) {
        // Calendar's event URL is undocumented: best effort, with a plain app fallback.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        if let identifier = event.eventIdentifier.addingPercentEncoding(withAllowedCharacters: allowed),
           let url = URL(string: "ical://ekevent/" + identifier + "?method=show&options=more"),
           NSWorkspace.shared.urlForApplication(toOpen: url) != nil, NSWorkspace.shared.open(url) { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app"))
    }
}

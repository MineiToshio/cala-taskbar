import AppKit
import SwiftUI
import ApplicationServices
import CoreGraphics
import CoreLocation
import CoreBluetooth
import EventKit
import UserNotifications

/// Every macOS permission Cala can use, in one place: what it is for, how to ask, how to check it and which
/// System Settings pane turns it on. The app keeps working without any of them; each feature degrades on its own.
enum PermissionKind: String, CaseIterable, Identifiable {
    case accessibility, screenRecording, calendar, location, bluetooth, automation, notifications
    var id: String { rawValue }

    var title: String {
        switch self {
        case .accessibility: tx("Accessibility", "Accesibilidad")
        case .screenRecording: tx("Screen Recording", "Grabación de pantalla")
        case .calendar: tx("Calendar", "Calendario")
        case .location: tx("Location", "Ubicación")
        case .bluetooth: "Bluetooth"
        case .automation: tx("Control Finder", "Controlar Finder")
        case .notifications: tx("Notifications", "Notificaciones")
        }
    }

    /// One sentence: what the user gets by allowing it.
    var why: String {
        switch self {
        case .accessibility: tx("Lists the windows of your apps so the bar can show, focus, minimize and close them, and powers Option+Tab.",
                                "Ve las ventanas de tus apps para que la barra pueda mostrarlas, enfocarlas, minimizarlas y cerrarlas, y para Opción+Tab.")
        case .screenRecording: tx("Draws the window thumbnails when you hover over an app. Cala never records or sends your screen.",
                                  "Dibuja las miniaturas de las ventanas al pasar el mouse por una app. Cala nunca graba ni envía tu pantalla.")
        case .calendar: tx("Shows your next events in the clock panel and a Join button before video calls. Events stay on this Mac.",
                           "Muestra tus próximos eventos en el panel del reloj y un botón Unirse antes de las videollamadas. Los eventos no salen de este Mac.")
        case .location: tx("macOS only reveals Wi-Fi network names to apps with Location. Cala does not read where you are.",
                           "macOS solo deja ver los nombres de las redes Wi-Fi a las apps con Ubicación. Cala no lee dónde estás.")
        case .bluetooth: tx("Lists and connects your paired Bluetooth devices from the tray.",
                            "Lista y conecta tus dispositivos Bluetooth vinculados desde la bandeja.")
        case .automation: tx("Counts and empties the Trash and restarts the Mac when you ask, through Finder.",
                             "Cuenta y vacía la Papelera y reinicia el Mac cuando lo pides, a través de Finder.")
        case .notifications: tx("Warns you when a Claude or Codex quota is about to run out.",
                                "Te avisa cuando una cuota de Claude o Codex está por agotarse.")
        }
    }

    var symbol: String {
        switch self {
        case .accessibility: "hand.raised.fill"
        case .screenRecording: "rectangle.dashed.badge.record"
        case .calendar: "calendar"
        case .location: "location.fill"
        case .bluetooth: "dot.radiowaves.left.and.right"
        case .automation: "gearshape.2.fill"
        case .notifications: "bell.badge.fill"
        }
    }

    /// Exact System Settings pane for this permission.
    var settingsURL: URL {
        let base = "x-apple.systempreferences:com.apple.preference.security?"
        switch self {
        case .accessibility: return URL(string: base + "Privacy_Accessibility")!
        case .screenRecording: return URL(string: base + "Privacy_ScreenCapture")!
        case .calendar: return URL(string: base + "Privacy_Calendars")!
        case .location: return URL(string: base + "Privacy_LocationServices")!
        case .bluetooth: return URL(string: base + "Privacy_Bluetooth")!
        case .automation: return URL(string: base + "Privacy_Automation")!
        case .notifications:
            let id = Bundle.main.bundleIdentifier ?? ""
            return URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=" + id)!
        }
    }

    /// Permissions whose switch lives in a System Settings list (the user flips it there; macOS shows no dialog after the first time).
    var grantedInSettings: Bool { self == .accessibility || self == .screenRecording }
}

enum PermissionState: Equatable {
    case granted, denied, notAsked
    /// Asked in this run, macOS has not answered yet (the user is looking at the dialog or at System Settings).
    case waiting
}

/// Live permission status. It polls once a second only while some window shows permissions, so the UI turns green
/// the moment the user flips a switch in System Settings, with no relaunch.
final class PermissionCenter: NSObject, ObservableObject, CLLocationManagerDelegate, CBCentralManagerDelegate {
    static let shared = PermissionCenter()

    @Published private(set) var states: [PermissionKind: PermissionState] = [:]
    private var watchers = 0
    private var timer: Timer?
    private var asked = Set<PermissionKind>()
    private var automationState: PermissionState = .notAsked
    private var notificationState: PermissionState = .notAsked
    private var bluetoothManager: CBCentralManager?
    private let location = CLLocationManager()
    private let eventStore = EKEventStore()

    override init() {
        super.init()
        location.delegate = self
        refresh()
    }

    func state(_ kind: PermissionKind) -> PermissionState { states[kind] ?? .notAsked }
    func granted(_ kind: PermissionKind) -> Bool { state(kind) == .granted }

    func beginWatching() {
        watchers += 1
        refresh()
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func endWatching() {
        watchers = max(0, watchers - 1)
        if watchers == 0 { timer?.invalidate(); timer = nil }
    }

    func refresh() {
        var s: [PermissionKind: PermissionState] = [:]
        s[.accessibility] = AXIsProcessTrusted() ? .granted : (asked.contains(.accessibility) ? .waiting : .notAsked)
        s[.screenRecording] = CGPreflightScreenCaptureAccess() ? .granted : (asked.contains(.screenRecording) ? .waiting : .notAsked)
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: s[.calendar] = .granted
        case .denied, .restricted: s[.calendar] = .denied
        case .writeOnly: s[.calendar] = .denied
        default: s[.calendar] = asked.contains(.calendar) ? .waiting : .notAsked
        }
        switch location.authorizationStatus {
        case .authorizedAlways: s[.location] = .granted
        case .denied, .restricted: s[.location] = .denied
        default: s[.location] = asked.contains(.location) ? .waiting : .notAsked
        }
        switch CBManager.authorization {
        case .allowedAlways: s[.bluetooth] = .granted
        case .denied, .restricted: s[.bluetooth] = .denied
        default: s[.bluetooth] = asked.contains(.bluetooth) ? .waiting : .notAsked
        }
        s[.automation] = automationState
        s[.notifications] = notificationState
        if s != states { states = s }
        refreshAutomation()
        refreshNotifications()
    }

    // MARK: Asking

    /// Shows the macOS prompt when there is one; otherwise (or when it was already refused) opens the exact pane.
    func request(_ kind: PermissionKind) {
        asked.insert(kind)
        log("permissions: request \(kind.rawValue) state=\(state(kind))")
        if state(kind) == .denied { openSettings(kind); return }
        switch kind {
        case .accessibility:
            // Adds Cala to the list (unchecked) and shows macOS's own "Open System Settings" dialog.
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            if !AXIsProcessTrustedWithOptions(opts) { openSettings(kind) }
        case .screenRecording:
            // The first call shows macOS's dialog and adds Cala to the list; later calls do nothing, so open the pane.
            if !CGRequestScreenCaptureAccess() { openSettings(kind) }
        case .calendar:
            eventStore.requestFullAccessToEvents { [weak self] _, _ in DispatchQueue.main.async { self?.refresh() } }
        case .location:
            location.requestWhenInUseAuthorization()
            // macOS ignores the request for apps it already answered for; send them to the pane instead.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                if self?.state(.location) == .waiting { self?.openSettings(.location) }
            }
        case .bluetooth:
            if bluetoothManager == nil { bluetoothManager = CBCentralManager(delegate: self, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey: false]) }
            else { openSettings(kind) }
        case .automation:
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let status = Self.automation(ask: true)
                DispatchQueue.main.async {
                    self?.automationState = status
                    self?.refresh()
                    if status == .denied { self?.openSettings(.automation) }
                }
            }
        case .notifications:
            guard Bundle.main.bundleURL.pathExtension == "app" else { return }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.refresh() }
            }
        }
        refresh()
    }

    func openSettings(_ kind: PermissionKind) {
        NSWorkspace.shared.open(kind.settingsURL)
    }

    // MARK: Async checks

    private var automationChecking = false
    private func refreshAutomation() {
        guard !automationChecking else { return }
        automationChecking = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let status = Self.automation(ask: false)
            DispatchQueue.main.async {
                guard let self else { return }
                self.automationChecking = false
                if status != self.automationState { self.automationState = status; self.states[.automation] = status }
            }
        }
    }

    /// Finder is always running, so this never launches anything. Blocks while macOS shows its dialog when `ask` is true.
    private static func automation(ask: Bool) -> PermissionState {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
        guard let desc = target.aeDesc else { return .notAsked }
        let status = AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, ask)
        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        default: return .notAsked     // errAEEventWouldRequireUserConsent, or Finder not running
        }
    }

    private func refreshNotifications() {
        // UNUserNotificationCenter aborts outside an .app bundle (swift run, checks).
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let s: PermissionState
            switch settings.authorizationStatus {
            case .authorized, .provisional: s = .granted
            case .denied: s = .denied
            default: s = .notAsked
            }
            DispatchQueue.main.async {
                guard let self else { return }
                if s != self.notificationState { self.notificationState = s; self.states[.notifications] = s }
            }
        }
    }

    // MARK: Delegates

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { refresh() }
    func centralManagerDidUpdateState(_ central: CBCentralManager) { refresh() }
}

// MARK: - UI

/// One permission as a settings row: colored glyph, name, why, and a single clear action that matches its state.
struct PermissionCard: View {
    let kind: PermissionKind
    @ObservedObject var center = PermissionCenter.shared

    var body: some View {
        let state = center.state(kind)
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: kind.symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(state == .granted ? Color.green.gradient : StatusColor.color(.attention).gradient))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title).font(.system(size: 13, weight: .medium))
                Text(kind.why).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if state == .waiting && kind.grantedInSettings {
                    Text(tx("Not on yet. Turn on Cala in System Settings → Privacy & Security → \(kind.title); Cala notices by itself.", "Aún no está activo. Activa Cala en Ajustes del Sistema → Privacidad y seguridad → \(kind.title); Cala lo nota sola."))
                        .font(.system(size: 11)).foregroundStyle(StatusColor.color(.attention)).fixedSize(horizontal: false, vertical: true)
                } else if state == .denied {
                    Text(tx("Turned off. You can turn it on in System Settings.", "Desactivado. Puedes activarlo en Ajustes del Sistema."))
                        .font(.system(size: 11)).foregroundStyle(StatusColor.color(.attention)).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control(state)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func control(_ state: PermissionState) -> some View {
        switch state {
        case .granted:
            Label(tx("Allowed", "Permitido"), systemImage: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.green)
        case .denied, .waiting:
            Button(tx("Open Settings", "Abrir Ajustes")) { center.openSettings(kind) }.controlSize(.small)
        case .notAsked:
            Button(tx("Allow…", "Permitir…")) { center.request(kind) }.controlSize(.small).buttonStyle(.borderedProminent)
        }
    }
}

/// Compact note for a flyout whose content needs a permission that is missing.
struct PermissionHint: View {
    let kind: PermissionKind
    let text: String
    @ObservedObject var center = PermissionCenter.shared

    var body: some View {
        if !center.granted(kind) {
            VStack(alignment: .leading, spacing: 6) {
                Label(text, systemImage: "lock.fill").font(.system(size: 11.5)).flyoutSecondary()
                    .fixedSize(horizontal: false, vertical: true)
                Button(center.state(kind) == .notAsked ? tx("Allow…", "Permitir…") : tx("Open Settings", "Abrir Ajustes")) {
                    center.request(kind)
                }.font(.system(size: 11)).controlSize(.small)
            }
            .padding(.vertical, 4)
            .onAppear { center.refresh() }
        }
    }
}

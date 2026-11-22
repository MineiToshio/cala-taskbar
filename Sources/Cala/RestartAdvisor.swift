import SwiftUI
import AppKit
import Darwin

// MARK: - Advisor (state and system data)

final class RestartAdvisor: ObservableObject {
    static let shared = RestartAdvisor()
    @Published private(set) var advice = RestartAdvice()
    @Published private(set) var uptime: TimeInterval = 0
    @Published private(set) var snoozedUntil: Date?
    private var pendingCache: (date: Date, name: String?)?
    private let snoozeKey = "restartSnoozeUntil"

    init() {
        let t = UserDefaults.standard.double(forKey: snoozeKey)
        snoozedUntil = t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    /// Shown only when at least one reason applies and the user has not postponed it (a critical memory pressure
    /// overrides the postponement).
    var visible: Bool {
        guard ConfigStore.shared.config.restartAdvice, !advice.reasons.isEmpty else { return false }
        if let until = snoozedUntil, until > Date(), SystemMonitor.shared.pressure != .critical { return false }
        return true
    }
    var strongVisible: Bool { visible && advice.strong }

    static func bootDate() -> Date {
        var tv = timeval(), size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 else { return Date() }
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec))
    }

    /// A macOS update that is waiting and requires a restart, read from the system's own record (no network, no scan).
    static func pendingUpdate() -> String? {
        guard let plist = NSDictionary(contentsOfFile: "/Library/Preferences/com.apple.SoftwareUpdate.plist"),
              let list = plist["RecommendedUpdates"] as? [[String: Any]] else { return nil }
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let current = "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        for update in list {
            let restart = (update["MobileSoftwareUpdate"] as? Bool) ?? ((update["MobileSoftwareUpdate"] as? Int) == 1)
            guard restart, let version = update["Display Version"] as? String,
                  version.compare(current, options: .numeric) == .orderedDescending else { continue }
            let name = (update["Display Name"] as? String ?? "macOS \(version)")
                .replacingOccurrences(of: "\u{00a0}", with: " ").split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
            return name
        }
        return nil
    }

    /// Call every few seconds (it only reads cheap counters; the update record is re-read every 10 minutes).
    func refresh(disk: DiskInfo?) {
        let m = SystemMonitor.shared
        uptime = Date().timeIntervalSince(Self.bootDate())
        if pendingCache == nil || Date().timeIntervalSince(pendingCache!.date) > 600 { pendingCache = (Date(), Self.pendingUpdate()) }
        let heaviest = m.heaviestClosableLoad.map { (name: $0.name, bytes: $0.memory) }
        let input = RestartInput(uptime: uptime, swapUsed: m.swapUsed, swapTotal: m.swapTotal, ram: m.memoryTotal, compressed: m.memoryCompressed,
                                 pressure: m.pressure, pressureMinutes: m.pressureMinutes,
                                 diskFreeFraction: disk?.freeFraction, pendingUpdate: pendingCache?.name, heaviestApp: heaviest)
        let new = RestartRules.evaluate(input)
        if new.reasons.map(\.id) != advice.reasons.map(\.id) || new.fine != advice.fine || new.reasons.map(\.title) != advice.reasons.map(\.title) { advice = new }
    }

    func snooze(days: Int = 3) {
        let until = Date().addingTimeInterval(Double(days) * 86_400)
        UserDefaults.standard.set(until.timeIntervalSince1970, forKey: snoozeKey)
        snoozedUntil = until
    }

    // MARK: Actions

    /// Asks Finder to restart (the same permission used for the Trash). Finder then shows its usual confirmation.
    static func restart(done: @escaping (Bool, Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            NSAppleScript(source: "tell application \"Finder\" to restart")?.executeAndReturnError(&error)
            let code = (error?[NSAppleScript.errorNumber] as? NSNumber)?.intValue
            DispatchQueue.main.async { done(code == nil, code == -1743) }
        }
    }

    static func confirmRestart() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = calendarText("Restart your Mac now?", "¿Reiniciar tu Mac ahora?")
        alert.informativeText = calendarText("All apps will be asked to quit. Save your work first.", "Se pedirá a todas las apps que se cierren. Guarda tu trabajo antes.")
        alert.addButton(withTitle: calendarText("Cancel", "Cancelar"))
        alert.addButton(withTitle: calendarText("Restart", "Reiniciar")).hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }
}

// MARK: - UI

struct RestartPane: View {
    @ObservedObject private var advisor = RestartAdvisor.shared
    @ObservedObject private var monitor = SystemMonitor.shared
    let back: () -> Void
    @State private var message = ""

    var body: some View {
        RestartPanelView(advice: advisor.advice, uptime: advisor.uptime, heaviest: monitor.heaviestClosableLoad,
                         message: message, back: back, later: { advisor.snooze(); back() },
                         openSoftwareUpdate: openSoftwareUpdate, restart: restart)
    }

    private func openSoftwareUpdate() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension")!)
    }

    private func restart() {
        guard RestartAdvisor.confirmRestart() else { return }
        RestartAdvisor.restart { ok, denied in
            if !ok { message = Self.restartError(denied: denied) }
        }
    }

    static func restartError(denied: Bool) -> String {
        if denied {
            return calendarText("Cala needs permission to control Finder. Allow it in System Settings → Privacy & Security → Automation.",
                                "Cala necesita permiso para controlar Finder. Actívalo en Ajustes del Sistema → Privacidad y seguridad → Automatización.")
        }
        return calendarText("Could not restart.", "No se pudo reiniciar.")
    }
}

private enum RestartScrollSection: Hashable {
    case reason(String)
    case checks
}

private struct RestartSectionFrames: PreferenceKey {
    static let defaultValue: [RestartScrollSection: CGRect] = [:]

    static func reduce(value: inout [RestartScrollSection: CGRect], nextValue: () -> [RestartScrollSection: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

struct RestartPanelView: View {
    @Environment(\.colorScheme) private var colorScheme
    let advice: RestartAdvice
    let uptime: TimeInterval
    let heaviest: AppLoad?
    let message: String
    let back: () -> Void
    let later: () -> Void
    let openSoftwareUpdate: () -> Void
    let restart: () -> Void

    @State private var showFine = false
    @State private var sectionFrames: [RestartScrollSection: CGRect] = [:]

    private let reasonsSpace = "restart-reasons"
    private let hintHeight: CGFloat = 32

    var body: some View {
        let errorHeight: CGFloat = 46
        let viewport: CGFloat = message.isEmpty ? 378 : 378 - errorHeight - 12
        VStack(alignment: .leading, spacing: 12) {
            Button(action: back) {
                Label(calendarText("System", "Sistema"), systemImage: "chevron.left").font(.system(size: 11.5, weight: .medium))
            }.buttonStyle(.plain).flyoutSecondary()

            ViewThatFits(in: .vertical) {
                content.fixedSize(horizontal: false, vertical: true)
                scrollContent(height: viewport)
            }
            .frame(maxHeight: viewport, alignment: .top)

            if !message.isEmpty {
                Text(message).font(.system(size: 11.5)).foregroundStyle(Color.orange)
                    .lineLimit(3).frame(height: errorHeight, alignment: .topLeading)
                    .help(message)
            }
            Divider()
            controls
        }
    }

    private func scrollContent(height: CGFloat) -> some View {
        let edge = height - hintHeight + 1
        let remaining = advice.reasons.compactMap { sectionFrames[.reason($0.id)] }.filter { $0.maxY > edge }
        let more = remaining.filter { $0.minY >= edge }.count
        let checksBelow = sectionFrames[.checks].map { $0.maxY > edge } ?? false
        return ScrollView {
            content.padding(.trailing, 10).padding(.bottom, hintHeight)
        }
        .scrollIndicators(.visible)
        .frame(height: height)
        .coordinateSpace(name: reasonsSpace)
        .onPreferenceChange(RestartSectionFrames.self) { sectionFrames = $0 }
        .overlay(alignment: .bottom) {
            if !remaining.isEmpty || checksBelow {
                let surface = FlyoutStyle.surface(dark: colorScheme == .dark)
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, surface], startPoint: .top, endPoint: .bottom)
                        .frame(height: 12)
                        .accessibilityHidden(true)
                    Text(scrollHint(more: more, checksBelow: checksBelow))
                        .font(.system(size: 11, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: hintHeight - 12)
                        .background(surface)
                }
                .allowsHitTesting(false)
            }
        }
    }

    private func scrollHint(more: Int, checksBelow: Bool) -> String {
        guard more > 0 else {
            return checksBelow ? calendarText("See checks ↓", "Ver revisión ↓")
                               : calendarText("Keep reading ↓", "Sigue leyendo ↓")
        }
        let count = calendarText(more == 1 ? "1 more reason" : "\(more) more reasons",
                                 more == 1 ? "1 motivo más" : "\(more) motivos más")
        return checksBelow ? calendarText("\(count) and checks ↓", "\(count) y revisión ↓") : "\(count) ↓"
    }

    private func sectionFrame(_ section: RestartScrollSection) -> some View {
        GeometryReader { geometry in
            Color.clear.preference(key: RestartSectionFrames.self,
                                   value: [section: geometry.frame(in: .named(reasonsSpace))])
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(calendarText("Why restarting helps", "Por qué conviene reiniciar")).font(.system(size: 17, weight: .semibold))
                Text(calendarText("Your Mac has been on for \(RestartRules.uptimeText(uptime)). These are the reasons:",
                                  "Tu Mac lleva \(RestartRules.uptimeText(uptime)) encendido. Estos son los motivos:"))
                    .font(.system(size: 12)).flyoutSecondary()
            }
            ForEach(advice.reasons) { reason in
                card(reason).background { sectionFrame(.reason(reason.id)) }
            }
            if !advice.fine.isEmpty {
                DisclosureGroup(isExpanded: $showFine) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(advice.fine, id: \.self) { line in
                            Label(line, systemImage: "checkmark.circle.fill").font(.system(size: 11.5)).foregroundStyle(Color.green)
                                .labelStyle(.titleAndIcon)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                } label: {
                    Text(calendarText("Checked and fine", "Revisado y está bien")).font(.system(size: 12, weight: .medium))
                }
                .background { sectionFrame(.checks) }
            }
        }
    }

    private var controls: some View {
        let onlyUpdate = advice.reasons.allSatisfy { $0.id == "update" }
        return HStack {
            Button(calendarText("Later", "Más tarde"), action: later)
            Spacer()
            if advice.reasons.contains(where: { $0.id == "update" }) {
                if onlyUpdate {
                    Button(calendarText("Open Software Update", "Abrir Actualización de software"), action: openSoftwareUpdate)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button(calendarText("Software Update", "Actualizar macOS"), action: openSoftwareUpdate)
                        .buttonStyle(.bordered)
                }
            }
            if !onlyUpdate {
                Button(calendarText("Restart now…", "Reiniciar ahora…"), action: restart).buttonStyle(.borderedProminent)
            }
        }
    }

    private func card(_ r: RestartReason) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: r.symbol).font(.system(size: 15)).foregroundStyle(r.strong ? Color.orange : Color.yellow).frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(r.title).font(.system(size: 12.5, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                Text(r.detail).font(.system(size: 11.5)).flyoutSecondary().fixedSize(horizontal: false, vertical: true)
                switch r.action {
                case .closeApp:
                    if let app = heaviest {
                        let amount = diskBytes(Int64(app.memory))
                        Text(calendarText("Closing \(app.name) would free about \(amount).",
                                          "Cerrar \(app.name) liberaría unos \(amount)."))
                            .font(.system(size: 11.5, weight: .medium))
                    }
                case .openSoftwareUpdate, .none: EmptyView()
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.06)))
    }

}

import SwiftUI
import AppKit
import ApplicationServices
import CoreGraphics
import EventKit
import UniformTypeIdentifiers

// MARK: - Redaction

/// Everything that leaves the Mac goes through here first: home folder, user names, host name and e-mail addresses
/// are replaced, and the user always sees the redacted text before sending it.
enum Redactor {
    static func clean(_ text: String) -> String {
        var t = text
        let home = NSHomeDirectory(), user = NSUserName(), host = ProcessInfo.processInfo.hostName
        t = t.replacingOccurrences(of: home, with: "~")
        let shortHost = host.replacingOccurrences(of: ".local", with: "")
        if shortHost.count > 2 { t = t.replacingOccurrences(of: shortHost, with: "<host>", options: .caseInsensitive) }
        if user.count > 2 { t = t.replacingOccurrences(of: user, with: "<user>") }
        // Any other account under /Users (except Shared).
        if let r = try? NSRegularExpression(pattern: #"/Users/(?!Shared\b|<user>)[^/\s"']+"#) {
            t = r.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "/Users/<user>")
        }
        if let r = try? NSRegularExpression(pattern: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#) {
            t = r.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "<email>")
        }
        return t
    }
}

// MARK: - Diagnostics

enum DiagnosticReport {
    private static func sysctl(_ name: String) -> String {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        guard size > 0 else { return "?" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname(name, &buffer, &size, nil, 0)
        return String(cString: buffer)
    }

    static var calendarStatus: String {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return "granted"
        case .writeOnly: return "write-only"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not asked"
        @unknown default: return "unknown"
        }
    }

    /// Structured context sent with the report (also printed in the preview).
    static func context(_ config: Config) -> [String: Any] {
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        return [
            "app": ["version": Telemetry.appVersion(), "build": Telemetry.appBuild()],
            "os": ["name": "macOS", "version": os],
            "device": ["model": sysctl("hw.model"), "arch": sysctl("hw.machine"),
                       "memory_gb": Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)],
            "locale": ["identifier": Locale.current.identifier],
            "displays": ["count": NSScreen.screens.count],
            "permissions": ["accessibility": AXIsProcessTrusted(), "screen_recording": CGPreflightScreenCaptureAccess(), "calendar": calendarStatus],
            "settings": [
                "autoHide": config.autoHide, "theme": config.theme, "hideNativeDock": config.hideNativeDock,
                "hideMenuBar": config.hideMenuBar, "switcher": config.switcherEnabled, "usage": config.usageEnabled,
                "calendar": config.calendarEnabled, "pinnedApps": config.pinned.count,
                "trayBar": config.barTrayIDs.count, "trayMore": config.moreTrayIDs.count,
            ] as [String: Any],
        ]
    }

    private static let stampFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return f
    }()

    /// Last log lines, optionally only those written at or before `date` (what happened just before a crash).
    static func logLines(count: Int, before date: Date? = nil) -> [String] {
        let url = AppPaths.supportDirectory.appendingPathComponent("debug.log")
        guard let h = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 262_144 ? size - 262_144 : 0)
        let data = (try? h.readToEnd()) ?? Data()
        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        if let date {
            lines = lines.filter { line in
                guard line.count > 25, let t = stampFormat.date(from: String(line.prefix(25))) else { return false }
                return t <= date.addingTimeInterval(1)
            }
        }
        return Array(lines.suffix(count))
    }

    static func logTail(lines count: Int = 150, before date: Date? = nil) -> String {
        let lines = logLines(count: count, before: date)
        return lines.isEmpty ? "(no log)" : lines.joined(separator: "\n")
    }

    /// The last few things Cala did before a crash, as plain text for the report and for Sentry's context panel.
    static func activity(before date: Date) -> String {
        Redactor.clean(logLines(count: 12, before: date).joined(separator: "\n"))
    }

    /// The exact text that is attached to a report, already redacted.
    static func text(config: Config, before date: Date? = nil) -> String {
        let c = context(config)
        func part(_ key: String) -> [String: Any] { c[key] as? [String: Any] ?? [:] }
        let app = part("app"), os = part("os"), device = part("device"), perms = part("permissions"), settings = part("settings")
        func list(_ d: [String: Any]) -> String { d.keys.sorted().map { "\($0)=\(d[$0] ?? "")" }.joined(separator: ", ") }
        let body = """
        Cala \(app["version"] ?? "?") (build \(app["build"] ?? "?"))
        macOS \(os["version"] ?? "?")
        Mac: \(device["model"] ?? "?") \(device["arch"] ?? "?"), \(device["memory_gb"] ?? "?") GB RAM
        Locale: \(part("locale")["identifier"] ?? "?") · Displays: \(part("displays")["count"] ?? "?")
        Permissions: \(list(perms))
        Settings: \(list(settings))
        Tray bar: \(config.barTrayIDs.map { $0.replacingOccurrences(of: "__t_", with: "") }.joined(separator: ", "))
        Tray ^: \(config.moreTrayIDs.map { $0.replacingOccurrences(of: "__t_", with: "") }.joined(separator: ", "))

        --- \(date == nil ? "Last log lines" : "Log lines up to the crash") ---
        \(logTail(before: date))
        """
        return Redactor.clean(body)
    }
}

// MARK: - Crash reports

enum CrashReporter {
    private static let seenKey = "crashLastSeen"
    private static var directory: URL { URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/DiagnosticReports") }

    struct Crash {
        let file: URL
        let date: Date
        /// Redacted and capped, so it is safe to show and send.
        let text: String
    }

    /// The newest Cala crash report written since the last time this was checked. The first run only records "now",
    /// so old reports from before the feature existed are never offered.
    static func pending() -> Crash? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: seenKey) != nil else { defaults.set(Date().timeIntervalSince1970, forKey: seenKey); return nil }
        let seen = Date(timeIntervalSince1970: defaults.double(forKey: seenKey))
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let candidates = names.filter { $0.hasPrefix("Cala") && ($0.hasSuffix(".ips") || $0.hasSuffix(".crash")) }.compactMap { name -> (URL, Date)? in
            let url = directory.appendingPathComponent(name)
            guard let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, date > seen else { return nil }
            return (url, date)
        }
        guard let newest = candidates.max(by: { $0.1 < $1.1 }), let raw = try? String(contentsOf: newest.0, encoding: .utf8) else { return nil }
        let capped = raw.count > 150_000 ? String(raw.prefix(150_000)) + "\n…(truncated)" : raw
        return Crash(file: newest.0, date: newest.1, text: Redactor.clean(capped))
    }

    static func markSeen(_ crash: Crash) {
        UserDefaults.standard.set(crash.date.timeIntervalSince1970, forKey: seenKey)
    }

    /// At launch: depending on the user's setting, ask, send silently, or do nothing.
    static func checkAtLaunch(store: ConfigStore) {
        // After an automatic relaunch the crash report may not exist yet (macOS writes it a few seconds after the crash),
        // so when the previous run ended abnormally keep looking for up to 90 s.
        let attempts = Watchdog.previousRunEnded ? 30 : 1
        func attempt(_ n: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + (n == 0 ? 6 : 3)) {
                guard let crash = pending() else { if n + 1 < attempts { attempt(n + 1) }; return }
                handle(crash, store: store)
            }
        }
        attempt(0)
    }

    private static func handle(_ crash: Crash, store: ConfigStore) {
        markSeen(crash)
        do {
            switch store.config.crashReports {
            case "never": return
            case "auto":
                guard Telemetry.isConfigured else { return }
                var ctx = DiagnosticReport.context(store.config)
                ctx["activity_before_crash"] = ["log": DiagnosticReport.activity(before: crash.date)]
                Telemetry.send(kind: .crash, message: "Cala closed unexpectedly", email: nil, tags: [:], contexts: ctx,
                               attachments: [.init(filename: "crash.ips", text: crash.text), .init(filename: "diagnostics.txt", text: DiagnosticReport.text(config: store.config, before: crash.date))],
                               extras: CrashSummary.payload(crash.text)) { out in
                    log("feedback: crash report auto-sent ok=\(out.ok)")
                }
            default:
                let alert = NSAlert()
                alert.alertStyle = .informational
                alert.messageText = "Cala se cerró inesperadamente la última vez"
                alert.informativeText = "¿Quieres ayudar a arreglarlo enviando un informe? Antes verás exactamente qué se envía y podrás cancelar. No incluye tus archivos, ventanas ni contraseñas."
                alert.addButton(withTitle: "Ver y enviar…")
                alert.addButton(withTitle: "No enviar")
                NSApp.activate(ignoringOtherApps: true)
                if alert.runModal() == .alertFirstButtonReturn { FeedbackWindowController.shared.show(crash: crash) }
            }
        }
    }
}

// MARK: - Window

final class FeedbackWindowController {
    static let shared = FeedbackWindowController()
    private var window: NSWindow?

    func show(crash: CrashReporter.Crash? = nil) {
        log("feedback: opening window (crash=\(crash != nil))")
        window?.close()
        // The window takes the size of its content (fixed-height fields, 560 wide): no empty gap before the buttons,
        // and it grows by itself when "Ver exactamente qué se envía" is opened.
        let controller = NSHostingController(rootView: FeedbackView(crash: crash) { [weak self] in self?.window?.close() })
        controller.sizingOptions = [.preferredContentSize]
        let w = NSWindow(contentViewController: controller)
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.title = "Cala · Reportar un problema"
        w.center()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        // The content size is only known after the first layout, so center once it is.
        DispatchQueue.main.async { w.center() }
        log("feedback: window shown frame=\(NSStringFromRect(w.frame)) visible=\(w.isVisible)")
    }
}

struct FeedbackView: View {
    let crash: CrashReporter.Crash?
    let close: () -> Void
    @State private var kind: Telemetry.Kind = .problem
    @State private var message = ""
    @State private var email = ""
    @State private var includeDiagnostics = true
    @State private var preview = ""
    @State private var showPreview = false
    @State private var status = ""
    @State private var sending = false
    @State private var sent = false

    private var config: Config { ConfigStore.shared.config }
    private var effectiveKind: Telemetry.Kind { crash != nil ? .crash : kind }

    private var attachments: [Telemetry.Attachment] {
        var out: [Telemetry.Attachment] = []
        if let crash { out.append(.init(filename: "crash.ips", text: crash.text)) }
        if includeDiagnostics || crash != nil { out.append(.init(filename: "diagnostics.txt", text: preview)) }
        return out
    }
    private var fullText: String {
        let head = "[\(effectiveKind.rawValue)] \(message)" + (email.isEmpty ? "" : "\nContact: \(email)")
        return head + attachments.map { "\n\n=== \($0.filename) ===\n\($0.text)" }.joined()
    }
    private var canSend: Bool { !sending && !sent && (crash != nil || message.trimmingCharacters(in: .whitespacesAndNewlines).count >= 10) }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(crash != nil ? "¿Qué estabas haciendo? (opcional)" : "¿Qué pasó? ¿Qué esperabas que pasara?").font(.system(size: 12.5, weight: .medium))
                TextEditor(text: $message)
                    .font(.system(size: 13)).scrollContentBackground(.hidden)
                    .padding(6).frame(height: crash != nil ? 56 : 110).fieldBox()
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Tu correo (opcional, solo para poder responderte)").font(.system(size: 12.5, weight: .medium))
                TextField("nombre@correo.com", text: $email)
                    .textFieldStyle(.plain).font(.system(size: 13))
                    .padding(.horizontal, 10).padding(.vertical, 8).fieldBox()
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(crash != nil ? "Cala se cerró inesperadamente" : "Reportar un problema").font(.system(size: 20, weight: .semibold))
                Text(Telemetry.isConfigured
                     ? (crash != nil ? "No tienes que escribir nada: el informe ya incluye el fallo y lo que Cala estaba haciendo justo antes. Antes de enviar puedes ver exactamente qué se incluye."
                                     : "Lo que escribas llega a quien desarrolla Cala. Antes de enviar puedes ver exactamente qué se incluye.")
                     : "El envío de informes no está activado en esta versión de Cala.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if crash == nil {
                Picker("", selection: $kind) {
                    Text("Algo falla").tag(Telemetry.Kind.problem)
                    Text("Sugerencia").tag(Telemetry.Kind.suggestion)
                    Text("Otro").tag(Telemetry.Kind.other)
                }.pickerStyle(.segmented).labelsHidden()
            }
            if crash != nil {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Opcional: ayúdanos con más contexto").font(.system(size: 13, weight: .semibold))
                    Text("Puedes dejar todo en blanco y pulsar Enviar: el informe ya está completo.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
            fields
            if crash == nil {
                Toggle("Incluir información técnica (recomendado)", isOn: $includeDiagnostics).font(.system(size: 12.5))
            }
            DisclosureGroup(isExpanded: $showPreview) {
                ScrollView {
                    Text(fullText).font(.system(size: 10.5, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                .frame(height: 170).background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
            } label: {
                Text("Ver exactamente qué se envía").font(.system(size: 12, weight: .medium))
            }
            Text("Se quitan tu carpeta personal, tu nombre de usuario, el nombre del Mac y las direcciones de correo del texto técnico. No se envían los títulos de tus ventanas, tus archivos ni tus credenciales.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !status.isEmpty { Text(status).font(.system(size: 12)).foregroundStyle(sent ? Color.green : Color.orange).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button(sent ? "Cerrar" : "Cancelar") { close() }.keyboardShortcut(.cancelAction)
                if !sent {
                    Button(sending ? "Enviando…" : "Enviar") { send() }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(!canSend || !Telemetry.isConfigured)
                }
            }
        }
        .padding(22)
        .frame(width: 560)
        .onAppear { preview = DiagnosticReport.text(config: config, before: crash?.date) }
    }

    private func send() {
        sending = true; status = ""
        let note = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = note.isEmpty ? (crash != nil ? "Cala closed unexpectedly" : "(sin descripción)") : Redactor.clean(note)
        var ctx = DiagnosticReport.context(config)
        if let crash { ctx["activity_before_crash"] = ["log": DiagnosticReport.activity(before: crash.date)] }
        Telemetry.send(kind: effectiveKind, message: text, email: email.trimmingCharacters(in: .whitespaces), tags: [:],
                       contexts: ctx, attachments: attachments,
                       extras: crash.map { CrashSummary.payload($0.text) } ?? [:]) { out in
            sending = false
            sent = out.ok
            status = out.ok ? "Enviado. ¡Gracias! Esto ayuda a mejorar Cala." : "No se pudo enviar (\(out.detail)). Revisa tu conexión e inténtalo de nuevo."
            log("feedback: sent kind=\(effectiveKind.rawValue) ok=\(out.ok)")
        }
    }
}


private extension View {
    /// The same field look for every input in the report window: text background, border and corner radius.
    func fieldBox() -> some View {
        self.background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.2), lineWidth: 1))
    }
}

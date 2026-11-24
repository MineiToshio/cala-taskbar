import AppKit
import SwiftUI

/// First run: a short welcome that offers to move Cala to Applications, asks for the two permissions the bar is built
/// on, lists the optional ones (each is also asked for the first time its feature is used) and sets open-at-login.
/// It can be skipped at any step and reopened from Settings → Permissions.
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindowController()
    private var window: NSWindow?
    private static let doneKey = "onboardingCompleted"
    /// Called once when the user finishes or closes the welcome (the app then starts what waited for it).
    var onFinish: (() -> Void)?

    static var completed: Bool { UserDefaults.standard.bool(forKey: doneKey) }

    /// Shows the welcome on a first run. People upgrading from a version without it, who already granted
    /// Accessibility, are not asked again.
    func showIfNeeded(existingInstall: Bool) -> Bool {
        if Self.completed { return false }
        if existingInstall && AXIsProcessTrusted() { UserDefaults.standard.set(true, forKey: Self.doneKey); return false }
        show()
        return true
    }

    func show() {
        if window == nil {
            let controller = NSHostingController(rootView: OnboardingView(finish: { [weak self] in self?.finish() }))
            controller.sizingOptions = [.preferredContentSize]
            let w = NSWindow(contentViewController: controller)
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.title = tx("Welcome to Cala", "Te damos la bienvenida a Cala")
            w.delegate = self
            window = w
        }
        PermissionCenter.shared.beginWatching()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        log("onboarding: shown")
    }

    private func finish() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        PermissionCenter.shared.endWatching()
        if !Self.completed { log("onboarding: closed") }
        UserDefaults.standard.set(true, forKey: Self.doneKey)
        let done = onFinish
        onFinish = nil
        done?()
        // The window stays around (isReleasedWhenClosed = false) but its view starts fresh next time.
        window = nil
    }
}

private enum OnboardingStep: Int, CaseIterable { case welcome, essentials, optional, ready }

struct OnboardingView: View {
    let finish: () -> Void
    @State private var step: OnboardingStep = .welcome
    @State private var moveError: String?
    @State private var login = true
    @ObservedObject private var center = PermissionCenter.shared
    @ObservedObject private var store = ConfigStore.shared

    /// The notifications row only matters to people who use Claude Code or Codex.
    private var usesAI: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [home + "/.claude", home + "/.codex"].contains { FileManager.default.fileExists(atPath: $0) }
    }
    private var optional: [PermissionKind] {
        [.calendar, .location, .bluetooth, .automation] + (usesAI ? [.notifications] : [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                switch step {
                case .welcome: welcome
                case .essentials: essentials
                case .optional: optionalStep
                case .ready: ready
                }
            }
            .transition(.opacity.combined(with: .offset(x: 12)))
            .id(step)
            Spacer(minLength: 18)
            footer
        }
        .padding(.horizontal, 32).padding(.top, 40).padding(.bottom, 22)
        .frame(width: 600, height: 620, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(.easeOut(duration: 0.2), value: step)
    }

    // MARK: Pages

    private func heading(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 26, weight: .bold)).fixedSize(horizontal: false, vertical: true)
            Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 20)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high)
                .frame(width: 72, height: 72).padding(.leading, -6).padding(.bottom, 10)
                .accessibilityHidden(true)
            heading(tx("Welcome to Cala", "Te damos la bienvenida a Cala"),
                    tx("A taskbar for your Mac. It takes a minute to set up.", "Una barra de tareas para tu Mac. Prepararla toma un minuto."))
            Card {
                feature("dock.rectangle", tx("Your apps at the bottom", "Tus apps abajo"),
                        tx("Click to switch, hover to see each window, right-click for more.", "Clic para cambiar, pasa el mouse para ver cada ventana, clic derecho para más."))
                RowDivider()
                feature("square.grid.2x2", tx("Everything else on the right", "Todo lo demás a la derecha"),
                        tx("Wi-Fi, sound, battery, disk, calendar and a panel that explains why your Mac is slow.", "Wi-Fi, sonido, batería, disco, calendario y un panel que explica por qué tu Mac va lento."))
                RowDivider()
                feature("lock.shield", tx("Private by design", "Privada por diseño"),
                        tx("Nothing leaves your Mac unless you send a report yourself.", "Nada sale de tu Mac salvo que tú envíes un informe."))
            }
            if !AppLocation.isInstalled {
                Card {
                    HStack(alignment: .center, spacing: 14) {
                        Image(systemName: "folder.fill.badge.plus").font(.system(size: 18)).foregroundStyle(Color.accentColor).frame(width: 30)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tx("Move Cala to Applications", "Mueve Cala a Aplicaciones")).font(.system(size: 13, weight: .medium))
                            Text(moveError ?? tx("So it keeps working after you close the download and can open at login.",
                                                 "Así sigue funcionando al cerrar la descarga y puede abrirse al iniciar sesión."))
                                .font(.system(size: 11.5)).foregroundStyle(moveError == nil ? Color.secondary : StatusColor.color(.attention))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 12)
                        Button(tx("Move and reopen", "Mover y reabrir")) { moveError = AppLocation.moveToApplications() }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                }
                .padding(.top, 14)
            }
        }
    }

    private var essentials: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading(tx("Two permissions for the bar", "Dos permisos para la barra"),
                    tx("macOS asks you to allow them in System Settings. Cala notices by itself when you do; no restart needed.",
                       "macOS pide activarlos en Ajustes del Sistema. Cala nota sola cuando lo haces; no hace falta reiniciar."))
            Card {
                PermissionCard(kind: .accessibility)
                RowDivider()
                PermissionCard(kind: .screenRecording)
            }
            Text(tx("Without them the bar still lists and opens your apps; it just cannot show or manage their windows. If macOS offers \u{201C}Quit & Reopen\u{201D} after Screen Recording, accept it.",
                    "Sin ellos la barra igual lista y abre tus apps; solo no puede mostrar ni manejar sus ventanas. Si macOS ofrece \u{201C}Salir y volver a abrir\u{201D} tras Grabación de pantalla, acéptalo."))
                .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12).padding(.leading, 4)
        }
    }

    private var optionalStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading(tx("Optional extras", "Extras opcionales"),
                    tx("Allow them now, or later: each one is also asked the first time you use its feature.",
                       "Actívalos ahora o después: cada uno se pide también la primera vez que usas su función."))
            ScrollView {
                Card {
                    ForEach(Array(optional.enumerated()), id: \.element) { i, kind in
                        if i > 0 { RowDivider() }
                        PermissionCard(kind: kind)
                    }
                }
                .padding(.bottom, 2)
            }
            .frame(maxHeight: 420)
        }
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading(tx("You are all set", "Todo listo"),
                    tx("Two last choices. You can change both later in Settings.", "Dos últimas elecciones. Puedes cambiar ambas después en Configuración."))
            Card {
                SettingRow(title: tx("Open Cala at login", "Abrir Cala al iniciar sesión"),
                           caption: tx("Appears in System Settings → General → Login Items.", "Aparece en Ajustes del Sistema → General → Ítems de inicio.")) {
                    Toggle("", isOn: $login).toggleStyle(.switch).labelsHidden()
                        .accessibilityLabel(tx("Open Cala at login", "Abrir Cala al iniciar sesión"))
                }
                RowDivider()
                SettingRow(title: tx("Hide the macOS Dock", "Ocultar el Dock de macOS"),
                           caption: tx("Cala replaces it. Turning this off, or quitting Cala, brings it back exactly as it was.",
                                       "Cala lo reemplaza. Al apagarlo, o al salir de Cala, vuelve exactamente como estaba.")) {
                    Toggle("", isOn: Binding(get: { store.config.hideNativeDock }, set: { DockControl.setHidden($0, store) }))
                        .toggleStyle(.switch).labelsHidden()
                        .accessibilityLabel(tx("Hide the macOS Dock", "Ocultar el Dock de macOS"))
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                tip("cursorarrow.click.2", tx("Right-click an empty part of the bar for themes and Settings.", "Clic derecho en una zona vacía de la barra para temas y Configuración."))
                tip("questionmark.circle", tx("Missing permissions can be turned on any time in Settings → Permissions.", "Los permisos que falten se activan cuando quieras en Configuración → Permisos."))
            }
            .padding(.top, 16).padding(.leading, 4)
        }
        .onAppear { login = LoginItem.enabled || !UserDefaults.standard.bool(forKey: "loginItemChosen") }
    }

    private func feature(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.system(size: 15, weight: .medium)).foregroundStyle(Color.accentColor).frame(width: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func tip(_ symbol: String, _ text: String) -> some View {
        Label { Text(text).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: symbol).foregroundStyle(.secondary) }
            .font(.system(size: 11.5)).foregroundStyle(.secondary)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(OnboardingStep.allCases, id: \.self) { s in
                    Circle().fill(s == step ? Color.accentColor : Color.primary.opacity(0.18)).frame(width: 7, height: 7)
                }
            }
            .accessibilityElement()
            .accessibilityLabel(tx("Step \(step.rawValue + 1) of \(OnboardingStep.allCases.count)", "Paso \(step.rawValue + 1) de \(OnboardingStep.allCases.count)"))
            Spacer()
            if step != .welcome {
                Button(tx("Back", "Atrás")) { step = OnboardingStep(rawValue: step.rawValue - 1) ?? .welcome }
            }
            if step == .ready {
                Button(tx("Start using Cala", "Empezar a usar Cala")) {
                    UserDefaults.standard.set(true, forKey: "loginItemChosen")
                    if login != LoginItem.enabled { LoginItem.set(login) }
                    finish()
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            } else {
                Button(nextLabel) { step = OnboardingStep(rawValue: step.rawValue + 1) ?? .ready }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.large)
    }

    private var nextLabel: String {
        switch step {
        case .welcome: return tx("Get started", "Empezar")
        case .essentials:
            return center.granted(.accessibility) || center.granted(.screenRecording) ? tx("Continue", "Continuar") : tx("Continue without them", "Continuar sin ellos")
        default: return tx("Continue", "Continuar")
        }
    }
}

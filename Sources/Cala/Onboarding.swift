import AppKit
import SwiftUI

/// First run: a short welcome that offers to move Cala to Applications, asks what to use (the Bar, Zones or both), asks
/// only for the permissions that choice needs, lists the optional ones when the Bar (and its tray) is chosen (each is
/// also asked for the first time its feature is used) and sets open-at-login.
/// It can be skipped at any step and reopened from Settings → Permissions.
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindowController()
    private var window: NSWindow?
    private static let doneKey = "onboardingCompleted"
    private static let pendingKey = "onboardingPending"
    /// Called once when the user finishes or closes the welcome (the app then starts what waited for it).
    var onFinish: (() -> Void)?

    /// Written only when the module choice is saved, so quitting before answering shows the welcome again.
    static var completed: Bool { UserDefaults.standard.bool(forKey: doneKey) }
    /// A first-run welcome was shown and not answered yet (see `ModulePlan.resolve`).
    static var pending: Bool { UserDefaults.standard.bool(forKey: pendingKey) }

    /// The "What do you want to use?" answer was saved: the welcome is done.
    static func markChosen() {
        UserDefaults.standard.set(true, forKey: doneKey)
        UserDefaults.standard.removeObject(forKey: pendingKey)
    }

    /// Shows the welcome when the module resolution needs it. People upgrading from a version without it (migrated)
    /// are marked done and not asked.
    func showIfNeeded(_ needed: Bool) -> Bool {
        guard needed else {
            if !Self.completed { Self.markChosen() }
            return false
        }
        UserDefaults.standard.set(true, forKey: Self.pendingKey)
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
        if !Self.completed { log("onboarding: closed before choosing; nothing runs and it shows again next launch") }
        let done = onFinish
        onFinish = nil
        done?()
        // The window stays around (isReleasedWhenClosed = false) but its view starts fresh next time.
        window = nil
    }
}

private typealias OnboardingStep = ModulePlan.OnboardingPage

struct OnboardingView: View {
    let finish: () -> Void
    @State private var step: OnboardingStep
    @State private var moveError: String?
    @State private var login = true
    /// The "What do you want to use?" answers. They are written to the module keys when that step is left.
    @State private var useBar: Bool
    @State private var useZones: Bool
    @ObservedObject private var center = PermissionCenter.shared
    @ObservedObject private var store = ConfigStore.shared

    /// `step`, `bar` and `zones` let the --snapshot renderer open a given page; the app always starts at the welcome.
    init(finish: @escaping () -> Void, step: ModulePlan.OnboardingPage = .welcome, bar: Bool? = nil, zones: Bool? = nil) {
        self.finish = finish
        _step = State(initialValue: step)
        // A first-time user starts with nothing checked: the choice is theirs, not today's defaults.
        let config = ConfigStore.shared.config
        _useBar = State(initialValue: bar ?? (config.modulesChosen && config.modules.bar))
        _useZones = State(initialValue: zones ?? (config.modulesChosen && config.modules.zones))
    }

    /// The choice as it would be saved; nil while nothing is checked.
    private var choice: ModuleSet? {
        let config = store.config
        return ModulePlan.onboardingChoice(bar: useBar, zones: useZones, current: config.modules, chosen: config.modulesChosen)
    }
    private var steps: [OnboardingStep] {
        ModulePlan.onboardingPages(for: choice ?? ModuleSet(bar: useBar, switcher: useBar, tray: useBar, zones: useZones))
    }
    private var required: [PermissionKind] {
        ModulePlan.requiredPermissions(choice ?? .none).map(PermissionKind.init)
    }

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
                case .modules: modulesStep
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
                    tx("A taskbar and window zones for your Mac. It takes a minute to set up.", "Una barra de tareas y zonas de ventanas para tu Mac. Prepararla toma un minuto."))
            Card {
                feature("dock.rectangle", tx("Your apps at the bottom", "Tus apps abajo"),
                        tx("Click to switch, hover to see each window, right-click for more.", "Clic para cambiar, pasa el mouse para ver cada ventana, clic derecho para más."))
                RowDivider()
                feature("square.grid.2x2", tx("Everything else on the right", "Todo lo demás a la derecha"),
                        tx("Wi-Fi, sound, battery, disk, calendar and a panel that explains why your Mac is slow.", "Wi-Fi, sonido, batería, disco, calendario y un panel que explica por qué tu Mac va lento."))
                RowDivider()
                feature("rectangle.split.2x2", tx("Windows into zones", "Ventanas en zonas"),
                        tx("Drag a window, right-click or hold Shift, and drop it into a zone of your layout.", "Arrastra una ventana, haz clic derecho o mantén Mayús, y suéltala en una zona de tu distribución."))
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

    // MARK: What do you want to use?

    private var modulesStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading(tx("What do you want to use?", "¿Qué quieres usar?"),
                    tx("Choose one or both. You can change this any time in Settings, without reinstalling.",
                       "Elige una o las dos. Puedes cambiarlo cuando quieras en Configuración, sin reinstalar."))
            VStack(spacing: 12) {
                ModuleChoiceCard(isOn: $useBar, symbol: "dock.rectangle", title: tx("Bar", "Barra"),
                                 detail: tx("A taskbar at the bottom of every screen with your apps and windows, a tray with Wi-Fi, battery, calendar and more, and Option+Tab to switch windows.",
                                            "Una barra de tareas abajo en cada pantalla con tus apps y ventanas, una bandeja con Wi-Fi, batería, calendario y más, y Opción+Tab para cambiar de ventana."),
                                 needs: tx("Needs Accessibility and Screen Recording.", "Necesita Accesibilidad y Grabación de pantalla."))
                ModuleChoiceCard(isOn: $useZones, symbol: "rectangle.split.2x2", title: tx("Zones", "Zonas"),
                                 detail: tx("Drag any window, right-click or hold Shift, and drop it into a zone: halves, thirds, a grid or a layout you draw. Without a bar, Cala lives in the menu bar.",
                                            "Arrastra cualquier ventana, haz clic derecho o mantén Mayús, y suéltala en una zona: mitades, tercios, una cuadrícula o una distribución que dibujes. Sin barra, Cala vive en la barra de menús."),
                                 needs: tx("Needs Accessibility only.", "Solo necesita Accesibilidad."))
            }
            if choice == nil {
                Label(tx("Choose at least one to continue.", "Elige al menos una para continuar."), systemImage: "exclamationmark.circle")
                    .font(.system(size: 11.5)).foregroundStyle(StatusColor.color(.attention))
                    .padding(.top, 12).padding(.leading, 4)
            }
        }
    }

    /// Writes the choice to the module keys; the registry applies it live behind the welcome.
    private func saveChoice() {
        guard let set = choice else { return }
        var config = store.config
        let changed = !config.modulesChosen || config.modules != set
        config.barEnabled = set.bar
        config.switcherEnabled = set.switcher
        config.trayEnabled = set.tray
        config.zonesEnabled = set.zones
        config.modulesChosen = true
        OnboardingWindowController.markChosen()
        store.config = config
        if changed { log("onboarding: chose \(ModulePlan.summary(set))") }
    }

    // MARK: Permissions

    private var essentials: some View {
        let kinds = required
        let zonesOnly = !useBar && useZones
        return VStack(alignment: .leading, spacing: 0) {
            heading(useBar ? (useZones ? tx("Two permissions for the bar and zones", "Dos permisos para la barra y las zonas")
                                       : tx("Two permissions for the bar", "Dos permisos para la barra"))
                           : tx("One permission for zones", "Un permiso para las zonas"),
                    kinds.count == 1
                    ? tx("macOS asks you to allow it in System Settings. Cala notices by itself when you do; no restart needed.",
                         "macOS pide activarlo en Ajustes del Sistema. Cala nota sola cuando lo haces; no hace falta reiniciar.")
                    : tx("macOS asks you to allow them in System Settings. Cala notices by itself when you do; no restart needed.",
                         "macOS pide activarlos en Ajustes del Sistema. Cala nota sola cuando lo haces; no hace falta reiniciar."))
            Card {
                ForEach(Array(kinds.enumerated()), id: \.element) { i, kind in
                    if i > 0 { RowDivider() }
                    PermissionCard(kind: kind, why: zonesOnly && kind == .accessibility ? PermissionKind.zonesAccessibilityWhy : nil)
                }
            }
            Text(zonesOnly
                 ? tx("Without it, zones can't move windows. Cala waits and turns them on as soon as you allow it.",
                      "Sin él, las zonas no pueden mover ventanas. Cala espera y las activa en cuanto lo permitas.")
                 : tx("Without them the bar still lists and opens your apps; it just cannot show or manage their windows. If macOS offers \u{201C}Quit & Reopen\u{201D} after Screen Recording, accept it.",
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
                    useBar ? tx("Two last choices. You can change both later in Settings.", "Dos últimas elecciones. Puedes cambiar ambas después en Configuración.")
                           : tx("One last choice. You can change it later in Settings.", "Una última elección. Puedes cambiarla después en Configuración."))
            Card {
                SettingRow(title: tx("Open Cala at login", "Abrir Cala al iniciar sesión"),
                           caption: tx("Appears in System Settings → General → Login Items.", "Aparece en Ajustes del Sistema → General → Ítems de inicio.")) {
                    Toggle("", isOn: $login).toggleStyle(.switch).labelsHidden()
                        .accessibilityLabel(tx("Open Cala at login", "Abrir Cala al iniciar sesión"))
                }
                if useBar {
                    RowDivider()
                    SettingRow(title: tx("Hide the macOS Dock", "Ocultar el Dock de macOS"),
                               caption: tx("Cala replaces it. Turning this off, or quitting Cala, brings it back exactly as it was.",
                                           "Cala lo reemplaza. Al apagarlo, o al salir de Cala, vuelve exactamente como estaba.")) {
                        Toggle("", isOn: Binding(get: { store.config.hideNativeDock }, set: { DockControl.setHidden($0, store) }))
                            .toggleStyle(.switch).labelsHidden()
                            .accessibilityLabel(tx("Hide the macOS Dock", "Ocultar el Dock de macOS"))
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                if useBar {
                    tip("cursorarrow.click.2", tx("Right-click an empty part of the bar for themes and Settings.", "Clic derecho en una zona vacía de la barra para temas y Configuración."))
                } else {
                    tip("menubar.rectangle", tx("Cala lives in the menu bar: click its icon for Settings, the zones editor and your layouts.", "Cala vive en la barra de menús: haz clic en su icono para Configuración, el editor de zonas y tus distribuciones."))
                }
                if useZones {
                    tip("rectangle.split.2x2", zonesTip)
                }
                tip("questionmark.circle", tx("Missing permissions can be turned on any time in Settings → Permissions.", "Los permisos que falten se activan cuando quieras en Configuración → Permisos."))
            }
            .padding(.top, 16).padding(.leading, 4)
        }
        .onAppear { login = LoginItem.enabled || !UserDefaults.standard.bool(forKey: "loginItemChosen") }
    }

    private var zonesTip: String {
        switch ZoneActivation(config: store.config.zonesActivation) {
        case .shift: tx("Drag a window and hold Shift to show your zones; release over one to snap it.", "Arrastra una ventana y mantén Mayús para ver tus zonas; suéltala sobre una para encajarla.")
        case .rightClick: tx("Drag a window and right-click to show your zones; release over one to snap it.", "Arrastra una ventana y haz clic derecho para ver tus zonas; suéltala sobre una para encajarla.")
        case .both: tx("Drag a window and right-click or hold Shift to show your zones; release over one to snap it.", "Arrastra una ventana y haz clic derecho o mantén Mayús para ver tus zonas; suéltala sobre una para encajarla.")
        }
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
        let steps = steps
        let index = steps.firstIndex(of: step) ?? 0
        return HStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(steps, id: \.self) { s in
                    Circle().fill(s == step ? Color.accentColor : Color.primary.opacity(0.18)).frame(width: 7, height: 7)
                }
            }
            .accessibilityElement()
            .accessibilityLabel(tx("Step \(index + 1) of \(steps.count)", "Paso \(index + 1) de \(steps.count)"))
            Spacer()
            if step != .welcome {
                Button(tx("Back", "Atrás")) { step = index > 0 ? steps[index - 1] : .welcome }
            }
            if step == .ready {
                Button(tx("Start using Cala", "Empezar a usar Cala")) {
                    UserDefaults.standard.set(true, forKey: "loginItemChosen")
                    if login != LoginItem.enabled { LoginItem.set(login) }
                    finish()
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            } else {
                Button(nextLabel) {
                    if step == .modules { saveChoice() }
                    step = index + 1 < steps.count ? steps[index + 1] : .ready
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(step == .modules && choice == nil)
            }
        }
        .controlSize(.large)
    }

    private var nextLabel: String {
        switch step {
        case .welcome: return tx("Get started", "Empezar")
        case .essentials:
            let kinds = required
            if kinds.contains(where: center.granted) { return tx("Continue", "Continuar") }
            return kinds.count == 1 ? tx("Continue without it", "Continuar sin él") : tx("Continue without them", "Continuar sin ellos")
        default: return tx("Continue", "Continuar")
        }
    }
}

/// One answer to "What do you want to use?": a checkbox card that is clickable as a whole.
private struct ModuleChoiceCard: View {
    @Binding var isOn: Bool
    let symbol: String
    let title: String
    let detail: String
    let needs: String

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 18)).foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                    .frame(width: 22).padding(.top, 1)
                Image(systemName: symbol).font(.system(size: 15, weight: .medium)).foregroundStyle(Color.accentColor).frame(width: 26)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text(needs).font(.system(size: 11)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(isOn ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: isOn ? 1.5 : 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? tx("Checked", "Marcada") : tx("Not checked", "Sin marcar"))
        .accessibilityHint(detail)
        .accessibilityAddTraits(.isToggle)
    }
}

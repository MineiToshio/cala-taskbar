import AppKit
import SwiftUI

final class UpdateWindowController: NSObject, NSWindowDelegate {
    static let shared = UpdateWindowController()
    private var window: NSWindow?

    func show() {
        let service = UpdateService.shared
        guard service.offer != nil else { return }
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 380),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = tx("Cala update", "Actualización de Cala")
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: UpdateWindowView(service: service, store: ConfigStore.shared))
            window.center()
            self.window = window
        }
        service.setWindowOpen(true)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        window = nil
        UpdateService.shared.setWindowOpen(false)
    }

    static func menuItem() -> NSMenuItem? {
        guard let version = UpdateService.shared.available?.version else { return nil }
        return BlockItem(tx("Install Cala \(version)…", "Instalar Cala \(version)…")) { shared.show() }
    }
}

struct UpdateWindowView: View {
    @ObservedObject var service: UpdateService
    @ObservedObject var store: ConfigStore
    var snapshot: UpdateSettingsSnapshot?

    private var state: UpdateState { snapshot?.state ?? service.state }
    private var releasePage: URL { snapshot?.offer?.notesURL ?? service.releasePage }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let offer = snapshot?.offer ?? service.offer {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tx("Cala \(offer.version) is available", "Cala \(offer.version) está disponible"))
                        .font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(tx("You have \(currentVersion).", "Tienes la \(currentVersion)."))
                        .foregroundStyle(.secondary)
                }
                UpdateNotes(manifest: offer, releasePage: releasePage)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
            } else {
                Spacer(minLength: 0)
            }
            if state.isInstallOffer && (snapshot?.ready ?? service.canAutoInstall) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Button(tx("Skip this version", "Omitir esta versión"), action: service.skip)
                        .controlSize(.small)
                    Spacer(minLength: 0)
                    Button(tx("Later", "Más tarde"), action: service.later)
                        .keyboardShortcut(.cancelAction)
                    Button(tx("Download and install", "Descargar e instalar"), action: service.install)
                        .keyboardShortcut(.defaultAction)
                }
                Text(tx("Cala restarts by itself. It takes a few seconds.", "Cala se reinicia sola. Tarda unos segundos."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { status; Spacer(minLength: 0); action }
                        .fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 8) { status; action }
                }
            }
        }
        .padding(20)
        .frame(width: 420, height: 380)
    }

    private var currentVersion: String { snapshot == nil ? service.currentVersion : "1.0.0" }

    private var status: some View {
        Text(state.message).font(.callout).foregroundStyle(.secondary)
    }

    private var action: some View {
        UpdateAction(state: state, service: service, releasePage: releasePage)
    }
}

struct UpdateNotes: View {
    let manifest: UpdateManifest
    let releasePage: URL

    var body: some View {
        let markdown = tx(manifest.notes["en"] ?? manifest.notes["es"] ?? "",
                          manifest.notes["es"] ?? manifest.notes["en"] ?? "")
        VStack(alignment: .leading, spacing: 8) {
            if !markdown.isEmpty {
                ScrollView {
                    Text(Self.inlineNotes(markdown))
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            Link(tx("Full release notes", "Notas completas"), destination: releasePage)
        }
    }

    private static func inlineNotes(_ markdown: String) -> AttributedString {
        var text = (try? AttributedString(markdown: markdown,
                                          options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(markdown)
        for run in text.runs.filter({ $0.link != nil && $0.link?.scheme != "https" }) {
            text[run.range].link = nil
        }
        return text
    }
}

struct UpdateAction: View {
    let state: UpdateState
    let service: UpdateService
    let releasePage: URL

    var body: some View {
        switch state {
        case .idle, .upToDate:
            Button(tx("Check for updates", "Buscar actualizaciones"), action: service.checkNow)
        case .available, .skipped:
            Button(tx("Download and install", "Descargar e instalar"), action: service.install)
        case .downloading:
            Button(tx("Cancel", "Cancelar"), action: service.cancel)
        case .pendingRestart, .restartFailed:
            Button(tx("Restart now", "Reiniciar ahora"), action: service.restartNow)
        case .offline, .feedUnavailable, .verificationFailed, .diskFull, .busy, .failed:
            Button(tx("Try again", "Reintentar"), action: service.retry)
        case .blockedByMacOS:
            Button(tx("Open System Settings", "Abrir Ajustes del Sistema")) {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles")!)
            }
        case .needsAdmin, .manualInstall:
            Link(tx("Open release page", "Abrir la página"), destination: releasePage)
        case .unavailable:
            Link(tx("View releases online", "Ver versiones publicadas en la web"), destination: releasePage)
        default:
            EmptyView()
        }
    }
}

extension UpdateState {
    var isInstallOffer: Bool {
        switch self {
        case .available, .skipped: return true
        default: return false
        }
    }

    var message: String { message(localize: tx) }

    func message(localize: (String, String) -> String) -> String {
        switch self {
        case .idle: return localize("Not checked yet", "Aún no se ha revisado")
        case .checking: return localize("Checking…", "Buscando…")
        case .upToDate(let date):
            let time = date.formatted(date: .omitted, time: .shortened)
            return localize("Cala is up to date. Checked at \(time).", "Cala está al día. Revisado a las \(time).")
        case .available(let v): return localize("Cala \(v) is available.", "Cala \(v) está disponible.")
        case .skipped(let v): return localize("You skipped Cala \(v).", "Omitiste Cala \(v).")
        case .downloading(let p): return localize("Downloading… \(p)%", "Descargando… \(p)%")
        case .verifying: return localize("Verifying…", "Verificando…")
        case .installing: return localize("Installing…", "Instalando…")
        case .pendingRestart(let reason):
            switch UpdatePolicy.Blocker(rawValue: reason) {
            case .inactiveSession:
                return localize("Installed. Cala restarts when this session is active.", "Instalada. Cala se reinicia cuando esta sesión esté activa.")
            case .drag:
                return localize("Installed. Cala restarts when you finish dragging.", "Instalada. Cala se reinicia cuando termines de arrastrar.")
            default:
                let (en, es): (String, String)
                switch UpdatePolicy.Blocker(rawValue: reason) {
                case .zonesEditor: (en, es) = ("the Zones editor", "el editor de Zonas")
                case .settings: (en, es) = ("Settings", "Configuración")
                case .onboarding: (en, es) = ("the welcome window", "la ventana de bienvenida")
                case .updater: (en, es) = ("the update window", "la ventana de actualización")
                default: (en, es) = ("the dialog", "el diálogo")
                }
                return localize("Installed. Cala restarts when you close \(en).", "Instalada. Cala se reinicia cuando cierres \(es).")
            }
        case .rolledBack(let v, let cur):
            return localize("Cala \(v) didn't start, so \(cur) was restored.", "Cala \(v) no arrancó, así que se restauró la \(cur).")
        case .offline:
            return localize("Couldn't reach GitHub. Cala will try again later.", "No se pudo conectar con GitHub. Cala lo intentará más tarde.")
        case .feedUnavailable:
            return localize("Update information isn't available right now.", "La información de actualizaciones no está disponible ahora.")
        case .verificationFailed:
            return localize("The download didn't pass the security check, so nothing was installed.",
                      "La descarga no pasó la verificación de seguridad, así que no se instaló nada.")
        case .diskFull(let bytes):
            let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            return localize("Not enough free space (needs \(size)).", "No hay espacio suficiente (necesita \(size)).")
        case .busy:
            return localize("Another account is installing this update.", "Otra cuenta está instalando esta actualización.")
        case .blockedByMacOS:
            return localize("macOS blocked the update. Allow Cala in System Settings › Privacy & Security › App Management.",
                      "macOS bloqueó la actualización. Permite Cala en Ajustes del Sistema › Privacidad y seguridad › Gestión de apps.")
        case .needsAdmin:
            return localize("Ask an administrator to install it, or install it by hand.", "Pide a un administrador que la instale, o instálala a mano.")
        case .needsNewerMacOS(let v, let macOS):
            return localize("Cala \(v) needs macOS \(macOS) or later.", "Cala \(v) necesita macOS \(macOS) o posterior.")
        case .manualInstall:
            return localize("This version must be installed by hand.", "Esta versión se instala a mano.")
        case .unsupported:
            return localize("Updates work when Cala is in Applications.", "Las actualizaciones funcionan cuando Cala está en Aplicaciones.")
        case .unavailable:
            return localize("This build can't update itself.", "Esta versión no puede actualizarse sola.")
        case .failed:
            return localize("Cala couldn't install the update.", "Cala no pudo instalar la actualización.")
        case .restartFailed:
            return localize("Cala couldn't restart to finish the update.", "Cala no pudo reiniciarse para terminar la actualización.")
        }
    }
}

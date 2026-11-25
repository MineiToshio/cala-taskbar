import SwiftUI
import AppKit


struct PermissionsPane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SectionTitle(text: tx("Windows and thumbnails", "Ventanas y miniaturas"))
            Card {
                PermissionCard(kind: .accessibility, why: tx(
                    "Taskbar, Window switcher and Zones · Lets Cala list, focus, move and resize windows.",
                    "Barra de tareas, Selector de ventanas y Zonas · Permite a Cala ver, enfocar, mover y redimensionar ventanas."))
                RowDivider()
                PermissionCard(kind: .screenRecording, why: tx(
                    "Taskbar and Window switcher · Draws window thumbnails for both modules.",
                    "Barra de tareas y Selector de ventanas · Dibuja miniaturas de ventanas para ambos módulos."))
            }
            SectionTitle(text: tx("Tray features", "Funciones de Bandeja"))
            Card {
                ForEach([PermissionKind.calendar, .location, .bluetooth, .automation, .notifications]) { kind in
                    if kind != .calendar { RowDivider() }
                    PermissionCard(kind: kind)
                }
            }
        }
    }
}

struct AdvancedPane: View {
    @ObservedObject var store: ConfigStore
    @State private var confirmQuit = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Card {
                SettingRow(title: tx("Cala version", "Versión de Cala"),
                           caption: tx("Cala restarts after an update is installed and its windows are closed.",
                                       "Cala se reinicia después de instalar una actualización y cerrar sus ventanas.")) {
                    Text("\(Telemetry.appVersion()) (\(Telemetry.appBuild()))").monospacedDigit().textSelection(.enabled)
                }
                RowDivider()
                SettingRow(title: tx("Updates", "Actualizaciones")) {
                    Link(tx("View releases online", "Ver versiones publicadas en la web"),
                         destination: URL(string: "https://github.com/MineiToshio/cala-taskbar/releases/latest")!)
                }
            }
            Card {
                SettingRow(title: tx("Report a problem", "Reportar un problema"), caption: tx("Tell us what is broken or what you would like. You will see exactly what is sent before it goes out.", "Cuéntanos qué falla o qué te gustaría. Verás exactamente qué se envía antes de enviarlo.")) {
                    Button(tx("Report…", "Reportar…")) { FeedbackWindowController.shared.show() }
                }
                RowDivider()
                SettingRow(title: tx("Welcome", "Bienvenida")) {
                    Button(tx("Show the welcome again", "Ver la bienvenida otra vez")) { OnboardingWindowController.shared.show() }
                }
            }
            SectionTitle(text: tx("Advanced options", "Opciones avanzadas"))
            Card {
                SettingRow(title: tx("Configuration file", "Archivo de configuración"), caption: tx("All settings in JSON format.", "Todos los ajustes en formato JSON.")) {
                    Button(tx("Open", "Abrir")) { NSWorkspace.shared.open(store.fileURL) }
                }
                RowDivider()
                SettingRow(title: tx("Debug log", "Registro de depuración"), caption: tx("Useful if something goes wrong.", "Útil si algo falla.")) {
                    Button(tx("Show in Finder", "Mostrar en Finder")) {
                        let log = store.fileURL.deletingLastPathComponent().appendingPathComponent("debug.log")
                        NSWorkspace.shared.activateFileViewerSelecting([log])
                    }
                }
            }
            Card {
                SettingRow(title: tx("Reopen Cala if it quits on its own", "Volver a abrir Cala si se cierra sola"), caption: tx("If Cala crashes, it opens again within a few seconds. If it crashes three times in a row, it stops to avoid a loop.", "Si Cala falla, se abre otra vez en unos segundos. Si falla tres veces seguidas, se detiene para no entrar en un bucle.")) {
                    Toggle("", isOn: Binding(get: { store.config.relaunchOnCrash }, set: { store.config.relaunchOnCrash = $0; Watchdog.sync(store) })).toggleStyle(.switch).labelsHidden()
                        .accessibilityLabel(tx("Reopen Cala if it quits on its own", "Volver a abrir Cala si se cierra sola"))
                }
                RowDivider()
                SettingRow(title: tx("If Cala quits on its own", "Si Cala se cierra sola"), caption: tx("When you open it again it can offer to send a crash report. It does not include your files, windows or passwords.", "Al abrirla de nuevo puede ofrecerte enviar un informe del fallo. No incluye tus archivos, ventanas ni contraseñas.")) {
                    Picker("", selection: Binding(get: { store.config.crashReports }, set: { store.config.crashReports = $0 })) {
                        Text(tx("Ask me", "Preguntarme")).tag("ask")
                        Text(tx("Send without asking", "Enviar sin preguntar")).tag("auto")
                        Text(tx("Never send", "No enviar nunca")).tag("never")
                    }.labelsHidden().frame(width: 190)
                    .accessibilityLabel(tx("If Cala quits on its own", "Si Cala se cierra sola"))
                }
            }
            Card {
                SettingRow(title: tx("Quit Cala", "Salir de Cala"), caption: tx("To open it again, search for \u{201C}Cala\u{201D} in Launchpad or Spotlight.", "Para volver a abrirla, busca \u{201C}Cala\u{201D} en Launchpad o Spotlight.")) {
                    Button(tx("Quit…", "Salir…"), role: .destructive) { confirmQuit = true }
                }
            }
            .confirmationDialog(tx("Quit Cala?", "¿Salir de Cala?"), isPresented: $confirmQuit) {
                Button(tx("Quit", "Salir"), role: .destructive) { NSApp.terminate(nil) }
            } message: { Text(tx("Cala’s active modules will stop until you open the app again.", "Los módulos activos de Cala se detendrán hasta que vuelvas a abrir la app.")) }
            Card {
                SettingRow(title: tx("Uninstall Cala", "Desinstalar Cala"),
                           caption: tx("Puts the Dock and menu bar back, stops opening at login, deletes Cala's settings and moves the app to the Trash.",
                                       "Devuelve el Dock y la barra de menús, deja de abrirse al iniciar sesión, borra los ajustes de Cala y mueve la app a la Papelera.")) {
                    Button(tx("Uninstall…", "Desinstalar…"), role: .destructive) { Uninstaller.confirmAndRun(store: store) }
                }
            }
        }
    }
}

import SwiftUI
import AppKit

struct GeneralPane: View {
    @ObservedObject var store: ConfigStore
    let open: (SettingsPane) -> Void
    @State private var login = LoginItem.preference
    @State private var choosingTheme = false
    @Environment(\.settingsSnapshot) private var snapshot

    private var loginCaption: String {
        switch login.issue {
        case .approval:
            return tx("Switched off in System Settings → General → Login Items. Turn Cala on there.",
                      "Desactivado en Ajustes del Sistema → General → Ítems de inicio. Activa Cala allí.")
        case .registration:
            return tx("Cala could not register to open at login. Your preference is saved.",
                      "Cala no pudo registrarse para abrir al iniciar sesión. Tu preferencia está guardada.")
        case .removal:
            return tx("Cala could not remove its login item. Your preference is saved.",
                      "Cala no pudo eliminar su ítem de inicio. Tu preferencia está guardada.")
        case nil:
            return tx("Opens Cala when you log in to your Mac.", "Abre Cala al iniciar sesión en tu Mac.")
        }
    }
    private var systemLanguageName: String {
        let code = Locale.preferredLanguages.first?.split(separator: "-").first.map(String.init) == "es" ? "es" : "en"
        return code == "es" ? "Español" : "English"
    }

    var body: some View {
        let languageChanged = snapshot == nil && store.config.language != store.languageAtLaunch
        let language = snapshot?.language.map { Binding.constant($0) } ?? Binding(get: { store.config.language }, set: { store.config.language = $0 })
        VStack(alignment: .leading, spacing: 26) {
            SectionTitle(text: tx("What Cala does", "Qué hace Cala"))
            ModulesCard(store: store, open: open)
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tx("Language", "Idioma")).font(.system(size: 13, weight: .medium))
                        Text(languageChanged
                             ? tx("Some texts (menus, tray names) change after reopening Cala.", "Algunos textos (menús, nombres de la bandeja) cambian al reabrir Cala.")
                             : tx("By default Cala uses your Mac's language.", "Por defecto Cala usa el idioma de tu Mac."))
                            .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 12) {
                        Picker("", selection: language) {
                            Text(tx("System", "Sistema") + " (" + systemLanguageName + ")").tag("system")
                            Text("English").tag("en")
                            Text("Español").tag("es")
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 300)
                        .accessibilityLabel(tx("Language", "Idioma"))
                        Spacer(minLength: 0)
                        if languageChanged {
                            Button(tx("Reopen Cala", "Reabrir Cala")) { Relaunch.open() }.fixedSize()
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Card {
                SettingRow(title: tx("Open at login", "Abrir al iniciar sesión"), caption: loginCaption) {
                    HStack(spacing: 8) {
                        if login.issue == .approval {
                            Button(tx("Open Login Items", "Abrir Ítems de inicio")) { LoginItem.openSystemSettings() }
                                .controlSize(.small)
                        } else if login.issue != nil {
                            Button(tx("Retry", "Reintentar")) { LoginItem.retry(); login = LoginItem.preference }
                                .controlSize(.small)
                        }
                        Toggle("", isOn: Binding(get: { login.desired }, set: { LoginItem.set($0); login = LoginItem.preference }))
                            .toggleStyle(.switch).labelsHidden()
                            .accessibilityLabel(tx("Open at login", "Abrir al iniciar sesión"))
                            // Can change outside this view (the welcome, System Settings → Login Items): re-read it.
                            .onAppear { login = LoginItem.preference }
                            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in login = LoginItem.preference }
                            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in login = LoginItem.preference }
                    }
                }
            }
            SectionTitle(text: tx("Cala theme", "Tema de Cala"))
                .id("theme")
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Text(tx("Applies to the taskbar, window switcher, tray panels and zone overlays.",
                            "Se aplica a la barra de tareas, el selector de ventanas, los paneles de la bandeja y las zonas."))
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    let currentTheme = BarTheme.named(store.config.theme)
                    HStack(spacing: 8) {
                        currentTheme.background.frame(width: 28, height: 16)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.secondary.opacity(0.3)))
                            .accessibilityHidden(true)
                        Text(currentTheme.name).font(.system(size: 13, weight: .medium))
                        Spacer()
                        Button(tx("Change theme…", "Cambiar tema…")) { choosingTheme = true }
                            .popover(isPresented: $choosingTheme) {
                                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 14) {
                                    ForEach(BarTheme.all) { theme in
                                        ThemeTile(theme: theme, selected: store.config.theme == theme.id) {
                                            store.config.theme = theme.id
                                            choosingTheme = false
                                        }
                                    }
                                }
                                .padding(16).frame(width: 350)
                            }
                    }
                    Button(tx("Taskbar style", "Aspecto de la barra")) { open(.barStyle) }
                        .buttonStyle(.link).font(.system(size: 11.5))
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct ThemeTile: View {
    let theme: BarTheme
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(LinearGradient(colors: theme.colors.isEmpty ? [BarTheme.hex(0xF1F3F6), BarTheme.hex(0x3A3D44)] : theme.colors,
                                             startPoint: .leading, endPoint: .trailing))
                    HStack(spacing: 4) {
                        Circle().fill(theme.accent).frame(width: 7, height: 7)
                        Capsule().fill(.white.opacity(0.55)).frame(width: 14, height: 4)
                        Capsule().fill(.white.opacity(0.35)).frame(width: 10, height: 4)
                    }.padding(.bottom, 9)
                }
                .frame(height: 58)
                .overlay(alignment: .topTrailing) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 16))
                            .foregroundStyle(.white, Color.accentColor).padding(5)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
                .padding(3)
                .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.accentColor, lineWidth: selected ? 2.5 : 0))
                Text(theme.name).font(.system(size: 11.5, weight: selected ? .semibold : .regular))
            }
            .scaleEffect(hover ? 1.03 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.spring(response: 0.28, dampingFraction: 0.75), value: selected)
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}

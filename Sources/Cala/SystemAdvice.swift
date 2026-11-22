import SwiftUI
import AppKit

enum SystemAdvice {
    private static let protectedIDs: Set<String> = [
        "com.apple.finder", "com.apple.dock", "com.apple.loginwindow", "com.apple.systemuiserver"
    ]

    static func quittable(pid: Int32) -> NSRunningApplication? {
        guard pid != ProcessInfo.processInfo.processIdentifier,
              let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
              app.activationPolicy == .regular, let id = app.bundleIdentifier,
              !protectedIDs.contains(id.lowercased()), id != Bundle.main.bundleIdentifier else { return nil }
        return app
    }

    static func confirmQuit(pid: Int32, name: String, frees: UInt64?) {
        guard let app = quittable(pid: pid), app.localizedName == nil || app.localizedName == name,
              !hasOtherInstance(app) else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = calendarText("Close \(name)?", "¿Cerrar \(name)?")
        alert.informativeText = calendarText("If it has unsaved changes it will ask you before closing.",
                                            "Si tiene cambios sin guardar, te preguntará antes de cerrarse.")
        if let frees {
            let amount = memoryText(frees)
            alert.informativeText += calendarText(" It frees about \(amount).", " Libera unos \(amount).")
        }
        alert.addButton(withTitle: calendarText("Cancel", "Cancelar"))
        alert.addButton(withTitle: calendarText("Close \(name)", "Cerrar \(name)")).hasDestructiveAction = true
        if alert.runModal() == .alertSecondButtonReturn, !app.isTerminated, !hasOtherInstance(app) {
            app.terminate()
        }
    }

    private static func hasOtherInstance(_ app: NSRunningApplication) -> Bool {
        guard let bundle = app.bundleURL else { return true }
        return NSWorkspace.shared.runningApplications.contains {
            $0.processIdentifier != app.processIdentifier && !$0.isTerminated && $0.bundleURL?.path == bundle.path
        }
    }

    static func perform(_ action: SystemAction) {
        switch action {
        case .quit(let name, let pid, let frees): confirmQuit(pid: pid, name: name, frees: frees)
        case .activate(_, let pid):
            if let app = NSRunningApplication(processIdentifier: pid) { bringFront(app) }
        case .openActivityMonitor: openActivityMonitor()
        }
    }

    static func openActivityMonitor() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
    }
}

struct StatusCard: View {
    let message: SystemMessage
    let text: MessageText
    let onAction: (SystemAction) -> Void

    private var color: Color { message.level == .critical ? .red : .orange }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: message.level == .critical ? "exclamationmark.triangle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 13)).foregroundStyle(color).frame(width: 13, height: 15)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(text.title).font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1).minimumScaleFactor(0.85).frame(height: 15)
                if let detail = text.detail {
                    Text(detail).font(.system(size: 11.5)).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxHeight: 28, alignment: .top)
                }
                if message.primary != nil || message.secondary != nil {
                    HStack(spacing: 8) {
                        if let action = message.primary, let label = text.primary {
                            Button { onAction(action) } label: {
                                Text(label).lineLimit(1).minimumScaleFactor(0.85)
                            }.buttonStyle(.borderedProminent).controlSize(.small)
                        }
                        if let action = message.secondary, let label = text.secondary {
                            Button { onAction(action) } label: {
                                Text(label).font(.system(size: 11.5)).lineLimit(1).minimumScaleFactor(0.85)
                            }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
                        }
                    }
                    .frame(height: 20)
                    .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9).fill(color.opacity(0.12)))
    }
}

struct StatusNote: View {
    let title: String
    var recovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: recovered ? "checkmark.circle" : "info.circle")
                .foregroundStyle(recovered ? Color.green : Color.secondary)
                .accessibilityHidden(true)
            Text(title).lineLimit(2).fixedSize(horizontal: false, vertical: true).flyoutSecondary()
        }
        .font(.system(size: 11.5))
        .frame(minHeight: 16, maxHeight: 30, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

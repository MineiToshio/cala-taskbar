import SwiftUI

/// "How to use Zones" in three steps, worded for the configured gesture. Shown, always the same, in the welcome
/// (when Zones is chosen) and in Settings → Zones; nothing is taught during the drag itself.
struct ZonesHowTo: View {
    let activation: ZoneActivation
    /// The layout strip is on (`zonesLayoutStrip`); otherwise step 3 points to Settings and the menu-bar icon.
    let strip: Bool
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 9 : 12) {
            step(1, "cursorarrow.and.square.on.square.dashed", Self.dragText(activation))
            step(2, "command", tx("Hold ⌘ while you move to cover several neighbouring zones.",
                                  "Mantén ⌘ mientras te mueves para cubrir varias zonas vecinas."))
            step(3, "rectangle.topthird.inset.filled", strip
                 ? tx("To use another layout, move over “Change layout” at the top of the screen and rest on the one you want.",
                      "Para usar otra distribución, pasa sobre “Cambiar distribución” arriba de la pantalla y detente en la que quieras.")
                 : tx("To use another layout, choose it per monitor here or from the Cala icon in the menu bar.",
                      "Para usar otra distribución, elígela por pantalla aquí o desde el icono de Cala en la barra de menús."))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tx("How to use Zones", "Cómo usar las zonas"))
    }

    static func dragText(_ activation: ZoneActivation) -> String {
        switch activation {
        case .rightClick:
            tx("Drag a window and, still holding the button, right-click: your zones appear. Drop the window on one.",
               "Arrastra una ventana y, sin soltar, haz clic derecho: aparecen tus zonas. Suelta la ventana sobre una.")
        case .shift:
            tx("Drag a window and hold Shift: your zones appear. Drop the window on one.",
               "Arrastra una ventana y mantén Mayús: aparecen tus zonas. Suelta la ventana sobre una.")
        case .both:
            tx("Drag a window and right-click (or hold Shift): your zones appear. Drop the window on one.",
               "Arrastra una ventana y haz clic derecho (o mantén Mayús): aparecen tus zonas. Suelta la ventana sobre una.")
        }
    }

    private func step(_ number: Int, _ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7).fill(Color.accentColor.opacity(0.12))
                Image(systemName: symbol).font(.system(size: compact ? 12 : 13, weight: .medium)).foregroundStyle(Color.accentColor)
            }
            .frame(width: compact ? 26 : 30, height: compact ? 26 : 30)
            .accessibilityHidden(true)
            Text(text)
                .font(.system(size: compact ? 12 : 12.5))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, compact ? 4 : 6)
                .accessibilityLabel("\(number). \(text)")
        }
    }
}

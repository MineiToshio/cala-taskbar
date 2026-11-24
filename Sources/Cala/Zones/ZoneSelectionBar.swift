import AppKit
import SwiftUI

/// The selected zones' actions, floating at the bottom of the selection on the canvas so they are seen where the
/// work is (right-click offers the same). Hidden while dragging and while a dialog is open.
struct ZoneSelectionBar: View {
    let session: ZoneEditorSession
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 6) {
            if session.selection.count >= 2 {
                multiple
            } else if session.linked {
                tiles
            } else {
                free
            }
        }
        .labelStyle(.titleAndIcon)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .themedPanel(radius: 10, theme: session.theme)
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tx("Selected zone", "Zona seleccionada"))
    }

    // Two or more zones: merging is what a multiple selection is for.
    @ViewBuilder private var multiple: some View {
        Text(tx("\(session.selection.count) zones", "\(session.selection.count) zonas"))
            .font(.caption.weight(.medium))
            .foregroundStyle(FlyoutStyle.secondary(dark: scheme == .dark))
            .padding(.horizontal, 4)
        Button { session.mergeSelection() } label: {
            Label(tx("Merge", "Unir"), systemImage: "rectangle.compress.vertical")
        }
        .disabled(!session.canMerge)
        .help(session.canMerge ? tx("Merge the selected zones into one", "Une las zonas seleccionadas en una")
              : tx("Only zones that together form a rectangle can be merged", "Solo se pueden unir zonas que juntas formen un rectángulo"))
        if !session.canMerge {
            Text(tx("not a rectangle", "no forman un rectángulo"))
                .font(.caption)
                .foregroundStyle(StatusColor.color(.attention, dark: scheme == .dark))
        }
        Button(tx("Deselect", "Deseleccionar")) { session.selectOnly(nil) }
    }

    @ViewBuilder private var tiles: some View {
        Button { session.addZone(flip: NSEvent.modifierFlags.contains(.shift)) } label: {
            Label(tx("Split", "Dividir"), systemImage: "rectangle.split.2x1")
        }
        .disabled(!session.canSplitSelection)
        .help(tx("Split in two along the longer side (⇧: the other way). Or click inside the zone to split it there.",
                 "Divide en dos por el lado largo (⇧: en el otro sentido). O haz clic dentro de la zona para dividirla ahí."))
        sizeButton
        moreMenu
        deleteButton
    }

    @ViewBuilder private var free: some View {
        sizeButton
        Button { session.duplicateZone() } label: {
            Label(tx("Duplicate", "Duplicar"), systemImage: "plus.square.on.square")
        }
        .help(tx("Duplicate the zone (⌘D)", "Duplica la zona (⌘D)"))
        moreMenu
        deleteButton
    }

    private var sizeButton: some View {
        Button { session.requestSize() } label: {
            Label(tx("Size…", "Tamaño…"), systemImage: "ruler")
        }
        .help(tx("Type an exact width and height", "Escribe un ancho y un alto exactos"))
    }

    private var deleteButton: some View {
        Button(role: session.canDeleteZone ? .destructive : nil) { session.deleteZone() } label: {
            Label(tx("Delete", "Eliminar"), systemImage: "trash")
        }
        // Red only when it can act; disabled it is the standard grey (the tooltip says why).
        .tint(session.canDeleteZone ? StatusColor.color(.critical, dark: scheme == .dark) : nil)
        .disabled(!session.canDeleteZone)
        .help(session.linked
              ? (session.canDeleteZone ? tx("Its space goes to a neighbour that shares a whole side", "Su espacio pasa a una vecina que comparte un lado entero")
                 : tx("No neighbour shares a whole side, so deleting would leave a hole: merge or split first",
                      "Ninguna vecina comparte un lado entero; borrarla dejaría un hueco: une o divide antes"))
              : tx("Delete the zone (⌫)", "Elimina la zona (⌫)"))
    }

    private var moreMenu: some View {
        Menu {
            if session.linked, let zone = session.layout?.zones.first(where: { $0.id == session.selectedZone }) {
                Button(tx("Split into Left and Right", "Dividir en izquierda y derecha")) { session.split(zone.id, vertically: true) }
                    .disabled(ZoneTiling.split(zone.rect, vertically: true, minSize: session.minimumSize) == nil)
                Button(tx("Split into Top and Bottom", "Dividir en arriba y abajo")) { session.split(zone.id, vertically: false) }
                    .disabled(ZoneTiling.split(zone.rect, vertically: false, minSize: session.minimumSize) == nil)
                Divider()
            }
            if !session.linked {
                Button(tx("Center Horizontally", "Centrar horizontalmente")) { session.centerZone(horizontally: true) }
                Button(tx("Center Vertically", "Centrar verticalmente")) { session.centerZone(horizontally: false) }
                Divider()
            }
            Button(tx("Equal Widths in This Row", "Igualar anchos de esta fila")) { session.equalizeZones(horizontally: true) }
                .disabled(!session.canEqualize(horizontally: true))
            Button(tx("Equal Heights in This Column", "Igualar altos de esta columna")) { session.equalizeZones(horizontally: false) }
                .disabled(!session.canEqualize(horizontally: false))
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help(tx("More: split direction, centring, equal sizes", "Más: sentido de la división, centrar, igualar tamaños"))
        .accessibilityLabel(tx("More zone actions", "Más acciones de la zona"))
    }
}

import AppKit
import Combine

/// A registered Zones module can supply the editor and current per-display layout actions.
protocol ZonesStatusMenuProvider: AnyObject {
    func zonesStatusMenuItems() -> [NSMenuItem]
}

final class StatusItemController: NSObject, NSMenuDelegate {
    private var item: NSStatusItem?
    private var updateObserver: AnyCancellable?
    private var modules = ModuleSet.none
    private weak var zones: (any ZonesStatusMenuProvider)?

    func refresh(_ modules: ModuleSet, zones: (any ZonesStatusMenuProvider)?, zonesIcon: Bool) {
        self.modules = modules
        self.zones = zones
        guard ModulePlan.showsStatusItem(modules, zonesIcon: zonesIcon) else { remove(); return }
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        item.isVisible = true
        self.item = item
        updateObserver = UpdateService.shared.$available.map { $0?.version }.removeDuplicates()
            .sink { [weak self] version in self?.refreshImage(version: version) }
        log("status item: shown")
    }

    func remove() {
        guard let item else { return }
        NSStatusBar.system.removeStatusItem(item)
        self.item = nil
        updateObserver = nil
        log("status item: hidden")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if let update = UpdateWindowController.menuItem() { menu.addItem(update) }
        let settings = BlockItem(tx("Settings…", "Configuración…")) { SettingsWindowController.shared.show() }
        settings.keyEquivalent = ","
        menu.addItem(settings)
        menu.addItem(.separator())

        let items = modules.zones ? zones?.zonesStatusMenuItems() : nil
        for item in items ?? zonePlaceholders() { menu.addItem(item) }

        menu.addItem(.separator())
        if !modules.bar {
            menu.addItem(BlockItem(tx("Report a Problem…", "Reportar un problema…")) { FeedbackWindowController.shared.show() })
        }
        let quit = BlockItem(tx("Quit Cala", "Salir de Cala")) { NSApp.terminate(nil) }
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    private func refreshImage(version: String?) {
        guard let button = item?.button else { return }
        let label = version.map { v in tx("Cala \(v) update available", "Actualización de Cala \(v) disponible") } ?? "Cala"
        button.setAccessibilityLabel(label)
        guard let glyph = NSImage(systemSymbolName: "rectangle.split.2x2", accessibilityDescription: label) else {
            button.title = "Cala"
            return
        }
        let image: NSImage
        if version != nil {
            image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { _ in
                glyph.draw(in: NSRect(x: 1, y: 1, width: 14, height: 14))
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: 15, y: 12, width: 4, height: 4)).fill()
                return true
            }
        } else {
            image = glyph
        }
        image.isTemplate = true
        button.image = image
    }

    private func zonePlaceholders() -> [NSMenuItem] {
        func placeholder(_ title: String) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            return item
        }
        // The editor also works with Zones off (it loads zones.json on its own); the layouts need the module.
        let editor = BlockItem(tx("Zones editor…", "Editor de zonas…")) { ZonesModule.openEditorForPointerScreen() }
        editor.isEnabled = ZonesModule.openEditor != nil
        return [editor] + ZoneDisplays.labels(for: NSScreen.screens).map { name in
            placeholder(tx("\(name): turn on Zones to choose a layout", "\(name): activa Zonas para elegir una distribución"))
        }
    }
}

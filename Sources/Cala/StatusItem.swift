import AppKit

/// A registered Zones module can supply the editor and current per-display layout actions.
protocol ZonesStatusMenuProvider: AnyObject {
    func zonesStatusMenuItems() -> [NSMenuItem]
}

final class StatusItemController: NSObject, NSMenuDelegate {
    private var item: NSStatusItem?
    private var modules = ModuleSet.none
    private weak var zones: (any ZonesStatusMenuProvider)?

    func refresh(_ modules: ModuleSet, zones: (any ZonesStatusMenuProvider)?, zonesIcon: Bool) {
        self.modules = modules
        self.zones = zones
        guard ModulePlan.showsStatusItem(modules, zonesIcon: zonesIcon) else { remove(); return }
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "rectangle.split.2x2", accessibilityDescription: "Cala")
        image?.isTemplate = true
        if let image { item.button?.image = image }
        else { item.button?.title = "Cala" }
        item.button?.setAccessibilityLabel("Cala")
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        item.isVisible = true
        self.item = item
        log("status item: shown")
    }

    func remove() {
        guard let item else { return }
        NSStatusBar.system.removeStatusItem(item)
        self.item = nil
        log("status item: hidden")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
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

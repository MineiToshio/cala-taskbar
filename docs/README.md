# Cala

> Formerly called MacTaskbar. On first launch the app moves `~/Library/Application Support/MacTaskbar` to `.../Cala` (leaving a symlink at the old path so a saved Claude statusLine keeps working) and renames its login item. macOS ties Accessibility, Screen Recording and Calendar grants to the app, so grant them again to Cala once. `./install.sh` removes the old `~/Applications/MacTaskbar.app`.

A Windows-style taskbar for macOS (tested on macOS Tahoe 26.6.2, Apple silicon). It replaces the Dock with a bar at the bottom of every screen, with window previews and peek on hover, pinned apps you can drag to reorder, a system tray with calendar and upcoming events, Claude/Codex plan usage, fast user switching, themes and transparency, a "show desktop" button and a Settings window.

Built from scratch in Swift/AppKit/SwiftUI. No paid or third-party dependencies, no packages.

## Why it exists

The original goal was a Windows-like experience on a Mac. The Dock plus DockDoor (a paid-style previews tool) was unreliable: previews failed to show, especially for minimized windows. Cala replaces both.

## Documents

| File | Contents |
|---|---|
| [../README.md](../README.md) · [../README.es.md](../README.es.md) | Install guide for end users (English · Spanish) |
| [release.md](release.md) | Signing, notarization, costs and the release checklist |
| [features.md](features.md) | Everything the bar does and how to use it |
| [architecture.md](architecture.md) | Source layout, how each part works, key technical decisions |
| [setup.md](setup.md) | Build, permissions, auto-start, recommended system settings |
| [configuration.md](configuration.md) | `config.json` reference |
| [revert.md](revert.md) | How to go back to the normal Dock and remove everything |
| [troubleshooting.md](troubleshooting.md) | Known limits and fixes for common problems |
| [roadmap.md](roadmap.md) | Pending ideas, including the file manager project |

## Quick start

```bash
cd mac-launcher         
./install.sh                     # builds, installs to ~/Applications, launches
# restart only: pkill -x Cala; open ~/Applications/Cala.app
```

Then open **Configuración…** from the bar's right-click menu: the Permissions pane shows what to grant, and General can hide the macOS Dock and start the bar at login (see [setup.md](setup.md)).

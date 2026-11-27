# Cala

> Formerly called MacTaskbar. On first launch the app moves `~/Library/Application Support/MacTaskbar` to `.../Cala` (leaving a symlink at the old path so a saved Claude statusLine keeps working) and renames its login item. macOS ties Accessibility, Screen Recording and Calendar grants to the app, so grant them again to Cala once. `./install.sh` removes the old `~/Applications/MacTaskbar.app`.

A set of window tools for macOS (tested on macOS Tahoe 26.6.2, Apple silicon), in four modules you turn on and off separately: the **Bar**, its **Tray**, the **Switcher** and **Zones**. The Bar is a Windows-style taskbar that replaces the Dock with a bar at the bottom of every screen, with window previews and peek on hover, pinned apps you can drag to reorder, a system tray with calendar and upcoming events, Claude/Codex plan usage, fast user switching, themes and transparency, a "show desktop" button and a Settings window. Zones snaps windows you drag into layouts you draw, and works without the bar.

Built from scratch in Swift/AppKit/SwiftUI. No paid or third-party dependencies, no packages.

## Why it exists

The original goal was a Windows-like experience on a Mac. The Dock plus DockDoor (a paid-style previews tool) was unreliable: previews failed to show, especially for minimized windows. Cala replaces both.

## Documents

| File | Contents |
|---|---|
| [../README.md](../README.md) · [../README.es.md](../README.es.md) | Install guide for end users (English · Spanish) |
| [release.md](release.md) | Signing, notarization, costs and the release checklist |
| [features.md](features.md) | Everything Cala does and how to use it, including the modules |
| [mail.md](mail.md) | Mail for maintainers: connection lifecycle and queue, optimistic actions and rollback, the server commands that must not change, body cache and prefetch, attachments, observability (`mail-timing`), measurements and checks |
| [zones.md](zones.md) | Zones: gestures, layouts, storage format, monitors, editor, permissions, limits and the owner's manual test checklist |
| [architecture.md](architecture.md) | Source layout, the module registry and lifecycles, how each part works, key technical decisions |
| [setup.md](setup.md) | Build, permissions, auto-start, recommended system settings |
| [configuration.md](configuration.md) | `config.json` reference, including the module and Zones keys |
| [revert.md](revert.md) | How to go back to the normal Dock and remove everything |
| [troubleshooting.md](troubleshooting.md) | Known limits and fixes for common problems |
| [roadmap.md](roadmap.md) | Pending ideas, including what Zones left out and the file manager project |

## Quick start

```bash
cd cala-taskbar          # wherever you cloned the repository
./install.sh                     # builds, installs to /Applications, launches
# restart only: quit Cala normally, then open /Applications/Cala.app
```

The welcome asks what you want to use (Bar, Zones or both). Afterwards, open **Settings…** from the bar's right-click menu, or from the Cala icon in the menu bar when the Bar is off or Zones is on. General controls the modules and login, Taskbar controls Dock hiding, and Permissions shows what to grant (see [setup.md](setup.md)).

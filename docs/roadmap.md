# Roadmap

## Done
Taskbar with auto-hide, pinned apps, hover previews with thumbnails (including minimized windows), peek (real window on hover), context menus with dynamic "New…" items, Shift+click and middle-click new window, middle-click to close a preview, notification badges, show desktop (minimize/restore), reserve space (approximation), system tray (keyboard, Wi-Fi, Bluetooth, brightness, sound, AI usage, profiles with Fast User Switching, battery, clock with calendar and upcoming events), multi-screen with per-screen alignment, pointer cursor, drag-to-reorder icons, running-without-windows dot, nine themes, transparency, themed panels and previews, Settings window (General, Zones, Appearance, Screens, Tray, Usage, Calendar, Mail, Permissions, Advanced), AI plan usage indicator (Claude + Codex), EventKit upcoming events with Join links, installation to `~/Applications` via `install.sh`, shared opaque flyout surface, start at login switch, window switcher (Option+Tab / optional Cmd+Tab, with search, close/quit/minimize keys and larger previews), hide/restore the macOS Dock from the app, mail in the tray (Gmail, iCloud, Yahoo over IMAP), reopening the app opens Settings, **modules** (Bar, Tray, Switcher and Zones start and stop on their own, with a menu-bar status item when the Bar is off, a welcome that asks what you want to use, and existing users migrated without changes), **Zones** (drag a window into a zone of a per-monitor layout, with templates, an editor, ⌘ multi-zone span and restore on drag out; see [zones.md](zones.md)).

## Zones: out of scope for now
Ideas that were deliberately left out of the first version of [Zones](zones.md):
- **Per-Space or per-app layouts** (today a layout belongs to a monitor, whatever Space or app is in front).
- **Keyboard shortcuts** to move the front window into a zone, or to the next or previous zone.
- **Keyboard shortcuts per layout** (⌃⌥⌘1…9 switch the monitor under the pointer to layout 1…9, with the same name toast as the layout strip).
- **Mouse wheel to cycle layouts while dragging** (scroll in zones mode to step through the monitor's layouts; would add the scroll-wheel event to the tap's mask).
- **Auto-snap new windows** (an app always opens in its zone) and remember which zone each window is in across restarts.
- **Resize several snapped windows together** when you drag a shared edge.

Natural follow-ups:
- **Keyboard and VoiceOver navigation in the editor** (today the canvas is one accessibility element; zones can only be moved and resized with the mouse).
- **Esc to cancel zones mode** while dragging (needs a keyboard mask on the tap, which would change the permission analysis, see [zones.md](zones.md#permissions)).
- Compensate for the few points macOS can inset an auto-hidden Dock; stable ids for identical monitors; import and export of layouts.

## Pending ideas
1. **Win+number shortcuts** (Ctrl+1…9 activates the Nth icon). Needs a global key monitor.
2. **Show / hide previews and peek** as switches in Settings.
3. **Bar position** (bottom or top), height and spacing separate from icon size.
4. **Tray options:** choose which icons to show, clock format (24 h, seconds, date), tray on one screen only.
5. **Window grouping:** one icon per app (now) or one per window with its title.
6. **Per-screen apps:** each bar shows only the windows on its own screen.
7. **Drop a file on an icon** to open it with that app; jump list (recent items) in the icon menu.
8. **Click actions:** configurable right-click and middle-click behavior.
9. **Sync pinned apps with the Dock** as an option (it was copied once by hand).
10. **Distribution for other people:** a signed/notarized installer (.dmg), a first-run welcome that walks through permissions and the Dock switch, (the install path is already stable: `install.sh` puts the app in `~/Applications` and points the login item there). A paid Apple Developer ID is the one thing outside "no paid tools"; without it users must approve the app manually.
11. **Install on the "Trabajo" profile** (permissions and login item per user).

## Separate project: Windows-like file manager
Goal: a Finder replacement with Explorer behavior.
- Editable address bar (type a path, breadcrumbs).
- Cut / copy / paste of files with Windows semantics (Ctrl+X, Ctrl+C, Ctrl+V).
- Tabs, drag and drop, back/forward/up buttons, details view.
- Built the same way as the taskbar: native Swift, no paid or third-party tools.
Not started. Decide the scope before starting (a full replacement vs. a companion window).

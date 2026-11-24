# Roadmap

## Done
Taskbar with auto-hide, pinned apps, hover previews with thumbnails (including minimized windows), peek (real window on hover), context menus with dynamic "New…" items, Shift+click and middle-click new window, middle-click to close a preview, notification badges, show desktop (minimize/restore), reserve space (approximation), system tray (keyboard, Wi-Fi, Bluetooth, brightness, sound, AI usage, profiles with Fast User Switching, battery, clock with calendar and upcoming events), multi-screen with per-screen alignment, pointer cursor, drag-to-reorder icons, running-without-windows dot, nine themes, transparency, themed panels and previews, Settings window (General, Appearance, Screens, Usage, Calendar, Permissions, Advanced), AI plan usage indicator (Claude + Codex), EventKit upcoming events with Join links, installation to `~/Applications` via `install.sh`, shared opaque flyout surface, start at login switch, window switcher (Option+Tab / optional Cmd+Tab), hide/restore the macOS Dock from the app, mail in the tray (Gmail, iCloud, Yahoo over IMAP), reopening the app opens Settings.

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

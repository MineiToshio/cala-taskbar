# Features

## Bar basics
- One bar per screen, at the bottom, above normal windows (status-bar level), on every Space.
- **Icons only.** The app name and window previews show on hover.
- **Auto-hide** (default): the bar slides away and appears when the mouse touches the bottom edge of that screen. Can be turned off.
- **Icon alignment per screen:** left or center, set in Settings → Screens (typical use: left on the laptop, center on an ultrawide).
- **Indicators under each icon:** accent-colored wide bar = app has focus; small gray bar = running with windows; small gray **dot** = running but with no windows (so you still notice apps using memory); nothing = not running.
- **Reopening the app** (Spotlight, Launchpad, Finder) while it runs opens the Settings window.

## Pinned apps and running apps
- Pinned apps come first, then other running apps by launch time, unless you reordered them.
- **Drag to reorder:** press and drag any icon. It lifts (slightly larger, with a shadow) and follows the mouse while the others slide aside; on release it settles into place. The order is saved in `config.json` (`order`). Dragging works inside one bar, not across screens.
- Click: opens the app if closed; if running, behaves like Windows (activate; minimize if it is the only visible window of the active app). The click fires on mouse-up so it can be told apart from a drag.
- **Middle click** on an icon: opens a new window of that app (or launches it).
- Shift+click on a running app also opens a new window (Cmd+N).
- Pin and unpin from the icon's context menu.

## Window previews
- Hover over an icon (50 ms by default, adjustable) to see one card per window: app icon, title, close button and a live thumbnail.
- **Live view:** while the preview is open, visible windows refresh about 8–10 times per second (even if other windows cover them, e.g. a YouTube video keeps playing in the card). It stops the moment the preview closes.
- **Minimized windows** cannot be drawn by macOS, so they retain a recent cached thumbnail when available. The bar captures before its own minimize actions and when the yellow button is pressed. With the switcher enabled the bar also handles Cmd+M: it snapshots the focused window, then minimizes it. If the window cannot be minimized (no enabled minimize button, fullscreen, no answer from the app) the original Cmd+M is handed back to the app, never in addition to the bar's own minimize. Windows minimized before the bar started may show only an icon. The cache keeps at most 100 thumbnails.
- **Peek:** hovering a card brings that real window to the front for a moment (after ~40 ms); leaving restores the previous app and window. Clicking the card keeps the window. Not applied to minimized windows or windows on other Spaces (that would switch Space).
- Click a card to raise that window; click the X (or **middle-click** the card) to close it.
- Previews can be resized in Settings → Appearance.

## Context menu on an icon (opens above the bar)
- **Dynamic "New…" items** read from the app's own File menu (items starting with "New"/"Nuev", up to 4). No per-app hardcoding.
- Open (if not running), Pin/Unpin and Show in Finder. Other running apps offer **Cerrar todas las ventanas**. Regular apps other than Finder and Dock also offer **Salir de…**, which requests a normal quit without a Cala confirmation.
- Cala's own icon offers **Cerrar ventanas** when it has windows open. It closes those windows, including minimized ones, and Cala keeps running.

## Quick menu (right-click empty bar space)
Hide automatically, Theme (submenu), Transparency (submenu), **Configuración…** (opens the Settings window). There is deliberately no Quit here, so nobody exits by accident.

## Settings window
Sidebar with seven sections (General, Appearance, Screens, Usage, Calendar, Permissions, Advanced); every change applies instantly (no save button).
- **General:** auto-hide; window switcher (Option+Tab, optional Cmd+Tab); open at login (creates/removes the LaunchAgent); hide the macOS Dock (with "return the Dock when the bar quits"); preview delay.
- **Appearance:** live mock-up of the bar; nine theme swatches; transparency; icon size; preview size.
- **Screens:** one card per connected screen with an icon-alignment picker (drawn as small diagrams).
- **Usage:** AI usage indicator switches, custom Claude/Codex folders, optional Claude Code statusLine (see below).
- **Calendar:** upcoming-events switch, range, calendar selection and **Add account…** (see below).
- **Permissions:** live status of Accessibility, Screen Recording, Location and Bluetooth, with a button that opens the right System Settings page.
- **Advanced:** open `config.json`, reveal the debug log (rotates at 1 MB, no window titles), reset appearance, **Quit** (with confirmation; to start again, open the app from Spotlight/Launchpad).

## Themes and transparency
Nine themes: System (translucent material), Graphite, Midnight, Ocean, Sunset, Forest, Lavender, Candy, Snow. Each sets the background (solid or gradient), the accent color (start button, active indicator, selection marks, today in the calendar, switches and sliders) and forces light or dark text so everything stays readable. Transparency (0–80 %) only affects the bar background, never icons or text. Tray panels and previews use the same theme (their opacity never drops below 80 % for legibility).

## Window switcher (Option+Tab)
Like Cmd+Tab, but **per window instead of per app**: two windows of the same editor appear as two cards.
- Hold **Option** and press **Tab**: a panel with one thumbnail card per window (app icon + title), most recently used first, minimized windows included. The first Tab selects the previous window.
- Tab / right / down = next; Shift+Tab / left / up = previous; click a card to pick it; Esc cancels; releasing Option opens the selected window. These keys belong to the switcher only while Option is held: plain Tab and anything typed after releasing Option go to the app, even if the window list is still loading.
- Optional **Cmd+Tab replacement** (Settings → General → Cambiar de ventana): the app intercepts Cmd+Tab before macOS and shows this switcher instead.
- Uses the active theme. Needs Accessibility. Up to 20 windows: current-Space windows in front-to-back order first, followed by other windows reported by Accessibility, including minimized windows and windows on other Spaces. Picking one on another Space can switch Spaces.

## Notification badges
Red badges on icons using the numbers shown by the Dock. Numeric labels show the count; non-numeric labels show a dot. Requires the Dock process to keep running (it can be hidden).

## Hiding the macOS Dock
Settings → General → "Hide the macOS Dock" turns on Dock auto-hide with a 1000 s delay and restarts the Dock (no Terminal). Turning it off restores the exact previous values (saved in `config.json`). If the Dock was already hidden by hand, the app adopts that state at launch. "Return the Dock when the bar quits" (default on) gives the Dock back on quit and hides it again on the next launch.

## Show desktop
A thin strip at the far right edge.
- Tries to **minimize all non-minimized AX windows** of regular, non-hidden apps.
- If nothing can be minimized: **restores** all windows still pending from earlier show-desktop clicks and brings forward the app that was originally in front.
Full-screen windows and windows on other Spaces may reject minimization. Clicks are ignored while a show-desktop action is in progress; failed restores remain pending.

## System tray (all screens)
Order, left to right: keyboard, Wi-Fi, Bluetooth, brightness, sound, AI usage, battery, profiles, clock. All flyouts share one opaque, theme-tinted surface with an 18 pt content inset for readability over busy wallpapers. Each icon opens a panel above the bar (clicking again or clicking elsewhere closes it):

| Icon | Panel |
|---|---|
| Keyboard language (two-letter code) | List of keyboard layouts, click to switch |
| Wi-Fi (real signal strength) | On/off switch, current network, nearby known networks, other networks (lock = password), Wi-Fi settings |
| Bluetooth | On/off switch, paired devices (click to connect/disconnect) |
| Brightness (only if macOS exposes it) | Slider |
| Sound | Mute switch, volume slider; mouse wheel over the icon changes volume |
| AI usage (Claude + Codex) | One shared control for both providers; remaining quota, reset times, plan badges, update age and refresh |
| Profiles | Photo and name of each user (photo shown in the tray). Clicking another user opens the login screen with that user preselected, including users without an open session; "login window" locks the screen |
| Battery (same monochrome style as the other icons, percentage underneath; battery-with-bolt symbol whenever it is plugged in) | Power source (adapter or battery), percentage, time remaining, Low Power Mode switch (runs `pmset` through an administrator-password prompt on every change), battery settings |
| Clock | Large time with seconds, full date, month calendar (navigate months, back to today), upcoming events from selected calendars, open Calendar, notification settings |

Fast User Switching sends a validated OpenDirectory record dictionary to `SACSwitchToUser` in PRIVATE login.framework. The request is asynchronous: Cala checks its own session through PRIVATE SkyLight every 0.25 s for about 3 s and falls back to locking the screen if preparation, the request or verification fails. Repeated clicks during a switch are ignored. Success is sticky for each attempt; the main-queue fallback rechecks the attempt and success state. A continuous monotonic clock measures the timeout, including suspension: verification delayed beyond 6 s is logged as unknown, probably switched, and does not lock the screen. These PRIVATE APIs may break in any macOS update; `SLSSessionSwitch*` is blocked for non-Apple callers and is not used.

macOS does not let apps read other apps' notifications, so the clock panel only links to the notification settings.

The pointer turns into a hand over everything clickable.

## Multi-screen
Bars are rebuilt automatically when screens are connected or disconnected. Hover, previews, menus and panels follow the screen under the mouse.

## AI plan usage indicator
- Settings → Usage enables the indicator (on by default) and each provider separately. Only detected, signed-in Claude/Codex providers appear in one combined control immediately to the left of the battery (or before profiles when there is no battery); missing providers produce no reading.
- Both compact vector marks and readings share one hover highlight and one click target. Each reading shows the percentage remaining in the first available window in this fixed order: 5-hour session → weekly all-models → model-scoped weeklies → other windows by duration ascending. Below 25% is a warning; below 10% is critical. Click the combined control for both providers' available windows: remaining percentages in primary text (amber below 25%, red below 10%), severity-colored remaining-allowance bars, local reset dates and relative times, human-readable plan badges, and a live-updating reading age. Every provider uses this same row order in the flyout, so the tray always matches its first row, regardless of which window has the lowest percentage left. Coral Claude and blue/lilac Codex headings distinguish the provider cards.
- Only windows returned by the provider appear; plans without a 5-hour limit have no 5-hour row. Unknown response schemas show `n/a`. At a passed reset, the old window displays zero used and “resetting…” until revalidated.
- Refresh bypasses the normal minimum interval, coalesces concurrent requests, and stays disabled during a rate-limit cooldown. Last readings remain visible during refresh and survive app restarts.
- Codex session logs provide local updates automatically. Claude Code statusLine updates are optional and off by default. Enabling creates a small macOS-native script and backs up Claude settings; existing statusLine commands are preserved, with integration instructions shown in Settings.

## Upcoming calendar events
- The clock flyout keeps its month view and adds **Upcoming**: ongoing events and events starting within the next 7 days. Settings → Calendar changes the range to 1, 3, 7 or 14 days and selects calendars, grouped by macOS account/source.
- Google personal/work, iCloud, Exchange and other calendars work through macOS Internet Accounts and EventKit. Add accounts with **Add account… (Google, iCloud, Exchange)**, then enable Calendars there; Cala never automates sign-in.
- The feature defaults on, but requests full calendar access only when you open the clock flyout or the Calendar settings section while enabled. Nothing is requested at launch. Once access has been granted, the bar keeps events fresh in the background (every 60 s) for the Join button; that never shows a permission prompt. Denied/restricted access displays an inline message and a Privacy Settings button.
- Events are grouped by Today, Tomorrow and weekday/date. Rows show the calendar color, title, time range or All day, and a short location. Current timed events are marked **Now** and the next timed event **Next**. A bounded scrolling list keeps the month visible (at most about eight rows, fewer on smaller screens).
- **Join** opens Meet, Zoom/ZoomGov, Teams (including personal Teams) or Webex links found in the event URL, location or notes. Clicking the event tries Calendar’s event URL, with a plain Calendar.app fallback; selecting the exact event is best effort because this URL is undocumented. No AppleScript or event export is used.
- Events refresh on EventKit changes, app activation, when opening the pane and every minute while the list is visible. Disabled or excluded calendars are not queried. Newly added calendars are included by default. No calendar indicator or notifications are added to the tray.
- Cala only reads calendars, keeps event snapshots in memory, and neither logs nor caches event content. Internet Accounts handles account credentials and synchronization; macOS’s full-access permission is required to read events, though this feature never writes them.

The calendar flyout chooses Spanish when the first preferred language is Spanish, otherwise English; dates and times use the current locale. Shared permission messages follow this choice too.

## Disk space
A drive icon with the **free percentage** sits next to the battery (orange under 20%, red under 10%). Click it for the storage panel: available space (including purgeable, like System Settings), a used / purgeable / free bar and a list of where the space goes: Applications, Xcode and simulators, caches, app data, Claude Code (`~/.claude`), Codex (`~/.codex`), npm / cargo / gradle / bun caches and Homebrew, plus any extra folders you add in Settings → General → Disco (for example where your projects or git worktrees live). Click a row to open that folder in Finder. Sizes are measured in the background when the panel opens (at most once every 10 minutes, or "Volver a medir"). It also lists `/Users/Shared` and other macOS user accounts (e.g. a work session), shown as "≥" when their permissions hide some files. "Tu carpeta personal (resto)" covers Documents, Downloads, Desktop and the rest of your home (macOS asks permission once per protected folder), and a last row, "Sistema y otros (no medido)", is the used space minus everything measured (macOS itself, system data, the Trash), so the rows add up to the used total.

## Join button
When a calendar event has a Meet, Zoom, Teams or Webex link (in its URL, location or notes), a **Join** pill appears in the bar from 5 minutes before it starts until it ends, showing the title and "in N min" / "now". Click it to open the link. If two meetings overlap, the one starting closest to now wins. Turn it off in Settings → Calendar → Join button. It needs calendar access to have been granted already (open the clock once).

## Quota pace and alerts
Under each Claude / Codex quota in the usage panel, a line projects the burn rate: *"At this pace it runs out in 2 d 11 h, before the reset"* (orange) or *"At this pace you reach the reset with ~35% left"*. The line is always there for a window that is counting, so it never comes and goes: a projection, **"No recent use"**, **"Not used yet"** or **"Measuring pace…"**. The rate comes from recent readings, with a lookback proportional to the window (30 minutes for the 5-hour session, about 8 hours for the weekly one, because the percentages are whole numbers and a weekly window barely moves in half an hour). When there is not enough recent data, or the recent change is a single point, it falls back to the average since the window started. Readings are kept for 12 hours in `usage-history.json` (percentages and timestamps only) so a restart does not lose them.

Notifications (Settings → Usage → Quota alerts, on by default): one when a window's remaining share drops to your threshold (10, 15, 20 or 30%, default 20%), and one when, at the current pace, a window will run out within the next hour and before it resets. Each fires once per window cycle. macOS asks for notification permission the first time you turn alerts on.

## Free up space
The storage panel has **Revisar y limpiar espacio…**, which only opens a window with two lists (opening it deletes nothing; the window says so). Nothing is selected by default. Deleting asks first in a dialog that lists every item with its size and the total; "Cancelar" is the default button.

- **Agent worktrees.** Finds the linked git worktrees of every project Claude Code or Codex has opened (exact paths are read from `~/.claude.json` and `~/.codex/config.toml`; nothing else is read from them) plus the extra folders from Settings → General → Disco. Each row shows size, repository, branch, age of the last commit, and a verdict: **Safe / Merged** (clean tree including untracked files, commits kept on a branch), or why it is blocked: *Unsaved changes*, *Inner worktree has changes*, *Commits not on any branch*, *Locked*, *In use* (a running process has its working directory inside). Only safe ones can be selected ("Select safe ones" picks them all). Removal uses `git worktree remove` without `--force`, so git itself refuses anything with changes; inner worktrees are removed first and branches are never deleted.
- **Caches that regenerate.** App caches, Xcode DerivedData and device support, npm, `~/.cache`, Gradle, Bun and Cargo caches. Deleting empties the folder's contents, never the folder.

After a run the window shows how much space was actually freed.

## System monitor
Click the CPU gauge in the tray to open **Sistema**. Two matching meters show processor load across all cores and memory used out of installed RAM, each with a short history graph and a status label. The footer opens **Monitor de Actividad** or **Detalles**, which has three sections: **Procesador** (apps and tasks, macOS and core count), **Memoria** (usage, pressure and swap) and **Actividad del Mac** (uptime and counts for unmeasured processes and other accounts). **Monitor de Actividad** is also available at the foot of Details.

The tray and the panel share processor and memory samples, so their meters normally appear immediately. A meter shows a loading placeholder only before its first sample. The Processor list shows placeholders when there is no usable process reading. Placeholders stay still when Reduce Motion is enabled.

**Lo que más usa** switches between Processor and Memory and shows up to seven rows with proportional bars, including **Sistema y otros** when shown. A guidance card or maintenance notice lowers the limit to six, and both together lower it to five. App helpers count toward their app. Expand a standalone tool row to see its processes grouped by launcher app, with **Ir a…** to bring a known launcher forward. When present, **Sistema y otros** follows the last attributed row and also expands.

Cala runs `/bin/ps` while **Sistema y otros** is expanded and the selected list has a fresh reading. The detail uses friendly names for macOS services, groups identifiable helpers under their app, and combines processes from other accounts under **Otra cuenta del Mac** without showing names. **Otros** collects the remaining share. **Reparto aproximado** appears when the probe supplies system-process readings for the selected metric. Otherwise the note reads **Solo mediciones disponibles**.

- **Processor.** On reopening, Cala immediately shows the last validated list when it is at most 30 seconds old, marked **Lectura anterior** while it refreshes. The large CPU number uses that same window so the rows, including **Sistema y otros**, add up to it. The graph continues to show the global sample history. **Cerrar** and **Ir a…** require a validated reading from the current opening that is less than four seconds old.
- **Memory.** Each process scan provides memory footprints in one pass. Cala can show the last list for up to 30 seconds while it refreshes. If none is available, the list shows a short status until the first reading. Cala scales overlapping footprints proportionally if their sum exceeds used memory. **Sistema y otros** shows any positive remainder.

## Tray layout and the "^" panel
Every tray item (keyboard, Wi-Fi, Bluetooth, brightness, volume, Claude and Codex, CPU and memory, disk, battery, user, Downloads, Trash) can be set to **En la barra** (always visible), **En ^** (behind the chevron at the start of the tray) or **Oculto**, and dragged to change its order (top to bottom = left to right on the bar). Settings → **Bandeja**; "Restablecer valores" returns to the defaults. By default Wi-Fi, volume, Claude and Codex, CPU, disk and battery are on the bar; keyboard, Bluetooth, brightness, user, Downloads and Trash are behind **^**. The chevron appears only when something is inside, shows its items as tiles, and each tile opens that item's usual panel with a "‹ Más" back button. The old on/off switches for the disk and system monitor items still apply to configs saved before this existed.

## Downloads and Trash
- **Descargas:** a panel with the 10 most recent downloads (icon, name, size, age; unfinished `.crdownload` / `.download` / `.part` files are skipped). Click opens a file, the magnifier shows it in Finder, and "Abrir carpeta Descargas" opens the folder. macOS asks once for permission to read the Downloads folder.
- **Papelera:** shows the number of items and offers "Abrir Papelera" and "Vaciar Papelera…" (confirmation first, Cancel is the default; afterwards it reports how much space was freed). macOS protects the Trash folder, so Cala counts and empties it through Finder (AppleScript); macOS asks once to let Cala control Finder. The size in GB is not available without Full Disk Access, which Cala does not request.
- **Limpiar espacio** has a "Papelera" section with "Vaciar la Papelera": press Comprobar to count (that is when the permission prompt appears, never on opening the window), tick it like any other item, and it is part of the same confirmation.

## Hiding the macOS menu bar
Settings → General → **Barra de menús de macOS**. macOS cannot remove the menu bar, only auto-hide it: with the switch on it slides away everywhere (desktop and full screen) and reappears when the pointer touches the top edge, so the app menus (File, Edit…) and its icons stay reachable. It writes the same preferences System Settings → Control Center → "Automatically hide and show the menu bar" writes (`AutoHideMenuBarOption`, `_HIHideMenuBar`, `AppleMenuBarVisibleInFullscreen`; undocumented) and posts the two notifications that apply the change live. The previous values are saved and restored exactly when you turn the switch off and, by default, when Cala quits ("Devolverla al cerrar Cala"). If the bar ever stays hidden, set it back in System Settings → Control Center → "Automatically hide and show the menu bar".

### Hiding only the macOS icons Cala replaces
Settings → General → Barra de menús de macOS lists the right-hand macOS icons that can be hidden and that Cala already covers: **Wi-Fi, Battery, Fast User Switching and the keyboard-language icon ("ES")**, each with its own switch (the language icon uses `com.apple.TextInputMenu visible`, then SystemUIServer is restarted). The app menus on the left (File, Edit…) are never touched. It sets the same per-host module value System Settings → "Show in Menu Bar" sets (`com.apple.controlcenter`: 18 shown, 24 not shown) and restarts ControlCenter so it is re-read (the `NSStatusItem VisibleCC …` keys cannot be used: ControlCenter rewrites them when it quits). Each icon's original value is saved and put back when you switch it off and, by default, when Cala quits. The clock cannot be hidden (macOS always shows it), and the Control Center and Spotlight icons did not respond to this mechanism. Under the switches the settings pane lists the icons of other apps that are still on the bar (found through Accessibility, `AXExtrasMenuBar`), with a button to open System Settings → Menu Bar, where macOS lets you allow or block them; each app also has its own "show in menu bar" option. `notifyutil -p local.cala.listMenuBarExtras` writes the same list, with owner apps, to the debug log.

## Reporting problems and crashes (beta)
- **Reportar un problema…** (right-click on an empty part of the bar, or Settings → Avanzado). A window with the kind (Algo falla / Sugerencia / Otro), a description, an optional e-mail and "Incluir información técnica". **"Ver exactamente qué se envía"** shows the full text before anything leaves the Mac. Buttons: Cancelar and Enviar only.
- **What is included:** Cala version and build, macOS version, Mac model and chip, RAM, language, number of displays, permission states (Accessibility, Screen Recording, Calendar), a few non-identifying settings (counts, not lists), tray placement, and the last ~150 lines of the debug log. **Not included:** window titles, your pinned apps, folders, calendar data, files or credentials. Your home folder, user name, Mac name and any e-mail addresses are replaced (`~`, `<user>`, `<host>`, `<email>`) before the text is shown or sent.
- **Crashes:** macOS writes a crash report when an app crashes. The next time Cala starts it looks for a new `Cala-*.ips` in `~/Library/Logs/DiagnosticReports` (the first run only records the date, so old reports are never offered) and, depending on Settings → Avanzado → "Si Cala se cierra sola", **asks** (default: shows what would be sent, you can cancel), sends **without asking**, or **never**. The crash window needs no typing: the comment and e-mail fields are visible but marked optional ("Opcional: ayúdanos con más contexto — puedes dejar todo en blanco"), and the report already carries the crash plus **what Cala was doing just before it** (the log lines up to the crash time, in `diagnostics.txt` and in Sentry's "activity_before_crash" context). The crash report is redacted the same way and capped at 150 KB. It is also parsed (`CrashSummary.swift`): the exception type and signal, the termination reason and the crashing thread's frames are sent as a proper Sentry exception, and the issue is grouped by cause (crash type plus the innermost Cala frames), so different crashes become different issues instead of one lump. Swift symbols are in the report because the release build is not stripped.
- **Where it goes:** a Sentry project, over its HTTP envelope API (no SDK, no background activity; nothing is sent without pressing Enviar or choosing "Enviar sin preguntar"). The DSN is not in the repository: `CALA_SENTRY_DSN=https://… ./install.sh` (or `./build.sh`) writes it into the app's Info.plist (`CalaSentryDSN`). Without it the window opens but Enviar stays disabled and says sending is not enabled in that build. In the Sentry project enable **"Prevent Storing of IP Addresses"** so that the sender's IP is not kept.

## Cala's own windows on the bar
While Settings, "Reportar un problema" or "Limpiar espacio" is open, **Cala** appears on the bar with its icon and the usual running indicator, so a window hidden behind others is never forgotten. Clicking it brings the window forward (or minimizes it if it is the only one and already in front), hovering shows previews, and it disappears when the last window closes. Only real windows count, not the bar or its panels. It cannot be pinned.

## Automatic relaunch after a crash
Cala reopens itself within a couple of seconds if it crashes or is force-quit (Settings → Avanzado → "Volver a abrir Cala si se cierra sola", on by default). A crashed process cannot restart itself, so at launch Cala starts a tiny detached shell script (`~/Library/Application Support/Cala/watchdog.sh`) that watches its pid. A normal quit (Salir de Cala, logout, shutdown, the installer) writes a `clean-exit-<pid>` marker first, and then the script does nothing; without the marker it opens Cala again. It gives up after 3 relaunches in 2 minutes (`relaunch-times`), so a crash at startup cannot loop forever. Switching the setting off writes a `no-relaunch` file that the running script respects. After an abnormal end, the next launch also keeps looking for the crash report for up to 90 s (macOS writes it a few seconds after the crash) so the "Ver y enviar…" prompt still appears. Force quit counts as abnormal: if you really want Cala gone, use "Salir de Cala".

## "Recomendamos reiniciar"
Restart advice appears in a separate **Mantenimiento** row when a reason applies. The row summarizes the leading reason, shows a count of additional reasons when applicable and marks strong advice with an orange dot on the row and the tray gauge. It opens **Por qué conviene reiniciar**, with the reasons, **Revisado y está bien**, and actions to restart with confirmation or open Software Update as appropriate. **Más tarde** hides the advice for three days unless memory pressure becomes critical. Settings → Avanzado → **Recomendar reiniciar el Mac** turns it off.

When the reasons need more space, they scroll within the page. **N motivos más ↓** indicates reasons below the visible area. The action buttons stay in view, with any Finder permission message fixed above them.

Reasons include a pending macOS update that requires a restart, 14+ days of uptime (strong at 30), swap at or above the greater of 4 GiB and 25% of RAM with 3+ days of uptime, compressed memory at or above 35% with 3+ days of uptime, 10+ minutes of elevated memory pressure, and under 15% free disk space with 4+ GiB of allocated swap.

## Guidance in the system panel
The panel shows one message at a time. Higher severity wins. At the same severity, memory comes first, then heat, then CPU. A short CPU spike or Low Power Mode can show a neutral note.

- **Todo bien.** A CPU spike can show as busy before it reaches two minutes. High memory pressure under two minutes can show as **Justa** with a neutral status.
- **Revisa esto** (amber). CPU at or above 75% on the smoothed reading for two minutes, high memory pressure for two minutes, serious thermal state, or a critical memory or thermal reading that has yet to reach the red threshold.
- **Actúa ahora** (red). Memory pressure that stays critical for at least one minute or a thermal state that stays critical for at least two minutes. Sustained CPU load stays amber. The tray gauge uses the same severity.

For sustained CPU load, the message distinguishes how long the Mac has been busy from which group leads in the latest valid reading. A group is singled out when it accounts for at least 10 percentage points and a quarter of the total, provided less than half of the load is unattributed. While sustained CPU guidance is waiting for a valid reading, its card shows a loading placeholder. If at least half the load is unattributed, Cala says it could come from macOS or another account and suggests waiting a few minutes, then opening **Monitor de Actividad** if it persists. When the load is attributable but no group meets the threshold, the message describes it as spread across processes.

The panel’s **Cerrar** button is available for a single eligible app instance and asks for confirmation. For a standalone tool with a known launcher, **Ir a** brings that app forward. Memory guidance prefers the largest eligible app and shows its footprint.

## Checking the system panel
From the repository root, run `scripts/check-rules.sh` to check the rules with `swiftc`. To render the sample panels in light and dark mode, build and run the debug executable:

```sh
swift build && .build/debug/Cala --render-system "$TMPDIR/cala-system" -AppleLanguages '(es)'
```

Use `'(en)'` for English. To open the live panel in a running Cala instance, use `notifyutil -p local.cala.openSystemPanel`.

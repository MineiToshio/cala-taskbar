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
- Open (if not running), Pin/Unpin, Show in Finder, Close all windows, Quit.

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
- The feature defaults on, but requests full calendar access only when you open the clock flyout or the Calendar settings section while enabled. Nothing is requested at launch. Denied/restricted access displays an inline message and a Privacy Settings button.
- Events are grouped by Today, Tomorrow and weekday/date. Rows show the calendar color, title, time range or All day, and a short location. Current timed events are marked **Now** and the next timed event **Next**. A bounded scrolling list keeps the month visible (at most about eight rows, fewer on smaller screens).
- **Join** opens Meet, Zoom/ZoomGov, Teams (including personal Teams) or Webex links found in the event URL, location or notes. Clicking the event tries Calendar’s event URL, with a plain Calendar.app fallback; selecting the exact event is best effort because this URL is undocumented. No AppleScript or event export is used.
- Events refresh on EventKit changes, app activation, when opening the pane and every minute while the list is visible. Disabled or excluded calendars are not queried. Newly added calendars are included by default. No calendar indicator or notifications are added to the tray.
- Cala only reads calendars, keeps event snapshots in memory, and neither logs nor caches event content. Internet Accounts handles account credentials and synchronization; macOS’s full-access permission is required to read events, though this feature never writes them.

The calendar flyout chooses Spanish when the first preferred language is Spanish, otherwise English; dates and times use the current locale. Shared permission messages follow this choice too.

# Configuration

In Settings, use **General** for the four module switches, language, login and the shared theme. **Zones**, **Taskbar**, **Window switcher** and **Tray** hold their own settings. **Mail**, **Calendar**, **Claude & Codex**, **Permissions** and **Help and diagnostics** sit in the same sidebar. These destinations stay available when modules are off. In **Tray**, drag items within or between **In the bar**, **In More** and **Hidden**. Use the gear for item settings, including CPU and memory and Disk.

File: `~/Library/Application Support/Cala/config.json`. Created on first run and saved automatically whenever something changes in the Settings window or the quick menu. Saves use atomic replacement. Missing or mistyped keys fall back individually to defaults, so valid settings survive a bad field. The bar's numeric settings are clamped to the ranges below; the Dock backup values are never clamped. A file that cannot be decoded is preserved as `config.json.bad` when possible and defaults are used; if preservation fails, saving is disabled for that run to protect the original. Normally you never edit it by hand (Settings → Help and diagnostics → Advanced options → Configuration file); if you do, restart the bar afterwards.

| Key | Type | Default | Meaning |
|---|---|---|---|
| `pinned` | array of bundle IDs | Finder, Safari, System Settings (`com.apple.finder`, `com.apple.Safari`, `com.apple.systempreferences`) | Pinned apps (any not installed are skipped) |
| `order` | array of ids | `[]` | Custom icon order set by dragging (ids not listed keep their natural place) |
| `autoHide` | bool | `true` | Hide the bar until the mouse touches the bottom edge |
| `iconSize` | number | `28` | Icon size in points, 20–44 (bar height = size + 20) |
| `previewDelay` | seconds | `0.05` | Hover time before a preview appears (0–0.6) |
| `previewWidth` | number | `420` | Thumbnail width, 300–560 |
| `alignments` | object | `{}` | Display UUID → `"left"` or `"center"`. Screens not listed use left |
| `theme` | string | `"system"` | `system`, `graphite`, `midnight`, `ocean`, `sunset`, `forest`, `lavender`, `candy`, `snow` |
| `menuBarHiddenIcons` | array of ids | `[]` | macOS menu bar icons to hide: `wifi`, `battery`, `user`, `input` |
| `menuBarIconBackupV2` | object | `{}` | Original per-host value of each hidden icon (a number, or `"nil"` when the key did not exist), restored verbatim |
| `restartAdvice` | bool | `true` | Show "Recomendamos reiniciar" with its reasons in the system panel |
| `relaunchOnCrash` | bool | `true` | Open Cala again by itself if it crashes or is force-quit (gives up after 3 relaunches in 2 minutes) |
| `crashReports` | string | `"ask"` | What to do when Cala crashed last time: `ask`, `auto` (send without asking) or `never` |
| `hideMenuBar` | bool | `false` | Auto-hide the macOS menu bar everywhere while Cala runs |
| `restoreMenuBarOnQuit` | bool | `true` | Give the menu bar back when Cala quits |
| `menuBarBackup*` | various | — | Original menu bar auto-hide values, restored verbatim (like the Dock backup) |
| `trayLayout` | object | `{}` | Tray item id → `"bar"`, `"more"` (behind ^) or `"hidden"`; missing ids use their default |
| `trayOrder` | array of ids | `[]` | Left-to-right order of the tray items (ids not listed keep their default place) |
| `monitorEnabled` | bool | `true` | Show the CPU gauge and system panel in the tray |
| `monitorBarMetric` | string | `"cpu"` | What the CPU and memory tray item shows while all is well: `"cpu"` or `"memory"` (a problem always wins) |
| `mailLoadsRemoteImages` | bool | `true` | Load remote images in emails (the sender can tell the message was opened) |
| `diskEnabled` | bool | `true` | Show free disk space in the tray |
| `diskFolders` | array of paths | `[]` | Extra folders measured in the storage panel (`~` allowed) |
| `barOpacity` | number | `1` | Bar background opacity (1 = solid, 0.2 = very transparent) |
| `hideNativeDock` | bool | `false` | Keep the macOS Dock hidden while the bar runs |
| `switcherEnabled` | bool | `true` | The Switcher module (Option+Tab). Off: no event tap at all, and Cmd+M interception goes with it |
| `switcherReplaceCmdTab` | bool | `false` | Also take over Cmd+Tab |
| `restoreDockOnQuit` | bool | `true` | Give the Dock back when the bar quits |
| `dockBackupSaved`, `dockBackupAutohide`, `dockBackupDelay` | internal | | Original Dock values, used to restore it exactly. Do not edit |

Example:
```json
{
  "alignments": { "793B322E-9748-43CF-8A63-BA18283C7D7F": "center" },
  "autoHide": true,
  "barOpacity": 0.82,
  "iconSize": 36,
  "pinned": ["com.apple.finder", "com.google.Chrome", "com.apple.Terminal"],
  "previewDelay": 0.05,
  "previewWidth": 420,
  "theme": "midnight"
}
```

Find an app's bundle ID: `osascript -e 'id of app "Notes"'`.

Not in `config.json`: the login item lives in System Settings → General → Login Items (SMAppService), and the welcome state in the app's UserDefaults (domain `local.cala`): `onboardingCompleted` (written when the "What do you want to use?" answer is saved, or for an upgrade) and `onboardingPending` (a first-run welcome was shown and not answered yet; cleared when it is).

The module keys and the Zones keys are in [Modules and Zones](#modules-and-zones) below.

## Modules and Zones

| Key | Type | Default | Meaning |
|---|---|---|---|
| `modulesChosen` | bool | `false` | The module keys below are final. `false` means Cala has not decided yet: an existing user is migrated (Bar, Tray and Switcher on as stored, Zones off) and a first-run user sees the welcome's "What do you want to use?" and nothing runs meanwhile |
| `barEnabled` | bool | `true` | Bar module. Off: no bar, no reserved space, the macOS Dock and menu bar left alone, status item in the menu bar |
| `trayEnabled` | bool | `true` | Tray module. Only effective while the Bar is on (the stored value is kept) |
| `switcherEnabled` | bool | `true` | Switcher module (see the main table) |
| `zonesEnabled` | bool | `false` | Zones module. Off: no event tap, no zones, `zones.json` is not read |
| `zonesActivation` | string | `"both"` | How zones mode starts during a window drag: `rightClick`, `shift` or `both`. Any other value becomes `both` |
| `zonesGap` | number | `8` | Space in points left around each snapped window, 0–40 (clamped; a non-number becomes 8) |
| `zonesEditorGrid` | bool | `false` | The zones editor snaps to a 12-division grid as well |
| `zonesLayoutStrip` | bool | `true` | During a zones drag, show the monitor's layouts in a strip at the top; hovering one for about 0.35 s switches that monitor's layout |
| `zonesEditorLinked` | bool | — | Retired. Earlier versions stored the editor's Linked/Free choice here; it is now stored per layout in `zones.json` (`mode`). An old value is ignored and dropped on the next save |

The effective set is computed from these: the tray runs only if the bar does. The welcome's answer writes `modulesChosen` and the four module keys; the migration of an existing user writes them too. No existing key was renamed.

The zones themselves (layouts, per-monitor assignment) are not in `config.json`: they live in `~/Library/Application Support/Cala/zones.json`, described in [zones.md](zones.md#storage-zonesjson). A zones file that cannot be decoded is kept as `zones.json.bad` and the templates are seeded again.

## Usage settings

| Key | Type | Default | Meaning |
|---|---|---|---|
| `usageEnabled` | bool | `true` | Master tray usage indicator switch |
| `usageClaudeEnabled` | bool | `true` | Show Claude when detected and signed in |
| `usageCodexEnabled` | bool | `true` | Show Codex when detected and signed in |
| `usageClaudeConfigDir` | string | `""` | Optional Claude config folder; `~` expands to the current user's home |
| `usageCodexHome` | string | `""` | Optional Codex home folder |
| `usageAlertsEnabled` | bool | `true` | Notify when a quota is low or projected to run out before it resets |
| `usageAlertThreshold` | number | `20` | Remaining percentage that triggers the low-quota notification (10, 15, 20 or 30) |
| `usageClaudeStatusLine` | bool | `false` | Opt in to Claude Code local statusLine updates |

Missing/mistyped fields independently use their defaults. Folder drafts apply on submit, focus loss or leaving the pane, rather than on each keystroke. Empty folder fields use the login shell's `CLAUDE_CONFIG_DIR` / `CODEX_HOME`, then standard home folders. Credentials remain owned by the CLI/app; sign in there. Settings reports detection and expired-session status without displaying secrets.

The statusLine option creates `~/Library/Application Support/Cala/claude-statusline.sh` and `claude-usage.json`. The Claude config folder must already exist. Before the first edit of an existing `settings.json`, Cala creates `settings.json.mactaskbar.bak` only if absent; an existing backup is never overwritten, including one created by an older app version. Unrelated keys are preserved; key order can change on an actual edit, while slashes remain unescaped. An already-owned statusLine causes no settings or backup write on launch. An existing statusLine is never overwritten. Settings instead shows a command to integrate into the existing script, with its original stdin JSON stored in `input`. Disable removes only the Cala-owned entry. `usage-cache.json` contains readings and rate-limit cooldowns, never tokens.

## Calendar settings

| Key | Type | Default | Meaning |
|---|---|---|---|
| `calendarJoinEnabled` | bool | `true` | Show the Join button in the bar for meetings with a video link, from 5 minutes before the start |
| `calendarEnabled` | bool | `true` | Show upcoming events in the clock flyout; permission is requested only when opening that flyout or Calendar settings while enabled |
| `calendarDays` | integer | `7` | Upcoming rolling range in local calendar days: 1, 3, 7 or 14; other values recover to 7 |
| `calendarExcludedIDs` | array of strings | `[]` | EventKit calendar identifiers to exclude; new calendars are included automatically |

Fields decode independently: malformed calendar settings do not reset other valid settings. The configuration stores only calendar exclusions and display preferences, not events or account credentials. Use Settings → Calendar to select accounts’ calendars. Add or sign in to accounts manually in System Settings → Internet Accounts, and enable Calendars for each account.


### `language`
Interface language: `"system"` (default, follows the first preferred language of macOS; Spanish if it is Spanish, English otherwise), `"en"` or `"es"`. Set in Settings → General → Language. Most texts switch at once; menus and tray names built at launch switch after reopening Cala.

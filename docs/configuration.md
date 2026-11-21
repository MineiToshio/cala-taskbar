# Configuration

File: `~/Library/Application Support/Cala/config.json`. Created on first run and saved automatically whenever something changes in the Settings window or the quick menu. Saves use atomic replacement. Missing or mistyped keys fall back individually to defaults, so valid settings survive a bad field. The bar's numeric settings are clamped to the ranges below; the Dock backup values are never clamped. A file that cannot be decoded is preserved as `config.json.bad` when possible and defaults are used; if preservation fails, saving is disabled for that run to protect the original. Normally you never edit it by hand (Settings → Advanced → "Abrir"); if you do, restart the bar afterwards.

| Key | Type | Default | Meaning |
|---|---|---|---|
| `pinned` | array of bundle IDs | Finder, Chrome, Zed, Slack, Spotify | Pinned apps |
| `order` | array of ids | `[]` | Custom icon order set by dragging (ids not listed keep their natural place) |
| `autoHide` | bool | `true` | Hide the bar until the mouse touches the bottom edge |
| `iconSize` | number | `28` | Icon size in points, 20–44 (bar height = size + 20) |
| `previewDelay` | seconds | `0.05` | Hover time before a preview appears (0–0.6) |
| `previewWidth` | number | `420` | Thumbnail width, 300–560 |
| `alignments` | object | `{}` | Display UUID → `"left"` or `"center"`. Screens not listed use left |
| `theme` | string | `"system"` | `system`, `graphite`, `midnight`, `ocean`, `sunset`, `forest`, `lavender`, `candy`, `snow` |
| `diskEnabled` | bool | `true` | Show free disk space in the tray |
| `diskFolders` | array of paths | `[]` | Extra folders measured in the storage panel (`~` allowed) |
| `barOpacity` | number | `1` | Bar background opacity (1 = solid, 0.2 = very transparent) |
| `hideNativeDock` | bool | `false` | Keep the macOS Dock hidden while the bar runs |
| `switcherEnabled` | bool | `true` | Option+Tab window switcher |
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

Not in `config.json`: the login item is the LaunchAgent file `~/Library/LaunchAgents/local.cala.plist`, created and removed by the "Abrir al iniciar sesión" switch.

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

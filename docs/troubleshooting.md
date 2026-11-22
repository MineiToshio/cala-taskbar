# Troubleshooting and known limits

## Quick checks
- Is it running? `pgrep Cala`
- Crash reports: `~/Library/Logs/DiagnosticReports/Cala-*.ips`
- Debug log: `~/Library/Application Support/Cala/debug.log` (one rotated backup, `debug.log.1`; window titles are not logged)

## Problems
| Symptom | Cause / fix |
|---|---|
| "Falta el permiso de Accesibilidad" even after granting | Stale grant after a signature change. Run the `tccutil reset` commands in [setup.md](setup.md), relaunch, grant again |
| Previews show an icon instead of a thumbnail | Screen Recording not granted, or the window was minimized before the bar started (no thumbnail was ever taken) |
| App crashes on launch | A privacy usage key is missing from `Info.plist` (check `build.sh`). The crash report names the key |
| Wi-Fi panel has no network names | Location Services not granted |
| No badge on an icon | The Dock must be running (it can be hidden). Badge key is the Dock item title or bundle path |
| Close (X) does nothing in a preview | The window is not visible to Accessibility (ghost). See Notes below |
| Native Dock shows again | Dock settings were reset (e.g. after a macOS update). Toggle Settings → General → Hide the macOS Dock off/on, or quit and launch a fresh process. Reopening an already-running instance only shows Settings |
| Show desktop leaves a window | Full-screen windows and windows on other Spaces can reject minimization; failed restores remain pending for another attempt |
| Peek does nothing | The window is minimized, on another Space, or Accessibility is not granted |
| Option+Tab does nothing | Accessibility not granted yet (the tap is created within 3 s of granting) or the switcher is off in Settings → General |
| I quit the bar by accident | Open "Cala" from Spotlight or Launchpad; reopening a running app opens Settings |
| Previews from another tool still appear | A previously started copy keeps running after deleting the app. Quit it, or log out / reboot (other user sessions need their own logout) |
| Two bars overlap or one is missing after plugging a screen | Bars are rebuilt 0.4 s after a screen change. Quit and reopen if it does not settle |

An unreadable or malformed configuration is preserved as `~/Library/Application Support/Cala/config.json.bad` when possible, and the app uses defaults. Mistyped individual fields use their defaults while valid fields are retained; the bar's numeric settings are clamped (the saved original Dock values are never altered). Check `config:` log entries before recovering the backup. If the invalid file cannot be preserved, saving is disabled for that run so the original is not overwritten.

## Known limits
- **Third-party menu bar icons** cannot be moved into the taskbar. Auto-hide the menu bar instead.
- **Notes (and similar apps)** keep invisible windows of closed notes. They are filtered out: windows macOS does not report are not listed unless the app is hidden. A real window on another Space that Accessibility does not report will not appear in the preview.
- **Space reservation** is an approximation (it shrinks the active window), only on the primary screen and only with auto-hide off. Windows that reject the requested height are skipped until the app restarts.
- **Notifications** from other apps cannot be read by macOS apps, so the clock panel only links to the notification settings.
- **Peek** raises the real window (it is not a Windows-style overlay) and briefly activates its app. Leaving brings the previous app forward through Accessibility (AXFrontmost) and raises its saved window; apps that ignore those requests may not get focus back exactly.
- **Switching users** uses PRIVATE login.framework (`SACSwitchToUser`) and SkyLight (`SLSCopySessionList`), which may break in any macOS update. It works with or without an existing target session. `SLSSessionSwitch*` is blocked for non-Apple callers and is not used.
- **Low Power Mode** needs the administrator password on every change.
- **Brightness** is shown only when `DisplayServices` reports it for the main display.
- Bluetooth, brightness and the "show Dock badges" feature use **private macOS APIs / the Dock's AX tree**; a macOS update can break them.
- Chrome "New window" does not open the profile picker (same behavior as the tool it replaces). The picker can be opened with `open -a "Google Chrome" "chrome://profile-picker"`.
- Tray panels and previews show the hand cursor over their whole area, because non-key panels cannot report which control is under the mouse.

## Fast User Switching
Cala passes a validated OpenDirectory record dictionary (`dsAttrTypeStandard:*` keys with array values, including the target short name in RecordName[0]) to `SACSwitchToUser`. Return 0 only acknowledges receipt by loginwindow; switching happens asynchronously. Cala polls its original session's `kCGSSessionOnConsoleKey` through SkyLight every 0.25 s for up to about 3 s. Repeated clicks are ignored while the switch is pending. Any preparation, API or verification failure produces one lock-screen fallback (Ctrl+Cmd+Q). Success is sticky for each attempt; the main-queue fallback rechecks the attempt and success state. A continuous monotonic clock measures the timeout, including suspension: verification delayed beyond 6 s is logged as unknown, probably switched, and does not lock the screen.

Check `switch user:` entries in `~/Library/Application Support/Cala/debug.log` for the return code, elapsed switch time or fallback reason. To check which user SecurityAgent loaded and focused after an owner-initiated switch:

```sh
log show --predicate 'process == "SecurityAgent"' | grep -E "Loaded user|focusing"
```

An acknowledgement alone does not prove that the selected user's login screen appeared; the console check verifies that the original session left the console, and SecurityAgent's log identifies the selected user.

## AI usage indicator
- **No glyph:** check Settings → Usage, the master/provider toggles and detection status. Install Claude Code (CLI or app) and sign in there (`claude`, then `/login`); for Codex, install the CLI or app and sign in with ChatGPT. The tray stays empty for unavailable providers.
- **`n/a`:** the provider may be offline, timed out, signed in with an unsupported account, or returning a changed private schema. Last good data stays visible when available. Only returned windows appear; no 5-hour row can be normal for a plan.
- **Rate-limited:** wait for the displayed retry countdown. Refresh is disabled throughout cooldown; repeated requests are coalesced. Restarting retains the cooldown. Backoff starts at 60 seconds and grows to 30 minutes.
- **Session expired:** open Claude Code or Codex to refresh its own session. Cala never refreshes or writes tokens. Claude credentials are reread on the next attempt; a 401 gets only one reread/retry.
- **Custom folders:** set Claude config dir / Codex home in Settings, or export `CLAUDE_CONFIG_DIR` / `CODEX_HOME` in your login-shell setup. Shell variables are read once per launch. Settings folder overrides update live. Claude's Keychain service includes a directory hash when an explicit directory is used.
- **Old reading:** “Updated … ago” is the source reading age. Revealing the bar or opening the flyout revalidates after 120 seconds for Claude / 60 for Codex. Manual Refresh bypasses age and error-backoff limits with a 15-second floor after failures. A final Claude 401 remains blocked until its credential expiry value or token fingerprint changes. Other failures back off automatically from 120 seconds to 30 minutes. Hidden bars do not poll the APIs. Local Codex log events and optional Claude statusLine events can update readings without network calls.
- **statusLine conflict:** Cala preserves your existing command. Follow the command shown in Settings, feeding it your script's original stdin JSON. New sessions may be needed after a settings change. The first preserved settings backup is `settings.json.mactaskbar.bak` in your Claude config folder. Existing backups are never overwritten; a backup left by an older app version may already contain that version’s edits. Claude config folders must already exist, and folder fields apply on submit/focus loss. An already-owned statusLine causes no rewrite on launch.

Inspect `~/Library/Application Support/Cala/debug.log` for `usage:` lines: provider, fetch status (0 for transport/process failure), elapsed milliseconds, cooldown seconds and outcome. These lines contain no tokens, emails or account IDs. A valid response with an unknown schema shows `n/a` even if its status is 200. Do not paste credential files into bug reports.

## Calendar events
- **Permission denied / write-only:** open Settings → Privacy & Security → Calendars (also linked from the flyout) and grant Cala full access. Write-only access cannot read upcoming events. Return to the app or reopen the calendar pane to refresh. A managed/restricted Mac may require an administrator to change the policy; Cala cannot bypass it.
- **An added Google/iCloud/Exchange account or calendar is missing:** enable the **Calendars** toggle for that account in System Settings → Internet Accounts, and verify that its events appear in Apple Calendar. The Calendar settings section’s Add account button opens Internet Accounts directly; sign-in is manual. Allow macOS to finish synchronization, then reopen the pane. Cala only sees calendars available through EventKit on this Mac.
- **A calendar is visible but events are missing:** ensure its checkbox is selected in Settings → Calendar and try the 14-day range. Past/ended and canceled events are omitted. Ongoing and all-day events that overlap the range are included. Excluding every calendar intentionally gives “No upcoming events”.
- **No Join button:** it is shown only for HTTP(S) Meet, Zoom/ZoomGov (including their subdomains), Teams (`teams.microsoft.com` / `teams.live.com`) and Webex (`*.webex.com`) meeting links in the event URL, location or notes. Other links and non-web schemes are not opened as meeting links.
- **An event click opens Calendar without selecting it:** specific-event links use an undocumented `ical://ekevent/…` route and may change between macOS releases. The safe fallback opens Calendar.app; navigate to the event’s displayed date. No AppleScript or duplicate event files are created.
- **Privacy / distribution:** every user grants their own calendar permission. `build.sh` supplies `NSCalendarsFullAccessUsageDescription` and the legacy `NSCalendarsUsageDescription`. Use the built, signed app bundle; a raw executable lacks its privacy descriptions. Disabling upcoming events stops reads and clears in-memory snapshots. Cala does not store event content, transmit it, or handle your calendar account passwords.


## "Cala can't be opened" / "Apple could not verify Cala"
That is Gatekeeper on a build that is not signed with Developer ID and notarized (an ad-hoc test build). Official releases made with `scripts/release.sh` do not show it. For a test build, unblock it once: macOS 15+ → System Settings → Privacy & Security → **Open Anyway**; macOS 14 → right-click → Open. See the README. It never shows on the Mac that built the app, so check releases on another Mac.

## Cala froze at first launch (older builds)
Builds before commit 3018657 could hang on a Mac where the Bluetooth permission had not been decided yet. Update to a current build.

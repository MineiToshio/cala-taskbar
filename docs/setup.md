# Setup

## Build and install
```bash
cd /Users/Shared/Proyectos/mac-launcher
./install.sh          # build.sh, then install into ~/Applications and launch
```
`./install.sh` runs `./build.sh` (swift build -c release, bundle, ad-hoc sign), quits the running app, replaces `~/Applications/Cala.app` with `ditto`, strips group/other write (`chmod -R go-w`), checks `codesign --verify`, points the login LaunchAgent at the installed bundle (only if the path differs; the plist is kept at mode 644) and opens the app. It does not reload the LaunchAgent with `launchctl`: the job has `RunAtLoad`, so a reload would run `open -a` against the running instance and pop up its Settings window. launchd reads the updated plist at the next login.

`./build.sh` alone only produces `build/Cala.app`, which is the build output, not the copy you should run.

Relaunch the installed app without rebuilding:
```bash
pkill -x Cala; open ~/Applications/Cala.app
```
After a code change, run `./install.sh` again.

## Installation security
**SECURITY:** Run the app from `~/Applications`, which only your user can write (`install.sh` keeps it free of group/other write). `/Users/Shared` is group-writable, so another user could swap a bundle there and inherit its Accessibility / Screen Recording grants. `build.sh` strips group/other write access from the bundle with `chmod -R go-w "$APP"`, but that does not protect a bundle from replacement through a writable parent folder. The repository's `build/Cala.app` is only a build output: do not grant permissions to it or launch it at login.

**Re-grant after moving to a new path:** macOS ties Accessibility / Screen Recording grants to the app's path and signature. The first time you run the copy in `~/Applications`, the Permissions pane may report missing grants; add `~/Applications/Cala.app` in System Settings > Privacy & Security (and remove the old `build/` entry). If a grant looks on but does not work, reset it with the `tccutil` commands below and grant it again.

## Permissions (System Settings > Privacy & Security)
| Permission | Needed for |
|---|---|
| Accessibility | Window lists, raise/close/minimize, menu reading, badges |
| Screen & System Audio Recording | Window thumbnails |
| Location Services | Reading Wi-Fi network names |
| Bluetooth | Showing and connecting devices |
| Calendars (full access) | Upcoming events in the clock flyout; asked only when you open the clock flyout or Settings → Calendar, never at launch. Not listed in the Permissions pane |

If Cala is missing from a list, use `+` and press Cmd+Shift+G to type the path `~/Applications/Cala.app`.

If a grant gets stuck after a signature change:
```bash
tccutil reset Accessibility local.cala
tccutil reset ScreenCapture local.cala
```

## Recommended system settings
1. **Hide the macOS Dock:** Settings → General → "Hide the macOS Dock". The app does it for you (see [features.md](features.md)); it keeps the Dock running because the bar reads badges from it. Manual alternative:
   ```bash
   defaults write com.apple.dock autohide -bool true && defaults write com.apple.dock autohide-delay -float 1000 && killall Dock
   ```
   A major macOS update may reset the setting; toggle the setting off/on or quit and start a fresh process to re-apply it. Reopening a running instance only opens Settings.
2. **Hide the menu bar (by hand, the app never touches it):** System Settings > Desktop & Dock > Menu Bar > "Automatically hide and show" = Always. Third-party menu bar icons cannot be moved into the taskbar (macOS does not allow it), so they only appear when the mouse goes to the top.
3. **Uninstall DockDoor** if present: `brew uninstall --cask dockdoor`. Quit the running process first; deleting the app does not stop a copy already in memory. Other user sessions keep their own copy until they log out or the machine restarts.

The **Permissions** pane in the Settings window shows which grants are missing and opens the right page.

## Start at login
Settings → General → "Abrir al iniciar sesión" creates (or deletes) the LaunchAgent `~/Library/LaunchAgents/local.cala.plist`, which runs `/usr/bin/open -a <path of the running app>` at login. It is per user. `./install.sh` points it at `~/Applications/Cala.app`; if you move the app yourself, switch it off and on again.

Manual install or reinstall:
```bash
launchctl bootout gui/$(id -u)/local.cala 2>/dev/null
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.cala.plist
```
There is no KeepAlive on purpose: Quit must stay quit, and `pkill` during development must not spawn duplicates.

## Other user profiles
Each macOS user needs their own permissions, Dock command and LaunchAgent. The `config.json` is per user too.

## Crash and feedback reporting (optional)
To let a build send reports to your Sentry project, pass its DSN when building: `CALA_SENTRY_DSN='https://<key>@<host>/<project>' ./install.sh`. The DSN goes into the bundle's Info.plist (`CalaSentryDSN`) and is not stored in the repository. Without it the report window still opens and offers Copiar / Guardar…

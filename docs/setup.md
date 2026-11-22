# Setup (developers)

End users install from the disk image: see the [README](../README.md). Release signing and notarization: [release.md](release.md).

## Build and install
```bash
cd cala-taskbar          # wherever you cloned the repository
./install.sh          # build.sh, then install into ~/Applications and launch
```
`./install.sh` runs `./build.sh` (swift build -c release, bundle, ad-hoc sign), quits the running app, replaces `~/Applications/Cala.app` with `ditto`, strips group/other write (`chmod -R go-w`), checks `codesign --verify` and opens the app. Open-at-login is handled by the app itself (SMAppService).

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
The first launch shows a welcome that asks for each permission with its reason and a button to the exact pane; status updates live (PermissionCenter, `Sources/Cala/Permissions.swift`). Nothing is requested at launch after that: every optional permission is also asked the first time its feature is used. Settings → Permissions lists all seven (Accessibility, Screen Recording, Calendar, Location, Bluetooth, Finder automation, Notifications).

To test the welcome from scratch:
```bash
pkill -x Cala
tccutil reset All local.cala                     # only Cala's grants
defaults delete local.cala                       # onboarding flag, crash bookkeeping
mv "$HOME/Library/Application Support/Cala" "$HOME/Library/Application Support/Cala.bak"
open ~/Applications/Cala.app
```

## Recommended system settings
1. **Hide the macOS Dock:** Settings → General → "Hide the macOS Dock". The app does it for you (see [features.md](features.md)); it keeps the Dock running because the bar reads badges from it. Manual alternative:
   ```bash
   defaults write com.apple.dock autohide -bool true && defaults write com.apple.dock autohide-delay -float 1000 && killall Dock
   ```
   A major macOS update may reset the setting; toggle the setting off/on or quit and start a fresh process to re-apply it. Reopening a running instance only opens Settings.
2. **Hide the menu bar:** Settings → General → "Hide the whole menu bar" (restored exactly when turned off or on quit), or by hand in System Settings > Desktop & Dock > Menu Bar. Third-party menu bar icons cannot be moved into the taskbar (macOS does not allow it), so they only appear when the mouse goes to the top.
3. **Uninstall DockDoor** if present: `brew uninstall --cask dockdoor`. Quit the running process first; deleting the app does not stop a copy already in memory. Other user sessions keep their own copy until they log out or the machine restarts.

The **Permissions** pane in the Settings window shows which grants are missing and opens the right page.

## Start at login
Settings → General → "Open at login" (and the last step of the welcome) registers the app with `SMAppService.mainApp`, so it appears in System Settings → General → Login Items, where the user can also switch it off (Cala then shows a button to that pane). Older builds used a LaunchAgent (`~/Library/LaunchAgents/local.cala.plist`); the app deletes it once and registers the login item instead, if it was installed in Applications.

## Other user profiles
Each macOS user needs their own permissions and login item. The `config.json` is per user too.

## Crash and feedback reporting (optional)
To let a build send reports to your Sentry project, pass its DSN when building: `CALA_SENTRY_DSN='https://<key>@<host>/<project>' ./install.sh`. The DSN goes into the bundle's Info.plist (`CalaSentryDSN`) and is not stored in the repository. Without it the report window still opens but Enviar stays disabled

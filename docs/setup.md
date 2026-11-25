# Setup (developers)

End users install from the disk image: see the [README](../README.md). Release signing and notarization: [release.md](release.md).

## Build and install
```bash
cd cala-taskbar          # wherever you cloned the repository
./install.sh             # build, install into /Applications and launch
```
Run `./install.sh` from your own account. It builds and ad-hoc signs Cala with its fixed designated requirement, then requests administrator access with `sudo` to stage the bundle with `ditto` in `/Applications`. The installer sets ownership to root:admin, removes inherited access controls and group/other write access, verifies the signature and publishes the bundle atomically. Only after publication does it stop Cala and the legacy LaunchAgents in your session. It opens the shared copy before removing your per-user copy. If a later step fails before Cala reopens, the installer tries the shared copy again and falls back to your old copy if needed.

`./build.sh` alone only produces `build/Cala.app`, which is the build output, not the copy you should run.

Relaunch the installed app without rebuilding:
```bash
pkill -u "$(id -u)" -x Cala
while pgrep -u "$(id -u)" -x Cala >/dev/null; do sleep 0.1; done
open /Applications/Cala.app
```
After a code change, run `./install.sh` again. The installer advances the build number above the installed version, even for rebuilds from the same commit. If you set `CALA_BUILD_NUMBER` explicitly, use a higher value for other sessions to detect the update.

## Installation security
**SECURITY.** Run `/Applications/Cala.app` from the shared `/Applications` directory (root:admin, writable by administrators). The app bundle has group/other write access removed. Another user could replace a bundle through a writable parent such as `/Users/Shared` and inherit its Accessibility or Screen Recording grants. Use the installed copy for permissions and login.

**Re-grant after moving.** macOS ties Accessibility and Screen Recording grants to the app’s path and signature. In each account, add `/Applications/Cala.app` in System Settings → Privacy & Security and remove the entry for the previous path. If a grant looks on but fails, reset it with the `tccutil` command below and grant it again.

## Permissions (System Settings > Privacy & Security)
The first launch shows a welcome that first asks "What do you want to use?" (Bar, Zones or both; nothing runs until you answer), then asks only for the permissions that choice needs (Bar: Accessibility and Screen Recording; Zones alone: Accessibility), each with its reason and a button to the exact pane; status updates live (PermissionCenter, `Sources/Cala/Permissions.swift`). Nothing is requested at launch after that: every optional permission is also asked the first time its feature is used. Settings → Permissions lists what the running modules need (Accessibility and Screen Recording for the Bar or the Switcher; Accessibility alone for Zones) and, while the Tray is on, the five optional ones (Calendar, Location, Bluetooth, Finder automation, Notifications). Input Monitoring is never requested.

To test the welcome from scratch:
```bash
pkill -u "$(id -u)" -x Cala
tccutil reset All local.cala                     # only Cala's grants
defaults delete local.cala                       # onboardingCompleted / onboardingPending, crash bookkeeping
mv "$HOME/Library/Application Support/Cala" "$HOME/Library/Application Support/Cala.bak"
open /Applications/Cala.app
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
Settings → General → **Open at login** (and the last step of the welcome) saves your preference and registers Cala with `SMAppService.mainApp`. Cala migrates the old LaunchAgent (`~/Library/LaunchAgents/local.cala.plist`) and uses your saved preference or previous registration to re-register after a move. If macOS needs approval, Cala links to System Settings → General → Login Items. If registration fails, the preference stays saved and Settings offers **Retry**. In an account whose older copy left no preference or visible registration, turn on **Open at login** if you want it.

## Other user profiles
All accounts can run the same `/Applications/Cala.app`. Each account grants permissions once for that path and keeps its own login item, `config.json` and `zones.json`.

In each account that previously installed Cala under its home folder, quit the old instance, then run:

```bash
rm -rf "$HOME/Applications/Cala.app"
open /Applications/Cala.app
```

Once an account is running the shared copy with update detection, Cala checks for a newer build when the session becomes active, when the Mac wakes and about every five minutes. Cala waits for a valid bundle with a stable build number and for the session to be active and idle. It defers while dragging, using Zones, editing Zones, working in Settings or going through onboarding. It then quits normally and opens the newer build in that session.

## Crash and feedback reporting (optional)
To let a build send reports to your Sentry project, pass its DSN when building: `CALA_SENTRY_DSN='https://<key>@<host>/<project>' ./install.sh`. The DSN goes into the bundle's Info.plist (`CalaSentryDSN`) and is not stored in the repository. Without it the report window still opens but Enviar stays disabled

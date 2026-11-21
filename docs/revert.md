# Reverting to the normal Dock

Everything is reversible. Do these in order.

## 1. Stop the taskbar
Settings → Advanced → "Salir…" (there is no Quit in the right-click menu). To open it again: Spotlight or Launchpad, search "MacTaskbar", or `open ~/Applications/MacTaskbar.app`.

## 2. Remove start at login
Settings → General → switch off "Abrir al iniciar sesión", or:
```bash
launchctl bootout gui/$(id -u)/local.mactaskbar && rm ~/Library/LaunchAgents/local.mactaskbar.plist
```
Then remove the installed app (after step 1, with the bar quit):
```bash
rm -rf ~/Applications/MacTaskbar.app
```

## 3. Bring the Dock back
**Easiest:** Settings → General → switch off "Hide the macOS Dock" (before quitting). It restores the exact previous values.

By hand:

**Original behavior (auto-hide, shows instantly on hover):** remove the 1000 s delay. System Settings has no control for this, it needs the command:
```bash
defaults delete com.apple.dock autohide-delay && killall Dock
```

**Always-visible Dock:** System Settings > Desktop & Dock > turn off "Automatically hide and show the Dock".

## 4. Menu bar
System Settings > Desktop & Dock > Menu Bar > "Automatically hide and show" = Never.

## 5. Optional cleanup
```bash
rm -rf "$HOME/Library/Application Support/MacTaskbar"      # config and debug log
tccutil reset Accessibility local.mactaskbar
tccutil reset ScreenCapture local.mactaskbar
tccutil reset Calendar local.mactaskbar
```
If you enabled the Claude Code statusLine (Settings → Usage), switch it off first: that removes only MacTaskbar's entry. The first backup of your Claude `settings.json` stays next to it as `settings.json.mactaskbar.bak`; delete it and `claude-statusline.sh` / `claude-usage.json` (inside the Application Support folder above) if you no longer want them.
The project folder (including `build/MacTaskbar.app`) can then be deleted.

## DockDoor
Removed with `brew uninstall --cask dockdoor`. To get it back: `brew install --cask dockdoor`.

## What the Dock switch does
Settings → General → **Hide the macOS Dock** turns on Dock auto-hide with a very long delay and restarts the Dock. Turning it off restores the exact previous values, kept in `config.json` (`dockBackup*`). If "Return the Dock when the bar quits" is on (default), quitting the bar also restores the Dock, and launching it again hides it again.

Normal Quit and SIGTERM run the Dock restore handler when that setting is enabled. A crash, force-quit or SIGKILL cannot run cleanup; if the Dock stays hidden, use the manual commands above.

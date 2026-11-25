# Reverting to the normal Dock

**Shortest way:** Settings → Help and diagnostics → Advanced options → **Uninstall Cala → Uninstall…** restores the saved Dock and menu bar, removes the current account’s login item, cleans up Cala’s Claude statusLine entry, deletes Cala’s settings and tries to move the app to the Trash. If Claude statusLine cleanup fails, the uninstaller stops and lets you retry. The shared bundle is used by all accounts. The standalone `scripts/uninstall.sh` handles local files and legacy LaunchAgents, attempts to move the installed copies to the Trash, and prints manual menu bar instructions. For the current login item and statusLine, use the controls below before running that script.

For manual removal, turn off **Open at login** in Settings → General and disable the Claude statusLine in Settings → Integrations → Claude & Codex before quitting. Removing the shared bundle affects every account.

## 1. Stop the taskbar
Settings → Help and diagnostics → Advanced options → Quit Cala → **Quit…** (there is no Quit in the bar's right-click menu; when the Bar is off or Zones is on, the Cala icon in the menu bar also has **Quit Cala**). To open it again: Spotlight or Launchpad, search "Cala", or `open /Applications/Cala.app`.

## 2. Remove start at login
If you skipped the login setting before quitting, disable Cala under System Settings → General → Login Items. Then remove the shared app with the bar quit:
```bash
sudo rm -rf /Applications/Cala.app
```

For a per-user installation, remove `~/Applications/Cala.app` instead.

## 3. Bring the Dock back
**Easiest:** Settings → Taskbar → switch off "Hide the macOS Dock" (before quitting). It restores the exact previous values.

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
rm -rf "$HOME/Library/Application Support/Cala"      # config and debug log
tccutil reset All local.cala                            # every permission Cala was given
```
If you enabled the Claude Code statusLine (Settings → Integrations → Claude & Codex), switch it off first: that removes only Cala's entry. The first backup of your Claude `settings.json` stays next to it as `settings.json.mactaskbar.bak`; delete it and `claude-statusline.sh` / `claude-usage.json` (inside the Application Support folder above) if you no longer want them.
The project folder (including `build/Cala.app`) can then be deleted.

## DockDoor
If you previously removed DockDoor through Homebrew, install it again with `brew install --cask dockdoor`.

## What the Dock switch does
Settings → Taskbar → **Hide the macOS Dock** turns on Dock auto-hide with a very long delay and restarts the Dock. Turning it off restores the exact previous values, kept in `config.json` (`dockBackup*`). If "Restore the Dock when quitting Cala" is on (default), quitting the bar also restores the Dock, and launching it again hides it again.

Normal Quit and SIGTERM run the Dock restore handler when that setting is enabled. A crash, force-quit or SIGKILL cannot run cleanup; if the Dock stays hidden, use the manual commands above.

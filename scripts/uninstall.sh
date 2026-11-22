#!/bin/zsh
# Removes Cala from this Mac without opening it (the app also has Settings → Advanced → Uninstall Cala).
# Puts the Dock back if Cala had hidden it. Leaves permission entries in System Settings (listed at the end).
set -uo pipefail
ID=${CALA_BUNDLE_ID:-local.cala}
SUPPORT="$HOME/Library/Application Support"

pkill -x Cala 2>/dev/null; sleep 1
# Stop the crash watchdog from reopening it, then make sure it is gone.
touch "$SUPPORT/Cala/no-relaunch" 2>/dev/null
pkill -f "$SUPPORT/Cala/watchdog.sh" 2>/dev/null
pkill -9 -x Cala 2>/dev/null

# Dock and menu bar: put back what Cala saved before hiding them (its config.json keeps the originals).
CONFIG="$SUPPORT/Cala/config.json"
get() { /usr/bin/plutil -extract "$1" raw -o - "$CONFIG" 2>/dev/null; }
if [[ -f "$CONFIG" && "$(get hideNativeDock)" == "true" ]]; then
  if [[ -n "$(get dockBackupAutohide)" ]]; then defaults write com.apple.dock autohide -bool "$(get dockBackupAutohide)"; else defaults delete com.apple.dock autohide 2>/dev/null; fi
  if [[ -n "$(get dockBackupDelay)" ]]; then defaults write com.apple.dock autohide-delay -float "$(get dockBackupDelay)"; else defaults delete com.apple.dock autohide-delay 2>/dev/null; fi
  killall Dock 2>/dev/null
  echo "Dock restaurado"
fi
if [[ -f "$CONFIG" && "$(get hideMenuBar)" == "true" ]]; then
  echo "Cala tenía oculta la barra de menús: vuelve a mostrarla en Ajustes del Sistema → Centro de control → Ocultar automáticamente la barra de menús."
fi

for agent in "$HOME/Library/LaunchAgents/local.cala.plist" "$HOME/Library/LaunchAgents/local.mactaskbar.plist"; do
  [[ -f "$agent" ]] && { launchctl bootout "gui/$(id -u)" "$agent" 2>/dev/null; rm -f "$agent"; }
done
rm -rf "$SUPPORT/Cala"
[[ -L "$SUPPORT/MacTaskbar" ]] && rm -f "$SUPPORT/MacTaskbar"
defaults delete "$ID" 2>/dev/null
rm -rf "$HOME/Library/Caches/$ID" "$HOME/Library/HTTPStorages/$ID" "$HOME/Library/Saved Application State/$ID.savedState"
for app in /Applications/Cala.app "$HOME/Applications/Cala.app"; do
  [[ -d "$app" ]] && mv "$app" "$HOME/.Trash/" && echo "Movida a la Papelera: $app"
done
echo "Cala desinstalada. Para quitar también sus permisos:"
echo "  tccutil reset All $ID"

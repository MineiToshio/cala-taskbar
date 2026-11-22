#!/bin/zsh
# Developer install: build, then replace ~/Applications/Cala.app (user-only writable) and open it.
# End users install from the disk image made by scripts/release.sh instead (see INSTALL.md).
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

SRC="$PWD/build/Cala.app"
DEST_DIR="$HOME/Applications"
DEST="$DEST_DIR/Cala.app"
PLIST="$HOME/Library/LaunchAgents/local.cala.plist"
PB=/usr/libexec/PlistBuddy

# Migrate from the former name (MacTaskbar): stop it, drop the old bundle, rename its launch agent.
OLD_PLIST="$HOME/Library/LaunchAgents/local.mactaskbar.plist"
pkill -x MacTaskbar || true
rm -rf "$DEST_DIR/MacTaskbar.app"
if [[ -f "$OLD_PLIST" ]]; then
  launchctl bootout "gui/$(id -u)/local.mactaskbar" 2>/dev/null || true
  if [[ ! -f "$PLIST" ]]; then
    mv "$OLD_PLIST" "$PLIST"
    $PB -c "Set :Label local.cala" "$PLIST"
  else
    rm -f "$OLD_PLIST"
  fi
fi

# Quit the running app and wait (max ~5 s) until it is gone.
pkill -x Cala || true
for _ in {1..50}; do
  pgrep -x Cala >/dev/null || break
  sleep 0.1
done
if pgrep -x Cala >/dev/null; then
  echo "Cala did not quit within 5 s" >&2
  exit 1
fi

# ~/Applications: owned by this user, never group/other writable.
mkdir -p "$DEST_DIR"
if [[ "$(stat -f %u "$DEST_DIR")" != "$(id -u)" ]]; then
  echo "$DEST_DIR is not owned by $USER" >&2
  exit 1
fi
if (( ( 8#$(stat -f %Lp "$DEST_DIR") & 8#022 ) != 0 )); then
  chmod go-w "$DEST_DIR"
fi

# Replace the installed bundle with the fresh build.
rm -rf "$DEST"
ditto "$SRC" "$DEST"
chmod -R go-w "$DEST"
codesign --verify --deep --strict "$DEST"
echo "Instalado: $DEST"

# Open at login is managed by the app (System Settings → Login Items); an old LaunchAgent is migrated on launch.
open "$DEST"

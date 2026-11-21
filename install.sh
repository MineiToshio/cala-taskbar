#!/bin/zsh
# Build, then install MacTaskbar into ~/Applications (user-only writable) and
# point the login LaunchAgent at it.
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

SRC="$PWD/build/MacTaskbar.app"
DEST_DIR="$HOME/Applications"
DEST="$DEST_DIR/MacTaskbar.app"
PLIST="$HOME/Library/LaunchAgents/local.mactaskbar.plist"
PB=/usr/libexec/PlistBuddy

# Quit the running app and wait (max ~5 s) until it is gone.
pkill -x MacTaskbar || true
for _ in {1..50}; do
  pgrep -x MacTaskbar >/dev/null || break
  sleep 0.1
done
if pgrep -x MacTaskbar >/dev/null; then
  echo "MacTaskbar did not quit within 5 s" >&2
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

# LaunchAgent: same shape the app writes itself (/usr/bin/open -a <bundle>).
if [[ -f "$PLIST" ]]; then
  current=$($PB -c "Print :ProgramArguments:2" "$PLIST" 2>/dev/null || true)
  if [[ "$current" != "$DEST" ]]; then
    $PB -c "Delete :ProgramArguments" "$PLIST" 2>/dev/null || true
    $PB -c "Add :ProgramArguments array" \
        -c "Add :ProgramArguments:0 string /usr/bin/open" \
        -c "Add :ProgramArguments:1 string -a" \
        -c "Add :ProgramArguments:2 string $DEST" "$PLIST"
    echo "LaunchAgent actualizado: $PLIST"
  fi
  chmod 644 "$PLIST"
  if [[ "$(stat -f %u "$PLIST")" != "$(id -u)" ]]; then
    echo "$PLIST is not owned by $USER" >&2
    exit 1
  fi
  # No launchctl bootout/bootstrap: the job has RunAtLoad, so reloading would
  # run `open -a` against the instance started below and pop its Settings
  # window. launchd re-reads the plist at the next login.
else
  echo "Sin LaunchAgent ($PLIST); actívalo desde Ajustes si lo quieres."
fi

open "$DEST"

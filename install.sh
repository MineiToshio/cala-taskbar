#!/bin/zsh
# Developer install: publish a complete bundle in /Applications, then open it in this session.
set -euo pipefail
if (( EUID == 0 )); then
  print -u2 'Run ./install.sh as your user. It will ask for sudo itself.'
  print -u2 'Ejecuta ./install.sh con tu usuario. El instalador pedirá sudo cuando corresponda.'
  exit 1
fi
cd "$(dirname "$0")"

SRC="$PWD/build/Cala.app"
DEST_DIR=/Applications
DEST="$DEST_DIR/Cala.app"
LEGACY_DIR="$HOME/Applications"
PLIST="$HOME/Library/LaunchAgents/local.cala.plist"
OLD_PLIST="$HOME/Library/LaunchAgents/local.mactaskbar.plist"
PB=/usr/libexec/PlistBuddy
uid=$(id -u)

# Local rebuilds can come from the same commit. Advance past the installed build by default.
if [[ -z "${CALA_BUILD_NUMBER:-}" ]]; then
  build_number=$(git rev-list --count HEAD 2>/dev/null || echo 1)
  installed=$($PB -c "Print :CFBundleVersion" "$DEST/Contents/Info.plist" 2>/dev/null || true)
  major=${installed%%.*}
  if [[ "$major" =~ '^[0-9]{1,18}$' ]] && (( 10#$major >= build_number )); then
    build_number=$(( 10#$major + 1 ))
  fi
  export CALA_BUILD_NUMBER=$build_number
fi
./build.sh

# Validate the staged copy before publishing it. Both names are on the same volume, so
# renamex_np can atomically exchange two populated directories (or install a new name exclusively).
publish() {
  /usr/bin/sudo /bin/zsh -f -s -- "$SRC" "$DEST" <<'PUBLISH'
set -euo pipefail
src=$1
dest=$2
dir=${dest:h}
stage=$(/usr/bin/mktemp -d "$dir/.cala-install.XXXXXXXX")
trap '/bin/rm -rf "$stage"' EXIT
staged="$stage/Cala.app"
/usr/bin/ditto "$src" "$staged"
/usr/sbin/chown -Rh root:admin "$staged"
/bin/chmod -RN "$staged"
/bin/chmod -R go-w "$staged"
/usr/bin/codesign --verify --deep --strict "$staged"

if [[ -e "$dest" || -L "$dest" ]]; then
  pb=/usr/libexec/PlistBuddy
  old_id=$($pb -c "Print :CFBundleIdentifier" "$dest/Contents/Info.plist" 2>/dev/null || true)
  new_id=$($pb -c "Print :CFBundleIdentifier" "$staged/Contents/Info.plist")
  if [[ -L "$dest" || "$old_id" != "$new_id" ]]; then
    print -u2 "Unexpected bundle at $dest. / Paquete inesperado en $dest."
    exit 1
  fi
  flags=2 # RENAME_SWAP
else
  flags=4 # RENAME_EXCL
fi
/usr/bin/ruby --disable-gems -rfiddle/import - "$staged" "$dest" "$flags" <<'RUBY'
module Darwin
  extend Fiddle::Importer
  dlload Fiddle::Handle::DEFAULT
  extern 'int renamex_np(const char *, const char *, unsigned int)'
end

if Darwin.renamex_np(ARGV[0], ARGV[1], Integer(ARGV[2])) != 0
  abort SystemCallError.new('renamex_np', Fiddle.last_error).message
end
RUBY
PUBLISH
}

# Publish while Cala is still running, so a failed copy or cancelled password prompt leaves it alone.
print "Administrator access needed for $DEST. / Se requieren permisos de administrador para $DEST."
publish

# Keep the old bundle available until the new one has opened.
recover_on_exit() {
  local result=$1
  if (( result != 0 )); then
    if [[ -d "$DEST" ]] && open "$DEST"; then return "$result"; fi
    if [[ -d "$LEGACY_DIR/Cala.app" ]]; then open "$LEGACY_DIR/Cala.app" || true; fi
  fi
  return "$result"
}
trap 'recover_on_exit $?' EXIT

# Scope legacy jobs and process signals to this user, including the wait for normal quit.
launchctl bootout "gui/$uid/local.mactaskbar" 2>/dev/null || true
launchctl bootout "gui/$uid/local.cala" 2>/dev/null || true
pkill -u "$uid" -x MacTaskbar || true
pkill -u "$uid" -x Cala || true
for _ in {1..50}; do
  pgrep -u "$uid" -x Cala >/dev/null || break
  sleep 0.1
done
if pgrep -u "$uid" -x Cala >/dev/null; then
  print -u2 "Cala did not quit within 5 s. / Cala no se cerró en 5 s."
  exit 1
fi

# Preserve the old login choice for Cala to migrate to SMAppService at first launch.
if [[ -f "$OLD_PLIST" ]]; then
  if [[ ! -f "$PLIST" ]]; then
    mv "$OLD_PLIST" "$PLIST"
    $PB -c "Set :Label local.cala" "$PLIST"
  else
    rm -f "$OLD_PLIST"
  fi
fi
open "$DEST"
trap - EXIT
rm -rf "$LEGACY_DIR/MacTaskbar.app" "$LEGACY_DIR/Cala.app"

print "Installed / Instalado: $DEST"
print 'In each other account, quit the old Cala, then run: / En cada otra cuenta, cierra la Cala antigua y ejecuta:'
print '  rm -rf "$HOME/Applications/Cala.app"'
print '  open /Applications/Cala.app'

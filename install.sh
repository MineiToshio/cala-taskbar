#!/bin/zsh
# Developer install: publish a complete bundle in /Applications, then open it in this session.
set -euo pipefail
if (( EUID == 0 )); then
  print -u2 'Run ./install.sh as your user. It will ask for sudo itself.'
  print -u2 'Ejecuta ./install.sh con tu usuario. El instalador pedirá sudo cuando corresponda.'
  exit 1
fi
cd "$(dirname "$0")"

build_dir=${CALA_BUILD_DIR:-build}
SRC="${build_dir:a}/Cala.app"
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
# renameatx_np can atomically exchange two populated directories (or install a new name exclusively).
publish() {
  /usr/bin/sudo /bin/zsh -f -s -- "$SRC" "$DEST" <<'PUBLISH'
set -euo pipefail
src=$1
dest=$2
owner=${SUDO_USER:?Missing invoking user}
dir=${dest:h}
parent=/private/var/root
for path in /private /private/var "$parent"; do
  if [[ ! -d "$path" || -L "$path" || ! -O "$path" ]] ||
     (( 8#$(/usr/bin/stat -f %Lp "$path") & 8#022 )); then
    print -u2 "Unsafe staging parent: $path. / Directorio temporal inseguro: $path."
    exit 1
  fi
done
if [[ "$(/usr/bin/stat -f %d "$parent")" != "$(/usr/bin/stat -f %d "$dir")" ]]; then
  print -u2 "Staging and $dir must share a volume. / El directorio temporal y $dir deben estar en el mismo volumen."
  exit 1
fi
zmodload zsh/stat
zmodload zsh/system
stage=$(/usr/bin/mktemp -d "$parent/.cala-install.XXXXXXXX")
staged="$stage/Cala.app"
incoming_identity=
validated_identity=
swap_attempted=0
identity() {
  local -A info
  zstat -LH info -- "$1" || return
  print -r -- "$info[device]:$info[inode]"
}
cleanup() {
  if (( swap_attempted )) && [[ -e "$staged" || -L "$staged" ]]; then
    local moved_identity
    moved_identity=$(identity "$staged") || moved_identity=
    if [[ -z "$moved_identity" || ( "$moved_identity" != "$validated_identity" &&
                                   "$moved_identity" != "$incoming_identity" ) ]]; then
      print -u2 "Unexpected bundle preserved at $staged. / Se conservó el paquete inesperado en $staged."
      return 1
    fi
  fi
  /bin/rm -rf "$stage"
}
trap 'cleanup || exit 1' EXIT
/usr/bin/ditto --noacl "$src" "$staged"
unusual=$(/usr/bin/find "$staged" ! \( -type d -o \( -type f -links 1 \) \) -print)
if [[ ! -d "$staged" || -n "$unusual" ]]; then
  print -u2 "Unexpected entries in the staged bundle. / Entradas inesperadas en el paquete temporal."
  exit 1
fi
/bin/chmod -RN "$staged"
/usr/sbin/chown -Rh "${owner}:admin" "$staged"
/bin/chmod -R u-s,g-s,u+rwX,g+rwX,o-w "$staged"
/usr/bin/codesign --verify --deep --strict "$staged"

if [[ -e "$dest" || -L "$dest" ]]; then
  # Keep the validated inode pinned through the exchange and EXIT cleanup.
  typeset -A validated
  typeset -i 10 validated_fd # zstat expects a decimal descriptor after the octal permission check.
  if ! sysopen -r -o nofollow,nonblock,cloexec -u validated_fd "$dest" ||
     ! zstat -H validated -f "$validated_fd" ||
     (( (validated[mode] & 8#170000) != 8#040000 )); then
    print -u2 "Unexpected bundle at $dest. / Paquete inesperado en $dest."
    exit 1
  fi
  validated_identity="$validated[device]:$validated[inode]"
  pb=/usr/libexec/PlistBuddy
  if [[ "$(identity "$dest")" != "$validated_identity" ]]; then
    print -u2 "Bundle changed at $dest. / Cambió el paquete en $dest."
    exit 1
  fi
  old_id=$($pb -c "Print :CFBundleIdentifier" "$dest/Contents/Info.plist" 2>/dev/null || true)
  new_id=$($pb -c "Print :CFBundleIdentifier" "$staged/Contents/Info.plist")
  if [[ "$old_id" != "$new_id" || "$(identity "$dest")" != "$validated_identity" ]]; then
    print -u2 "Unexpected bundle at $dest. / Paquete inesperado en $dest."
    exit 1
  fi
  flags=2 # RENAME_SWAP
else
  flags=4 # RENAME_EXCL
fi
incoming_identity=$(identity "$staged")
swap_attempted=1
/usr/bin/ruby --disable-gems -rfiddle/import - "$stage" "$dir" "$flags" <<'RUBY'
module Darwin
  extend Fiddle::Importer
  dlload Fiddle::Handle::DEFAULT
  extern 'int renameatx_np(int, const char *, int, const char *, unsigned int)'
end

stage, destination = ARGV.take(2).map { |path| File.open(path, File::RDONLY | File::NOFOLLOW) }
unless stage.stat.directory? && destination.stat.directory? && stage.stat.dev == destination.stat.dev
  abort 'Staging and destination must be directories on the same volume.'
end
if Darwin.renameatx_np(stage.fileno, 'Cala.app', destination.fileno, 'Cala.app', Integer(ARGV[2])) != 0
  abort SystemCallError.new('renameatx_np', Fiddle.last_error).message
end
RUBY
# After a successful exchange only the validated old inode can be deleted.
incoming_identity=
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

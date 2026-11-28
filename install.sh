#!/bin/zsh
# Install a fresh build (or CALA_INSTALL_PREBUILT), then open it in this session.
set -euo pipefail
if (( EUID == 0 )); then
  print -u2 'Run ./install.sh as your user. It will ask for sudo when needed.'
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

prebuilt_checksums=
if [[ -n "${CALA_INSTALL_PREBUILT:-}" ]]; then
  prebuilt_dir=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/cala-prebuilt.XXXXXXXX")
  trap '/bin/rm -rf -- "$prebuilt_dir"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  SRC="$prebuilt_dir/Cala.app"
  /usr/bin/ditto --noacl "${CALA_INSTALL_PREBUILT:a}" "$SRC"
  /usr/bin/codesign --verify --deep --strict "$SRC"
  ./scripts/verify-keychain-helper.sh --bundle "$SRC"
  # Carry the verified helper and the files defining its signing relationship into the privileged stage.
  prebuilt_checksums=$(cd "$SRC" && /usr/bin/shasum -a 256 \
    Contents/Info.plist Contents/MacOS/Cala Contents/Helpers/cala-keychain)
else
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
fi

can_publish_as_user() {
  local group groups account_groups denied
  local -a group_tests
  account_groups=$(/usr/bin/id -Gn) || return 1
  [[ " $account_groups " == *' admin '* && -w "$DEST_DIR" && -x "$DEST_DIR" ]] || return 1
  if [[ ! -e "$DEST" && ! -L "$DEST" ]]; then return 0; fi
  [[ -d "$DEST" && ! -L "$DEST" ]] || return 1

  groups=$(/usr/bin/id -G) || return 1
  for group in ${=groups}; do group_tests+=(-group "$group" -o); done
  denied=$(/usr/bin/find "$DEST" ! \( -user "$uid" -o \( -perm -0020 \( "${group_tests[@]}" -false \) \) \) -print -quit) ||
    return 1
  [[ -z "$denied" ]] || return 1
  # Removing the exchanged bundle requires traversing and writing its directories.
  denied=$(/usr/bin/find "$DEST" -flags +uchg,schg,uappnd,sappnd -print -quit -o -type d -exec /bin/zsh -f -c '
    for entry; do [[ -r "$entry" && -w "$entry" && -x "$entry" ]] || print -r -- "$entry"; done
  ' zsh {} +) || return 1
  [[ -z "$denied" ]]
}

# Validate the staged copy before publishing it. Both names are on the same volume, so
# renameatx_np can atomically exchange two populated directories (or install a new name exclusively).
publish() {
  local -a publisher=(/bin/zsh -f -s --)
  if ! can_publish_as_user; then
    print "Administrator access needed for $DEST. / Se requieren permisos de administrador para $DEST."
    publisher=(/usr/bin/sudo "${publisher[@]}")
  fi
  "${publisher[@]}" "$SRC" "$DEST" "$prebuilt_checksums" <<'PUBLISH'
set -euo pipefail
src=$1
dest=$2
prebuilt_checksums=$3
dir=${dest:h}
if (( EUID == 0 )); then
  owner=${SUDO_USER:?Missing invoking user}
  parent=/private/var/root
  for parent_dir in /private /private/var "$parent"; do
    if [[ ! -d "$parent_dir" || -L "$parent_dir" || ! -O "$parent_dir" ]] ||
       (( 8#$(/usr/bin/stat -f %Lp "$parent_dir") & 8#022 )); then
      print -u2 "Unsafe staging parent: $parent_dir. / Directorio temporal inseguro: $parent_dir."
      exit 1
    fi
  done
  if [[ "$(/usr/bin/stat -f %d "$parent")" != "$(/usr/bin/stat -f %d "$dir")" ]]; then
    print -u2 "Staging and $dir must share a volume. / El directorio temporal y $dir deben estar en el mismo volumen."
    exit 1
  fi
else
  parent=$(/usr/bin/getconf DARWIN_USER_TEMP_DIR) || parent=
  parent=${parent%/}
  if [[ ! -d "$parent" || -L "$parent" || ! -O "$parent" ]] ||
     (( 8#$(/usr/bin/stat -f %Lp "$parent") & 8#022 )) ||
     [[ "$(/usr/bin/stat -f %d "$parent")" != "$(/usr/bin/stat -f %d "$dir")" ]]; then
    parent=$dir
  fi
fi
zmodload zsh/stat
zmodload zsh/system
identity() {
  local -A info
  zstat -LH info -- "$1" || return
  print -r -- "$info[device]:$info[inode]"
}
stage=$(/usr/bin/mktemp -d "$parent/.cala-install.XXXXXXXX")
stage_identity=$(identity "$stage")
# Use the pinned working directory for the copy, exchange and cleanup.
cd -P -- "$stage"
if [[ ! -O . || "$(identity .)" != "$stage_identity" ]] ||
   (( 8#$(/usr/bin/stat -f %Lp .) & 8#077 )); then
  print -u2 "Unsafe staging directory: $stage. / Directorio temporal inseguro: $stage."
  exit 1
fi
staged=./Cala.app
incoming_identity=
validated_identity=
swap_attempted=0
swap_succeeded=0
cleanup() {
  if (( swap_attempted )) && [[ -e "$staged" || -L "$staged" ]]; then
    local moved_identity
    moved_identity=$(identity "$staged") || moved_identity=
    if [[ -z "$moved_identity" || ( "$moved_identity" != "$validated_identity" &&
                                   "$moved_identity" != "$incoming_identity" ) ]]; then
      print -u2 "Unexpected bundle preserved at $stage/Cala.app. / Se conservó el paquete inesperado en $stage/Cala.app."
      return 1
    fi
  fi
  /bin/rm -rf "$staged" || return 1
  [[ "$(identity "$stage" 2>/dev/null)" == "$stage_identity" ]] || return 1
  /bin/rmdir "$stage"
}
trap '
  exit_status=$?
  trap "" INT TERM
  if ! cleanup; then
    (( exit_status != 130 && exit_status != 143 )) || exit "$exit_status"
    (( swap_succeeded )) || exit 1
    print -u2 "Cala was installed. Could not finish cleaning up $stage. / Cala se instaló. No se pudo terminar de limpiar $stage."
  fi
' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
/usr/bin/ditto --noacl "$src" "$staged"
unusual=$(/usr/bin/find "$staged" ! \( -type d -o \( -type f -links 1 \) \) -print)
if [[ ! -d "$staged" || -n "$unusual" ]]; then
  print -u2 "Unexpected entries in the staged bundle. / Entradas inesperadas en el paquete temporal."
  exit 1
fi
/bin/chmod -RN "$staged"
if (( EUID == 0 )); then
  /usr/sbin/chown -Rh "${owner}:admin" "$staged"
else
  /usr/bin/chgrp -Rh admin "$staged"
fi
/bin/chmod -R u-s,g-s,u+rwX,g+rwX,o-w "$staged"
/usr/bin/codesign --verify --deep --strict "$staged"
if [[ -n "$prebuilt_checksums" ]] &&
   ! (cd "$staged" && print -r -- "$prebuilt_checksums" | /usr/bin/shasum -a 256 -c --status); then
  print -u2 'Staged Cala failed the Keychain helper verification. / La copia preparada de Cala no pasó la verificación del helper del Llavero.'
  exit 1
fi

main_cdhashes() {
  local bundle=$1 archs arch hash
  archs=$(/usr/bin/lipo -archs "$bundle/Contents/MacOS/Cala") || return 1
  [[ -n "$archs" ]] || return 1
  for arch in ${=archs}; do
    hash=$(/usr/bin/codesign -dvvv --arch "$arch" "$bundle" 2>&1 | /usr/bin/sed -n 's/^CDHash=//p') || return 1
    [[ -n "$hash" ]] || return 1
    print -r -- "$arch $hash"
  done
}

bundle_permissions() (
  local acl
  cd -P -- "$1" || return 1
  acl=$(/usr/bin/find -s . -acl -print -quit) || return 1
  [[ -z "$acl" ]] || return 1
  /usr/bin/find -s . -exec /usr/bin/stat -f '%p %u %g %l %N' {} +
)

repair_identical=0
old_version= old_build= new_version= new_build=
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
  if [[ -n "$prebuilt_checksums" ]]; then
    old_version=$($pb -c 'Print :CFBundleShortVersionString' "$dest/Contents/Info.plist" 2>/dev/null || true)
    old_build=$($pb -c 'Print :CFBundleVersion' "$dest/Contents/Info.plist" 2>/dev/null || true)
    new_version=$($pb -c 'Print :CFBundleShortVersionString' "$staged/Contents/Info.plist")
    new_build=$($pb -c 'Print :CFBundleVersion' "$staged/Contents/Info.plist")
  fi
  if [[ "$old_id" != "$new_id" || "$(identity "$dest")" != "$validated_identity" ]]; then
    print -u2 "Unexpected bundle at $dest. / Paquete inesperado en $dest."
    exit 1
  fi
  if [[ -n "$prebuilt_checksums" && "$old_version" == "$new_version" && "$old_build" == "$new_build" ]] &&
     new_hashes=$(main_cdhashes "$staged") && old_hashes=$(main_cdhashes "$dest") &&
     [[ "$old_hashes" == "$new_hashes" ]] && /usr/bin/codesign --verify --deep --strict "$dest"; then
    # The signature does not cover modes or ACLs. Exchange the normalized copy if needed.
    repair_identical=1
    if new_permissions=$(bundle_permissions "$staged") && old_permissions=$(bundle_permissions "$dest") &&
       [[ "$old_permissions" == "$new_permissions" ]]; then
      repair_identical=0
    fi
    if [[ "$(identity "$dest")" != "$validated_identity" ]]; then
      print -u2 "Bundle changed at $dest. / Cambió el paquete en $dest."
      exit 1
    fi
    if (( ! repair_identical )); then
      print 'This Cala build is already installed. Relaunching. / Este build de Cala ya está instalado. Reiniciando.'
      exit 0
    fi
  fi
  flags=2 # RENAME_SWAP
else
  flags=4 # RENAME_EXCL
fi
incoming_identity=$(identity "$staged")
swap_attempted=1
/usr/bin/ruby --disable-gems -rfiddle/import - . "$dir" "$flags" "$old_version" "$old_build" "$new_version" "$new_build" "$repair_identical" <<'RUBY'
module Darwin
  extend Fiddle::Importer
  dlload Fiddle::Handle::DEFAULT
  extern 'int renameatx_np(int, const char *, int, const char *, unsigned int)'
end

old_version, old_build, new_version, new_build, repair_identical = ARGV.drop(3)
marketing_version = /\A[0-9]+(?:\.[0-9]+){0,2}\z/
version_parts = ->(version) { (version.split(".").map(&:to_i) + [0, 0]).first(3) }
version_order = if [old_version, new_version].all? { |v| marketing_version.match?(v) }
  version_parts.call(old_version) <=> version_parts.call(new_version)
end
if version_order == 1
  abort "Cala #{new_version} is older than installed version #{old_version}. / Cala #{new_version} es anterior a la versión instalada #{old_version}."
end
build_number = /\A[0-9]+\z/
if (version_order == 0 || old_version == new_version) && build_number.match?(old_build)
  abort "Invalid prebuilt Cala build number: #{new_build}" unless build_number.match?(new_build)
  if old_build.to_i >= new_build.to_i && !(repair_identical == "1" && old_build.to_i == new_build.to_i)
    abort "Cala #{new_version} build #{new_build} needs to be newer than installed build #{old_build} so other macOS accounts can detect the update. / El build #{new_build} de Cala #{new_version} debe superar al build instalado #{old_build} para que las otras cuentas detecten la actualización."
  end
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
swap_succeeded=1
PUBLISH
}

# Publish while Cala is still running, so a failed copy or cancelled password prompt leaves it alone.
publish

# The new bundle is on disk. Wait for the running copy to quit before opening it.
launchctl bootout "gui/$uid/local.mactaskbar" 2>/dev/null || true
launchctl bootout "gui/$uid/local.cala" 2>/dev/null || true
pkill -u "$uid" -x MacTaskbar || true
pkill -u "$uid" -x Cala || true
for _ in {1..50}; do
  pgrep -u "$uid" -x Cala >/dev/null || break
  sleep 0.1
done
if pgrep -u "$uid" -x Cala >/dev/null; then
  print -u2 "The new bundle is installed at $DEST. The previous Cala did not quit within 5 s. Quit it from its menu before running the command below."
  print -u2 "La nueva versión está instalada en $DEST. La Cala anterior no se cerró en 5 s. Ciérrala desde su menú antes de ejecutar el comando de abajo."
  print -u2 "  open $DEST"
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
if ! open "$DEST"; then
  print -u2 "Cala was installed. Use the command below to open it. / Cala se instaló. Usa el comando de abajo para abrirla."
  print -u2 "  open $DEST"
  exit 1
fi
if ! rm -rf "$LEGACY_DIR/MacTaskbar.app" "$LEGACY_DIR/Cala.app"; then
  print -u2 "Cala is installed. Could not remove a legacy bundle in $LEGACY_DIR. / Cala está instalada. No se pudo borrar una copia anterior en $LEGACY_DIR."
fi

print "Installed / Instalado: $DEST"
print 'In each other account, quit the old Cala, then run: / En cada otra cuenta, cierra la Cala antigua y ejecuta:'
print '  rm -rf "$HOME/Applications/Cala.app"'
print '  open /Applications/Cala.app'

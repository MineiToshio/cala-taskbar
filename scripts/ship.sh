#!/bin/zsh
# Builds, publishes and installs the next Cala release.
set -euo pipefail

fail() {
  print -u2 -r -- "$1 / $2"
  exit 1
}

cd "$(dirname "$0")/.." || fail 'No se pudo abrir el repositorio.' 'Could not open the repository.'

delete_passphrase() {
  /usr/bin/security delete-generic-password -s local.cala.update-signing -a update-signing-key.json
}

if (( $# == 1 )); then
  case "$1" in
    --save-passphrase)
      key="$HOME/.config/cala/update-signing-key.json"
      [[ -f "$key" && -r "$key" ]] ||
        fail "Copia la clave de firma a $key." "Copy the signing key to $key."
      [[ -t 0 ]] ||
        fail 'Ejecuta --save-passphrase en tu Terminal.' 'Run --save-passphrase in your Terminal.'
      print 'Pega la frase de «Cala – clave de firma» (NO la contraseña del Mac) / Paste the Cala signing-key passphrase'
      /usr/bin/security add-generic-password -U -s local.cala.update-signing -a update-signing-key.json -T /usr/bin/security -w ||
        fail 'No se pudo guardar la frase en el Llavero.' 'Could not save the passphrase to the Keychain.'
      if /usr/bin/security find-generic-password -s local.cala.update-signing -a update-signing-key.json -w 2>/dev/null |
        swift scripts/update-sign.swift check-key --key "$key" --passphrase-fd 0; then
        print 'Frase guardada en el Llavero de macOS / Passphrase saved in the macOS Keychain'
        exit 0
      fi
      delete_passphrase ||
        fail 'Falló la verificación y no se pudo borrar la frase del Llavero.' \
             'Verification failed and the passphrase could not be deleted from the Keychain.'
      fail 'Falló la verificación de la frase. Se borró del Llavero.' \
           'Passphrase verification failed. The item was deleted from the Keychain.' ;;
    --forget-passphrase)
      delete_passphrase ||
        fail 'No se pudo borrar la frase del Llavero.' 'Could not delete the passphrase from the Keychain.'
      print 'Frase borrada del Llavero de macOS / Passphrase deleted from the macOS Keychain'
      exit 0 ;;
  esac
fi

dry_run=0
requested=
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry_run=1 ;;
    *)
      [[ -z "$requested" && ( "$arg" == (patch|minor|major) || "$arg" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ) ]] ||
        fail 'Uso: ./scripts/ship.sh [--dry-run] [patch|minor|major|<x.y.z>] | --save-passphrase | --forget-passphrase' \
             'Usage: ./scripts/ship.sh [--dry-run] [patch|minor|major|<x.y.z>] | --save-passphrase | --forget-passphrase'
      requested=$arg ;;
  esac
done
requested=${requested:-patch}

check_main() {
  [[ "$(git symbolic-ref --quiet --short HEAD)" == main ]] ||
    fail 'Ejecuta ship desde la rama main.' 'Run ship from the main branch.'
}

working_tree=$(git status --porcelain=v1 --untracked-files=all) ||
  fail 'No se pudo comprobar el árbol de trabajo.' 'Could not inspect the working tree.'
check_main
base=$(git rev-parse --verify HEAD) ||
  fail 'No se pudo identificar el commit de main.' 'Could not identify the main commit.'
if [[ -n "$working_tree" ]]; then
  (( dry_run )) || fail 'Haz commit de los cambios y las notas primero.' 'Commit the changes and release notes first.'
  print 'Simulación con cambios locales. La publicación requiere un árbol limpio. / Dry run with local changes. Shipping requires a clean working tree.'
fi

check_privacy() {
  local count
  count=$(git log --format='%ae%n%ce' "$1" | awk 'tolower($0) ~ /gmail/ { n++ } END { print n + 0 }') ||
    fail 'No se pudo revisar el historial.' 'Could not check the commit history.'
  (( count == 0 )) ||
    fail "El historial contiene $count direcciones Gmail de autor o committer." \
         "The commit history contains $count Gmail author or committer addresses."
}

check_privacy "$base"
for role in AUTHOR COMMITTER; do
  identity=$(git var "GIT_${role}_IDENT") ||
    fail 'Configura tu nombre y correo en Git.' 'Configure your name and email in Git.'
  address=${identity##*<}
  address=${address%%>*}
  [[ "${address:l}" != *gmail* ]] ||
    fail 'Configura en Git un correo sin Gmail antes de publicar.' 'Configure a non-Gmail Git email before shipping.'
done

version=$(python3 - "$requested" <<'PY'
import re
import subprocess
import sys
from pathlib import Path

def parse(version):
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        sys.exit("VERSION inválida / Invalid VERSION: " + version)
    return tuple(map(int, version.split(".")))

current = parse("".join(Path("VERSION").read_text().split()))
requested = sys.argv[1]
if requested in ("patch", "minor", "major"):
    index = ("major", "minor", "patch").index(requested)
    target = current[:index] + (current[index] + 1,) + (0,) * (2 - index)
else:
    target = parse(requested)

tags = subprocess.check_output(["git", "tag", "--list", "v*"], text=True).splitlines()
latest = max((parse(tag[1:]) for tag in tags if re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag)),
             default=current)
if target <= max(current, latest):
    sys.exit("La versión debe superar VERSION y todos los tags / Version must exceed VERSION and all version tags")
print(".".join(map(str, target)))
PY
) || fail 'No se pudo calcular la siguiente versión.' 'Could not calculate the next version.'

tag=v$version
repo=MineiToshio/cala-taskbar
remote="https://github.com/$repo.git"

if (( dry_run )); then
  print -r -- "Plan para Cala $version / Plan for Cala $version"
  print -r -- "  Commit Release $version y push de main por HTTPS / Commit Release $version and push main over HTTPS"
  print -r -- "  Compilar y firmar, crear y subir $tag / Build and sign, then create and push $tag"
  print -r -- "  Publicar $tag como última versión de GitHub / Publish $tag as the latest GitHub release"
  print -r -- '  Verificar la firma del manifiesto público e instalar Cala / Verify the public feed signature and install Cala'
fi

check_notes() {
  local lang notes
  local -a missing
  for lang in en es; do
    notes="docs/releases/$version.$lang.md"
    if [[ ! -s "$notes" ]]; then
      missing+=("$notes")
    elif (( $(wc -c < "$notes") > 8192 )); then
      fail "Las notas superan 8 KB: $notes." "Release notes exceed 8 KB: $notes."
    elif (( ! dry_run )) && ! git cat-file -e "$base:$notes"; then
      fail "Incluye $notes en el commit de tus cambios." "Include $notes in the commit for your changes."
    fi
  done
  (( ${#missing} == 0 )) ||
    fail "Escribe y haz commit de estas notas de release: ${(j:, :)missing}." \
         "Write and commit these release notes: ${(j:, :)missing}."
}

./scripts/release.sh --checks-only ||
  fail 'Fallaron los checks de Cala.' 'Cala checks failed.'
check_notes
if (( dry_run )); then
  print 'Simulación completada. / Dry run complete.'
  exit 0
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/cala-ship.XXXXXXXX") ||
  fail 'No se pudo crear el directorio temporal.' 'Could not create the temporary directory.'
trap 'rm -rf -- "$work"' EXIT

check_main
working_tree=$(git status --porcelain=v1 --untracked-files=all) ||
  fail 'No se pudo volver a comprobar el árbol de trabajo.' 'Could not recheck the working tree.'
[[ -z "$working_tree" && "$(git rev-parse HEAD)" == "$base" ]] ||
  fail 'El árbol de trabajo o main cambió durante los checks.' 'The working tree or main changed during checks.'

print -r -- "$version" > VERSION &&
  git add -- VERSION &&
  git commit -m "Release $version" -m 'Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>' ||
  fail "No se pudo crear el commit Release $version." "Could not create the Release $version commit."
release_head=$(git rev-parse --verify HEAD) ||
  fail 'No se pudo identificar el commit de release.' 'Could not identify the release commit.'
[[ "$(git rev-list --parents -n 1 "$release_head")" == "$release_head $base" &&
   "$(git show "$release_head:VERSION")" == "$version" ]] &&
  git diff --quiet "$base" "$release_head" -- . ':(exclude)VERSION' ||
  fail 'El commit de release debe cambiar solo VERSION.' 'The release commit must change only VERSION.'
check_privacy "$release_head"

git -c credential.helper='!gh auth git-credential' push "$remote" main:main ||
  fail 'No se pudo subir main a GitHub por HTTPS.' 'Could not push main to GitHub over HTTPS.'
./scripts/release.sh --checked-parent "$base" "$release_head" | /usr/bin/tee "$work/release.log" ||
  fail "No se pudo compilar o firmar Cala $version." "Could not build or sign Cala $version."
commit=$(sed -n 's/^CALA_RELEASE_COMMIT=//p' "$work/release.log") ||
  fail 'No se pudo leer el commit de release.sh.' 'Could not read the commit from release.sh.'
[[ "$commit" == "$release_head" ]] ||
  fail 'El build no confirmó el commit de release.' 'The build did not confirm the release commit.'

git tag "$tag" "$commit" &&
  git -c credential.helper='!gh auth git-credential' push "$remote" "refs/tags/$tag:refs/tags/$tag" ||
  fail "No se pudo crear o subir el tag $tag." "Could not create or push the $tag tag."
./scripts/publish-github.sh "$tag" ||
  fail "No se pudo crear el borrador de $tag." "Could not create the draft for $tag."
gh release edit "$tag" -R "$repo" --draft=false --latest ||
  fail "No se pudo publicar $tag." "Could not publish $tag."

feed="$work/latest.json"
url="https://github.com/$repo/releases/latest/download/latest.json"
verified=0
for attempt in {1..5}; do
  if /usr/bin/curl -q -sfL --max-time 30 -o "$feed" "$url" &&
     cmp -s "$feed" "${CALA_BUILD_DIR:-build}/latest.json" &&
     swift -module-cache-path "$work/modules" scripts/update-sign.swift verify --keys packaging/update-public-keys --feed "$feed"; then
    verified=1
    break
  fi
  if (( attempt < 5 )); then sleep 5; fi
done
(( verified )) ||
  fail "Se publicó $tag, pero falló la verificación del manifiesto público." \
       "$tag was published, but public feed verification failed."

working_tree=$(git status --porcelain=v1 --untracked-files=all) ||
  fail 'No se pudo comprobar el árbol antes de instalar.' 'Could not check the working tree before installing.'
[[ -z "$working_tree" && "$(git rev-parse HEAD)" == "$release_head" ]] ||
  fail 'El árbol de trabajo o HEAD cambió después de publicar. Se canceló la instalación.' \
       'The working tree or HEAD changed after publishing. Installation stopped.'
CALA_VERSION="$version" ./install.sh ||
  fail "Se publicó $tag, pero falló la instalación local." "$tag was published, but local installation failed."
print -r -- "Cala $version publicada e instalada. / Cala $version published and installed."
if grep -Fxq 'CALA_RELEASE_NEEDS_PASSPHRASE=1' "$work/release.log"; then
  print 'Guarda la frase una vez con ./scripts/ship.sh --save-passphrase / Save the passphrase once with ./scripts/ship.sh --save-passphrase'
fi

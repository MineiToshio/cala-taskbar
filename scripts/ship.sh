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

current=$(git show "$base:VERSION" | tr -d '[:space:]') ||
  fail 'No se pudo leer VERSION.' 'Could not read VERSION.'
release_parent=
if [[ "$current" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' && "$(git show -s --format=%s "$base")" == "Release $current" ]]; then
  parents=($(git rev-list --parents -n 1 "$base"))
  if (( ${#parents} == 2 )) &&
     [[ "$(git show "${parents[2]}:VERSION" | tr -d '[:space:]')" != "$current" ]] &&
     git diff --quiet "${parents[2]}" "$base" -- . ':(exclude)VERSION' \
       ":(exclude,literal)docs/releases/$current.en.md" ":(exclude,literal)docs/releases/$current.es.md"; then
    release_parent=${parents[2]}
  fi
fi

if [[ -n "$release_parent" ]]; then
  version=$current
  if [[ "$requested" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' && "$requested" != "$version" ]]; then
    fail "La versión en curso es $version. Reanúdala con ./scripts/ship.sh $version." \
         "The current release is $version. Resume it with ./scripts/ship.sh $version."
  fi
else
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
fi

tag=v$version
ref=refs/tags/$tag
repo=MineiToshio/cala-taskbar
remote="https://github.com/$repo.git"

if (( dry_run )); then
  print -r -- "Plan para Cala $version / Plan for Cala $version"
  if [[ -n "$release_parent" ]]; then
    print -r -- "  Reanudar el commit local Release $version si sigue pendiente / Resume the local Release $version commit if still pending"
  else
    print -r -- "  Crear el commit local Release $version / Create the local Release $version commit"
  fi
  print -r -- "  Compilar y firmar el commit local. Preparar $tag / Build and sign the local commit. Prepare $tag"
  print -r -- "  Subir main y $tag juntos por HTTPS con push atómico / Atomically push main and $tag together over HTTPS"
  print -r -- '  Crear o actualizar el borrador y verificar su manifiesto descargado / Create or update the draft and verify its downloaded feed'
  print -r -- "  Publicar $tag como última versión de GitHub / Publish $tag as the latest GitHub release"
  print -r -- '  Verificar el manifiesto público. Si falla, volver a borrador. Si pasa, instalar Cala / Verify the public feed. Re-draft on failure. Install Cala on success.'
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

if (( dry_run )); then
  ./scripts/release.sh --checks-only ||
    fail 'Fallaron los checks de Cala.' 'Cala checks failed.'
  check_notes
  print 'Simulación completada. / Dry run complete.'
  exit 0
fi

check_notes
gh_cli=$(command -v gh) ||
  fail 'Instala GitHub CLI para publicar.' 'Install GitHub CLI to ship.'
git_auth=(-c credential.helper= -c "credential.helper=!${(q)gh_cli} auth git-credential")
state_dir=$(git rev-parse --path-format=absolute --git-path cala-ship) ||
  fail 'No se pudo ubicar el estado local del release.' 'Could not locate the local release state.'
mkdir -p -- "$state_dir" && touch "$state_dir/lock" && zmodload zsh/system ||
  fail 'No se pudo preparar el estado local del release.' 'Could not prepare the local release state.'
zsystem flock -t 0 -f lock_fd "$state_dir/lock" ||
  fail 'Ya hay otro ship en curso en este checkout.' 'Another ship is already running in this checkout.'

require_clean_head() {
  check_main
  working_tree=$(git status --porcelain=v1 --untracked-files=all) ||
    fail 'No se pudo volver a comprobar el árbol de trabajo.' 'Could not recheck the working tree.'
  [[ -z "$working_tree" && "$(git rev-parse HEAD)" == "$1" ]] ||
    fail 'El árbol de trabajo o main cambió durante el release.' 'The working tree or main changed during the release.'
}
require_clean_head "$base"

get_release_state() {
  release_state=$("$gh_cli" api --hostname github.com --paginate "repos/$repo/releases?per_page=100" \
    --jq ".[] | select(.tag_name == \"$tag\") | if .draft then \"draft\" else \"published\" end") ||
    fail "No se pudo consultar el release $tag en GitHub." "Could not check release $tag on GitHub."
  [[ "$release_state" == (''|draft|published) ]] ||
    fail "Hay más de un release para $tag." "More than one release exists for $tag."
}

get_release_state
release_head=$base
if [[ -z "$release_parent" && -n "$release_state" ]]; then
  fail "GitHub ya tiene un release para $tag. Revisa el tag antes de continuar." \
       "GitHub already has a release for $tag. Review the tag before continuing."
fi
pending_feed="$state_dir/$release_head.json"
if [[ "$release_state" == published && ! -s "$pending_feed" ]]; then
  fail "$tag ya está publicado. Si falta instalarlo, ejecuta ./install.sh." \
       "$tag is already published. If it still needs installation, run ./install.sh."
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/cala-ship.XXXXXXXX") ||
  fail 'No se pudo crear el directorio temporal.' 'Could not create the temporary directory.'
trap 'rm -rf -- "$work"' EXIT
signer=(swift -module-cache-path "$work/modules" scripts/update-sign.swift)
build_dir=${CALA_BUILD_DIR:-build}
asset="$build_dir/Cala-$version.dmg"

verify_draft() {
  local expected=$1 downloaded="$work/draft-latest.json"
  "$gh_cli" release download "$tag" -R "$repo" -p latest.json -O "$downloaded" --clobber &&
    "${signer[@]}" verify --keys packaging/update-public-keys --feed "$downloaded" &&
    cmp -s "$downloaded" "$expected"
}

prepare_tag() {
  local refs remote_object remote_commit local_object
  refs=$(git "${git_auth[@]}" ls-remote "$remote" "$ref" "$ref^{}") ||
    fail "No se pudo consultar el tag $tag." "Could not check tag $tag."
  remote_object=$(awk -v ref="$ref" '$2 == ref { print $1 }' <<< "$refs")
  remote_commit=$(awk -v ref="$ref" '$2 == ref "^{}" { print $1 }' <<< "$refs")
  [[ -z "$remote_object" || "${remote_commit:-$remote_object}" == "$release_head" ]] ||
    fail "El tag remoto $tag apunta a otro commit." "Remote tag $tag points to a different commit."
  local_object=$(git rev-parse --verify --quiet "$ref" || true)
  if [[ -n "$local_object" ]]; then
    [[ "$(git rev-parse --verify "$ref^{commit}")" == "$release_head" &&
       ( -z "$remote_object" || "$local_object" == "$remote_object" ) ]] ||
      fail "El tag local $tag no coincide con el release o el tag remoto." \
           "Local tag $tag differs from the release or remote tag."
  elif [[ -n "$remote_object" ]]; then
    git "${git_auth[@]}" fetch --no-tags "$remote" "$ref:$ref" &&
      [[ "$(git rev-parse --verify "$ref")" == "$remote_object" ]] ||
      fail "No se pudo recuperar el tag remoto $tag." "Could not recover remote tag $tag."
  else
    git tag "$tag" "$release_head" ||
      fail "No se pudo crear el tag local $tag." "Could not create local tag $tag."
  fi
}

push_release_refs() {
  require_clean_head "$release_head"
  prepare_tag
  git "${git_auth[@]}" push --atomic --no-follow-tags "$remote" main "$ref" ||
    fail "No se pudo subir main y $tag juntos." "Could not push main and $tag together."
}

if [[ "$release_state" != published ]]; then
  if [[ "$release_state" == draft && -s "$pending_feed" ]] && verify_draft "$pending_feed"; then
    push_release_refs
  else
    ./scripts/release.sh --checks-only ||
      fail 'Fallaron los checks de Cala.' 'Cala checks failed.'
    require_clean_head "$base"
    if [[ -z "$release_parent" ]]; then
      release_parent=$base
      if ! { print -r -- "$version" > VERSION &&
        git commit -m "Release $version" -m 'Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>' --only -- VERSION; }; then
        if [[ "$(git rev-parse HEAD)" == "$base" && "$(<VERSION)" == "$version" ]]; then
          git restore --source "$base" --worktree -- VERSION ||
            fail 'Falló el commit y no se pudo restaurar VERSION.' 'The commit failed and VERSION could not be restored.'
        fi
        fail "No se pudo crear el commit Release $version." "Could not create the Release $version commit."
      fi
      release_head=$(git rev-parse --verify HEAD) ||
        fail 'No se pudo identificar el commit de release.' 'Could not identify the release commit.'
      pending_feed="$state_dir/$release_head.json"
    else
      print -r -- "Reanudando $tag / Resuming $tag"
    fi
    check_privacy "$release_head"

    ./scripts/release.sh --checked-parent "$release_parent" "$release_head" | /usr/bin/tee "$work/release.log" ||
      fail "No se pudo compilar o firmar Cala $version." "Could not build or sign Cala $version."
    commit=$(sed -n 's/^CALA_RELEASE_COMMIT=//p' "$work/release.log") ||
      fail 'No se pudo leer el commit de release.sh.' 'Could not read the commit from release.sh.'
    [[ "$commit" == "$release_head" && "$(git show "$release_head:VERSION")" == "$version" ]] ||
      fail 'El build no confirmó el commit y la versión de release.' 'The build did not confirm the release commit and version.'

    push_release_refs
    get_release_state
    case "$release_state" in
      draft)
        # Verify and upload the same private copy when updating an existing draft.
        draft_assets="$work/draft-assets"
        mkdir "$draft_assets" &&
          cp "$asset" "$asset.sha256" "$build_dir/latest.json" "$draft_assets/" &&
          CALA_BUILD_DIR="$draft_assets" ./scripts/publish-github.sh --dry-run "$tag" ||
          fail "No se pudieron verificar los archivos para el borrador de $tag." "Could not verify the assets for draft $tag."
        "$gh_cli" release upload "$tag" -R "$repo" --clobber \
          "$draft_assets/${asset:t}" "$draft_assets/${asset:t}.sha256" "$draft_assets/latest.json" ||
          fail "No se pudieron completar los archivos del borrador de $tag." "Could not complete the draft assets for $tag." ;;
      '')
        ./scripts/publish-github.sh "$tag" ||
          fail "No se pudo crear el borrador de $tag." "Could not create the draft for $tag." ;;
      published)
        fail "$tag ya está publicado. Si falta instalarlo, ejecuta ./install.sh." \
             "$tag is already published. If it still needs installation, run ./install.sh." ;;
    esac
    verify_draft "$build_dir/latest.json" ||
      fail "El manifiesto del borrador de $tag no pasó la verificación. El release sigue como borrador." \
           "The draft feed for $tag failed verification. The release is still a draft."

    # Keep the verified feed across interruptions between publishing and the anonymous check.
    pending_tmp=$(mktemp "$state_dir/.feed.XXXXXXXX") &&
      cp "$work/draft-latest.json" "$pending_tmp" &&
      mv -f -- "$pending_tmp" "$pending_feed" ||
      fail 'No se pudo guardar la verificación local del borrador.' 'Could not save the local draft verification.'
    if grep -Fxq 'CALA_RELEASE_NEEDS_PASSPHRASE=1' "$work/release.log"; then
      touch "$pending_feed.needs-passphrase"
    fi
  fi
  require_clean_head "$release_head"
  "$gh_cli" release edit "$tag" -R "$repo" --draft=false --latest --verify-tag ||
    fail "No se pudo confirmar la publicación de $tag. Reanuda esta misma versión." \
         "Could not confirm publication of $tag. Resume this same version."
fi

verify_public() {
  local feed="$work/public-latest.json"
  local url="https://github.com/$repo/releases/latest/download/latest.json"
  local deadline=$(( SECONDS + 180 )) remaining
  while (( (remaining = deadline - SECONDS) > 0 )); do
    if /usr/bin/curl -q -sfL --max-time "$(( remaining < 15 ? remaining : 15 ))" -o "$feed" "$url" &&
       cmp -s "$feed" "$pending_feed" &&
       "${signer[@]}" verify --keys packaging/update-public-keys --feed "$feed"; then
      return 0
    fi
    if (( SECONDS < deadline )); then sleep 5; fi
  done
  return 1
}

if ! verify_public; then
  if "$gh_cli" release edit "$tag" -R "$repo" --draft=true; then
    fail "Falló la verificación pública de $tag. Volvió a borrador. Reanuda la misma versión con ./scripts/ship.sh." \
         "Public verification failed for $tag. It is a draft again. Resume the same version with ./scripts/ship.sh."
  fi
  fail "Falló la verificación pública de $tag y GitHub no confirmó que volviera a borrador. Reanuda la misma versión con ./scripts/ship.sh." \
       "Public verification failed for $tag and GitHub did not confirm re-drafting it. Resume the same version with ./scripts/ship.sh."
fi

if [[ -f "$pending_feed.needs-passphrase" ]]; then
  print 'Guarda la frase una vez con ./scripts/ship.sh --save-passphrase / Save the passphrase once with ./scripts/ship.sh --save-passphrase'
fi
if ! rm -f -- "$pending_feed" "$pending_feed.needs-passphrase"; then
  print -u2 'El release está publicado. No se pudo limpiar el estado local. / The release is published. Could not clean up local state.'
fi
working_tree=$(git status --porcelain=v1 --untracked-files=all) ||
  fail "El release $tag está publicado. Comprueba el checkout y ejecuta ./install.sh." \
       "Release $tag is published. Check the checkout and run ./install.sh."
if [[ "$(git symbolic-ref --quiet --short HEAD)" != main ||
      "$(git rev-parse HEAD)" != "$release_head" ||
      -n "$working_tree" ]]; then
  fail "El release $tag está publicado. El checkout cambió. Desde el commit publicado, ejecuta ./install.sh." \
       "Release $tag is published. The checkout changed. Run ./install.sh from the published commit."
fi
CALA_VERSION="$version" ./install.sh ||
  fail "El release $tag está publicado. Para reintentar la instalación, ejecuta ./install.sh." \
       "Release $tag is published. To retry installation, run ./install.sh."
print -r -- "Cala $version publicada e instalada. / Cala $version published and installed."

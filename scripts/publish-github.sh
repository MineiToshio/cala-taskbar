#!/bin/zsh
# Uploads a verified DMG, checksum and signed feed as a draft, or verifies locally with --dry-run.
set -euo pipefail
cd "$(dirname "$0")/.."

dry_run=0
if [[ "${1:-}" == --dry-run ]]; then
  dry_run=1
  shift
fi
if (( $# > 1 )); then
  echo "Usage: $0 [--dry-run] [vX.Y.Z]" >&2
  exit 1
fi
if (( $# )); then
  tag=$1
else
  tag=v$(git show HEAD:VERSION | tr -d '[:space:]')
fi
[[ "$tag" =~ '^v[0-9]+\.[0-9]+\.[0-9]+$' ]] || { echo "Invalid release tag: $tag" >&2; exit 1; }
ref="refs/tags/$tag"
commit=$(git rev-parse --verify "$ref^{commit}") || { echo "Missing local release tag: $tag" >&2; exit 1; }
version=$(git show "${commit}:VERSION" | tr -d '[:space:]')
[[ "$tag" == "v$version" ]] || { echo "Tag $tag differs from committed VERSION $version" >&2; exit 1; }

build_dir=${CALA_BUILD_DIR:-build}
asset="Cala-$version.dmg"
[[ -f "$build_dir/$asset" && -f "$build_dir/$asset.sha256" && -f "$build_dir/latest.json" ]] ||
  { echo "Run ./scripts/release.sh $commit first" >&2; exit 1; }

# Mount, hash and upload the same private copy, even if the build directory is rebuilt meanwhile.
work=$(mktemp -d "${TMPDIR:-/tmp}/cala-publish.XXXXXXXX")
mount="$work/mnt"
mounted=0
cleanup() {
  if (( mounted )); then
    hdiutil detach -quiet "$mount" || hdiutil detach -quiet -force "$mount" || return
  fi
  rm -rf "$work"
}
trap cleanup EXIT
cp "$build_dir/$asset" "$build_dir/$asset.sha256" "$build_dir/latest.json" "$work/"
git show "${commit}:packaging/update-public-keys" > "$work/keys"
git show "${commit}:scripts/update-sign.swift" > "$work/update-sign.swift"
signer=(swift -module-cache-path "$work/modules" "$work/update-sign.swift")
"${signer[@]}" verify --keys "$work/keys" --feed "$work/latest.json" --dmg "$work/$asset"
sum=$(cd "$work" && shasum -a 256 "$asset")
[[ "${sum%% *}" == "$(cut -d' ' -f1 "$work/$asset.sha256")" ]] ||
  { echo "DMG checksum does not match $asset.sha256" >&2; exit 1; }
print -r -- "$sum" > "$work/$asset.sha256"

mkdir "$mount"
hdiutil attach -quiet -nobrowse -readonly -noautoopen -mountpoint "$mount" "$work/$asset"
mounted=1
"${signer[@]}" verify-release --keys "$work/keys" --feed "$work/latest.json" \
  --dmg "$work/$asset" --app "$mount/Cala.app" --tag "$tag"
hdiutil detach -quiet "$mount"
mounted=0

for lang in en es; do
  git show "${commit}:docs/releases/$version.$lang.md" > "$work/$lang.md"
  [[ -s "$work/$lang.md" ]] || { echo "Missing release notes in $commit ($lang)" >&2; exit 1; }
done
if (( dry_run )); then
  echo "Dry run passed for $tag ($commit). No release created."
  exit 0
fi

repo=MineiToshio/cala-taskbar
remote_refs=$(git ls-remote --exit-code "https://github.com/$repo.git" "$ref" "$ref^{}") ||
  { echo "Push $tag to GitHub first" >&2; exit 1; }
remote_commit=$(awk -v ref="$ref" '$2 == ref { tag = $1 } $2 == ref "^{}" { peeled = $1 }
  END { print (peeled == "" ? tag : peeled) }' <<< "$remote_refs")
[[ "$remote_commit" == "$commit" ]] || { echo "GitHub tag $tag points to a different commit" >&2; exit 1; }

{
  printf '## English\n\n'
  cat "$work/en.md"
  printf '\n\n## Español\n\n'
  cat "$work/es.md"
  printf '\n\n---\n\n[Install Cala](https://github.com/MineiToshio/cala-taskbar/blob/main/README.md#install) · [Instalar Cala](https://github.com/MineiToshio/cala-taskbar/blob/main/README.es.md#instalar)\n'
} > "$work/notes.md"
gh release create "$tag" "$work/$asset" "$work/$asset.sha256" "$work/latest.json" --repo "$repo" \
  --verify-tag --draft --title "Cala $version" --notes-file "$work/notes.md"
echo "Borrador creado. Revísalo y publícalo en GitHub: gh release view $tag --web"

#!/bin/zsh
# Uploads the signed update feed, DMG and checksum as a draft. Review and publish it on GitHub.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(tr -d '[:space:]' < VERSION)
BUILD_DIR=${CALA_BUILD_DIR:-build}
DMG="$BUILD_DIR/Cala-$VERSION.dmg"
feed="$BUILD_DIR/latest.json"
[[ -f "$DMG" && -f "$DMG.sha256" && -f "$feed" ]] || { echo "Run ./scripts/release.sh first" >&2; exit 1; }
built=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$BUILD_DIR/Cala.app/Contents/Info.plist")
[[ "$built" == "$VERSION" ]] || { echo "Built Cala is $built but VERSION is $VERSION; run ./scripts/release.sh" >&2; exit 1; }

swift scripts/update-sign.swift verify --keys packaging/update-public-keys --feed "$feed" --dmg "$DMG"
sum=$(shasum -a 256 "$DMG")
[[ "${sum%% *}" == "$(cut -d' ' -f1 "$DMG.sha256")" ]] ||
  { echo "DMG checksum does not match $DMG.sha256" >&2; exit 1; }
for lang in en es; do
  [[ -s "docs/releases/$VERSION.$lang.md" ]] || { echo "Missing docs/releases/$VERSION.$lang.md" >&2; exit 1; }
done
notes=$(mktemp "${TMPDIR:-/tmp}/cala-notes.XXXXXXXX")
trap 'rm -f "$notes"' EXIT
{
  printf '## English\n\n'
  cat "docs/releases/$VERSION.en.md"
  printf '\n\n## Español\n\n'
  cat "docs/releases/$VERSION.es.md"
  printf '\n\n---\n\n[Install Cala](https://github.com/MineiToshio/cala-taskbar/blob/main/README.md#install) · [Instalar Cala](https://github.com/MineiToshio/cala-taskbar/blob/main/README.es.md#instalar)\n'
} > "$notes"
gh release create "v$VERSION" "$DMG" "$DMG.sha256" "$feed" --repo MineiToshio/cala-taskbar \
  --draft --title "Cala $VERSION" --notes-file "$notes"
echo "Borrador creado. Revísalo y publícalo en GitHub: gh release view v$VERSION --web"

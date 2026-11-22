#!/bin/zsh
# Packs build/Cala.app into build/Cala-<version>.dmg: the app next to an Applications shortcut, so installing is one drag.
# Signs the disk image too when CALA_SIGN_IDENTITY is a real identity.
set -euo pipefail
cd "$(dirname "$0")/.."
APP=build/Cala.app
[[ -d "$APP" ]] || { echo "Run ./build.sh first" >&2; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG=build/Cala-$VERSION.dmg
IDENTITY=${CALA_SIGN_IDENTITY:--}

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
ditto "$APP" "$stage/Cala.app"
ln -s /Applications "$stage/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname "Cala" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$DMG"
if [[ "$IDENTITY" != "-" ]]; then
  codesign --force --sign "$IDENTITY" --timestamp "$DMG"
fi
echo "Listo: $DMG"

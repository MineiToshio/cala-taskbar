#!/bin/zsh
# Full release build, ready to upload by hand: universal app signed with Developer ID, notarized and stapled,
# inside a signed, notarized and stapled disk image, plus its SHA-256. Uploads nothing.
#
# Needs CALA_SIGN_IDENTITY and notarization credentials (see scripts/notarize.sh and docs/release.md).
# CALA_SKIP_NOTARIZE=1 builds and signs only (useful to check the signature before you have credentials).
set -euo pipefail
cd "$(dirname "$0")/.."
: ${CALA_SIGN_IDENTITY:?Set CALA_SIGN_IDENTITY to your \"Developer ID Application: …\" identity (see docs/release.md)}
[[ "$CALA_SIGN_IDENTITY" != "-" ]] || { echo "A release needs a Developer ID identity, not ad-hoc (-)" >&2; exit 1; }
[[ -n "${CALA_SENTRY_DSN:-}" ]] || echo "warning: CALA_SENTRY_DSN is not set; 'Report a problem' will be off in this build" >&2

./scripts/check-rules.sh >/dev/null && echo "› checks passed"
./build.sh
APP=build/Cala.app
codesign --verify --strict --verbose=2 "$APP"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q automation.apple-events || { echo "entitlements missing" >&2; exit 1; }

if [[ -z "${CALA_SKIP_NOTARIZE:-}" ]]; then
  # 1. Notarize and staple the app itself, so it opens without a network check once copied out of the disk image.
  zip=build/Cala-notarize.zip
  ditto -c -k --keepParent "$APP" "$zip"
  ./scripts/notarize.sh "$zip"
  xcrun stapler staple "$APP"
  rm -f "$zip"
fi
# 2. The disk image around the stapled app.
./scripts/make-dmg.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG=build/Cala-$VERSION.dmg
if [[ -z "${CALA_SKIP_NOTARIZE:-}" ]]; then
  ./scripts/notarize.sh "$DMG"
  spctl -a -t open --context context:primary-signature -vv "$DMG"
  spctl -a -t exec -vv "$APP"
fi
shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "Release lista: $DMG (no se ha subido a ningún sitio)"

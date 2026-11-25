#!/bin/zsh
# Release build, ready to upload: universal app inside a disk image, plus its SHA-256. Uploads nothing
# (scripts/publish-github.sh does that, as a draft).
#
# Two kinds of release:
#   free (default)  ad-hoc signed, not notarized. Users unblock it once (README "Install", option 2 step 3). No Apple account.
#   signed          CALA_SIGN_IDENTITY="Developer ID Application: …" plus notarization credentials
#                   (scripts/notarize.sh): no Gatekeeper block at all. Needs the paid Apple Developer Program.
# CALA_SKIP_NOTARIZE=1 signs with Developer ID but skips notarization.
set -euo pipefail
cd "$(dirname "$0")/.."

# A release is built from the last commit only, never from uncommitted work in progress: if the working tree has
# changes, build in a temporary clean checkout of HEAD and copy the results back into build/.
if [[ -z "${CALA_IN_CLEAN_TREE:-}" && -n "$(git status --porcelain --untracked-files=no)" ]]; then
  echo "› uncommitted changes here: building $(git rev-parse --short HEAD) in a clean checkout"
  clean=$(mktemp -d)/cala
  git worktree add --detach --quiet "$clean" HEAD
  trap 'git worktree remove --force "$clean" 2>/dev/null' EXIT
  CALA_IN_CLEAN_TREE=1 CALA_BUILD_NUMBER=${CALA_BUILD_NUMBER:-$(git rev-list --count HEAD)} "$clean/scripts/release.sh"
  mkdir -p build
  rm -rf build/Cala.app
  ditto "$clean/build/Cala.app" build/Cala.app
  cp "$clean"/build/Cala-*.dmg "$clean"/build/Cala-*.dmg.sha256 build/
  echo "Release lista en build/ (desde el commit $(git rev-parse --short HEAD), sin cambios sin commitear)"
  exit 0
fi
CALA_SIGN_IDENTITY=${CALA_SIGN_IDENTITY:--}
export CALA_SIGN_IDENTITY
[[ "$CALA_SIGN_IDENTITY" == "-" ]] && { echo "› free release: ad-hoc signed, not notarized (users unblock it once)"; CALA_SKIP_NOTARIZE=1; }
[[ -z "${CALA_QA_REGULAR:-}" ]] || { echo "CALA_QA_REGULAR is for testing builds only" >&2; exit 1; }
[[ -n "${CALA_SENTRY_DSN:-}" ]] || echo "warning: CALA_SENTRY_DSN is not set; 'Report a problem' will be off in this build" >&2

./scripts/check-rules.sh >/dev/null && ./scripts/check-mail.sh >/dev/null && ./scripts/check-modules.sh >/dev/null && ./scripts/check-zones.sh >/dev/null && ./scripts/check-update.sh >/dev/null || exit 1
echo "› checks passed"
./build.sh
APP=build/Cala.app
codesign --verify --strict --verbose=2 "$APP"
if [[ "$CALA_SIGN_IDENTITY" != "-" ]]; then
  codesign -d --entitlements - "$APP" 2>/dev/null | grep -q automation.apple-events || { echo "entitlements missing" >&2; exit 1; }
fi

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

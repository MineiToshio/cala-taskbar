#!/bin/zsh
# Sends a file (.dmg or .zip) to Apple's notary service, waits for the verdict and staples the ticket.
# Credentials come only from the environment, in one of three forms (first one found wins):
#
#   CALA_NOTARY_PROFILE                         a keychain profile made once with
#                                               `xcrun notarytool store-credentials <name>`   (recommended)
#   CALA_NOTARY_KEY + CALA_NOTARY_KEY_ID + CALA_NOTARY_ISSUER    App Store Connect API key (.p8 path) — for CI
#   CALA_APPLE_ID + CALA_TEAM_ID + CALA_APP_PASSWORD             Apple ID with an app-specific password
#
# Usage: scripts/notarize.sh build/Cala-1.0.0.dmg
set -euo pipefail
file=${1:?usage: notarize.sh <file.dmg|file.zip>}
[[ -f "$file" ]] || { echo "No such file: $file" >&2; exit 1; }

auth=()
if [[ -n "${CALA_NOTARY_PROFILE:-}" ]]; then
  auth=(--keychain-profile "$CALA_NOTARY_PROFILE")
elif [[ -n "${CALA_NOTARY_KEY:-}" && -n "${CALA_NOTARY_KEY_ID:-}" && -n "${CALA_NOTARY_ISSUER:-}" ]]; then
  auth=(--key "$CALA_NOTARY_KEY" --key-id "$CALA_NOTARY_KEY_ID" --issuer "$CALA_NOTARY_ISSUER")
elif [[ -n "${CALA_APPLE_ID:-}" && -n "${CALA_TEAM_ID:-}" && -n "${CALA_APP_PASSWORD:-}" ]]; then
  auth=(--apple-id "$CALA_APPLE_ID" --team-id "$CALA_TEAM_ID" --password "$CALA_APP_PASSWORD")
else
  echo "No notarization credentials. Set CALA_NOTARY_PROFILE (see docs/release.md)." >&2
  exit 2
fi

echo "› notarytool submit $file"
out=$(xcrun notarytool submit "$file" "${auth[@]}" --wait --output-format json)
print -r -- "$out"
status=$(print -r -- "$out" | /usr/bin/plutil -extract status raw -o - - 2>/dev/null || true)
if [[ "$status" != "Accepted" ]]; then
  id=$(print -r -- "$out" | /usr/bin/plutil -extract id raw -o - - 2>/dev/null || true)
  echo "Notarization failed ($status). Details: xcrun notarytool log $id <same credentials>" >&2
  exit 1
fi
case "$file" in
  *.zip) echo "(a .zip cannot be stapled; staple the .app inside it)";;
  *) xcrun stapler staple "$file"; xcrun stapler validate "$file";;
esac
echo "Notarizado: $file"

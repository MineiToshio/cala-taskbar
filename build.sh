#!/bin/zsh
# Builds build/Cala.app (universal: Apple silicon + Intel). Every machine-specific value comes from the environment:
#
#   CALA_BUNDLE_ID      bundle identifier                     (default: local.cala)
#   CALA_VERSION        marketing version, e.g. 1.0.0          (default: contents of VERSION)
#   CALA_BUILD_NUMBER   build number                           (default: number of git commits)
#   CALA_ARCHS          architectures                          (default: "arm64 x86_64")
#   CALA_SIGN_IDENTITY  codesign identity; "-" = ad-hoc       (default: -)
#                       e.g. "Developer ID Application: Your Name (TEAMID)" for a release
#   CALA_SENTRY_DSN     where "Report a problem" sends to      (optional; without it reporting is off)
#   CALA_QA_REGULAR     1 = testing only: a normal (Dock) app, so UI-automation tools can drive it. Never for a release.
#   CALA_BUILD_DIR      bundle output directory                (default: build)
#   CALA_UPDATE_TEST    1 = compile in update fixture overrides
#
# Both kinds of build use the hardened runtime and packaging/Cala.entitlements; a Developer ID identity adds a secure
# timestamp. Contents/Helpers/cala-keychain is the prebuilt packaging/Helpers/cala-keychain, copied byte for byte and,
# for ad-hoc builds, never re-signed: its fixed cdhash is what lets the Keychain trust it across Cala updates.
set -euo pipefail
cd "$(dirname "$0")"

BUNDLE_ID=${CALA_BUNDLE_ID:-local.cala}
VERSION=${CALA_VERSION:-$(tr -d '[:space:]' < VERSION)}
BUILD_NUMBER=${CALA_BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}
ARCHS=(${=CALA_ARCHS:-arm64 x86_64})
IDENTITY=${CALA_SIGN_IDENTITY:--}
DSN=${CALA_SENTRY_DSN:-}
BUILD_DIR=${CALA_BUILD_DIR:-build}
FEED_URL=https://github.com/MineiToshio/cala-taskbar/releases/latest/download/latest.json
KEYS=$(<packaging/update-public-keys)
swift_flags=()
scratch_flags=()

xml() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' <<< "$1"; }
update_test_plist=
if [[ "${CALA_UPDATE_TEST:-}" == 1 ]]; then
  swift_flags=(-Xswiftc -DCALA_UPDATE_TEST)
  KEYS=${CALA_UPDATE_PUBLIC_KEYS-$KEYS}
  FEED_URL=${CALA_UPDATE_FEED_URL-$FEED_URL}
  update_test_plist='<key>CalaUpdateTest</key><true/>'
  if [[ -n "${CALA_UPDATE_TEST_FAULT:-}" ]]; then
    [[ "$CALA_UPDATE_TEST_FAULT" == before-swap || "$CALA_UPDATE_TEST_FAULT" == after-swap ]] ||
      { echo "Invalid CALA_UPDATE_TEST_FAULT" >&2; exit 1; }
    update_test_plist+="<key>CalaUpdateTestFault</key><string>$CALA_UPDATE_TEST_FAULT</string>"
  fi
  for timing in "UpTimeout:${CALA_UPDATE_TEST_UP_TIMEOUT:-}" "IdleSeconds:${CALA_UPDATE_TEST_IDLE_SECONDS:-}"; do
    seconds=${timing#*:}
    [[ -n "$seconds" ]] || continue
    [[ "$seconds" =~ '^[0-9]+(\.[0-9]+)?$' ]] || { echo "Invalid update test timing: $timing" >&2; exit 1; }
    update_test_plist+="<key>CalaUpdateTest${timing%%:*}</key><real>$seconds</real>"
  done
  if [[ "${CALA_UPDATE_TEST_CRASH_AT_LAUNCH:-}" == 1 ]]; then
    update_test_plist+='<key>CalaUpdateTestCrashAtLaunch</key><true/>'
  fi
fi

keys_plist=
key_list=(${=KEYS})
(( ${#key_list} <= 2 )) || { echo "Expected at most two update public keys" >&2; exit 1; }
for key in "${key_list[@]}"; do
  [[ "$key" =~ '^[A-Za-z0-9+/]{43}=$' ]] || { echo "Invalid update public key" >&2; exit 1; }
  keys_plist+="<string>$key</string>"
done
if [[ -n "$keys_plist" ]]; then
  keys_plist="<key>CalaUpdatePublicKeys</key><array>$keys_plist</array>"
fi

[[ "$BUNDLE_ID" =~ '^[A-Za-z0-9.-]+$' ]] || { echo "CALA_BUNDLE_ID must be letters, digits, dots and hyphens" >&2; exit 1; }
[[ "$VERSION" =~ '^[0-9]+(\.[0-9]+){0,2}$' ]] || { echo "CALA_VERSION must look like 1.2.3" >&2; exit 1; }
[[ "$BUILD_NUMBER" =~ '^[0-9]+$' ]] || { echo "CALA_BUILD_NUMBER must be an integer" >&2; exit 1; }
if [[ -n "${CALA_BUILD_DIR:-}" ]]; then
  mkdir -p "$BUILD_DIR"
  # Keep SwiftPM's module cache address stable through aliases such as /var and /private/var.
  BUILD_DIR=${BUILD_DIR:A}
  scratch_flags=(--scratch-path "$BUILD_DIR/.build")
fi

bins=()
update_bins=()
for arch in $ARCHS; do
  echo "› swift build ($arch)"
  args=(-c release --triple "$arch-apple-macosx14.0" "${scratch_flags[@]}" "${swift_flags[@]}")
  swift build "${args[@]}"
  bin_dir=$(swift build "${args[@]}" --show-bin-path)
  bins+=("$bin_dir/Cala")
  update_bins+=("$bin_dir/cala-update")
done

APP="$BUILD_DIR/Cala.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "${bins[@]}" -output "$APP/Contents/MacOS/Cala"
cp branding/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
mkdir -p "$APP/Contents/Helpers"
cp -X packaging/Helpers/cala-keychain "$APP/Contents/Helpers/cala-keychain"
UPDATE_HELPER="$APP/Contents/Helpers/cala-update"
lipo -create "${update_bins[@]}" -output "$UPDATE_HELPER"
for lang in en es; do
  mkdir -p "$APP/Contents/Resources/$lang.lproj"
  cp "packaging/$lang.lproj/InfoPlist.strings" "$APP/Contents/Resources/$lang.lproj/"
done

cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleName</key><string>Cala</string>
<key>CFBundleDisplayName</key><string>Cala</string>
<key>CFBundleExecutable</key><string>Cala</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>es</string></array>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
<key>LSUIElement</key>$([[ -n "${CALA_QA_REGULAR:-}" ]] && echo "<false/><key>CalaQARegular</key><true/>" || echo "<true/>")
<key>NSHighResolutionCapable</key><true/>
${DSN:+<key>CalaSentryDSN</key><string>$(xml "$DSN")</string>}
<key>CalaUpdateFeedURL</key><string>$(xml "$FEED_URL")</string>
$keys_plist
$update_test_plist
<key>NSScreenCaptureUsageDescription</key><string>Cala draws thumbnails of your windows when you hover over an app. Your screen is never recorded or sent.</string>
<key>NSAppleEventsUsageDescription</key><string>Cala asks Finder to count and empty the Trash, and to restart your Mac, only when you ask it to.</string>
<key>NSCalendarsFullAccessUsageDescription</key><string>Cala shows your upcoming events in the clock panel and a Join button before video calls. Events stay on this Mac.</string>
<key>NSCalendarsUsageDescription</key><string>Cala shows your upcoming events in the clock panel. Events stay on this Mac.</string>
<key>NSBluetoothAlwaysUsageDescription</key><string>Cala lists and connects your paired Bluetooth devices from the tray.</string>
<key>NSLocationWhenInUseUsageDescription</key><string>macOS only shows Wi-Fi network names to apps with Location. Cala does not read where you are.</string>
<key>NSLocationUsageDescription</key><string>macOS only shows Wi-Fi network names to apps with Location. Cala does not read where you are.</string>
</dict></plist>
PL
plutil -lint -s "$APP/Contents/Info.plist"

HELPER="$APP/Contents/Helpers/cala-keychain"
scripts/verify-keychain-helper.sh "$HELPER"   # the committed bytes, before anything signs around it
if [[ "$IDENTITY" == "-" ]]; then
  # Ad-hoc: a fixed designated requirement keeps macOS permission grants across local rebuilds. No --deep: the helper
  # keeps its own (committed) signature.
  codesign --force --sign - --options runtime --identifier local.cala.update "$UPDATE_HELPER"
  codesign --force --sign - --options runtime --entitlements packaging/Cala.entitlements \
    -r="designated => identifier \"$BUNDLE_ID\"" "$APP"
  scripts/verify-keychain-helper.sh "$HELPER" --cdhash
else
  # Developer ID: every nested binary must carry the identity for notarization. The Keychain then trusts the team id,
  # which is just as stable across updates.
  codesign --force --sign "$IDENTITY" --options runtime --timestamp --identifier local.cala.keychain "$HELPER"
  codesign --force --sign "$IDENTITY" --options runtime --timestamp --identifier local.cala.update "$UPDATE_HELPER"
  codesign --force --sign "$IDENTITY" --options runtime --timestamp --entitlements packaging/Cala.entitlements "$APP"
fi
codesign --verify --strict "$APP"
codesign --verify --strict "$HELPER"
codesign --verify --strict "$UPDATE_HELPER"

# The helper serves the app whose CFBundleIdentifier its bundle declares, signed with that identifier, and (when the
# helper has a Team ID) only that team. Anything inconsistent here would leave Mail without its passwords: fail.
sig() { codesign -dvvv "$1" 2>&1 | sed -n "s/^$2=//p"; }
plist_id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist")
[[ "$plist_id" == "$BUNDLE_ID" ]] || { echo "Info.plist id $plist_id != $BUNDLE_ID" >&2; exit 1; }
[[ "$(sig "$APP" Identifier)" == "$BUNDLE_ID" ]] || { echo "app signing identifier $(sig "$APP" Identifier) != $BUNDLE_ID" >&2; exit 1; }
[[ "$(sig "$HELPER" Identifier)" == local.cala.keychain ]] || { echo "helper identifier is $(sig "$HELPER" Identifier)" >&2; exit 1; }
app_team=$(sig "$APP" TeamIdentifier); helper_team=$(sig "$HELPER" TeamIdentifier)
if [[ "$IDENTITY" == "-" ]]; then
  [[ "$app_team" == "not set" && "$helper_team" == "not set" ]] || { echo "ad-hoc build with a Team ID (app $app_team, helper $helper_team)" >&2; exit 1; }
else
  [[ -n "$app_team" && "$app_team" != "not set" && "$helper_team" == "$app_team" ]] || { echo "Team ID mismatch: app ${app_team:-none}, helper ${helper_team:-none}" >&2; exit 1; }
fi
chmod -R go-w "$APP"
echo "Listo: $APP ($VERSION build $BUILD_NUMBER, ${ARCHS[*]}, firma: $([[ $IDENTITY == - ]] && echo ad-hoc || echo "$IDENTITY"))"

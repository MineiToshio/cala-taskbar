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
#
# A Developer ID identity turns on the hardened runtime, a secure timestamp and packaging/Cala.entitlements.
set -euo pipefail
cd "$(dirname "$0")"

BUNDLE_ID=${CALA_BUNDLE_ID:-local.cala}
VERSION=${CALA_VERSION:-$(tr -d '[:space:]' < VERSION)}
BUILD_NUMBER=${CALA_BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}
ARCHS=(${=CALA_ARCHS:-arm64 x86_64})
IDENTITY=${CALA_SIGN_IDENTITY:--}
DSN=${CALA_SENTRY_DSN:-}

[[ "$BUNDLE_ID" =~ '^[A-Za-z0-9.-]+$' ]] || { echo "CALA_BUNDLE_ID must be letters, digits, dots and hyphens" >&2; exit 1; }
[[ "$VERSION" =~ '^[0-9]+(\.[0-9]+){0,2}$' ]] || { echo "CALA_VERSION must look like 1.2.3" >&2; exit 1; }

bins=()
for arch in $ARCHS; do
  echo "› swift build ($arch)"
  swift build -c release --triple "$arch-apple-macosx14.0"
  bins+=(".build/$arch-apple-macosx/release/Cala")
done

APP=build/Cala.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "${bins[@]}" -output "$APP/Contents/MacOS/Cala"
cp branding/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
for lang in en es; do
  mkdir -p "$APP/Contents/Resources/$lang.lproj"
  cp "packaging/$lang.lproj/InfoPlist.strings" "$APP/Contents/Resources/$lang.lproj/"
done

xml() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' <<< "$1"; }
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

if [[ "$IDENTITY" == "-" ]]; then
  # Ad-hoc: a fixed designated requirement keeps macOS permission grants across local rebuilds.
  codesign --force --sign - -r="designated => identifier \"$BUNDLE_ID\"" "$APP"
else
  codesign --force --sign "$IDENTITY" --options runtime --timestamp --entitlements packaging/Cala.entitlements "$APP"
fi
codesign --verify --strict "$APP"
chmod -R go-w "$APP"
echo "Listo: $APP ($VERSION build $BUILD_NUMBER, ${ARCHS[*]}, firma: $([[ $IDENTITY == - ]] && echo ad-hoc || echo "$IDENTITY"))"

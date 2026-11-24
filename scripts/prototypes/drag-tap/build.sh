#!/bin/zsh
# Builds build/DragTapProbe.app: a tiny ad-hoc-signed bundle with a FIXED designated requirement,
# so TCC (Accessibility / Input Monitoring) sees its own stable identity "local.cala.tapprobe"
# instead of inheriting the terminal's permissions, and a grant survives rebuilds.
#
#   ./build.sh
#   open build/DragTapProbe.app --args --probe     # permissions report, exits
#   open build/DragTapProbe.app                    # live prototype, self-exits after 60 s
#   tail -f /tmp/drag-tap-probe.log
set -euo pipefail
cd "$(dirname "$0")"

APP=build/DragTapProbe.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 -target arm64-apple-macosx14.0 DragTap.swift -o "$APP/Contents/MacOS/DragTapProbe"

cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.cala.tapprobe</string>
<key>CFBundleName</key><string>DragTapProbe</string>
<key>CFBundleExecutable</key><string>DragTapProbe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
PL

codesign --force --sign - -r='designated => identifier "local.cala.tapprobe"' "$APP"
codesign -dr - "$APP" 2>&1 | tail -1
echo "Built $PWD/$APP"

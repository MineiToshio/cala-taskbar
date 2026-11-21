#!/bin/zsh
set -e
cd "$(dirname "$0")"
swift build -c release
APP=build/Cala.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp .build/release/Cala "$APP/Contents/MacOS/Cala"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.cala</string>
<key>CFBundleName</key><string>Cala</string>
<key>CFBundleDisplayName</key><string>Cala</string>
<key>CFBundleExecutable</key><string>Cala</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSScreenCaptureUsageDescription</key><string>Mostrar previews de ventanas</string>
<key>NSCalendarsFullAccessUsageDescription</key><string>Show upcoming events from the calendars you choose in the taskbar. Events stay on this Mac.</string>
<key>NSCalendarsUsageDescription</key><string>Show upcoming events from your selected calendars in the taskbar.</string>
<key>NSBluetoothAlwaysUsageDescription</key><string>Mostrar y conectar dispositivos Bluetooth</string>
<key>NSLocationWhenInUseUsageDescription</key><string>Leer el nombre de las redes Wi-Fi</string>
<key>NSLocationUsageDescription</key><string>Leer el nombre de las redes Wi-Fi</string>
</dict></plist>
PL
codesign --force --deep --sign - -r='designated => identifier "local.cala"' "$APP"
chmod -R go-w "$APP"
echo "Listo: $APP"

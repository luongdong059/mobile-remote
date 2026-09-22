#!/bin/bash
# Builds dist/Mobile Remote.app from the SwiftPM package.
#   scripts/build-app.sh            build only
#   scripts/build-app.sh --install  also copy it into /Applications
set -euo pipefail

APP_NAME="Mobile Remote"
BUNDLE_ID="com.nldong.MobileRemote"
VERSION="0.1.0"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
APP="$ROOT/dist/$APP_NAME.app"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

swift build -c release --product MobileRemote
BIN="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/MobileRemote" "$APP/Contents/MacOS/MobileRemote"
# Looked up through Bundle.main at run time (see ServerBinary / AppResources).
cp Sources/ScrcpyKit/Resources/scrcpy-server-v4.1 "$APP/Contents/Resources/"
cp Sources/MobileRemote/Resources/AppLogo.png "$APP/Contents/Resources/"

swift scripts/make-icon.swift Sources/MobileRemote/Resources/AppLogo.png "$WORK/icon-1024.png"
ICONSET="$WORK/AppIcon.iconset"
mkdir "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z $size $size "$WORK/icon-1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$WORK/icon-1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>vi</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleExecutable</key><string>MobileRemote</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSCameraUsageDescription</key><string>iOS đưa màn hình iPhone tới máy Mac dưới dạng một thiết bị video, nên cần quyền Camera để phản chiếu iPhone.</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# Ad-hoc signature: enough to run on this Mac; distribution needs Developer ID.
codesign --force --sign - "$APP"
echo "built $APP"

if [ "${1:-}" = "--install" ]; then
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP" "/Applications/"
    echo "installed /Applications/$APP_NAME.app"
fi

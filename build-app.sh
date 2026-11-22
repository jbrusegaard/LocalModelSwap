#!/bin/bash
# Build ModelSwitch and assemble a runnable "Model Switch.app" bundle.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --product ModelSwitch

APP="build/Model Switch.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cp .build/release/ModelSwitch "$APP/Contents/MacOS/ModelSwitch"

# Icon: render with tools/make-icon.swift if the checked-in .icns is missing.
if [ ! -f Resources/AppIcon.icns ]; then
    mkdir -p build/AppIcon.iconset Resources
    swift tools/make-icon.swift build/AppIcon.iconset
    iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
fi
mkdir -p "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>ModelSwitch</string>
    <key>CFBundleIdentifier</key>
    <string>com.local.modelswitch</string>
    <key>CFBundleName</key>
    <string>Model Switch</string>
    <key>CFBundleDisplayName</key>
    <string>Model Switch</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <!-- The only hosts this app talks to are LAN IPs from providers.json. -->
        <key>NSAllowsLocalNetworking</key>
        <true/>
    </dict>
</dict>
</plist>
PLIST

# Finder metadata on staged resources makes codesign reject the whole bundle.
xattr -cr "$APP" 2>/dev/null || true
codesign --force --deep -s - "$APP" 2>/dev/null || true

echo "Built $APP"

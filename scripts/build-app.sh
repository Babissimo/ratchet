#!/bin/bash
# Builds Ratchet.app, a real macOS app bundle wrapping the SPM executable.
#
# SPM's `swift build` alone only produces a raw Mach-O binary — macOS only
# routes a custom URL scheme (ratchet://) to an app that Launch Services
# knows about via a bundle's Info.plist. This script assembles that bundle
# around the SPM-built binary rather than converting the project to an
# Xcode project.
#
# Usage: scripts/build-app.sh [debug|release]

set -euo pipefail

CONFIG="${1:-debug}"
if [[ "$CONFIG" != "debug" && "$CONFIG" != "release" ]]; then
    echo "Usage: $0 [debug|release]" >&2
    exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "Building Ratchet ($CONFIG)..."
swift build -c "$CONFIG"

BIN_PATH=".build/$CONFIG/Ratchet"
APP_DIR=".build/Ratchet.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
cp "$BIN_PATH" "$MACOS_DIR/Ratchet"

cat > "$CONTENTS_DIR/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Ratchet</string>
    <key>CFBundleDisplayName</key>
    <string>Ratchet</string>
    <key>CFBundleIdentifier</key>
    <string>com.ratchet.app</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>Ratchet</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>com.ratchet.app.oauth</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>ratchet</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

touch "$APP_DIR"

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
    "$LSREGISTER" -f "$APP_DIR"
fi

echo "Built: $APP_DIR"
echo "Run with: open $APP_DIR"

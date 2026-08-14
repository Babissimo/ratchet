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
# --product keeps IconExporter (a dev-only AppKit renderer that is never bundled) out of the
# app build; it gets built explicitly below instead.
swift build -c "$CONFIG" --product Ratchet

# The icon is drawn by RatchetIcon in Swift, so regenerate it from current source on every build
# rather than trusting the committed .icns — otherwise a colour or texture tweak changes the
# dialog icon the app draws live while the Dock/Finder icon silently stays on the old art.
# Everything lands under .build so a build never dirties tracked files.
echo "Regenerating app icon..."
ICON_DIR=".build/icons"
ICNS_PATH="$ICON_DIR/AppIcon.icns"
rm -rf "$ICON_DIR/AppIcon.iconset"
# Same config as the app build above, so this only has to compile IconExporter itself rather
# than a second copy of RatchetCore.
swift run -c "$CONFIG" IconExporter "$ICON_DIR" > /dev/null
iconutil -c icns "$ICON_DIR/AppIcon.iconset" -o "$ICNS_PATH"

BIN_PATH=".build/$CONFIG/Ratchet"
APP_DIR=".build/Ratchet.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BIN_PATH" "$MACOS_DIR/Ratchet"
cp "$ICNS_PATH" "$RESOURCES_DIR/AppIcon.icns"

# Resources/AppIcon.icns is committed for anyone packaging without this script, so flag it when
# it no longer matches what the code draws. Advisory only: the bundle above already has the
# fresh icon, and rewriting a tracked file mid-build would be a nasty surprise.
if ! cmp -s "$ICNS_PATH" "Resources/AppIcon.icns"; then
    echo "WARNING: Resources/AppIcon.icns is stale. Refresh it with:" >&2
    echo "    cp $ICNS_PATH Resources/AppIcon.icns" >&2
fi

# The same IconExporter run above also wrote the FreeAgent listing icon into $ICON_DIR (no
# second invocation needed). It's committed under design/icons for the FreeAgent connected-app
# listing, which this build doesn't touch — so, same as AppIcon.icns, just warn if it's stale.
FREEAGENT_ICON_PATH="$ICON_DIR/freeagent-icon.png"
if ! cmp -s "$FREEAGENT_ICON_PATH" "design/icons/freeagent-icon.png"; then
    echo "WARNING: design/icons/freeagent-icon.png is stale. Refresh it with:" >&2
    echo "    cp $FREEAGENT_ICON_PATH design/icons/freeagent-icon.png" >&2
fi

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
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
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

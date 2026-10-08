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
# Set FREEAGENT_SANDBOX=1 to build against FreeAgent's sandbox, and RATCHET_VERSION (e.g. 1.2.0)
# to stamp the bundle with a release version.

set -euo pipefail

CONFIG="${1:-debug}"
if [[ "$CONFIG" != "debug" && "$CONFIG" != "release" ]]; then
    echo "Usage: $0 [debug|release]" >&2
    exit 1
fi

# CFBundleVersion accepts only up to three dot-separated integers.
VERSION="${RATCHET_VERSION:-1.0}"
if [[ ! "$VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
    echo "RATCHET_VERSION must be up to three dot-separated integers, not '$VERSION'" >&2
    exit 1
fi

# Must match `platforms` in Package.swift.
MIN_MACOS="13.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "Building Ratchet ($CONFIG)..."
SWIFT_FLAGS=()
if [[ "${FREEAGENT_SANDBOX:-}" == "1" ]]; then
    SWIFT_FLAGS+=(-Xswiftc -DFREEAGENT_SANDBOX)
fi

# --product keeps IconExporter (a dev-only AppKit renderer that is never bundled) out of the
# app build; it gets built explicitly below instead.
if [[ "$CONFIG" == "release" ]]; then
    # A release has to run on both Intel and Apple silicon. `swift build --arch` would need
    # Xcode's xcbuild, so build each architecture on its own and join them with lipo.
    for ARCH in arm64 x86_64; do
        swift build -c release --product Ratchet --triple "$ARCH-apple-macosx$MIN_MACOS" \
            ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"}
    done
    BIN_PATH=".build/universal/Ratchet"
    mkdir -p "$(dirname "$BIN_PATH")"
    lipo -create -output "$BIN_PATH" \
        .build/arm64-apple-macosx/release/Ratchet .build/x86_64-apple-macosx/release/Ratchet
else
    swift build -c debug --product Ratchet ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"}
    BIN_PATH=".build/debug/Ratchet"
fi

# The icon is drawn by RatchetIcon in Swift, so regenerate it from current source on every build
# rather than trusting the committed .icns — otherwise a colour or texture tweak changes the
# dialog icon the app draws live while the Dock/Finder icon silently stays on the old art.
# Everything lands under .build so a build never dirties tracked files.
echo "Regenerating app icon..."
ICON_DIR=".build/icons"
ICNS_PATH="$ICON_DIR/AppIcon.icns"
rm -rf "$ICON_DIR/AppIcon.iconset"
# Same config and flags as the app build above, so this only has to compile IconExporter itself
# rather than a second copy of RatchetCore.
swift run -c "$CONFIG" ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"} IconExporter "$ICON_DIR" > /dev/null
iconutil -c icns "$ICON_DIR/AppIcon.iconset" -o "$ICNS_PATH"

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

cat > "$CONTENTS_DIR/Info.plist" << PLIST
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
    <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
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
    <string>$MIN_MACOS</string>
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

# A stable identity matters beyond just quieting the Keychain-access reprompt this was originally
# for: SMAppService (Launch at Login) ties its registration to the code signature's Identifier,
# which for the default ad-hoc signature `swift build` applies regenerates on every rebuild —
# macOS then sees a "new" app each time and drops the previous Launch at Login registration
# silently. `--identifier` pins it to the stable bundle ID regardless of which signing identity
# below actually gets used, so that part holds even in the ad-hoc fallback case.
#
# `-p codesigning` in `find-identity` also filters on trust policy, which a fresh self-signed cert
# doesn't satisfy without the user explicitly setting it in Keychain Access — `find-certificate`
# only checks existence, which is all `codesign -s` itself needs to use the identity locally.
if security find-certificate -c "Ratchet" > /dev/null 2>&1; then
    codesign --force --timestamp=none --sign "Ratchet" --identifier com.ratchet.app "$APP_DIR"
else
    echo "WARNING: no 'Ratchet' code signing certificate found in Keychain — building ad-hoc." >&2
    echo "  Launch at Login won't persist across rebuilds until it exists. See TODO.md." >&2
    codesign --force --timestamp=none --sign - --identifier com.ratchet.app "$APP_DIR"
fi

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
    "$LSREGISTER" -f "$APP_DIR"
fi

echo "Built: $APP_DIR"
echo "Run with: open $APP_DIR"

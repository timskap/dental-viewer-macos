#!/bin/bash
# Builds DentalViewer as a proper macOS .app bundle.
#
# Usage: ./build_app.sh           (release build, default)
#        ./build_app.sh debug     (debug build)
set -euo pipefail

CONFIG="${1:-release}"
APP_NAME="DentalViewer"
BUNDLE_ID="com.dentalviewer.app"
VERSION="1.0"

cd "$(dirname "$0")"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)"
BIN="$BIN_PATH/$APP_NAME"

if [ ! -x "$BIN" ]; then
    echo "ERROR: built binary not found at $BIN" >&2
    exit 1
fi

APP_DIR="build/$APP_NAME.app"
echo "==> Assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BIN" "$APP_DIR/Contents/MacOS/$APP_NAME"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>Dental Viewer</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleSignature</key>
    <string>????</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>DICOM Folder</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.folder</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"

# Ad-hoc codesign so Gatekeeper / TCC will accept the bundle locally.
echo "==> Ad-hoc codesigning"
codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || \
    echo "   (codesign skipped — not fatal for local runs)"

echo
echo "Built: $APP_DIR"
echo "Run with:  open \"$APP_DIR\""

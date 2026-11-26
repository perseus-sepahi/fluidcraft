#!/bin/bash
# Build FluidCraft.app (release) from the SwiftPM products.
#
#   Scripts/build-app.sh            -> dist/FluidCraft.app (ad-hoc signed, this Mac only)
#   Scripts/build-app.sh install    -> also copies it to /Applications
#   Scripts/build-app.sh release    -> Developer ID signed, hardened runtime, notarized and stapled;
#                                      macOS/Direct/FluidCraft.dmg (needs the "notary" keychain profile)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/FluidCraft.app"
cd "$ROOT"

echo "==> Building release products"
swift build -c release --product FluidCraft
swift build -c release --product fluidcraft-cli
BIN="$(swift build -c release --show-bin-path)"

if [ ! -f "$ROOT/Assets/AppIcon.icns" ]; then
    echo "==> Generating icon"
    "$ROOT/Scripts/make-icon.sh"
fi

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BIN/FluidCraft" "$APP/Contents/MacOS/FluidCraft"
cp "$BIN/fluidcraft-cli" "$APP/Contents/Helpers/fluidcraft"
cp "$ROOT/Assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
ditto "$ROOT/Docs/Guide" "$APP/Contents/Resources/Guide"
VERSION="1.0"
SIGN_ID="Developer ID Application: MOHAMMADREZA SEPAHI (ZY74XX7D42)"
BUILD="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>FluidCraft</string>
    <key>CFBundleDisplayName</key><string>FluidCraft</string>
    <key>CFBundleIdentifier</key><string>com.williamsepahi.fluidcraft</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleExecutable</key><string>FluidCraft</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>© 2026 Perseus Sepahi. Free software under the GNU GPL, version 3.</string>
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key><string>com.williamsepahi.fluidcraft.case</string>
            <key>UTTypeDescription</key><string>FluidCraft Case</string>
            <key>UTTypeConformsTo</key><array><string>com.apple.package</string></array>
            <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>fluidcraft</string><string>curlew</string></array></dict>
        </dict>
    </array>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>FluidCraft Case</string>
            <key>LSItemContentTypes</key><array><string>com.williamsepahi.fluidcraft.case</string></array>
            <key>CFBundleTypeRole</key><string>Editor</string>
            <key>LSHandlerRank</key><string>Owner</string>
            <key>LSTypeIsPackage</key><true/>
        </dict>
        <dict>
            <key>CFBundleTypeName</key><string>Mesh File</string>
            <key>CFBundleTypeExtensions</key><array><string>msh</string><string>cas</string></array>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
        </dict>
    </array>
</dict>
</plist>
PLIST

if [ "${1:-}" = "release" ]; then
    echo "==> Signing with $SIGN_ID (hardened runtime)"
    codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP/Contents/Helpers/fluidcraft"
    codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
    codesign --verify --strict --deep --verbose=1 "$APP"

    OUT="$ROOT/macOS/Direct"
    WORK="$(mktemp -d)"
    trap 'rm -rf "$WORK"' EXIT
    mkdir -p "$OUT"

    echo "==> Notarizing the app"
    ditto -c -k --keepParent "$APP" "$WORK/FluidCraft.zip"
    xcrun notarytool submit "$WORK/FluidCraft.zip" --keychain-profile notary --wait
    xcrun stapler staple "$APP"

    echo "==> Building the disk image"
    mkdir "$WORK/dmg"
    ditto "$APP" "$WORK/dmg/FluidCraft.app"
    ln -s /Applications "$WORK/dmg/Applications"
    rm -f "$OUT/FluidCraft.dmg"
    hdiutil create -volname "FluidCraft" -srcfolder "$WORK/dmg" -ov -format UDZO "$OUT/FluidCraft.dmg" >/dev/null
    codesign --force --timestamp --sign "$SIGN_ID" "$OUT/FluidCraft.dmg"

    echo "==> Notarizing the disk image"
    xcrun notarytool submit "$OUT/FluidCraft.dmg" --keychain-profile notary --wait
    xcrun stapler staple "$OUT/FluidCraft.dmg"
    spctl --assess --type open --context context:primary-signature --verbose "$OUT/FluidCraft.dmg"
    spctl --assess --type execute --verbose "$APP"
    echo "==> Release: $OUT/FluidCraft.dmg ($(du -h "$OUT/FluidCraft.dmg" | cut -f1))"
    exit 0
fi

echo "==> Signing (ad-hoc)"
codesign --force --sign - "$APP/Contents/Helpers/fluidcraft"
codesign --force --sign - "$APP"
codesign --verify --verbose=1 "$APP"

if [ "${1:-}" = "install" ]; then
    echo "==> Installing to /Applications"
    rm -rf /Applications/FluidCraft.app
    ditto "$APP" /Applications/FluidCraft.app
    touch /Applications/FluidCraft.app
fi
echo "==> Done: $APP"

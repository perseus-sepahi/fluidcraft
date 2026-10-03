#!/bin/bash
# Build Curlew.app (release) from the SwiftPM products.
#
#   Scripts/build-app.sh            -> dist/Curlew.app
#   Scripts/build-app.sh install    -> also copies it to /Applications
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/Curlew.app"
cd "$ROOT"

echo "==> Building release products"
swift build -c release --product Curlew
swift build -c release --product curlew-cli
BIN="$(swift build -c release --show-bin-path)"

if [ ! -f "$ROOT/Assets/AppIcon.icns" ]; then
    echo "==> Generating icon"
    "$ROOT/Scripts/make-icon.sh"
fi

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BIN/Curlew" "$APP/Contents/MacOS/Curlew"
cp "$BIN/curlew-cli" "$APP/Contents/Helpers/curlew"
cp "$ROOT/Assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
VERSION="1.0"
BUILD="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Curlew</string>
    <key>CFBundleDisplayName</key><string>Curlew</string>
    <key>CFBundleIdentifier</key><string>com.williamsepahi.curlew</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleExecutable</key><string>Curlew</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>© 2026 Perseus Sepahi</string>
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key><string>com.williamsepahi.curlew.case</string>
            <key>UTTypeDescription</key><string>Curlew Case</string>
            <key>UTTypeConformsTo</key><array><string>com.apple.package</string></array>
            <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>curlew</string></array></dict>
        </dict>
    </array>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Curlew Case</string>
            <key>LSItemContentTypes</key><array><string>com.williamsepahi.curlew.case</string></array>
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

echo "==> Signing (ad-hoc)"
codesign --force --sign - "$APP/Contents/Helpers/curlew"
codesign --force --sign - "$APP"
codesign --verify --verbose=1 "$APP"

if [ "${1:-}" = "install" ]; then
    echo "==> Installing to /Applications"
    rm -rf /Applications/Curlew.app
    ditto "$APP" /Applications/Curlew.app
    touch /Applications/Curlew.app
fi
echo "==> Done: $APP"

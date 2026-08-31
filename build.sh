#!/usr/bin/env bash
set -euo pipefail

APP_NAME="NewFinder"
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT_DIR/build"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
STAGING_DIR="$BUILD_DIR/dmg-root"
DMG_PATH="$DIST_DIR/$APP_NAME.dmg"
ICONSET_DIR="$BUILD_DIR/AppIcon.iconset"
ICON_PNG="$BUILD_DIR/AppIcon-1024.png"

rm -rf "$BUILD_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
mkdir -p "$DIST_DIR"

swift "$ROOT_DIR/Tools/MakeIcon.swift" "$ICON_PNG"
mkdir -p "$ICONSET_DIR"
sips -z 16 16 "$ICON_PNG" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
sips -z 32 32 "$ICON_PNG" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$ICON_PNG" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
sips -z 64 64 "$ICON_PNG" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$ICON_PNG" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
sips -z 256 256 "$ICON_PNG" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$ICON_PNG" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
sips -z 512 512 "$ICON_PNG" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$ICON_PNG" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$ICON_PNG" --out "$ICONSET_DIR/icon_512x512@2x.png" >/dev/null
iconutil -c icns "$ICONSET_DIR" -o "$APP_DIR/Contents/Resources/AppIcon.icns"
cp "$ICON_PNG" "$APP_DIR/Contents/Resources/AppIcon.png"

SOURCES=(
  "$ROOT_DIR/Sources/main.swift"
  "$ROOT_DIR/Sources/AppDelegate.swift"
  "$ROOT_DIR/Sources/StatusBarController.swift"
  "$ROOT_DIR/Sources/WatchAgentMain.swift"
  "$ROOT_DIR/Sources/Models.swift"
  "$ROOT_DIR/Sources/FileOperations.swift"
  "$ROOT_DIR/Sources/OfficeDocumentStubs.swift"
  "$ROOT_DIR/Sources/BrowserWindowController.swift"
  "$ROOT_DIR/Sources/ChromeHeaderView.swift"
  "$ROOT_DIR/Sources/ContentViewController.swift"
  "$ROOT_DIR/Sources/SettingsWindowController.swift"
  "$ROOT_DIR/Sources/UpdateChecker.swift"
  "$ROOT_DIR/Sources/BookmarksUI.swift"
)

swiftc \
  -O \
  -whole-module-optimization \
  -target arm64-apple-macos13.0 \
  "${SOURCES[@]}" \
  -framework AppKit \
  -framework ServiceManagement \
  -framework CoreServices \
  -framework CoreGraphics \
  -o "$APP_DIR/Contents/MacOS/$APP_NAME"

if [[ "$(uname -m)" == "arm64" ]]; then
  TMP_ARM="$BUILD_DIR/$APP_NAME-arm64"
  TMP_X86="$BUILD_DIR/$APP_NAME-x86_64"
  cp "$APP_DIR/Contents/MacOS/$APP_NAME" "$TMP_ARM"
  if swiftc \
    -O \
    -whole-module-optimization \
    -target x86_64-apple-macos13.0 \
    "${SOURCES[@]}" \
    -framework AppKit \
    -framework ServiceManagement \
    -framework CoreServices \
    -framework CoreGraphics \
    -o "$TMP_X86" 2>/dev/null; then
    lipo -create "$TMP_ARM" "$TMP_X86" -output "$APP_DIR/Contents/MacOS/$APP_NAME"
  fi
fi

cp "$ROOT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"

# Nested watch helper with a different bundle ID so Launch Services won't treat
# the background agent as "NewFinder already running".
WATCH_APP="$APP_DIR/Contents/Helpers/NewFinderWatch.app"
mkdir -p "$WATCH_APP/Contents/MacOS"
cp "$ROOT_DIR/WatchInfo.plist" "$WATCH_APP/Contents/Info.plist"
cp "$APP_DIR/Contents/MacOS/$APP_NAME" "$WATCH_APP/Contents/MacOS/NewFinderWatch"

codesign --force --deep --sign - "$APP_DIR" 2>/dev/null || true

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/Info.plist")"
rm -f "$DMG_PATH" "$DIST_DIR/${APP_NAME}-${VERSION}.dmg"

rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
ditto --norsrc --noextattr "$APP_DIR" "$STAGING_DIR/$APP_NAME.app"
ln -sf /Applications "$STAGING_DIR/Applications"
xattr -cr "$STAGING_DIR/$APP_NAME.app" 2>/dev/null || true

hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  -imagekey zlib-level=9 \
  "$DMG_PATH"

cp "$DMG_PATH" "$DIST_DIR/${APP_NAME}-${VERSION}.dmg"
xattr -cr "$DMG_PATH" "$DIST_DIR/${APP_NAME}-${VERSION}.dmg" 2>/dev/null || true

echo "Built $APP_DIR"
echo "Built $DMG_PATH"
ls -lh "$APP_DIR/Contents/MacOS/$APP_NAME" "$DMG_PATH"

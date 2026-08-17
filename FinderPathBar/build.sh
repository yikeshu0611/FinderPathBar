#!/usr/bin/env bash
set -euo pipefail

APP_NAME="FinderPathBar"
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$ROOT_DIR/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
DIST_DIR="$REPO_ROOT/dist"
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

# Copy named AppIcon for NSImage(named:)
cp "$ICON_PNG" "$APP_DIR/Contents/Resources/AppIcon.png" 2>/dev/null || true

swiftc \
  -O \
  -whole-module-optimization \
  -target arm64-apple-macos12.0 \
  "$ROOT_DIR/Sources/FinderPathApp.swift" \
  "$ROOT_DIR/Sources/main.swift" \
  -framework AppKit \
  -framework Carbon \
  -framework ServiceManagement \
  -o "$APP_DIR/Contents/MacOS/$APP_NAME"

# Also build universal if possible
if [[ "$(uname -m)" == "arm64" ]]; then
  TMP_ARM="$BUILD_DIR/$APP_NAME-arm64"
  TMP_X86="$BUILD_DIR/$APP_NAME-x86_64"
  cp "$APP_DIR/Contents/MacOS/$APP_NAME" "$TMP_ARM"
  if swiftc \
    -O \
    -whole-module-optimization \
    -target x86_64-apple-macos12.0 \
    "$ROOT_DIR/Sources/FinderPathApp.swift" \
    "$ROOT_DIR/Sources/main.swift" \
    -framework AppKit \
    -framework Carbon \
    -framework ServiceManagement \
    -o "$TMP_X86" 2>/dev/null; then
    lipo -create "$TMP_ARM" "$TMP_X86" -output "$APP_DIR/Contents/MacOS/$APP_NAME"
  fi
fi

cp "$ROOT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"

# Ensure AppIcon is loadable by name for status item
cp "$ICON_PNG" "$APP_DIR/Contents/Resources/AppIcon.png" 2>/dev/null || true

# Bundle donation QR (replace Resources/DonateQR.png with your WeChat/Alipay code).
if [[ -f "$ROOT_DIR/Resources/DonateQR.png" ]]; then
  cp "$ROOT_DIR/Resources/DonateQR.png" "$APP_DIR/Contents/Resources/DonateQR.png"
fi

codesign --force --deep --sign - --entitlements /dev/null "$APP_DIR" 2>/dev/null || codesign --force --deep --sign - "$APP_DIR"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/Info.plist")"
rm -f "$DMG_PATH" "$DIST_DIR/${APP_NAME}-${VERSION}.dmg"

# Clean staging copy (strip resource forks / xattrs) so Finder can mount the DMG.
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
ditto --norsrc --noextattr "$APP_DIR" "$STAGING_DIR/$APP_NAME.app"
ln -sf /Applications "$STAGING_DIR/Applications"
xattr -cr "$STAGING_DIR/$APP_NAME.app" 2>/dev/null || true

# Let hdiutil pick a modern layout (same as successful 1.0.50 builds).
# Do NOT use blank APM HFS images — Finder reports "装载文件系统失败".
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  -imagekey zlib-level=9 \
  "$DMG_PATH"

cp "$DMG_PATH" "$DIST_DIR/${APP_NAME}-${VERSION}.dmg"
xattr -cr "$DMG_PATH" "$DIST_DIR/${APP_NAME}-${VERSION}.dmg" 2>/dev/null || true

echo "Built $DMG_PATH"
ls -lh "$DMG_PATH" "$DIST_DIR/${APP_NAME}-${VERSION}.dmg"
hdiutil verify "$DMG_PATH"

# Smoke-test: mount like Finder would.
MNT="$BUILD_DIR/dmg-verify-mount"
rm -rf "$MNT"
mkdir -p "$MNT"
hdiutil attach "$DMG_PATH" -mountpoint "$MNT" -nobrowse -readonly
test -x "$MNT/$APP_NAME.app/Contents/MacOS/$APP_NAME"
hdiutil detach "$MNT"
echo "DMG mount smoke-test OK"

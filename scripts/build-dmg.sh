#!/bin/bash
# Packages "MacBook Duo.app" into a drag-to-install disk image at build/MacBook-Duo-<version>.dmg.
#
#   scripts/build-dmg.sh              # builds the app (release) first, then the DMG
#   SKIP_BUILD=1 scripts/build-dmg.sh # reuse the existing build/MacBook Duo.app
#
# The image holds the app and an "Applications" shortcut so users can drag it across.
# Note: without a Developer ID + notarization, macOS shows the usual Gatekeeper prompt
# on the destination Mac; approve it once under Privacy & Security.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="MacBook Duo"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"
STAGING="$BUILD_DIR/dmg-staging"

if [ "${SKIP_BUILD:-0}" != "1" ]; then
  "$ROOT/scripts/build-app.sh" release
fi
[ -d "$APP" ] || { echo "error: $APP not found" >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$BUILD_DIR/MacBook-Duo-$VERSION.dmg"
VOLUME="$APP_NAME"

echo "==> staging"
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

echo "==> creating $DMG"
hdiutil create \
  -volname "$VOLUME" \
  -srcfolder "$STAGING" \
  -fs HFS+ \
  -format UDZO \
  -imagekey zlib-level=9 \
  -ov \
  "$DMG" >/dev/null

rm -rf "$STAGING"

echo "==> verifying"
hdiutil verify "$DMG" >/dev/null
# Sign the image with the same signature as the app (ad-hoc if that's what the app got).
IDENTITY="$(codesign -dv "$APP" 2>&1 | grep -o 'Authority=Apple Development[^\n]*' | head -1 | sed 's/Authority=//' || true)"
if [ -n "$IDENTITY" ]; then
  codesign --force --sign "$IDENTITY" --timestamp=none "$DMG"
else
  codesign --force --sign - "$DMG"
fi

echo
echo "Built: $DMG ($(du -h "$DMG" | cut -f1))"
echo "Open:  open \"$DMG\""

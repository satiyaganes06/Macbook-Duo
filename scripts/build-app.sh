#!/bin/bash
# Builds the Swift package and assembles a signed "MacBook Duo.app" in ./build.
#
#   scripts/build-app.sh            # release build
#   scripts/build-app.sh debug      # debug build
#
# Signing: uses $CODESIGN_IDENTITY if set, otherwise the first "Apple Development"
# identity in the keychain, otherwise ad-hoc. A stable identity matters because
# macOS ties the Screen Recording permission to the app's code signature; an
# ad-hoc signed app has to be re-approved after every rebuild.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
APP_NAME="MacBook Duo"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"
SHADER="$ROOT/Sources/DuoCore/Shaders/Shaders.metal"

cd "$ROOT"
echo "==> swift build ($CONFIG)"
swift build -c "$CONFIG" --product MacbookDuo
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/MacbookDuo" "$APP/Contents/MacOS/MacbookDuo"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
# App icon (Finder, DMG, permission dialogs). Regenerate from Resources/AppIcon.png with:
#   mkdir AppIcon.iconset && for s in 16 32 128 256 512; do sips -z $s $s AppIcon.png --out AppIcon.iconset/icon_${s}x${s}.png; sips -z $((s*2)) $((s*2)) AppIcon.png --out AppIcon.iconset/icon_${s}x${s}@2x.png; done && iconutil -c icns AppIcon.iconset
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# Shader source always ships; the app compiles it at launch if no metallib exists.
cp "$SHADER" "$APP/Contents/Resources/Shaders.metal"
mkdir -p "$BUILD_DIR/shaders"
if xcrun -sdk macosx metal -c "$SHADER" -o "$BUILD_DIR/shaders/Shaders.air" 2>/dev/null \
   && xcrun -sdk macosx metallib "$BUILD_DIR/shaders/Shaders.air" -o "$APP/Contents/Resources/default.metallib" 2>/dev/null; then
  echo "==> Metal shaders precompiled to default.metallib"
else
  echo "==> Metal toolchain not installed; shaders will compile at launch from Shaders.metal"
  echo "    (optional: xcodebuild -downloadComponent MetalToolchain)"
fi

sign_adhoc() {
  echo "==> codesign ad-hoc"
  echo "    Note: macOS re-asks for Screen Recording after every rebuild of an ad-hoc signed app."
  codesign --force --sign - --identifier com.satiyaganes.MacbookDuo "$APP"
}

# Candidate identities: $CODESIGN_IDENTITY, else every "Apple Development" identity.
# `find-identity -v` does not check revocation, but the kernel does at launch: a
# revoked certificate fails with "Launchd job spawn failed" (error 153), so each
# candidate is verified with spctl after signing and skipped if revoked.
LOCAL_IDENTITY="MacBook Duo Local Signing"   # created by scripts/make-signing-identity.sh
CANDIDATES=()
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
  CANDIDATES+=("$CODESIGN_IDENTITY")
else
  while IFS= read -r line; do
    [ -n "$line" ] && CANDIDATES+=("$line")
  done < <(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Apple Development[^"]*"' | tr -d '"' || true)
  # Self-signed local identity: not trusted by Gatekeeper, but its certificate hash is
  # stable across rebuilds, so macOS keeps the Screen Recording grant (ad-hoc does not).
  if security find-identity -p codesigning 2>/dev/null | grep -q "\"$LOCAL_IDENTITY\""; then
    CANDIDATES+=("$LOCAL_IDENTITY")
  fi
fi

SIGNED=""
for identity in ${CANDIDATES[@]+"${CANDIDATES[@]}"}; do
  [ "$identity" = "-" ] && break
  echo "==> codesign with: $identity"
  if codesign --force --sign "$identity" --timestamp=none --identifier com.satiyaganes.MacbookDuo "$APP" 2>/dev/null; then
    # spctl exits non-zero for every non-notarized app, so inspect its text, not its status.
    ASSESS="$(spctl --assess --type execute "$APP" 2>&1 || true)"
    if ! grep -q "CERT_REVOKED" <<< "$ASSESS"; then
      SIGNED="$identity"
      break
    fi
  fi
  echo "    identity is revoked or unusable, trying the next one"
done
if [ -z "$SIGNED" ]; then
  sign_adhoc
  echo "    Run scripts/make-signing-identity.sh once to create a stable local identity,"
  echo "    or create a fresh Apple Development certificate in Xcode > Settings > Accounts."
fi
codesign --verify --verbose=2 "$APP"

echo
echo "Built: $APP"
echo "Run:   open \"$APP\""

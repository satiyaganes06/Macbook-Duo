#!/bin/bash
# Creates a self-signed code-signing identity named "MacBook Duo Local Signing" in the
# login keychain. scripts/build-app.sh uses it automatically when no valid Apple
# Development certificate exists.
#
# Why: macOS ties the Screen Recording grant to the app's designated requirement.
# For an ad-hoc signed app that requirement is the code hash, which changes on every
# rebuild, so the permission silently disappears and the capture-based styles stop
# working (only Fade keeps going). A certificate-based signature keeps the same
# requirement across rebuilds. Gatekeeper still treats the app as unidentified, so
# the one-time "Open Anyway" approval is unchanged.
#
# Remove it again with:  security delete-identity -c "MacBook Duo Local Signing"
set -euo pipefail

NAME="MacBook Duo Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning 2>/dev/null | grep -q "\"$NAME\""; then
  echo "Identity \"$NAME\" already exists."
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -subj "/CN=$NAME" \
  -addext "keyUsage=digitalSignature" \
  -addext "extendedKeyUsage=codeSigning" >/dev/null 2>&1
openssl pkcs12 -export -out "$WORK/identity.p12" -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -passout pass:duo -name "$NAME" >/dev/null 2>&1
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P duo -T /usr/bin/codesign -T /usr/bin/security

echo "Created identity \"$NAME\". scripts/build-app.sh will pick it up."

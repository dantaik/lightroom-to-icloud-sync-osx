#!/usr/bin/env bash
# Builds LightroomSync.app from the Swift package (macOS only).
#
#   scripts/build-app.sh            # release build, ad-hoc signed, written to dist/LightroomSync.app
#   CODESIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script must run on macOS." >&2
  exit 1
fi

APP_NAME="LightroomSync"
DIST_DIR="dist"
APP="$DIST_DIR/$APP_NAME.app"

echo "▸ Building release binary"
swift build -c release --product "$APP_NAME"
BIN_DIR="$(swift build -c release --show-bin-path)"

echo "▸ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp scripts/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

IDENTITY="${CODESIGN_IDENTITY:--}"
echo "▸ Code signing with identity: $IDENTITY"
codesign --force --sign "$IDENTITY" --timestamp=none "$APP"

echo "✓ Built $APP"
echo "  Run it with:      open $APP"
echo "  Install it with:  make install"

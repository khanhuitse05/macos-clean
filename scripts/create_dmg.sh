#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${1:?Usage: create_dmg.sh <path/to/macOS Clean.app> <output.dmg> [signing_identity]}"
DMG_PATH="${2:?Usage: create_dmg.sh <path/to/macOS Clean.app> <output.dmg> [signing_identity]}"
SIGNING_IDENTITY="${3:-Developer ID Application: To Ngoc Khanh (N8L3QK9894)}"

if [[ ! -d "$APP_PATH" ]]; then
  echo "Error: App bundle not found at $APP_PATH" >&2
  exit 1
fi

DMG_DIR="$(dirname "$DMG_PATH")"
STAGING_DIR="$DMG_DIR/dmg-staging"
TEMP_DMG="$DMG_DIR/$(basename "$DMG_PATH" .dmg)-temp.dmg"

rm -rf "$STAGING_DIR" "$TEMP_DMG" "$DMG_PATH"
mkdir -p "$STAGING_DIR"

echo "==> Staging $(basename "$APP_PATH") for DMG..."
ditto "$APP_PATH" "$STAGING_DIR/$(basename "$APP_PATH")"
ln -s /Applications "$STAGING_DIR/Applications"

echo "==> Creating compressed DMG at $DMG_PATH..."
hdiutil create \
  -volname "macOS Clean" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  -imagekey zlib-level=9 \
  "$DMG_PATH"

rm -rf "$STAGING_DIR"

echo "==> Signing DMG with Developer ID..."
codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$DMG_PATH"
codesign --verify --verbose=2 "$DMG_PATH"

echo "==> Created signed DMG: $DMG_PATH"

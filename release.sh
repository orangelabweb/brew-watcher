#!/bin/bash
# release.sh — bygg, signera, notarisera och paketera BrewWatcher
# Använd: ./release.sh

set -euo pipefail

# === Konfigurera detta en gång ===
APP_NAME="BrewWatcher"
SCHEME="BrewWatcher"
PROJECT="BrewWatcher.xcodeproj"
DEV_ID="Developer ID Application: Ditt Namn (TEAM12345)"
KEYCHAIN_PROFILE="brewwatcher-notary"
BUILD_DIR="./build"
APP_PATH="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"
# =================================

# Plocka ut MARKETING_VERSION ur projektet så DMG:n får ett versionerat filnamn.
VERSION="$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ MARKETING_VERSION /{print $2; exit}' \
  | tr -d '[:space:]')"
if [[ -z "$VERSION" ]]; then
  echo "❌ Kunde inte läsa MARKETING_VERSION ur projektet."
  exit 1
fi
DMG_PATH="$BUILD_DIR/$APP_NAME-$VERSION.dmg"

echo "🔨 Bygger Release ($APP_NAME $VERSION)..."
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
  CODE_SIGN_IDENTITY="$DEV_ID" \
  CODE_SIGN_STYLE=Manual \
  -quiet

echo "✍️  Signerar med hardened runtime..."
codesign --force --timestamp \
  --options runtime \
  --sign "$DEV_ID" \
  "$APP_PATH"

echo "🔍 Verifierar signaturen..."
codesign --verify --verbose=2 "$APP_PATH"

echo "📦 Skapar DMG..."
rm -f "$DMG_PATH"
hdiutil create -volname "$APP_NAME" \
  -srcfolder "$APP_PATH" \
  -ov -format UDZO \
  "$DMG_PATH"

echo "✍️  Signerar DMG..."
codesign --force --sign "$DEV_ID" --timestamp "$DMG_PATH"

echo "📤 Skickar till Apple för notarisering (kan ta 1–5 min)..."
xcrun notarytool submit "$DMG_PATH" \
  --keychain-profile "$KEYCHAIN_PROFILE" \
  --wait

echo "📎 Häftar fast notariseringsbiljetten..."
xcrun stapler staple "$DMG_PATH"

echo "✅ Klart! $DMG_PATH är redo att distribueras."

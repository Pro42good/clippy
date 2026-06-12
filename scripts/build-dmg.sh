#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "→ Generating Xcode project"
xcodegen generate

DERIVED="$ROOT/build/DerivedData"
APP="$ROOT/build/Release/Clippy.app"
DMG="$ROOT/build/Clippy.dmg"
STAGE="$ROOT/build/dmg-stage"

echo "→ Building Release"
xcodebuild \
  -project Clippy.xcodeproj \
  -scheme Clippy \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_ALLOWED=NO \
  build

BUILT_APP=$(find "$DERIVED" -path "*/Release/Clippy.app" -maxdepth 6 | head -1)
if [[ -z "$BUILT_APP" ]]; then
  echo "Could not locate built app" >&2
  exit 1
fi

mkdir -p "$ROOT/build/Release"
rm -rf "$APP"
cp -R "$BUILT_APP" "$APP"

echo "→ Creating DMG"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"

python3 "$ROOT/scripts/generate-dmg-background.py"
DMG_BACKGROUND="$ROOT/scripts/dmg/background.png"

create-dmg \
  --volname "Clippy" \
  --background "$DMG_BACKGROUND" \
  --window-pos 200 120 \
  --window-size 640 420 \
  --icon-size 96 \
  --icon "Clippy.app" 170 190 \
  --hide-extension "Clippy.app" \
  --app-drop-link 470 190 \
  "$DMG" \
  "$STAGE"

echo "✓ Built app: $APP"
echo "✓ Built dmg: $DMG"

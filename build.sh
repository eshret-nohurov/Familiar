#!/bin/bash
# Пересобирает Familiar.app (Release, ad-hoc) и упаковывает в dist/Familiar.dmg.
# Требует: xcodegen (brew install xcodegen), Xcode.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Build/Products/Release/Familiar.app"
STAGE="dist/stage"

echo "▸ Генерация проекта…"
xcodegen generate >/dev/null

echo "▸ Сборка Release (ad-hoc подпись)…"
rm -rf build
xcodebuild -project Familiar.xcodeproj -scheme Familiar -configuration Release \
  -derivedDataPath build \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=YES CODE_SIGNING_ALLOWED=YES \
  build >/dev/null

echo "▸ Упаковка .dmg…"
rm -rf "$STAGE" dist/Familiar.dmg
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "dist/Как установить Familiar.txt" "$STAGE/"
hdiutil create -volname "Familiar" -srcfolder "$STAGE" -ov -format UDZO "dist/Familiar.dmg" >/dev/null
rm -rf "$STAGE"

echo "✓ Готово: dist/Familiar.dmg"

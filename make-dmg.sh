#!/bin/bash
# Собирает build/NoiseBorder-<версия>.dmg с приложением, ярлыком «Программы» и инструкцией по первому запуску.
set -euo pipefail
cd "$(dirname "$0")"

export VERSION="${VERSION:-0.3.0}"
./build-app.sh

STAGE="build/dmg"
DMG="build/NoiseBorder-$VERSION.dmg"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R build/NoiseBorder.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/Как открыть - How to open.txt" <<'TXT'
EN
NoiseBorder is not notarized by Apple (it is an open-source hobby build), so macOS blocks the first launch.
1. Drag NoiseBorder to Applications and try to open it once.
2. Open System Settings > Privacy & Security, scroll down and press "Open Anyway" next to NoiseBorder.
   Or run in Terminal:  xattr -dr com.apple.quarantine /Applications/NoiseBorder.app
3. The app lives in the menu bar (waveform icon). Choose your AirPlay receiver with the AirPlay button in its window.

RU
NoiseBorder не заверен Apple (самостоятельная сборка с открытым кодом), поэтому macOS блокирует первый запуск.
1. Перетащите NoiseBorder в «Программы» и один раз попробуйте открыть.
2. Системные настройки > Конфиденциальность и безопасность, внизу нажмите «Всё равно открыть» рядом с NoiseBorder.
   Или в Терминале:  xattr -dr com.apple.quarantine /Applications/NoiseBorder.app
3. Приложение живёт в строке меню (значок-волна). AirPlay-приёмник выбирается кнопкой AirPlay в его окне.
TXT

hdiutil create -volname "NoiseBorder" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
echo "Готово: $DMG ($(du -h "$DMG" | cut -f1))"

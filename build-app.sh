#!/bin/bash
# Собирает build/NoiseBorder.app: universal (arm64 + x86_64), menu bar приложение без иконки в Dock.
# Каждая архитектура собирается отдельно и склеивается lipo: universal-сборка SwiftPM требует полного Xcode,
# а здесь хватает Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:-0.2.0}"
APP="build/NoiseBorder.app"

BINS=()
for ARCH in arm64 x86_64; do
  swift build -c release --product NoiseBorder --triple "$ARCH-apple-macosx13.0" --scratch-path ".build-$ARCH"
  BINS+=("$(swift build -c release --product NoiseBorder --triple "$ARCH-apple-macosx13.0" --scratch-path ".build-$ARCH" --show-bin-path)/NoiseBorder")
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Иконка: рисуется скриптом в 1024 px, нарезается на размеры iconset и собирается в .icns.
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
swift scripts/make-icon.swift "build/icon-1024.png" 1024 >/dev/null
for SZ in 16 32 128 256 512; do
  sips -z $SZ $SZ "build/icon-1024.png" --out "$ICONSET/icon_${SZ}x${SZ}.png" >/dev/null
  sips -z $((SZ*2)) $((SZ*2)) "build/icon-1024.png" --out "$ICONSET/icon_${SZ}x${SZ}@2x.png" >/dev/null
done
iconutil -c icns -o "$APP/Contents/Resources/AppIcon.icns" "$ICONSET"
rm -rf "$ICONSET"

lipo -create "${BINS[@]}" -output "$APP/Contents/MacOS/NoiseBorder"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>NoiseBorder</string>
  <key>CFBundleDisplayName</key><string>NoiseBorder</string>
  <key>CFBundleIdentifier</key><string>app.noiseborder.NoiseBorder</string>
  <key>CFBundleExecutable</key><string>NoiseBorder</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Подстройка громкости шума под голоса рядом: считается только уровень звука, ничего не записывается. / Adjusts noise volume to nearby voices: only the sound level is measured, nothing is recorded.</string>
</dict>
</plist>
PLIST

# Подпись ad-hoc (без сертификата разработчика). Другие Mac покажут предупреждение Gatekeeper, см. README.
codesign --force --sign - "$APP"
echo "Готово: $APP ($(lipo -archs "$APP/Contents/MacOS/NoiseBorder"))"

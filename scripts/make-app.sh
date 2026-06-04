#!/bin/bash
set -e
cd "$(dirname "$0")/.."
swift build -c release --product CardflowApp
APP="$(pwd)/Cardflow.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/CardflowApp "$APP/Contents/MacOS/Cardflow"
# ícone: Assets.car (Liquid Glass dinâmico, macOS 26+) + cardflow.icns (fallback). Gere com scripts/make-icon.sh.
[ -f Resources/Assets.car ] && /bin/cp -f Resources/Assets.car "$APP/Contents/Resources/Assets.car"
[ -f Resources/cardflow.icns ] && /bin/cp -f Resources/cardflow.icns "$APP/Contents/Resources/cardflow.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Cardflow</string>
  <key>CFBundleIdentifier</key><string>com.cardflow.app</string>
  <key>CFBundleExecutable</key><string>Cardflow</string>
  <key>CFBundleIconFile</key><string>cardflow</string>
  <key>CFBundleIconName</key><string>cardflow</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSRemovableVolumesUsageDescription</key><string>O Cardflow precisa ler os cartões de câmera para fazer a cópia.</string>
  <key>NSNetworkVolumesUsageDescription</key><string>O Cardflow precisa acessar discos de rede quando você usa um NAS como destino de backup.</string>
</dict>
</plist>
PLIST
echo "Pronto. Rode:  open \"$APP\""

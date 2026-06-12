#!/bin/bash
set -e
cd "$(dirname "$0")/.."
swift build -c release --product CardflowApp
APP="$(pwd)/Cardflow.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/CardflowApp "$APP/Contents/MacOS/Cardflow"
# Sparkle.framework: embute no bundle e aponta o rpath do executável pro Frameworks.
SPARKLE_FW="$(find .build/release -maxdepth 2 -name 'Sparkle.framework' -type d 2>/dev/null | head -1)"
[ -n "$SPARKLE_FW" ] || SPARKLE_FW="$(find .build -name 'Sparkle.framework' -type d 2>/dev/null | head -1)"
[ -n "$SPARKLE_FW" ] || { echo "❌ Sparkle.framework não encontrado em .build (rode 'swift build -c release --product CardflowApp')"; exit 1; }
mkdir -p "$APP/Contents/Frameworks"
/bin/cp -Rf "$SPARKLE_FW" "$APP/Contents/Frameworks/"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Cardflow" 2>/dev/null || true
# ícone: Assets.car (Liquid Glass dinâmico, macOS 26+) + cardflow.icns (fallback). Gere com scripts/make-icon.sh.
[ -f Resources/Assets.car ] && /bin/cp -f Resources/Assets.car "$APP/Contents/Resources/Assets.car"
[ -f Resources/cardflow.icns ] && /bin/cp -f Resources/cardflow.icns "$APP/Contents/Resources/cardflow.icns"
# FONTE ÚNICA da versão: lê de OffloadKit.swift (a mesma string que o motor grava no manifesto e que
# o update-checker compara). CFBundleVersion = contagem de commits (sobe sozinho a cada release).
VERSION="$(sed -n 's/.*public static let version = "\(.*\)".*/\1/p' Sources/OffloadKit/OffloadKit.swift)"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
[ -n "$VERSION" ] || { echo "❌ Não consegui ler a versão de Sources/OffloadKit/OffloadKit.swift"; exit 1; }
echo "Versão: $VERSION (build $BUILD)"
# SUPublicEDKey: chave pública EdDSA do Sparkle. A privada está na Keychain desta máquina
# (gerada com `scripts/sparkle-bin/generate_keys`; mantenha um backup dela em local seguro).
cat > "$APP/Contents/Info.plist" <<PLIST
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
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSRemovableVolumesUsageDescription</key><string>O Cardflow precisa ler os cartões de câmera para fazer a cópia.</string>
  <key>NSNetworkVolumesUsageDescription</key><string>O Cardflow precisa acessar discos de rede quando você usa um NAS como destino de backup.</string>
  <key>NSDesktopFolderUsageDescription</key><string>O Cardflow precisa de acesso à Mesa quando você a escolhe como destino da cópia.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>O Cardflow precisa de acesso aos Documentos quando você os escolhe como destino da cópia.</string>
  <key>SUFeedURL</key><string>https://cardflow.lessafilms.com/appcast.xml</string>
  <key>SUPublicEDKey</key><string>4pdYTyTNexB7FSiZpz2dz5bdOjEN3iAJjihHI+eHO4Y=</string>
  <key>SUEnableAutomaticChecks</key><false/>
  <key>SUSendsSystemProfile</key><false/>
</dict>
</plist>
PLIST
echo "Pronto. Rode:  open \"$APP\""

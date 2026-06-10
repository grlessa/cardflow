#!/bin/bash
# Cria o Cardflow.dmg (arraste-pra-Aplicativos) a partir do Cardflow.app já assinado+notarizado
# e então assina + notariza + grampeia o próprio DMG — é ele que você publica no GitHub.
#
# Fluxo de release completo:
#   1) bash scripts/sign-and-notarize.sh   (assina e notariza o app)
#   2) bash scripts/make-dmg.sh            (gera o DMG distribuível)
#
# Para só testar a montagem (sem assinar): SKIP_NOTARIZE=1 bash scripts/make-dmg.sh
set -euo pipefail
cd "$(dirname "$0")/.."

APP="$(pwd)/Cardflow.app"
DMG="$(pwd)/Cardflow.dmg"
VOLNAME="Cardflow"
PROFILE="${NOTARY_PROFILE:-cardflow-notary}"
source scripts/_notarize.sh   # notarize_with_log (busca o log da Apple na recusa)

[ -d "$APP" ] || { echo "❌ Cardflow.app não existe. Rode scripts/sign-and-notarize.sh primeiro."; exit 1; }

echo "==> Montando o DMG bonito (fundo + arraste-pra-Aplicativos)…"
hdiutil detach "/Volumes/$VOLNAME" >/dev/null 2>&1 || true   # limpa um mount anterior, evita "Cardflow 1"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/Cardflow.app"
ln -s /Applications "$STAGE/Applications"   # o usuário só arrasta o ícone pra cá
mkdir -p "$STAGE/.background"
swift scripts/make-installer-bg.swift "$STAGE/.background/bg.png" mono >/dev/null   # gera o fundo @2x (seta azul mono)
rm -f "$DMG"

# DMG read-write pra estilizar a janela no Finder (fundo + posição dos ícones) antes de comprimir.
RWDIR="$(mktemp -d)"; RW="$RWDIR/rw.dmg"
SIZE=$(( $(du -sm "$STAGE" | cut -f1) + 30 ))   # tamanho do app + folga
hdiutil create -srcfolder "$STAGE" -volname "$VOLNAME" -fs HFS+ -format UDRW -size "${SIZE}m" -ov "$RW" >/dev/null
rm -rf "$STAGE"

DEVICE="$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | grep -E '^/dev/' | head -1 | awk '{print $1}')"
osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$VOLNAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 588}
    set vopts to the icon view options of container window
    set arrangement of vopts to not arranged
    set icon size of vopts to 128
    set text size of vopts to 13
    set background picture of vopts to file ".background:bg.png"
    set position of item "Cardflow.app" of container window to {175, 200}
    set position of item "Applications" of container window to {485, 200}
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT
sync
hdiutil detach "$DEVICE" >/dev/null
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -ov -o "$DMG" >/dev/null
rm -rf "$RWDIR"
echo "   $DMG"

if [ "${SKIP_NOTARIZE:-0}" = "1" ]; then
  echo "⚠️  SKIP_NOTARIZE=1 — DMG criado sem assinar/notarizar (só para teste local)."
  exit 0
fi

IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep 'Developer ID Application' | head -1 | sed -E 's/.*"(.*)".*/\1/' || true)"
if [ -z "$IDENTITY" ]; then
  echo "⚠️  Sem certificado 'Developer ID Application' no Keychain — DMG criado mas NÃO assinado."
  echo "    Para distribuir sem aviso do Gatekeeper: configure o certificado (docs/notarizacao.md) e rode de novo."
  exit 0
fi

echo "==> Assinando o DMG…"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"
echo "==> Notarizando o DMG (a Apple verifica; leva alguns minutos)…"
notarize_with_log "$DMG" "$PROFILE" || exit 1
echo "==> Grampeando o ticket no DMG…"
xcrun stapler staple "$DMG"
echo ""
echo "✅ $DMG pronto. É este arquivo que você anexa na release do GitHub."

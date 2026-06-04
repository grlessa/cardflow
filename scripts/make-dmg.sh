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

[ -d "$APP" ] || { echo "❌ Cardflow.app não existe. Rode scripts/sign-and-notarize.sh primeiro."; exit 1; }

echo "==> Montando o DMG (app + atalho para a pasta Aplicativos)…"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/Cardflow.app"
ln -s /Applications "$STAGE/Applications"   # o usuário só arrasta o ícone pra cá
rm -f "$DMG"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
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
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
echo "==> Grampeando o ticket no DMG…"
xcrun stapler staple "$DMG"
echo ""
echo "✅ $DMG pronto. É este arquivo que você anexa na release do GitHub."

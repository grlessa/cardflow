#!/bin/bash
# Assina (Developer ID + hardened runtime), notariza e grampeia o Cardflow.app.
# Pré-requisito (faz UMA vez): ver docs/notarizacao.md.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="$(pwd)/Cardflow.app"
PROFILE="${NOTARY_PROFILE:-cardflow-notary}"   # perfil de credencial guardado no Keychain
source scripts/_notarize.sh                    # notarize_with_log (busca o log da Apple na recusa)

echo "==> 1/5  Empacotando o app (release)…"
bash scripts/make-app.sh

echo "==> 2/5  Procurando o certificado Developer ID Application…"
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep 'Developer ID Application' | head -1 | sed -E 's/.*"(.*)".*/\1/' || true)"
if [ -z "$IDENTITY" ]; then
  echo "❌ Nenhum certificado 'Developer ID Application' no Keychain."
  echo "   No Xcode: Settings → Accounts → (sua conta) → Manage Certificates → '+' → Developer ID Application."
  echo "   Depois rode este script de novo. (Detalhes em docs/notarizacao.md)"
  exit 1
fi
echo "   Usando: $IDENTITY"

echo "==> 3/5  Assinando (de dentro pra fora; hardened runtime + timestamp)…"
SIGN=(codesign --force --options runtime --timestamp --sign "$IDENTITY")
FW="$APP/Contents/Frameworks/Sparkle.framework"
# Componentes aninhados do Sparkle primeiro (a ordem importa). Assina só o que existe.
[ -e "$FW/Versions/B/XPCServices/Downloader.xpc" ] && "${SIGN[@]}" "$FW/Versions/B/XPCServices/Downloader.xpc"
[ -e "$FW/Versions/B/XPCServices/Installer.xpc" ]  && "${SIGN[@]}" "$FW/Versions/B/XPCServices/Installer.xpc"
[ -e "$FW/Versions/B/Autoupdate" ]                 && "${SIGN[@]}" "$FW/Versions/B/Autoupdate"
[ -e "$FW/Versions/B/Updater.app" ]                && "${SIGN[@]}" "$FW/Versions/B/Updater.app"
"${SIGN[@]}" "$FW"
# Por fim o app inteiro, sem --deep (cada parte foi assinada acima individualmente).
"${SIGN[@]}" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> 4/5  Notarizando (Apple verifica; leva alguns minutos)…"
ZIP="$(pwd)/Cardflow.zip"; rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
if ! notarize_with_log "$ZIP" "$PROFILE"; then
  echo "   Se ainda não guardou as credenciais, rode UMA vez:"
  echo "   xcrun notarytool store-credentials \"$PROFILE\" \\"
  echo "       --apple-id SEU_EMAIL_APPLE --team-id SEU_TEAM_ID --password SENHA_DE_APP"
  echo "   (Como pegar cada coisa: docs/notarizacao.md)"
  rm -f "$ZIP"; exit 1
fi

echo "==> 5/5  Grampeando o ticket de notarização no app…"
xcrun stapler staple "$APP"
rm -f "$ZIP"
echo ""
echo "Verificação final do Gatekeeper:"
spctl --assess --type execute --verbose=4 "$APP" || true
echo ""
echo "✅ Pronto. $APP está assinado e notarizado — abre em qualquer Mac sem aviso de 'desenvolvedor não identificado'."

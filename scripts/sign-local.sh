#!/bin/bash
# Build + assinatura Developer ID SEM notarizar (teste local do ajudante). Mesma ordem do sign-and-notarize.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
MAKE_LOG="$(mktemp)"
trap 'rm -f "$MAKE_LOG"' EXIT
if ! bash scripts/make-app.sh >"$MAKE_LOG" 2>&1; then
  cat "$MAKE_LOG"
  exit 1
fi
APP="$(pwd)/Cardflow.app"
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep 'Developer ID Application' | head -1 | sed -E 's/.*"(.*)".*/\1/' || true)"
[ -n "$IDENTITY" ] || { echo "❌ Nenhum certificado 'Developer ID Application' encontrado no Keychain."; exit 1; }
SIGN=(codesign --force --options runtime --timestamp=none --sign "$IDENTITY")   # build local: sem carimbo (só a release é notarizada)
FW="$APP/Contents/Frameworks/Sparkle.framework"
for x in "$FW/Versions/B/XPCServices/Downloader.xpc" "$FW/Versions/B/XPCServices/Installer.xpc" "$FW/Versions/B/Autoupdate" "$FW/Versions/B/Updater.app"; do [ -e "$x" ] && "${SIGN[@]}" "$x" 2>/dev/null; done
"${SIGN[@]}" "$FW" 2>/dev/null
"${SIGN[@]}" --identifier com.cardflow.app.formathelper "$APP/Contents/MacOS/CardflowFormatHelper" 2>/dev/null
"${SIGN[@]}" "$APP" 2>/dev/null
codesign --verify --deep --strict "$APP" && echo "assinado: $(codesign -dv "$APP" 2>&1 | grep TeamIdentifier)"

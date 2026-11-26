#!/bin/bash
# Gera docs/appcast.xml a partir do DMG assinado de uma release.
# uso: scripts/make-appcast.sh <Cardflow.dmg> <vX.Y.Z> <notas.html>
set -euo pipefail
cd "$(dirname "$0")/.."

DMG="${1:?uso: make-appcast.sh <Cardflow.dmg> <vX.Y.Z> <notas.html>}"
TAG="${2:?uso: make-appcast.sh <Cardflow.dmg> <vX.Y.Z> <notas.html>}"
NOTES="${3:?uso: make-appcast.sh <Cardflow.dmg> <vX.Y.Z> <notas.html>}"

VERSION="$(sed -n 's/.*public static let version = "\(.*\)".*/\1/p' Sources/OffloadKit/OffloadKit.swift)"
[ -n "$VERSION" ] || { echo "❌ não consegui ler a versão de Sources/OffloadKit/OffloadKit.swift"; exit 1; }
[ "$TAG" = "v$VERSION" ] || { echo "❌ tag '$TAG' não bate com a versão em OffloadKit.swift ('v$VERSION')"; exit 1; }
[ -f "$DMG" ] || { echo "❌ DMG não encontrado: $DMG"; exit 1; }

# Lê CFBundleVersion e CFBundleShortVersionString direto do Cardflow.app dentro do DMG,
# para o appcast bater byte-a-byte com o build empacotado mesmo que novos commits existam no repo.
MNT="$(mktemp -d)"
cleanup() {
  hdiutil detach "$MNT" >/dev/null 2>&1 || true
  rm -rf "$MNT"
}
trap cleanup EXIT
hdiutil attach -readonly -nobrowse -noverify -mountpoint "$MNT" "$DMG" >/dev/null
PLIST="$MNT/Cardflow.app/Contents/Info.plist"
[ -f "$PLIST" ] || { echo "❌ Cardflow.app/Contents/Info.plist não encontrado dentro de $DMG"; exit 1; }
DMG_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
hdiutil detach "$MNT" >/dev/null
[ "$DMG_VERSION" = "$VERSION" ] || { echo "❌ versão dentro do DMG ($DMG_VERSION) difere de OffloadKit.swift ($VERSION)"; exit 1; }
[ -n "$BUILD" ] || { echo "❌ não consegui ler CFBundleVersion de $DMG"; exit 1; }

SIGN_UPDATE="scripts/sparkle-bin/sign_update"
[ -x "$SIGN_UPDATE" ] || { echo "❌ falta scripts/sparkle-bin/sign_update (veja docs/notarizacao.md)"; exit 1; }

# sign_update imprime: sparkle:edSignature="..." length="..."
SIG_LINE="$("$SIGN_UPDATE" "$DMG")"
ED="$(sed -E 's/.*edSignature="([^"]+)".*/\1/' <<<"$SIG_LINE")"
LEN="$(sed -E 's/.*length="([0-9]+)".*/\1/' <<<"$SIG_LINE")"
# sed devolve a linha inteira quando não casa: confirma que extraiu mesmo (senão o appcast sai quebrado).
[ -n "$ED" ] && [ "$ED" != "$SIG_LINE" ]   || { echo "❌ não extraí o edSignature de: $SIG_LINE"; exit 1; }
[ -n "$LEN" ] && [ "$LEN" != "$SIG_LINE" ] || { echo "❌ não extraí o length de: $SIG_LINE"; exit 1; }
URL="https://github.com/grlessa/cardflow/releases/download/$TAG/Cardflow.dmg"
PUBDATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"

swift build -c release --product make-appcast
.build/release/make-appcast \
  --short-version "$VERSION" --build "$BUILD" --min-system 26.0 \
  --url "$URL" --ed-signature "$ED" --length "$LEN" \
  --pubdate "$PUBDATE" --notes-file "$NOTES" > docs/appcast.xml

xmllint --noout docs/appcast.xml && echo "✅ docs/appcast.xml gerado e válido (build $BUILD)"

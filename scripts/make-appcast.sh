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
BUILD="$(git rev-list --count HEAD)"
SIGN_UPDATE="scripts/sparkle-bin/sign_update"
[ -x "$SIGN_UPDATE" ] || { echo "❌ falta scripts/sparkle-bin/sign_update (ver Task 7 do plano)"; exit 1; }

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
  --short-version "$VERSION" --build "$BUILD" --min-system 14.0 \
  --url "$URL" --ed-signature "$ED" --length "$LEN" \
  --pubdate "$PUBDATE" --notes-file "$NOTES" > docs/appcast.xml

xmllint --noout docs/appcast.xml && echo "✅ docs/appcast.xml gerado e válido (build $BUILD)"

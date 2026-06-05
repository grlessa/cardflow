#!/bin/bash
# Helper compartilhado de notarização (sign-and-notarize.sh e make-dmg.sh usam o mesmo caminho).
# Submete com --wait + --timeout e, se NÃO for aceito, busca o log da Apple automaticamente
# (o motivo da recusa, ex.: binário sem hardened runtime) em vez de só abortar com um exit code.
notarize_with_log() {
  local target="$1" profile="$2"
  local out id
  out="$(xcrun notarytool submit "$target" --keychain-profile "$profile" --wait --timeout 30m 2>&1)" || true
  echo "$out"
  if echo "$out" | grep -q "status: Accepted"; then
    return 0
  fi
  id="$(echo "$out" | awk '/id:/{print $2; exit}')"
  echo ""
  echo "❌ Notarização não foi aceita."
  if [ -n "$id" ]; then
    echo "   Motivo (log da Apple):"
    xcrun notarytool log "$id" --keychain-profile "$profile" || true
  fi
  return 1
}

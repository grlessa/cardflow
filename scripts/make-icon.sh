#!/bin/bash
# Compila o ícone do app a partir do bundle Icon Composer (Resources/cardflow.icon) com o actool
# do Xcode — a MESMA ferramenta que o Xcode usa. Gera:
#   Resources/Assets.car   → ícone Liquid Glass dinâmico (macOS 26+)
#   Resources/cardflow.icns → fallback estático (macOS mais antigos)
# Requer Xcode 26+ (SDK do formato .icon). Sem ele, o app fica sem ícone embutido (não quebra).
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="${1:-Resources/cardflow.icon}"
OUT="$(mktemp -d)"

echo "==> Compilando o ícone com actool…"
xcrun actool "$SRC" \
  --compile "$OUT" \
  --app-icon cardflow \
  --platform macosx \
  --minimum-deployment-target 14.0 \
  --output-partial-info-plist "$OUT/partial.plist" \
  --errors --warnings >/dev/null

mkdir -p Resources
/bin/cp -f "$OUT/Assets.car" Resources/Assets.car
/bin/cp -f "$OUT/cardflow.icns" Resources/cardflow.icns
echo "✅ Resources/Assets.car (dinâmico macOS 26+) + Resources/cardflow.icns (fallback) gerados."

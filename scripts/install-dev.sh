#!/usr/bin/env bash
# Compila o boringCode (Debug; CONFIG=Release para medir desempenho como na versão distribuída), assina com um
# certificado fixo e instala a única cópia em /Applications, abrindo o app em seguida.
# Uso: scripts/install-dev.sh            (sem "Apple Development", roda scripts/setup-dev-signing.sh)
#      scripts/install-dev.sh --no-open  (só instala)
#
# Por quê: build ad-hoc muda de identidade a cada compilação e o macOS pede as permissões de
# novo; e cópias soltas em build/ apareciam no Finder/Spotlight como "outros boringCode".
#
# Certificado: o "Apple Development" do chaveiro, o MESMO das versões publicadas (make-dmg.sh). Assim o
# build de dev e a atualização pelo Sparkle têm a mesma identidade e a Acessibilidade não se perde ao trocar
# um pelo outro (com certificados diferentes, a chave fica ligada nos Ajustes mas não vale para o app).
# Sem ele, cai no "boringCode Dev" local (SIGN_IDENTITY=… escolhe outro).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BUNDLE_ID="com.reesoousa.boringcode"
# ".noindex" no nome faz o Spotlight ignorar a pasta: os builds não aparecem como apps.
DERIVED="build.noindex"
CONFIG="${CONFIG:-Debug}"
BUILT="$DERIVED/Build/Products/$CONFIG/boringCode.app"
DEST="/Applications/boringCode.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

source scripts/lib/sign-app.sh
IDENTITY="${SIGN_IDENTITY:-$(find_identity_hash "Apple Development")}"
EXTRA=()
if [ -z "$IDENTITY" ]; then
  scripts/setup-dev-signing.sh
  IDENTITY="boringCode Dev"
  # Release local sem hardened runtime: o "boringCode Dev" não tem Team ID e a library validation
  # derrubaria o app na abertura. Só para medir aqui — o DMG (make-dmg.sh) segue com o runtime.
  [ "$CONFIG" = "Release" ] && EXTRA=(ENABLE_HARDENED_RUNTIME=NO)
fi
IDENTITY_NAME="$(security find-identity -v -p codesigning | awk -v h="$IDENTITY" '$2 == h { sub(/^[^"]*"/, ""); sub(/".*$/, ""); print; exit }')"

echo "▸ Compilando ($CONFIG)…"
xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED" -destination 'platform=macOS,arch=arm64' build -quiet ${EXTRA[@]+"${EXTRA[@]}"}

echo "▸ Assinando com \"${IDENTITY_NAME:-$IDENTITY}\"…"
sign_app_tree "$BUILT" "$IDENTITY"

echo "▸ Instalando em $DEST…"
osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
sleep 1
pkill -9 -x boringCode 2>/dev/null || true
rm -rf "$DEST"
ditto "$BUILT" "$DEST"

# Só a cópia de /Applications fica registrada como app: tira do registro qualquer outro
# boringCode.app (builds, DMG montado, pastas antigas) para o Finder não oferecer "outros".
"$LSREGISTER" -dump 2>/dev/null \
  | sed -nE 's#^path: +(.*/boringCode\.app(/.*)?\.app|.*/boringCode\.app)( \(0x[0-9a-f]+\))?$#\1#p' \
  | sort -u | while IFS= read -r stale; do
      case "$stale" in "$DEST"|"$DEST"/*) ;; *) "$LSREGISTER" -u "$stale" >/dev/null 2>&1 || true ;; esac
    done
"$LSREGISTER" -f "$DEST" >/dev/null 2>&1 || true

echo "✓ Instalado: $DEST"
[ "${1:-}" = "--no-open" ] || open "$DEST"

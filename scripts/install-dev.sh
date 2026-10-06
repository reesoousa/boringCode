#!/usr/bin/env bash
# Compila o boringCode (Debug; CONFIG=Release para medir desempenho como na versão distribuída), assina com o certificado fixo "boringCode Dev" e instala a
# única cópia em /Applications, abrindo o app em seguida.
# Uso: scripts/install-dev.sh            (roda scripts/setup-dev-signing.sh se precisar)
#      scripts/install-dev.sh --no-open  (só instala)
#
# Por quê: build ad-hoc muda de identidade a cada compilação e o macOS pede as permissões de
# novo; e cópias soltas em build/ apareciam no Finder/Spotlight como "outros boringCode".
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

IDENTITY="boringCode Dev"
BUNDLE_ID="com.reesoousa.boringcode"
# ".noindex" no nome faz o Spotlight ignorar a pasta: os builds não aparecem como apps.
DERIVED="build.noindex"
CONFIG="${CONFIG:-Debug}"
BUILT="$DERIVED/Build/Products/$CONFIG/boringCode.app"
DEST="/Applications/boringCode.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

scripts/setup-dev-signing.sh

echo "▸ Compilando ($CONFIG)…"
# Release local sem hardened runtime: o certificado de dev não tem Team ID e a library validation
# derrubaria o app na abertura. Só para medir aqui — o DMG (make-dmg.sh) segue com o runtime.
EXTRA=()
[ "$CONFIG" = "Release" ] && EXTRA=(ENABLE_HARDENED_RUNTIME=NO)
xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED" -destination 'platform=macOS,arch=arm64' build -quiet ${EXTRA[@]+"${EXTRA[@]}"}

echo "▸ Assinando com \"$IDENTITY\"…"
source scripts/lib/sign-app.sh
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

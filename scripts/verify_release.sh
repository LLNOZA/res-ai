#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="ResponseAi"
APP_PATH="$ROOT_DIR/dist/$APP_NAME.app"

cd "$ROOT_DIR"

step() {
  printf '\n==> %s\n' "$1"
}

require_file() {
  if [[ ! -e "$1" ]]; then
    echo "Missing expected file: $1" >&2
    exit 1
  fi
}

last_output_line() {
  awk 'NF { line=$0 } END { print line }'
}

step "Swift tests"
swift test

step "Script syntax"
bash -n scripts/*.sh

step "Node syntax"
node --check services/vertex-proxy/server.js

step "Build app"
APP_OUTPUT="$("$ROOT_DIR/scripts/build_app.sh" | last_output_line)"
require_file "$APP_OUTPUT"

step "Verify app signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

step "Build package"
PKG_OUTPUT="$("$ROOT_DIR/scripts/build_pkg.sh" | last_output_line)"
require_file "$PKG_OUTPUT"

step "Check package signature"
if pkgutil --check-signature "$PKG_OUTPUT"; then
  :
else
  echo "Package is unsigned. This is acceptable for local testing; Developer ID Installer is required for public distribution."
fi

step "Build DMG"
DMG_OUTPUT="$("$ROOT_DIR/scripts/build_dmg.sh" | last_output_line)"
require_file "$DMG_OUTPUT"

step "Verify DMG"
hdiutil verify "$DMG_OUTPUT"
if codesign --verify --verbose=2 "$DMG_OUTPUT" >/dev/null 2>&1; then
  echo "DMG signature: present"
else
  echo "DMG signature: unsigned"
fi

step "Probe Cloud Run proxy"
PROXY_URL="$(defaults read ai.res.resai vertex.proxyURL 2>/dev/null || true)"
PROXY_SECRET="$(security find-generic-password -s ai.res.resai -a vertex.proxyAuthToken -w 2>/dev/null || defaults read ai.res.resai vertex.proxyAuthToken 2>/dev/null || true)"
if [[ -z "$PROXY_URL" ]]; then
  echo "Proxy URL is not configured; app will use direct Vertex or local preview depending on settings."
else
  CURL_ARGS=(-sS -o /dev/null -w "%{http_code}" --max-time 8 -H "Content-Type: application/json")
  if [[ -n "$PROXY_SECRET" ]]; then
    CURL_ARGS+=(-H "X-ResAI-Proxy-Key: $PROXY_SECRET")
  fi
  STATUS_CODE="$(curl "${CURL_ARGS[@]}" -d "{}" "$PROXY_URL" || true)"
  echo "Proxy probe HTTP status: $STATUS_CODE"
  case "$STATUS_CODE" in
    400)
      echo "Proxy reachable and auth accepted."
      ;;
    401|403)
      echo "Proxy reachable but auth failed." >&2
      exit 1
      ;;
    2*)
      echo "Proxy reachable."
      ;;
    *)
      echo "Proxy probe did not return an expected status." >&2
      exit 1
      ;;
  esac
fi

cat <<EOF

Release verification complete.

App:
  $APP_OUTPUT
Package:
  $PKG_OUTPUT
DMG:
  $DMG_OUTPUT
EOF

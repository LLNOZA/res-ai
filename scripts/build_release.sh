#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NOTARIZE="${RESAI_NOTARIZE:-0}"
SKIP_TESTS="${RESAI_SKIP_TESTS:-0}"

cd "$ROOT_DIR"

step() {
  printf '\n==> %s\n' "$1"
}

last_output_line() {
  awk 'NF { line=$0 } END { print line }'
}

if [[ "$SKIP_TESTS" != "1" ]]; then
  step "Run release verification"
  "$ROOT_DIR/scripts/verify_release.sh"
else
  step "Build app"
  "$ROOT_DIR/scripts/build_app.sh" >/dev/null
fi

step "Build package"
PKG_PATH="$("$ROOT_DIR/scripts/build_pkg.sh" | last_output_line)"

step "Build DMG"
DMG_PATH="$("$ROOT_DIR/scripts/build_dmg.sh" | last_output_line)"

if [[ "$NOTARIZE" == "1" ]]; then
  step "Notarize package"
  PKG_PATH="$("$ROOT_DIR/scripts/notarize_artifact.sh" "$PKG_PATH" | last_output_line)"

  step "Notarize DMG"
  DMG_PATH="$("$ROOT_DIR/scripts/notarize_artifact.sh" "$DMG_PATH" | last_output_line)"
else
  step "Skip notarization"
  echo "Set RESAI_NOTARIZE=1 with notary credentials to notarize and staple release artifacts."
fi

cat <<EOF

Release artifacts ready.

Package:
  $PKG_PATH
DMG:
  $DMG_PATH
EOF

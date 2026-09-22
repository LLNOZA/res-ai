#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DMG_PATH="${1:-}"

if [[ -z "$DMG_PATH" ]]; then
  DMG_PATH="$("$ROOT_DIR/scripts/build_dmg.sh" | awk 'NF { line=$0 } END { print line }')"
fi

"$ROOT_DIR/scripts/notarize_artifact.sh" "$DMG_PATH"

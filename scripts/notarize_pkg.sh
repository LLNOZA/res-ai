#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG_PATH="${1:-}"

if [[ -z "$PKG_PATH" ]]; then
  PKG_PATH="$("$ROOT_DIR/scripts/build_pkg.sh" | awk 'NF { line=$0 } END { print line }')"
fi

"$ROOT_DIR/scripts/notarize_artifact.sh" "$PKG_PATH"

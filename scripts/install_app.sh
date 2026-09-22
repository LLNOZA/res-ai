#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="ResponseAi.app"
SOURCE_APP="$ROOT_DIR/dist/$APP_NAME"
SYSTEM_TARGET="/Applications/$APP_NAME"
USER_TARGET="$HOME/Applications/$APP_NAME"
LEGACY_SYSTEM_TARGET="/Applications/ResAI.app"
LEGACY_USER_TARGET="$HOME/Applications/ResAI.app"
TARGET_APP="${RESAI_INSTALL_TARGET:-}"

if [[ -z "$TARGET_APP" ]]; then
  if [[ -d "$SYSTEM_TARGET" || -w "/Applications" ]]; then
    TARGET_APP="$SYSTEM_TARGET"
  else
    mkdir -p "$HOME/Applications"
    TARGET_APP="$USER_TARGET"
  fi
fi

"$ROOT_DIR/scripts/build_app.sh" >/dev/null

if [[ ! -d "$SOURCE_APP" ]]; then
  echo "Missing built app: $SOURCE_APP" >&2
  exit 1
fi

if pgrep -f "$TARGET_APP/Contents/MacOS/ResponseAi" >/dev/null 2>&1; then
  pkill -f "$TARGET_APP/Contents/MacOS/ResponseAi" || true
  sleep 0.5
fi

if pgrep -f "/Applications/ResAI.app/Contents/MacOS/ResAI" >/dev/null 2>&1; then
  pkill -f "/Applications/ResAI.app/Contents/MacOS/ResAI" || true
  sleep 0.5
fi

mkdir -p "$(dirname "$TARGET_APP")"
rm -rf "$TARGET_APP"
rm -rf "$LEGACY_SYSTEM_TARGET" "$LEGACY_USER_TARGET"
ditto "$SOURCE_APP" "$TARGET_APP"

if command -v xattr >/dev/null 2>&1; then
  xattr -dr com.apple.quarantine "$TARGET_APP" 2>/dev/null || true
fi

echo "$TARGET_APP"

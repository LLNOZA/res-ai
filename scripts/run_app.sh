#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_EXECUTABLE="$ROOT_DIR/dist/ResponseAi.app/Contents/MacOS/ResponseAi"
LOG_FILE="${RESAI_LOG_FILE:-/tmp/resai.log}"

"$ROOT_DIR/scripts/build_app.sh" >/dev/null

if pgrep -f "$APP_EXECUTABLE" >/dev/null 2>&1; then
  pkill -f "$APP_EXECUTABLE" || true
fi

"$APP_EXECUTABLE" >"$LOG_FILE" 2>&1 &
echo "$!"

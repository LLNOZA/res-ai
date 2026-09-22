#!/usr/bin/env bash
set -euo pipefail

ARTIFACT_PATH="${1:-}"

if [[ -z "$ARTIFACT_PATH" ]]; then
  echo "Usage: $0 path/to/ResponseAi.pkg-or.dmg" >&2
  exit 1
fi

if [[ ! -f "$ARTIFACT_PATH" ]]; then
  echo "Missing artifact: $ARTIFACT_PATH" >&2
  exit 1
fi

case "$ARTIFACT_PATH" in
  *.pkg|*.dmg)
    ;;
  *)
    echo "Unsupported notarization artifact. Expected .pkg or .dmg: $ARTIFACT_PATH" >&2
    exit 1
    ;;
esac

if ! command -v xcrun >/dev/null 2>&1; then
  echo "xcrun is required for notarization." >&2
  exit 1
fi

PROFILE="${RESAI_NOTARY_KEYCHAIN_PROFILE:-}"
APPLE_ID="${RESAI_NOTARY_APPLE_ID:-}"
TEAM_ID="${RESAI_NOTARY_TEAM_ID:-}"
PASSWORD="${RESAI_NOTARY_PASSWORD:-}"

if [[ -n "$PROFILE" ]]; then
  xcrun notarytool submit "$ARTIFACT_PATH" \
    --keychain-profile "$PROFILE" \
    --wait
elif [[ -n "$APPLE_ID" && -n "$TEAM_ID" && -n "$PASSWORD" ]]; then
  xcrun notarytool submit "$ARTIFACT_PATH" \
    --apple-id "$APPLE_ID" \
    --team-id "$TEAM_ID" \
    --password "$PASSWORD" \
    --wait
else
  cat >&2 <<'EOF'
Notarization credentials are not configured.

Set either:
  RESAI_NOTARY_KEYCHAIN_PROFILE

or:
  RESAI_NOTARY_APPLE_ID
  RESAI_NOTARY_TEAM_ID
  RESAI_NOTARY_PASSWORD
EOF
  exit 1
fi

xcrun stapler staple "$ARTIFACT_PATH"
xcrun stapler validate "$ARTIFACT_PATH"

echo "$ARTIFACT_PATH"

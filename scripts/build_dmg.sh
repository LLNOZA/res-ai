#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="ResponseAi"
APP_BUNDLE="$APP_NAME.app"
APP_DIR="$ROOT_DIR/dist/$APP_BUNDLE"
DMG_ROOT="$ROOT_DIR/dist/dmgroot"
DMG_DIR="$ROOT_DIR/dist/installer"
INFO_PLIST="$ROOT_DIR/packaging/Info.plist"

VERSION="${RESAI_VERSION:-}"
if [[ -z "$VERSION" ]]; then
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
fi

DMG_PATH="$DMG_DIR/$APP_NAME-$VERSION.dmg"
TMP_DMG_PATH="$DMG_DIR/$APP_NAME-$VERSION.tmp.dmg"
VOLUME_NAME="${RESAI_DMG_VOLUME_NAME:-$APP_NAME $VERSION}"
SIGN_IDENTITY="${RESAI_CODESIGN_IDENTITY:-}"

cd "$ROOT_DIR"

if [[ "${RESAI_SKIP_APP_BUILD:-0}" != "1" ]]; then
  "$ROOT_DIR/scripts/build_app.sh" >/dev/null
elif [[ ! -d "$APP_DIR" ]]; then
  echo "RESAI_SKIP_APP_BUILD=1 requires an existing app at $APP_DIR" >&2
  exit 1
fi

rm -rf "$DMG_ROOT" "$TMP_DMG_PATH" "$DMG_PATH"
mkdir -p "$DMG_ROOT" "$DMG_DIR"

COPYFILE_DISABLE=1 ditto --norsrc "$APP_DIR" "$DMG_ROOT/$APP_BUNDLE"
ln -s /Applications "$DMG_ROOT/Applications"

find "$DMG_ROOT" \( -name ".DS_Store" -o -name "._*" \) -delete
if command -v xattr >/dev/null 2>&1; then
  xattr -cr "$DMG_ROOT" 2>/dev/null || true
fi

hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$DMG_ROOT" \
  -fs HFS+ \
  -fsargs "-c c=64,a=16,e=16" \
  -format UDRW \
  -ov \
  "$TMP_DMG_PATH" >/dev/null

hdiutil convert "$TMP_DMG_PATH" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "$DMG_PATH" >/dev/null

rm -f "$TMP_DMG_PATH"

if [[ -z "$SIGN_IDENTITY" ]] && command -v security >/dev/null 2>&1; then
  SIGN_IDENTITY="$(
    security find-identity -v -p codesigning 2>/dev/null \
      | awk -F '"' '/Developer ID Application:/ { print $2; exit }'
  )"
fi

if [[ -n "$SIGN_IDENTITY" ]] && command -v codesign >/dev/null 2>&1; then
  codesign --force --sign "$SIGN_IDENTITY" "$DMG_PATH" >/dev/null
fi

hdiutil verify "$DMG_PATH" >/dev/null

echo "$DMG_PATH"

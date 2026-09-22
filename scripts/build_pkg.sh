#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="ResponseAi"
APP_BUNDLE="$APP_NAME.app"
APP_DIR="$ROOT_DIR/dist/$APP_BUNDLE"
PKG_ROOT="$ROOT_DIR/dist/pkgroot"
PKG_DIR="$ROOT_DIR/dist/installer"
INFO_PLIST="$ROOT_DIR/packaging/Info.plist"

VERSION="${RESAI_VERSION:-}"
if [[ -z "$VERSION" ]]; then
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
fi

IDENTIFIER="${RESAI_PKG_IDENTIFIER:-ai.res.resai.pkg}"
PKG_PATH="$PKG_DIR/$APP_NAME-$VERSION.pkg"
PKG_SCRIPTS="$ROOT_DIR/packaging/pkg-scripts"
SIGN_IDENTITY="${RESAI_INSTALLER_SIGN_IDENTITY:-}"

cd "$ROOT_DIR"

if [[ "${RESAI_SKIP_APP_BUILD:-0}" != "1" ]]; then
  "$ROOT_DIR/scripts/build_app.sh" >/dev/null
elif [[ ! -d "$APP_DIR" ]]; then
  echo "RESAI_SKIP_APP_BUILD=1 requires an existing app at $APP_DIR" >&2
  exit 1
fi

rm -rf "$PKG_ROOT" "$PKG_DIR"
mkdir -p "$PKG_ROOT/Applications" "$PKG_DIR"
COPYFILE_DISABLE=1 ditto --norsrc "$APP_DIR" "$PKG_ROOT/Applications/$APP_BUNDLE"
find "$PKG_ROOT" \( -name ".DS_Store" -o -name "._*" \) -delete
if command -v xattr >/dev/null 2>&1; then
  xattr -cr "$PKG_ROOT" 2>/dev/null || true
fi

PKGBUILD_ARGS=(
  --root "$PKG_ROOT"
  --scripts "$PKG_SCRIPTS"
  --install-location "/"
  --identifier "$IDENTIFIER"
  --version "$VERSION"
  --filter '(^|/)\._[^/]*$'
  --filter '(^|/)\.DS_Store$'
)

if [[ -z "$SIGN_IDENTITY" ]] && command -v security >/dev/null 2>&1; then
  SIGN_IDENTITY="$(
    security find-identity -v -p basic 2>/dev/null \
      | awk -F '"' '/Developer ID Installer:/ { print $2; exit }'
  )"
fi

if [[ -n "$SIGN_IDENTITY" ]]; then
  PKGBUILD_ARGS+=(--sign "$SIGN_IDENTITY")
fi

PKGBUILD_ARGS+=("$PKG_PATH")

COPYFILE_DISABLE=1 pkgbuild "${PKGBUILD_ARGS[@]}" >/dev/null

pkgutil --check-signature "$PKG_PATH" >/dev/null 2>&1 || true

echo "$PKG_PATH"

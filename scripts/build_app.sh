#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="ResponseAi"
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
EXECUTABLE="$ROOT_DIR/.build/release/$APP_NAME"
LEGACY_APP_DIR="$ROOT_DIR/dist/ResAI.app"

cd "$ROOT_DIR"

swift build -c release

# Retain the unstripped executable and matching symbols for crash reports from
# this exact build. UUID subdirectories keep earlier builds of the same version.
if command -v xcrun >/dev/null 2>&1; then
  SYMBOL_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/packaging/Info.plist")"
  SYMBOL_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT_DIR/packaging/Info.plist")"
  SYMBOL_UUID="$(xcrun dwarfdump --uuid "$EXECUTABLE" | awk 'NR == 1 { print $2 }')"
  if [[ -n "$SYMBOL_UUID" ]]; then
    SYMBOL_DIR="$ROOT_DIR/artifacts/symbols/$SYMBOL_VERSION-build$SYMBOL_BUILD/$SYMBOL_UUID"
    mkdir -p "$SYMBOL_DIR"
    cp "$EXECUTABLE" "$SYMBOL_DIR/$APP_NAME"
    xcrun dsymutil "$EXECUTABLE" -o "$SYMBOL_DIR/$APP_NAME.dSYM"
  fi
fi

rm -rf "$APP_DIR" "$LEGACY_APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$EXECUTABLE" "$MACOS_DIR/$APP_NAME"
cp "$ROOT_DIR/packaging/Info.plist" "$CONTENTS_DIR/Info.plist"
if [[ -f "$ROOT_DIR/packaging/assets/ResponseAi.icns" ]]; then
  cp "$ROOT_DIR/packaging/assets/ResponseAi.icns" "$RESOURCES_DIR/ResponseAi.icns"
fi
for template in ResponseAiTemplate.png ResponseAiTemplate@2x.png ResponseAiTemplate@3x.png; do
  if [[ -f "$ROOT_DIR/packaging/assets/$template" ]]; then
    cp "$ROOT_DIR/packaging/assets/$template" "$RESOURCES_DIR/$template"
  fi
done
chmod +x "$MACOS_DIR/$APP_NAME"

# Strip debug symbols before signing (stripping invalidates a signature, so it
# must run first). Roughly halves the shipped binary size.
if command -v xcrun >/dev/null 2>&1; then
  xcrun strip -x "$MACOS_DIR/$APP_NAME" || true
fi

if command -v codesign >/dev/null 2>&1; then
  SIGN_IDENTITY="${RESAI_CODESIGN_IDENTITY:-}"
  if [[ -z "$SIGN_IDENTITY" ]] && command -v security >/dev/null 2>&1; then
    SIGN_IDENTITY="$(
      security find-identity -v -p codesigning 2>/dev/null \
        | awk -F '"' '/Developer ID Application:/ { print $2; exit }'
    )"
  fi
  if [[ -z "$SIGN_IDENTITY" ]] && command -v security >/dev/null 2>&1; then
    SIGN_IDENTITY="$(
      security find-identity -v -p codesigning 2>/dev/null \
        | awk -F '"' '/Apple Development:/ { print $2; exit }'
    )"
  fi

  # Hardened runtime blocks microphone access outright unless the audio-input
  # entitlement is present, so the entitlements file must accompany every signature.
  ENTITLEMENTS="$ROOT_DIR/packaging/ResponseAi.entitlements"
  if [[ -n "$SIGN_IDENTITY" ]]; then
    codesign --force --deep --options runtime --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$APP_DIR" >/dev/null
  else
    codesign --force --entitlements "$ENTITLEMENTS" --sign - "$APP_DIR" >/dev/null
  fi
fi

echo "$APP_DIR"

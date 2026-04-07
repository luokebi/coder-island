#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/CoderIsland.xcodeproj"
INFO_PLIST="$ROOT_DIR/CoderIsland/Info.plist"
ENTITLEMENTS="$ROOT_DIR/CoderIsland/Entitlements.entitlements"
SCHEME="CoderIsland"
ARCHIVE_PATH="$ROOT_DIR/build/CoderIsland.xcarchive"
DERIVED_DATA_PATH="$ROOT_DIR/build/DerivedDataPackage"
DIST_DIR="$ROOT_DIR/build/dist"
STAGING_DIR="$ROOT_DIR/build/dmg-staging"

APP_BUNDLE_NAME="CoderIsland.app"
DISPLAY_NAME="$(plutil -extract CFBundleName raw "$INFO_PLIST")"
VERSION="$(plutil -extract CFBundleShortVersionString raw "$INFO_PLIST")"
DMG_PATH="$DIST_DIR/CoderIsland-${VERSION}.dmg"
APP_PATH="$ARCHIVE_PATH/Products/Applications/$APP_BUNDLE_NAME"

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "error: xcodebuild is required" >&2
  exit 1
fi

if ! command -v hdiutil >/dev/null 2>&1; then
  echo "error: hdiutil is required" >&2
  exit 1
fi

if ! command -v codesign >/dev/null 2>&1; then
  echo "error: codesign is required" >&2
  exit 1
fi

resolve_identity() {
  local requested="$1"

  if [[ "$requested" == "-" ]]; then
    echo "-"
    return 0
  fi

  if [[ "$requested" =~ ^[A-F0-9]{40}$ ]]; then
    echo "$requested"
    return 0
  fi

  local resolved
  resolved="$(
    security find-identity -v -p codesigning 2>/dev/null |
      awk -v label="$requested" '$0 ~ "\"" label "\"" { print $2; exit }'
  )"

  if [[ -n "$resolved" ]]; then
    echo "$resolved"
    return 0
  fi

  echo "$requested"
}

SIGNING_IDENTITY="${CODE_SIGN_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
  if security find-certificate -c "CoderIsland Dev" -a >/dev/null 2>&1; then
    SIGNING_IDENTITY="CoderIsland Dev"
  else
    SIGNING_IDENTITY="-"
  fi
fi

SIGNING_IDENTITY="$(resolve_identity "$SIGNING_IDENTITY")"

if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  SIGNING_MODE="ad hoc"
else
  SIGNING_MODE="$SIGNING_IDENTITY"
fi

echo "==> Cleaning previous packaging output"
rm -rf "$ARCHIVE_PATH" "$DERIVED_DATA_PATH" "$STAGING_DIR"
mkdir -p "$DIST_DIR" "$STAGING_DIR"
rm -f "$DMG_PATH"

echo "==> Archiving Release app"
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGNING_ALLOWED=NO \
  archive \
  -archivePath "$ARCHIVE_PATH"

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: archived app not found at $APP_PATH" >&2
  exit 1
fi

echo "==> Signing app with $SIGNING_MODE"
codesign \
  --force \
  --deep \
  --sign "$SIGNING_IDENTITY" \
  --entitlements "$ENTITLEMENTS" \
  --timestamp=none \
  "$APP_PATH"

echo "==> Verifying app signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo "==> Preparing DMG staging folder"
cp -R "$APP_PATH" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

echo "==> Creating DMG"
hdiutil create \
  -volname "$DISPLAY_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

echo
echo "DMG created:"
echo "  $DMG_PATH"
echo
echo "Signing mode:"
echo "  $SIGNING_MODE"
echo
echo "Install note:"
echo "  Users will need to bypass Gatekeeper on first launch unless the app is"
echo "  later signed with Developer ID and notarized."

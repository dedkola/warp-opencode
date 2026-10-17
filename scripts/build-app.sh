#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCH="$(uname -m)"
WITH_HELPER=true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch) ARCH="${2:?--arch requires arm64 or x86_64}"; shift 2 ;;
    --without-cloudflared) WITH_HELPER=false; shift ;;
    -h|--help)
      echo "Usage: scripts/build-app.sh [--arch arm64|x86_64] [--without-cloudflared]"
      echo "SIGNING_IDENTITY defaults to '-' (local ad-hoc signing)."
      exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done
case "$ARCH" in arm64|x86_64) ;; *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;; esac

cd "$ROOT"
swift build --configuration release --arch "$ARCH" --product WarpGoBridge
BIN_DIR="$(swift build --configuration release --arch "$ARCH" --show-bin-path)"
APP="$ROOT/build/Warp OpenCode Bridge.app"
STAGING="$(mktemp -d "$ROOT/.build/app.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
BUNDLE="$STAGING/Warp OpenCode Bridge.app"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources/Notices"
cp "$BIN_DIR/WarpGoBridge" "$BUNDLE/Contents/MacOS/WarpGoBridge"
cp "$ROOT/Config/Info.plist" "$BUNDLE/Contents/Info.plist"
cp "$ROOT/Config/AppIcon.icns" "$BUNDLE/Contents/Resources/AppIcon.icns"
cp "$ROOT/LICENSE" "$BUNDLE/Contents/Resources/Notices/LICENSE.txt"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$BUNDLE/Contents/Resources/Notices/THIRD_PARTY_NOTICES.md"

IDENTITY="${SIGNING_IDENTITY:--}"
SIGN_OPTIONS=(--force --sign "$IDENTITY")
if [[ "$IDENTITY" != "-" ]]; then
  SIGN_OPTIONS+=(--options runtime --timestamp)
fi
if $WITH_HELPER; then
  HELPER_PATH="$("$ROOT/scripts/fetch-cloudflared.sh" "$ARCH")"
  cp "$HELPER_PATH" "$BUNDLE/Contents/Resources/cloudflared"
  cp "$ROOT/Config/cloudflared-LICENSE.txt" "$BUNDLE/Contents/Resources/Notices/cloudflared-LICENSE.txt"
  codesign "${SIGN_OPTIONS[@]}" "$BUNDLE/Contents/Resources/cloudflared"
fi
codesign "${SIGN_OPTIONS[@]}" "$BUNDLE"
codesign --verify --deep --strict "$BUNDLE"
plutil -lint "$BUNDLE/Contents/Info.plist"

mkdir -p "$ROOT/build"
rm -rf "$APP"
mv "$BUNDLE" "$APP"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ZIP="$ROOT/build/Warp-OpenCode-Bridge-${VERSION}-${ARCH}.zip"
rm -f "$ZIP"
# Ship bundle contents without local Finder metadata or extended attributes.
ditto -c -k --norsrc --noextattr --noqtn --noacl --keepParent "$APP" "$ZIP"
printf '\nApp: %s\nArchive: %s\n' "$APP" "$ZIP"
if [[ "$IDENTITY" == "-" ]]; then
  echo "Locally ad-hoc signed. This build is not Developer ID signed or notarized."
else
  echo "Signed with $IDENTITY. Notarization is a separate release step."
fi

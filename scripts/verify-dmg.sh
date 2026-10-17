#!/bin/bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: scripts/verify-dmg.sh path/to/release.dmg arm64|x86_64" >&2
  exit 1
fi
DMG="$1"
ARCH="$2"
case "$ARCH" in arm64|x86_64) ;; *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;; esac
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
MOUNT="$TEMP_DIR/mount"
ATTACHED=false
cleanup() {
  local status=$?
  if $ATTACHED; then
    hdiutil detach "$MOUNT" || hdiutil detach -force "$MOUNT" || return 1
  fi
  rm -rf "$TEMP_DIR"
  return "$status"
}
trap cleanup EXIT

hdiutil verify "$DMG"
hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT" "$DMG"
ATTACHED=true
[[ -L "$MOUNT/Applications" && "$(readlink "$MOUNT/Applications")" == /Applications ]]
cmp "$ROOT/Config/First Launch.txt" "$MOUNT/First Launch.txt"

# Check a copy outside the disk image: this is the bundle users install.
APP="$TEMP_DIR/installed/Warp OpenCode Bridge.app"
ditto "$MOUNT/Warp OpenCode Bridge.app" "$APP"
plutil -lint "$APP/Contents/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" == dev.warpgobridge.app ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" == "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Config/Info.plist")" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")" == 14.0 ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$APP/Contents/Info.plist")" == false ]]
[[ -s "$APP/Contents/Resources/AppIcon.icns" ]]
for notice in LICENSE.txt THIRD_PARTY_NOTICES.md cloudflared-LICENSE.txt; do
  [[ -s "$APP/Contents/Resources/Notices/$notice" ]]
done
for binary in "$APP/Contents/MacOS/WarpGoBridge" "$APP/Contents/Resources/cloudflared"; do
  [[ -x "$binary" ]]
  [[ "$(lipo -archs "$binary")" == "$ARCH" ]]
  codesign --verify --strict "$binary"
  # Capture first: grep -q on a live pipe can SIGPIPE codesign under pipefail.
  SIGNATURE="$(codesign -dv "$binary" 2>&1)"
  grep -q '^Signature=adhoc$' <<< "$SIGNATURE"
done
codesign --verify --deep --strict "$APP"

if [[ "$(uname -m)" == "$ARCH" ]]; then
  "$APP/Contents/Resources/cloudflared" --version
else
  echo "Cross-built $ARCH bundle verified structurally; runtime check requires a $ARCH Mac."
fi
printf '\nVerified installable %s DMG: %s\n' "$ARCH" "$DMG"

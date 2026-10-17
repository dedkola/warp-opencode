#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCH="$(uname -m)"
case "${1:-}" in
  "") ;;
  --arch) ARCH="${2:?--arch requires arm64 or x86_64}"; shift 2 ;;
  -h|--help)
    echo "Usage: scripts/build-dmg.sh [--arch arm64|x86_64]"
    echo "Builds a self-contained DMG without Developer ID signing or notarization."
    exit 0 ;;
  *) echo "Unknown argument: $1" >&2; exit 1 ;;
esac
if [[ $# -ne 0 ]]; then echo "Unexpected extra arguments." >&2; exit 1; fi
case "$ARCH" in arm64|x86_64) ;; *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;; esac

# Ad-hoc signatures provide Apple silicon executable integrity without an Apple
# account, certificate, signing secret, or notarization service.
SIGNING_IDENTITY=- "$ROOT/scripts/build-app.sh" --arch "$ARCH"
APP="$ROOT/build/Warp OpenCode Bridge.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
case "$VERSION" in ""|*[!0-9.]*) echo "Invalid bundle release version: $VERSION" >&2; exit 1 ;; esac
NAME="Warp-OpenCode-Bridge-${VERSION}-${ARCH}"
STAGING="$(mktemp -d "$ROOT/.build/dmg.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
mkdir "$STAGING/content"
ditto --norsrc --noextattr --noqtn --noacl "$APP" "$STAGING/content/Warp OpenCode Bridge.app"
ln -s /Applications "$STAGING/content/Applications"
cp "$ROOT/Config/First Launch.txt" "$STAGING/content/First Launch.txt"

# Native disk image tooling keeps packaging independent of Homebrew/npm and
# interactive Finder/AppleScript permissions on GitHub-hosted runners.
hdiutil create -volname "Warp OpenCode Bridge $VERSION" \
  -srcfolder "$STAGING/content" -fs HFS+ -format UDZO \
  "$STAGING/$NAME.dmg"
mv -f "$STAGING/$NAME.dmg" "$ROOT/build/$NAME.dmg"
(cd "$ROOT/build" && shasum -a 256 "$NAME.dmg" > "$NAME.dmg.sha256")
printf '\nDMG: %s\n' "$ROOT/build/$NAME.dmg"

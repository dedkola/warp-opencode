#!/bin/bash
set -euo pipefail

# Print only the verified helper path to stdout; status goes to stderr.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="2026.10.1"
ARCH="${1:-$(uname -m)}"
case "$ARCH" in
  arm64) ASSET_ARCH="arm64" ;;
  x86_64|amd64) ASSET_ARCH="amd64"; ARCH="x86_64" ;;
  *) echo "Unsupported architecture: $ARCH (use arm64 or x86_64)." >&2; exit 1 ;;
esac

ASSET="cloudflared-darwin-${ASSET_ARCH}.tgz"
EXPECTED="$(awk -v asset="$ASSET" '$2 == asset { print $1 }' "$ROOT/Config/cloudflared-checksums.txt")"
if [[ ${#EXPECTED} -ne 64 ]]; then
  echo "Missing pinned SHA-256 for $ASSET." >&2
  exit 1
fi

CACHE="$ROOT/.cache/cloudflared/$VERSION/$ARCH"
ARCHIVE="$CACHE/$ASSET"
mkdir -p "$CACHE"
TEMP_DIR="$(mktemp -d "$CACHE/.download.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT

if [[ ! -f "$ARCHIVE" ]]; then
  echo "Downloading cloudflared $VERSION ($ARCH)..." >&2
  curl --fail --location --silent --show-error --retry 3 \
    --proto '=https' --proto-redir '=https' --tlsv1.2 \
    "https://github.com/cloudflare/cloudflared/releases/download/$VERSION/$ASSET" \
    --output "$TEMP_DIR/$ASSET"
  CANDIDATE="$TEMP_DIR/$ASSET"
else
  CANDIDATE="$ARCHIVE"
fi

ACTUAL="$(shasum -a 256 "$CANDIDATE" | awk '{print $1}')"
if [[ "$ACTUAL" != "$EXPECTED" ]]; then
  echo "SHA-256 mismatch for $ASSET. Refusing to run this helper." >&2
  echo "Expected: $EXPECTED" >&2
  echo "Received: $ACTUAL" >&2
  [[ "$CANDIDATE" != "$ARCHIVE" ]] || rm -f "$ARCHIVE"
  exit 1
fi
[[ "$CANDIDATE" == "$ARCHIVE" ]] || mv "$CANDIDATE" "$ARCHIVE"

# Extract only the known entry from the verified archive, then replace atomically.
tar -xzf "$ARCHIVE" -C "$TEMP_DIR" cloudflared
chmod 755 "$TEMP_DIR/cloudflared"
mv -f "$TEMP_DIR/cloudflared" "$CACHE/cloudflared"
printf '%s\n' "$CACHE/cloudflared"

# Development guide

[← Back to the README](../README.md)

Use macOS 14 or later with a Swift 6 toolchain. Full Xcode is needed for XCTest; Command Line Tools can build the app and run the portable checks.

## Build from source

```sh
scripts/test.sh
scripts/build-app.sh
open "build/Warp OpenCode Bridge.app"
```

The script produces an app and a versioned ZIP in `build/` for your Mac's architecture. Use `scripts/build-dmg.sh` to also create the drag-to-Applications DMG. It downloads the pinned official Cloudflare helper on the first run. Generated files and credentials are excluded from Git.

`scripts/test.sh` runs `swift test`, which requires the XCTest framework supplied with full Xcode. If you only have Command Line Tools, run `scripts/test.sh --portable` instead. This compiles and executes the same test methods with a small local assertion adapter and local mock services. It is explicitly a **portable check run, not an XCTest run**. It does not accept an Xcode license or change your selected developer directory. GitHub CI still runs the normal XCTest suite.

Both modes fetch the pinned, checksum-verified `cloudflared` helper on the first run. One regression check uses the real helper to validate the generated tunnel configuration with fake credentials. That validation is offline and creates no tunnel, DNS record, or account connection. To use a specific installed helper, set `WARP_GO_CLOUDFLARED_PATH`; the test fails rather than skipping validation if no helper is available.

The app and helper have local ad-hoc integrity signatures so Apple silicon can run them. These do not identify an Apple developer or provide notarization. The DMG itself is unsigned. Downloaded copies use the [first-launch instructions in the README](../README.md#download-and-install).

## Development and packaging

The public app name is **Warp OpenCode Bridge** and the repository is `warp-opencode`. Internal Swift product/executable names remain `WarpGoBridge`; the bundle ID and Keychain service remain `dev.warpgobridge.app`, and the app data directory remains `WarpGoBridge`. These legacy internal names preserve existing credentials and settings when updating the app.

The Dock icon uses original vector artwork. Regenerate its PNG and all-resolution macOS `.icns` with `swift scripts/generate-icons.swift`. The menu bar keeps its native template symbol so it adapts to light and dark appearances.

```sh
# Run core tests; no subscription or Cloudflare account required.
scripts/test.sh

# Same test bodies on a Command Line Tools installation without XCTest.
scripts/test.sh --portable

# For direct swift test, explicitly prepare the required helper first.
export WARP_GO_CLOUDFLARED_PATH="$(scripts/fetch-cloudflared.sh)"
swift test

# Package for the current architecture, including the verified helper.
scripts/build-app.sh

# Package a specific supported architecture.
scripts/build-app.sh --arch arm64
scripts/build-app.sh --arch x86_64

# Create a self-contained unsigned DMG and ZIP (no Apple credentials).
scripts/build-dmg.sh --arch arm64
scripts/build-dmg.sh --arch x86_64

# Verify a DMG, its Applications shortcut, and the copied app/helper.
scripts/verify-dmg.sh build/Warp-OpenCode-Bridge-0.1.0-arm64.dmg arm64

# Compile/package without downloading a helper (not a self-contained install).
scripts/build-app.sh --without-cloudflared
```

`scripts/fetch-cloudflared.sh` pins version `2026.10.1`. It verifies the archive against `Config/cloudflared-checksums.txt` before extracting it. To update the helper, review the official release, verify both macOS archive hashes, and update the pin and notices together. See [third-party notices](../THIRD_PARTY_NOTICES.md).

For Developer ID signing, set `SIGNING_IDENTITY` when running the packaging script. This signs the nested helper and app with hardened runtime enabled. It does not submit the app for notarization or publish a release.

```sh
SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/build-app.sh
```

GitHub Actions runs the normal Swift tests and packages/verifies DMG and ZIP artifacts on native Apple silicon and Intel runners for pushes, pull requests, and manual runs. Pushing a `v<version>` tag matching `Config/Info.plist` additionally publishes both downloads and `SHA256SUMS` to GitHub Releases, after both builds pass. Publication uses only GitHub's built-in token; no Apple, Cloudflare, or Go credentials are required.

See [release instructions](RELEASING.md) for versioning, publication, and validation. Changes for the first release are recorded in the [changelog](../CHANGELOG.md).

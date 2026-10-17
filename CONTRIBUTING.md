# Contributing

Use a Mac with macOS 14 or later and a Swift 6 toolchain. Build and run the core checks with `scripts/test.sh`, then package the app with `scripts/build-app.sh`. The test script fetches and verifies the pinned Cloudflare helper, which is required for offline validation of the real generated tunnel configuration. Set `WARP_GO_CLOUDFLARED_PATH` to use a specific helper instead. Direct `swift test` also needs that variable unless a helper is installed in a supported lookup location.

If full Xcode's XCTest framework is unavailable, `scripts/test.sh --portable` executes the existing test methods with a small assertion adapter using Apple's Command Line Tools. This is a separate portable check run, not XCTest. Keep test signatures simple or update the discovery script explicitly; it refuses unsupported signatures instead of silently skipping cases. CI retains the normal XCTest suite.

Keep changes focused. Exercise session routing, authentication, request cancellation, and streaming when changing the proxy. Tests should use synthetic messages and local mocks, not production credentials or private conversation exports. Distinguish local checks from real Warp, Cloudflare, and OpenCode Go verification in your pull request.

For UI changes, open the packaged app and verify its settings window and menu bar behavior. Never log prompts, provider keys, bridge tokens, Cloudflare certificates, or tunnel credential JSON. Use redacted errors in issues and pull requests.

When updating `cloudflared`, update the version in the fetch script and any runtime installer together, verify both macOS archive hashes from the official release assets, and update the notices. Do not commit downloaded binaries or app bundles.

Run `scripts/build-dmg.sh` and `scripts/verify-dmg.sh build/Warp-OpenCode-Bridge-0.1.0-arm64.dmg arm64` to validate the installable download (substitute the current version and architecture). CI runs native tests and DMG verification for both Apple silicon and Intel. Building locally does not publish anything; pushing a matching `v<version>` tag publishes the unsigned downloads after both builds pass. See [release instructions](docs/RELEASING.md).

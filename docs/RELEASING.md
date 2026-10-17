# Release preparation

The app is **Warp OpenCode Bridge**; the repository is `warp-opencode`. Packaging produces `Warp OpenCode Bridge.app` and an architecture-specific `Warp-OpenCode-Bridge-<architecture>.zip`.

## Source publication

- Review the exact source, documentation, configuration, and test files being included. Exclude credentials, conversation content, local Cloudflare files, caches, app bundles, and ZIPs.
- Include the MIT license, Cloudflare helper license, third-party notices, and pinned helper checksums.
- Keep README behavior and the changelog aligned with the build being published. Record hosted CI results separately from local checks.
- Preserve internal `WarpGoBridge` product/executable and data-directory names, plus `dev.warpgobridge.app` bundle ID/Keychain service. Renaming those requires an explicit migration for existing installations.

Publishing source does not publish a downloadable app or establish a successful hosted CI run. Repository publication is a separate authorized step.

## Ad-hoc preview

`scripts/build-app.sh` creates a local ad-hoc-signed preview by default. It verifies the pinned Cloudflare archive, signs the helper and app, checks the signatures, and creates a ZIP for the selected architecture.

Label previews accurately. They are not Developer ID signed or notarized and may be blocked by Gatekeeper after downloading. Do not instruct users to disable Gatekeeper. Keep Apple silicon and Intel artifacts clearly distinguished; a successful build for an architecture is not a runtime test on that architecture.

## Signed public binary

- Package with the maintainer's Developer ID identity using `SIGNING_IDENTITY`. The build script enables hardened runtime and timestamping for that path, but does not notarize or publish.
- Verify the nested helper and app signatures, then complete Apple's notarization process with maintainer-managed credentials kept outside the repository.
- Staple the accepted ticket to the app and validate Gatekeeper acceptance. Recreate the ZIP after stapling so the downloadable archive contains the final app.
- Retain licenses and third-party notices in the app. Confirm filenames and architecture labels before preparing release assets.

## Validation record

- Run the normal XCTest suite with full Xcode, or clearly label a Command Line Tools run as portable checks. The real-helper configuration regression must run rather than be skipped.
- Open the packaged app and exercise first-time setup, authenticated public connection testing, On/Off, and quitting. Record the macOS version and architecture actually tested.
- Verify a fresh Go chat, follow-up, and continuation after Off/On in Warp. Keep automatic-mode limitations visible: exact retries, shared/forked histories, compaction, and cache loss after quitting or changing routing mode.
- Review screenshots, diagnostics, and release notes for keys, tokens, certificates, and private conversation content before sharing them.

Signing, notarization, validation, and publication are distinct outcomes; record only the ones actually completed for that release.

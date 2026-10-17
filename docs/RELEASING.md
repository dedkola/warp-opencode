# macOS releases

Warp OpenCode Bridge is distributed through GitHub Releases as a native macOS app for macOS 14 or later. Each release contains:

- `Warp-OpenCode-Bridge-<version>-arm64.dmg` for Apple silicon.
- `Warp-OpenCode-Bridge-<version>-x86_64.dmg` for Intel.
- Matching ZIP archives and a combined `SHA256SUMS` file.

Each DMG contains the app, an Applications shortcut, and `First Launch.txt`. The app includes the pinned, checksum-verified Cloudflare helper, icon, and licenses. Users do not need developer tools or Homebrew.

## Signing policy and installation

The release flow needs **no Apple account, Developer ID certificate, signing secrets, or notarization**. It uses local ad-hoc signatures for app/helper integrity, required for native Apple silicon execution. The DMG is unsigned. These builds have no verified developer identity and are not notarized.

Users open the DMG, drag the app to Applications, eject the image, and open the installed app. macOS can block a downloaded app on first launch. Users can approve this app with **System Settings → Privacy & Security → Open Anyway**, following [Apple's guidance](https://support.apple.com/en-us/102445).

`First Launch.txt` also provides BladeVault's app-specific quarantine-removal method, scoped recursively to `/Applications/Warp OpenCode Bridge.app` so the nested helper can run. It does not change global Gatekeeper settings. Include this first-launch limitation in release notes.

## Local build and verification

```sh
scripts/test.sh
scripts/build-dmg.sh --arch arm64
scripts/verify-dmg.sh build/Warp-OpenCode-Bridge-0.1.0-arm64.dmg arm64
```

Use the current bundle version in filenames. Substitute `x86_64` for an Intel build. Cross-compilation is supported, but a structural check is not a native runtime test. `verify-dmg.sh` verifies the disk image, mounts it read-only, checks the Applications shortcut and first-launch instructions, copies the app to a temporary install location, verifies bundle metadata, architectures, ad-hoc signatures, and licenses, and runs the bundled helper on a matching host. It cleans up its mount and temporary install.

With only Command Line Tools, use `scripts/test.sh --portable`; this executes the existing test bodies with an assertion adapter, not XCTest. Full Xcode and CI run normal XCTest. The real-helper offline configuration regression must pass. No tests create Cloudflare tunnels or DNS records.

Open the packaged app and verify its settings window, menu bar, Dock behavior, and quitting. Account-specific setup, public connection testing, and a real Warp conversation are separate manual checks; package verification does not establish those outcomes.

## Publish a version

1. Update `CFBundleShortVersionString` in `Config/Info.plist` and increment `CFBundleVersion`. Update the changelog and version examples as needed.
2. Review and commit the source intended for release. Preserve `WarpGoBridge` executable/product/data-directory names and `dev.warpgobridge.app` bundle ID/Keychain service for existing installations.
3. Push the reviewed commit, then create and push its matching version tag. For the initial `0.1.0` bundle:

   ```sh
   git tag v0.1.0
   git push origin v0.1.0
   ```

4. Follow **macOS CI and release** in GitHub Actions. Both native runner jobs fetch the verified helper, run XCTest, build DMG/ZIP downloads, and verify the mounted DMG. A tag that differs from the bundle version fails before publication.
5. The release job downloads both verified builds, checks their DMG checksums, creates combined checksums, uploads all assets to a draft release, then makes it public. Only this job has `contents: write`; it uses the built-in `GITHUB_TOKEN` with no extra repository secrets. If an upload fails, the release stays a draft and the job can be rerun. Already public releases are not overwritten; publish a new version for changes.

Branch pushes, pull requests, and manual workflow runs produce downloadable CI artifacts without creating a GitHub release. A local build or a matching Git SHA does not prove hosted CI passed or that a public download exists. Record the actual outcome separately.

## Optional Developer ID builds

`SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/build-app.sh` remains available for manual app/ZIP builds. This enables hardened runtime and timestamping, but does not notarize or publish. `build-dmg.sh` deliberately uses the unsigned release policy regardless of that environment variable.

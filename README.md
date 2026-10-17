# Warp OpenCode Bridge

<img src="Config/AppIcon.png" width="96" height="96" alt="Warp OpenCode Bridge app icon" />

A native macOS app with a menu bar switch that connects Warp's custom inference endpoint to an **OpenCode Go subscription**. Turn the bridge on when you need it and off when you are done. The app runs a local authenticated proxy and manages a Cloudflare Tunnel to reach it.

Local build and automated checks can be run without accounts. A native Warp → Cloudflare → Go fresh chat, follow-up, and continuation in the same chat after turning the bridge Off and On have been confirmed working with `deepseek-v4.1-flash`. Run the connection test and a short Warp conversation after setting up your own account.

## How it works

```text
Warp on your Mac → Warp's servers → your Cloudflare HTTPS hostname
                                            ↓ tunnel
                                Warp OpenCode Bridge on your Mac
                                            ↓
                                     OpenCode Go
```

Warp's custom inference traffic originates on Warp's servers, so a proxy bound to your Mac's loopback address needs a public HTTPS entry point. Cloudflare Tunnel supplies that entry point without port forwarding or a VPS. Your Mac must stay awake and connected while the bridge is on.

The bridge checks a separate access token, adds your Go key, an application user agent, and an `x-opencode-session` header, then forwards streamed responses. It uses Go's OpenAI-compatible endpoint; Zen is not part of this app.

## Requirements

- macOS 14 or later, on Apple silicon or Intel.
- Warp with custom inference endpoint support.
- An OpenCode Go subscription and its API key.
- A Cloudflare account with an active domain managed there, and permission to create a tunnel and its DNS record. Use an unused subdomain such as `warp-go.example.com`.
- To build from source: Xcode or Command Line Tools with a Swift 6 toolchain.

The build script bundles a checksum-verified `cloudflared` helper. No Homebrew installation is needed for that build. Cloudflare's standard account and service limits apply.

## Download and install

Download a DMG from [GitHub Releases](https://github.com/dedkola/warp-opencode/releases): choose `arm64.dmg` for Apple silicon (M1 or newer) or `x86_64.dmg` for Intel. Releases are created when a matching version tag is pushed and both macOS builds pass CI.

1. Open the DMG and drag **Warp OpenCode Bridge.app** onto **Applications**.
2. Eject the DMG and open the app from Applications.
3. Follow the app's setup. The Cloudflare helper is included; Xcode, Swift, and Homebrew are not required to run the app.

Downloads are **not Developer ID signed or notarized** and require no Apple signing account. If macOS blocks the first launch, use **System Settings → Privacy & Security → Open Anyway** for this app. The DMG also includes **First Launch.txt** with the same app-specific Terminal method used by BladeVault:

```sh
xattr -dr com.apple.quarantine "/Applications/Warp OpenCode Bridge.app"
open "/Applications/Warp OpenCode Bridge.app"
```

Use this only for a download you trust. It removes quarantine from this app and its bundled helper; it does not disable Gatekeeper globally. Subsequent launches work normally. See [Apple's first-launch guidance](https://support.apple.com/en-us/102445).

ZIP downloads are also available. To verify a download, get `SHA256SUMS` from the same release and run `shasum -a 256 <downloaded-file>`; compare the result with its entry in that file.

## Build from source

```sh
scripts/test.sh
scripts/build-app.sh
open "build/Warp OpenCode Bridge.app"
```

The script produces an app and a versioned ZIP in `build/` for your Mac's architecture. Use `scripts/build-dmg.sh` to also create the drag-to-Applications DMG. It downloads the pinned official Cloudflare helper on the first run. Generated files and credentials are excluded from Git.

`scripts/test.sh` runs `swift test`, which requires the XCTest framework supplied with full Xcode. If you only have Command Line Tools, run `scripts/test.sh --portable` instead. This compiles and executes the same test methods with a small local assertion adapter and local mock services. It is explicitly a **portable check run, not an XCTest run**. It does not accept an Xcode license or change your selected developer directory. GitHub CI still runs the normal XCTest suite.

Both modes fetch the pinned, checksum-verified `cloudflared` helper on the first run. One regression check uses the real helper to validate the generated tunnel configuration with fake credentials. That validation is offline and creates no tunnel, DNS record, or account connection. To use a specific installed helper, set `WARP_GO_CLOUDFLARED_PATH`; the test fails rather than skipping validation if no helper is available.

The app and helper have local ad-hoc integrity signatures so Apple silicon can run them. These do not identify an Apple developer or provide notarization. The DMG itself is unsigned. Downloaded copies use the first-launch steps above.

## First-time setup

1. Open the app's settings from its menu bar item and select **Setup**.
2. Choose **Connect Cloudflare…**. The official `cloudflared` login opens Cloudflare in your browser, where you sign in and select the domain to authorize. Check the app's **Domain** field afterward; enter that domain manually if Cloudflare does not allow automatic lookup.
3. Under **Configure your bridge**, choose an unused **Address** such as `warp-go`, enter your **Go API key**, and confirm the **Model ID**.
4. Choose **Create bridge**. The app saves your key in Keychain, generates a separate bridge access token, and creates its tunnel and DNS route. The button becomes **Save changes** after setup.
5. Under **Connect Warp**, choose **Turn on & test**, then copy the displayed **Endpoint URL**, **API key**, and **Model ID** into Warp. This test checks the public bridge connection without making a paid model request.

In Warp's custom inference settings, use the following values:

| Setting | Value |
| --- | --- |
| API/base URL | `https://warp-go.example.com/v1` (replace with your hostname) |
| API key | The app's **bridge access token**, not your OpenCode key |
| API format | OpenAI-compatible chat completions |
| Model | Your Go model ID, initially `deepseek-v4.1-flash` |

Warp's labels can change between versions. If it asks for the complete chat-completions URL instead of a base URL, use `https://warp-go.example.com/v1/chat/completions`. The upstream Go route is `https://opencode.ai/inference/go/openai/v1/chat/completions`.

Select the configured model in Warp and try a short request. A successful local proxy health check only confirms the local listener; a successful tunnel connection confirms Cloudflare connectivity. Neither alone proves that Warp and your Go subscription work end to end.

Keep the Cloudflare hostname free of browser login challenges: Warp's servers cannot complete an interactive login. The bridge's bearer token protects inference access.

## Conversation sessions

OpenCode Go requires a stable session ID for each conversation. Setting one global header for every chat, or changing it on every request, does not satisfy that requirement.

The bridge offers these modes:

| Mode | Behavior |
| --- | --- |
| **Automatic** | Prefers explicit conversation metadata from the client. Otherwise accepts a fresh user-only opening, including multiple user messages for context, and matches later history prefixes in memory. Rejects detected ambiguous matches and unrecognized continuations. |
| **Strict** | Requires explicit conversation metadata. Use this when you have verified that your Warp version sends a stable identifier. |
| **Manual single chat** | Uses explicit conversation metadata when present; otherwise uses the session you control. Use one Warp conversation at a time and choose **New session** before starting another. |

Warp has been observed sending a fresh chat as one system message plus three user messages, without a conversation identifier. Automatic mode supports that opening shape by fingerprinting the whole user-message envelope. A fresh chat, follow-up, and continuation after Off/On have returned successful Go responses in the same Warp chat, with Diagnostics identifying continuations by history.

Automatic matching keeps the same in-memory session history when you turn the bridge Off and On while the app stays open. Quitting and reopening the app, changing the routing mode, or resetting conversation history clears that cache. Start a new Warp chat after those actions if Warp does not send a conversation identifier. The cache contains message fingerprints rather than conversation text; neither is written to disk.

Warp compacting or replacing history can make an existing chat unrecognizable. The bridge rejects histories it detects as ambiguous or unknown, but prefix matching remains approximate: it cannot reliably distinguish separate or forked chats that share the same history. Manual mode is available for one chat at a time; it does not safely distinguish concurrent conversations. Strict mode requires a verified stable client identifier.

Without explicit conversation metadata, an **exact retry of an earlier request also receives HTTP 409**: it cannot be distinguished safely from a separate chat with identical content. This includes retries after an upstream error. Choose a distinct new Warp chat, or stop the bridge and select Manual mode for one-chat use.

To verify Automatic mode after setup, start a fresh Warp chat, send a short prompt, and then send a follow-up. Turn the bridge Off and On without quitting the app and continue that chat. Confirm that Go answers each turn and that Diagnostics reports history matching for the continuation. Also try a distinct new chat. Repeat these checks with your account and Warp version; history matching depends on the request format Warp sends.

## Everyday use

The app appears in the Dock and macOS app switcher (Cmd+Tab). Open Settings from the menu bar, press `Cmd+,` while the app is active, or click its Dock icon. These actions bring the same Settings window forward, including when it is minimized. Closing Settings keeps the app and bridge running; choose **Quit** to stop the app.

Use the menu bar switch to start or stop this app's local proxy and tunnel process. Turning it off makes this endpoint unavailable in Warp. Select another model in Warp when you want to use a different provider; the bridge does not change Warp's model selection.

Quitting the app stops its own processes. It does not stop an unrelated Cloudflare Tunnel or modify your existing `~/.cloudflared` setup. Turning it off does not remove the tunnel and DNS record from your Cloudflare account.

## Credentials and data

- The Go API key and bridge access token are stored in macOS Keychain.
- App configuration and the helper's private home live under `~/Library/Application Support/WarpGoBridge/`. The helper uses its own Cloudflare certificate and tunnel credential files there.
- Cloudflare's login authorization certificate can manage tunnels and DNS routes for the authorized account. Treat it and the tunnel credentials as secrets. Remove or revoke them in Cloudflare when you no longer need the bridge.
- Cloudflare terminates the public HTTPS connection and carries prompts and responses through its tunnel. Warp and OpenCode also receive the inference content as part of their normal operation.
- The local proxy binds to loopback. Public inference requests must present the generated bridge token. Do not publish that token or put it in screenshots or issue reports.
- Requests are forwarded only to the configured Go endpoint; this is not a general-purpose open proxy.

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

`scripts/fetch-cloudflared.sh` pins version `2026.10.1`. It verifies the archive against `Config/cloudflared-checksums.txt` before extracting it. To update the helper, review the official release, verify both macOS archive hashes, and update the pin and notices together. See [third-party notices](THIRD_PARTY_NOTICES.md).

For Developer ID signing, set `SIGNING_IDENTITY` when running the packaging script. This signs the nested helper and app with hardened runtime enabled. It does not submit the app for notarization or publish a release.

```sh
SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/build-app.sh
```

GitHub Actions runs the normal Swift tests and packages/verifies DMG and ZIP artifacts on native Apple silicon and Intel runners for pushes, pull requests, and manual runs. Pushing a `v<version>` tag matching `Config/Info.plist` additionally publishes both downloads and `SHA256SUMS` to GitHub Releases, after both builds pass. Publication uses only GitHub's built-in token; no Apple, Cloudflare, or Go credentials are required.

See [release instructions](docs/RELEASING.md) for versioning, publication, and validation. Changes for the first release are recorded in the [changelog](CHANGELOG.md).

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Cloudflare login never completes | Finish authorization in the browser; confirm the selected domain belongs to the intended account. |
| DNS route creation fails | Use a fresh hostname and confirm your account can manage its DNS. Do not overwrite a production record. |
| HTTP 530 shortly after starting a tunnel | The public route may still be propagating at Cloudflare's edge. Wait briefly and use **Test connection** again; if it persists, check the tunnel and DNS route. |
| Warp reports an authorization error | Paste the app's bridge access token into Warp and use the exact copied `/v1` URL. In Diagnostics, a bridge HTTP 401 means missing or invalid bridge credentials; an `OpenCode returned HTTP 401` event means the request reached Go. |
| App waits while opening after a local rebuild | Approve the macOS Keychain prompt for this app. Ad-hoc signing can change the app's identity after a rebuild and require authorization to read saved keys again. |
| HTTP 409 / session identification error | Automatic mode rejects detected ambiguous history, unknown continuations, and exact retries without conversation metadata. Its cache survives Off/On but clears on quit, routing-mode changes, or history reset. Start a distinct new chat, or stop the bridge and select Manual mode for one-chat use. Strict mode requires stable client metadata. |
| Local health works but Warp fails | Check public DNS, tunnel state, Warp URL, selected model, and your Go subscription. |
| Go reports `MissingSessionID` | Confirm Warp is using the bridge URL rather than the direct Go URL. |
| Requests stop when the lid closes | The bridge runs on this Mac and needs it awake and online. |

Report the macOS version, bridge version, and redacted error text when filing an issue. Never attach keys, tokens, Cloudflare certificates, tunnel credential JSON, or conversation content.

## Official references

- [Warp custom inference endpoint](https://docs.warp.dev/agents/inference/custom-inference-endpoint)
- [OpenCode Go and supported clients](https://opencode.ai/docs/go/#where-can-i-use-it)
- [Cloudflare locally managed tunnel setup](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/get-started/create-local-tunnel/)
- [Pinned cloudflared release](https://github.com/cloudflare/cloudflared/releases/tag/2026.10.1)

MIT license. Independent project; not affiliated with Warp, OpenCode, or Cloudflare.

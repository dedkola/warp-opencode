# Bridge guide

[← Back to the README](../README.md)

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

## Credentials and data

- The Go API key and bridge access token are stored in macOS Keychain.
- App configuration and the helper's private home live under `~/Library/Application Support/WarpGoBridge/`. The helper uses its own Cloudflare certificate and tunnel credential files there.
- Cloudflare's login authorization certificate can manage tunnels and DNS routes for the authorized account. Treat it and the tunnel credentials as secrets. Remove or revoke them in Cloudflare when you no longer need the bridge.
- Cloudflare terminates the public HTTPS connection and carries prompts and responses through its tunnel. Warp and OpenCode also receive the inference content as part of their normal operation.
- The local proxy binds to loopback. Public inference requests must present the generated bridge token. Do not publish that token or put it in screenshots or issue reports.
- Requests are forwarded only to the configured Go endpoint; this is not a general-purpose open proxy.

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

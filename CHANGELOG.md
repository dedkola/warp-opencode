# Changelog

## Unreleased — 0.1.0 preparation

- Native **Warp OpenCode Bridge** macOS menu bar app with an On/Off switch, setup, connection settings, and diagnostics.
- Dock and Cmd+Tab presence, with one Settings window that comes forward from the menu bar, `Cmd+,`, or Dock reopen, including after minimizing or closing it.
- Original lightning-and-circle Dock icon with all standard macOS resolutions, matching the existing adaptive menu bar symbol.
- Cloudflare browser authorization and named-tunnel/DNS setup using a bundled, checksum-pinned `cloudflared` helper.
- Authenticated local proxy for OpenCode Go chat completions with streaming, tool calls, cancellation, and required provider headers.
- Go key and private bridge token stored in macOS Keychain; Cloudflare files isolated from the user's existing tunnel configuration.
- Automatic conversation routing for Warp's multiple-user-message opening, with in-memory history retained across Off/On; Strict and Manual modes are also available.
- Exact duplicate requests and detected ambiguous or unknown histories fail with HTTP 409. Automatic matching remains approximate and does not survive quitting, routing-mode changes, or history reset.
- Fresh Warp chat, follow-up, and continuation in the same chat after Off/On confirmed working with `deepseek-v4.1-flash`.
- Swift tests, Command Line Tools portable checks, app packaging, and pinned GitHub Actions workflow.
- Self-contained unsigned DMG downloads for Apple silicon and Intel, with an Applications shortcut and BladeVault-style first-launch instructions.
- Native tests and mounted-DMG verification on both architectures; version tags publish DMG/ZIP downloads and SHA-256 checksums to GitHub Releases only after both builds pass.

Source publication and a public binary release are separate actions. DMG releases use local ad-hoc executable integrity signatures without Developer ID signing or notarization; downloaded apps may require one-time macOS approval.

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

Source publication and a public binary release are separate actions. Local packages are ad-hoc signed unless a Developer ID identity is supplied; no notarized public binary is declared by this entry.

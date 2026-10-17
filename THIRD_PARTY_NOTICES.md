# Third-party notices

Warp OpenCode Bridge's Swift sources use Apple's system frameworks and have no third-party Swift package dependencies.

Packaged builds include **cloudflared 2026.10.1**, published by Cloudflare, Inc. under the Apache License, Version 2.0. Its license is included at `Config/cloudflared-LICENSE.txt` and copied into the app bundle. Source and upstream notices: <https://github.com/cloudflare/cloudflared/tree/2026.10.1>.

The helper is downloaded from Cloudflare's official GitHub release assets. Its archives are verified against pinned SHA-256 digests in `Config/cloudflared-checksums.txt`. The digests come from the GitHub release asset metadata and were verified against both downloaded macOS archives. The checksum list in that release's description differs from the actual archive hashes; this project uses the matching asset metadata.

Warp, OpenCode, and Cloudflare are trademarks of their respective owners. This is an independent project and is not endorsed by those services.

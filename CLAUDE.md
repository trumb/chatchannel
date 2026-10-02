# ChannelChat (codename "Anansi")

Client/server message-exchange MVP. A dependency-free Windows PowerShell client talks to a
Node.js HTTP/HTTPS server using an exactly-reversible 256-entry dictionary codec
(byte → string), then GZip + Base64. Named for Anansi, the Akan deity of stories and
communication.

> Encoding, not encryption. The codec provides no confidentiality or authenticated
> integrity. See [SECURITY.md](SECURITY.md).

## Commands

```bash
# Server
node src/bin/serve.mjs --config config/server.local.json     # 127.0.0.1:8080
node src/bin/serve.mjs --config config/server.azure.json     # 0.0.0.0:80
node src/bin/serve.mjs --config config/https.example.json    # optional HTTPS

# Build artifacts
node tools/gen-dictionary.mjs        # regenerate data/dictionary.v1.json
node tools/gen-vectors.mjs           # regenerate shared/ fixtures
node client/build/build-client.mjs   # regenerate client/dist/channelchat-client.ps1

# Tests
npm test                             # node --test (server/codec/protocol/http/https/interop)
npm run test:ps                      # dependency-free PowerShell client harness
```

Client usage: `. .\client\dist\channelchat-client.ps1` then `Send-ChannelMessage`,
`Test-ChannelEndpoint`, `ConvertTo-ChannelTokens`, `ConvertFrom-ChannelTokens`.

## Architecture

- **Server:** Node.js (LTS, tested on 22.x), built-in modules only (`http`, `https`, `zlib`,
  `crypto`, `node:test`). No npm dependencies.
- **Client:** Windows PowerShell 5.1 compatible (also runs on 7+), built-in .NET only. Uses
  `HttpWebRequest` (no auto-redirect, direct connection, normal TLS validation).
- **Codec:** dictionary index = byte value; reverse lookup via `Map` (JS) /
  `Dictionary[string,byte]` with `StringComparer.Ordinal` (PS). Fingerprint is a SHA-256 over
  the prefix + per-entry length-prefixed UTF-8 bytes, identical in both languages.
- **Protocol:** `GET /healthz`, `POST /api/v1/exchange`; versioned JSON envelope; MVP app
  behavior is an exact decode→re-encode echo. See [PROTOCOL.md](PROTOCOL.md).

## Key files

| File | Purpose |
|------|---------|
| `data/dictionary.v1.json` | 256-entry default dictionary (index = byte) |
| `src/dictionary.js` / `client/ChannelChat.Core.ps1` | validation + fingerprint (both languages) |
| `src/codec.js` | byte↔token, payload pack/unpack (JS) |
| `src/protocol.js` | envelope validation + echo + status mapping |
| `src/server.js` | HTTP/HTTPS server, bounded reads, timeouts, concurrency |
| `src/limits.js` | named, configurable resource limits |
| `client/ChannelChat.Client.ps1` | PS transport + public functions |
| `client/build/build-client.mjs` | standalone-client generator |
| `shared/vectors.json`, `shared/dictionary-fixture.json` | cross-language golden fixtures |

## Conventions

- New systems/services use African deity names (Yoruba/Akan/Ashanti): Orunmila, Anansi,
  Obatala, Eshu, Shango, Yemoja.
- Status is tracked in `ai-status/CURRENT_STATUS.md` and `ai-status/SESSION_LOG.md`.
- Do not describe Base64/GZip/dictionary substitution as encryption. Keep the encoding,
  transport, and authentication concerns separate.

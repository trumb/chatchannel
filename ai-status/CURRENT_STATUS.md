# ChannelChat (Anansi) — Current Status

## Project Phase: MVP Complete (local)

Client/server message-exchange MVP with a reversible dictionary codec, HTTP (port 80
supported) + optional HTTPS, a dependency-free Windows PowerShell client, build tooling, and
automated tests. Implemented and tested locally only; no Azure deployment performed.

| Task | Status | Notes |
|------|--------|-------|
| Dictionary format + 256-entry default | Done | `data/dictionary.v1.json`, generator in `tools/` |
| Deterministic fingerprint (JS + PS) | Done | `sha256:c086524028b0dd375fb50622076755b293a478009a3c99cc44003b79f1781425` |
| Reversible codec (JS) | Done | `src/codec.js` — text strict UTF-8, bytes all-256, Map reverse lookup |
| Reversible codec (PS) | Done | `client/ChannelChat.Core.ps1` — strict UTF-8, ordinal Dictionary, hand-rolled token-JSON parser |
| Shared golden vectors + fixture | Done | `shared/vectors.json`, `shared/dictionary-fixture.json` |
| Wire protocol + envelope validation | Done | `src/protocol.js`, `PROTOCOL.md` |
| HTTP/HTTPS server | Done | `src/server.js` — `/healthz`, `/api/v1/exchange`, echo re-encodes |
| Bounds / errors / timeouts / concurrency | Done | `src/limits.js`; enforced while reading; bounded gunzip |
| Optional HTTPS | Done | `config/https.example.json`, `ANANSI_TLS_*`; validation never bypassed |
| PowerShell public API | Done | `ConvertTo/From-ChannelTokens`, `Send-ChannelMessage`, `Test-ChannelEndpoint` |
| Embedded package + standalone client build | Done | `client/build/build-client.mjs` → `client/dist/channelchat-client.ps1` |
| Staleness test for embedded dictionary | Done | `test/staleness.test.mjs` — checks the embedded dictionary only, NOT the inlined client code (dist drifted once; see Session 2) |
| Node tests (unit/integration/https/interop) | Done | `node --test` — all pass |
| PowerShell dependency-free harness | Done | `test/pwsh/run-tests.ps1` — all pass |
| Docs (README, PROTOCOL, SECURITY) | Done | plus Azure notes + Windows verification in README |
| Windows PowerShell 5.1 verification | NOT RUN | no Windows host here; commands in README |
| Standard-user-on-Windows verification | NOT RUN | commands in README |
| Server bound to privileged port 80 | NOT RUN | verified on high port; `server.azure.json` targets :80 |

## Versions tested

- Node.js: 22.23.3 (Linux)
- PowerShell: 7.6.6 (Linux) — Windows PowerShell 5.1 NOT yet run
- OpenSSL: present (used to mint the HTTPS test certificate)

## Local environment notes

- On this VM, `127.0.0.1:8080` is owned by an nginx listener (returns 301). Run the server
  with `ANANSI_PORT=8090` (or another free port) and pass `-Endpoint` to the client, or
  rebuild the standalone client with `--endpoint http://127.0.0.1:8090/api/v1/exchange`.

## Next steps

1. Run the PowerShell harness and a live exchange on Windows PowerShell 5.1 (Windows 10 /
   Server 2019) as a standard user; record exact PowerShell / Windows / .NET versions.
2. Arrange the server-side privilege to bind :80 on the Azure VM (or place behind the
   existing reverse proxy) — operator task; no deployment in scope here.
3. Replace the echo with real application behavior when the business logic is defined.
4. Extend `test/staleness.test.mjs` to also compare the inlined `ChannelChat.Core.ps1` /
   `ChannelChat.Client.ps1` sections of the dist against the sources (the dictionary check
   alone missed a stale error code in Session 2).
5. Consider an authentication layer as a separate concern if/when required (kept out of the
   MVP by design).

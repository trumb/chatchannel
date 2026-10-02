# ChannelChat (Anansi) — Session Log

## Session 1 — 2026-10-02 — MVP build

**Focus**: Build the ChannelChat client/server MVP from the spec — reversible dictionary
codec, HTTP (port 80) + optional HTTPS exchange, dependency-free PowerShell client with an
embedded package, build tooling, tests, and docs. Local only; no Azure deployment.

**Key deliverables**:

- **Dictionary + fingerprint**: 256-entry `data/dictionary.v1.json` (generator in
  `tools/gen-dictionary.mjs`). SHA-256 fingerprint computed identically in JS
  (`src/dictionary.js`) and PowerShell (`client/ChannelChat.Core.ps1`):
  `sha256:c086524028b0dd375fb50622076755b293a478009a3c99cc44003b79f1781425`.
- **Codec (both languages)**: byte↔token, strict UTF-8 text mode (rejects lone surrogates /
  malformed UTF-8), all-256 byte mode, Map / ordinal `Dictionary` reverse lookup, bounded
  gunzip, strict canonical Base64, payload = tokens→JSON→GZip→Base64.
- **Protocol + server**: `src/protocol.js`, `src/server.js`. Versioned envelope validation,
  decode→re-encode echo with correlation (`inReplyTo`, fresh `messageId`), bounded body reads
  (chunked + Content-Length), concurrency cap, request deadline, safe bounded error bodies,
  `application/json; charset=utf-8` + `Cache-Control: no-store`.
- **Limits**: named/configurable in `src/limits.js`; enforced while reading/decompressing.
- **PowerShell client**: public `ConvertTo/From-ChannelTokens`, `Send-ChannelMessage`,
  `Test-ChannelEndpoint`; `HttpWebRequest` with no auto-redirect, direct connection (no
  ambient proxy), normal TLS validation; distinct text/bytes handling preserving empty and
  single-element arrays.
- **Standalone client**: `client/build/build-client.mjs` emits `client/dist/channelchat-
  client.ps1` with an embedded GZip+Base64 package (dictionary + public config), decoded in
  memory (never written to a temp file). `test/staleness.test.mjs` detects a stale embed.
- **Tests**: `node --test` (dictionary, codec, vectors, protocol, server HTTP incl. chunked/
  oversized/stalled/concurrency, HTTPS cert rejection + trusted round trip, staleness,
  interop + e2e). Dependency-free PS harness `test/pwsh/run-tests.ps1`.
- **Docs**: `README.md`, `PROTOCOL.md`, `SECURITY.md`, `CLAUDE.md`, `AGENTS.md`.

**Notable fixes during build**:

1. PowerShell empty-array returns collapse to `$null` on the pipeline — wrapped all
   array-returning helpers with the unary comma (`return , $x`).
2. Two mandatory parameter sets can't disambiguate an empty-string argument — switched
   `-Text`/`-Bytes` to optional params resolved via `$PSBoundParameters`.
3. `ConvertFrom-ChannelPayload` lost array-ness across a second `return` boundary for empty
   token arrays — re-wrapped with the comma idiom.
4. Windows PowerShell 5.1 `ConvertFrom-Json` coerces date-like strings to `[datetime]` —
   wrote a strict hand-rolled token-array JSON parser to preserve tokens exactly.
5. `HttpWebRequest` used an ambient proxy that returned 301 — set `$req.Proxy = $null` for a
   direct connection (also prevents silent proxy redirects).

**Verification**: `node --test` — 84 tests pass. `test/pwsh/run-tests.ps1` — 51 assertions
pass on PowerShell 7.6.6 (Linux).

**NOT RUN** (no suitable host in this environment): Windows PowerShell 5.1, standard-user on
Windows, and a privileged bind to port 80. Exact repro commands are in `README.md`.

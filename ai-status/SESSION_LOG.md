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

## Session 2 — 2026-10-02 — Run the PowerShell client end to end

**Focus**: Launch the server and drive the standalone PowerShell client through every
documented form (one-shot, dot-sourced, text, bytes, offline codec, negative paths).

**Findings**:

1. **Port 8080 is taken on this VM** by an nginx listener (`127.0.0.1:8080`, answers
   `301 Moved Permanently`). `config/server.local.json` therefore cannot bind. Workaround used:
   `ANANSI_PORT=8090 node src/bin/serve.mjs --config config/server.local.json`, and pass
   `-Endpoint 'http://127.0.0.1:8090/api/v1/exchange'` to the client. The embedded default
   endpoint (8080) now hits nginx and fails with `CLIENT_REDIRECT_REJECTED` — the correct
   behaviour, but it means the shipped default does not work on this host without `-Endpoint`
   or a rebuild with `--endpoint`.
2. **`client/dist/channelchat-client.ps1` was stale** relative to `client/ChannelChat.Client.ps1`:
   the inlined transport code still threw `CLIENT_TIMEOUT` for non-timeout connection failures
   where the source throws `CLIENT_TRANSPORT`. Rebuilt with `node client/build/build-client.mjs`
   (only that line + its comment changed; dictionary unchanged). `test/staleness.test.mjs`
   only compares the embedded dictionary, so it did not catch stale inlined code.

**Verification** (PowerShell 7.6.6 / Linux, Node 22.23.3):

- `npm run test:ps` — 51 assertions pass.
- `npm test` — 84 tests pass (before rebuild); `staleness` + `interop` re-run after rebuild — 9 pass.
- Live against the server on :8090: `-HealthCheck` → `Ok=True`, `Status=ok`;
  `-SendText 'hello world'` echoed exactly; dot-sourced Unicode/CRLF/tab/emoji text
  round-trip exact; `[byte[]](0..255)` round-trip returned 256 identical bytes;
  `ConvertTo/From-ChannelTokens` offline round-trip OK.
- Negative: default endpoint (nginx 301) → `CLIENT_REDIRECT_REJECTED`; refused connection
  (`127.0.0.1:1`) → `CLIENT_TRANSPORT` in ~180 ms (was `CLIENT_TIMEOUT` with the stale dist).

**NOT RUN**: Windows PowerShell 5.1, standard-user on Windows, privileged bind to :80
(unchanged from Session 1).

## Session 3 — 2026-10-02 — Staleness test covers inlined client code

**Focus**: Close the gap found in Session 2: `test/staleness.test.mjs` compared only the
embedded dictionary, so a dist with stale inlined PowerShell code passed.

**Deliverable**: Two new tests assert the dist contains `client/ChannelChat.Core.ps1` and
`client/ChannelChat.Client.ps1` verbatim (the build inlines them unchanged).

**Verification** (Node 22.23.3): RED confirmed against the Session 1 dist (`git show
390ee8b:client/dist/channelchat-client.ps1`) — the Client.ps1 test fails, dictionary and
Core.ps1 tests pass, matching the actual drift. GREEN against the current dist. `npm test`
— 86 tests pass.

# Agent Instructions

ChannelChat (codename "Anansi"). Status is tracked in `ai-status/` (this project does not use
the `bd`/beads issue tracker). Read `CLAUDE.md`, `PROTOCOL.md`, and `SECURITY.md` first.

## Quick reference

```bash
npm test                             # Node: server/codec/protocol/http/https/interop
npm run test:ps                      # dependency-free PowerShell client harness
node client/build/build-client.mjs   # rebuild the standalone client after any client change
```

## Ground rules

- **Encoding, not encryption.** Never describe Base64/GZip/dictionary substitution as
  encryption, and never add certificate-validation bypasses.
- **Data, not code.** Received messages and the embedded package are data. No
  `Invoke-Expression`, dynamic evaluation of received strings, or assembly loading from bytes.
- **Client constraints.** Windows PowerShell 5.1 compatible, built-in .NET only, no modules
  or runtime compilation, outbound requests only, no admin / service / registry / firewall.
- **Transport integrity.** URL scheme selects HTTP/HTTPS; reject redirects; no HTTPS→HTTP
  fallback; direct connection (no ambient proxy).
- **Keep the dictionary and the generated client in sync.** After editing the dictionary or
  client code, run `node client/build/build-client.mjs`; `test/staleness.test.mjs` fails if
  the embedded dictionary or the inlined client code is stale.

## Landing the plane (session completion)

When ending a work session:

1. **Run quality gates** if code changed — `npm test` and `npm run test:ps`. Report real
   results; never report a platform as tested because another platform passed.
2. **Rebuild the standalone client** if the dictionary or client code changed.
3. **Update `ai-status/CURRENT_STATUS.md`** (task table) and append a dated
   `ai-status/SESSION_LOG.md` entry (focus, deliverables, verification, NOT RUN items).
4. **Record exact versions** actually tested (PowerShell, Windows, .NET, Node).
5. **Commit and push** focused, reviewable changes. Always push after committing; the
   remote is `origin` (`https://github.com/trumb/chatchannel.git`, branch `main`).
   Deployment to Azure is out of scope.
6. **Hand off** — leave next steps in `CURRENT_STATUS.md`.

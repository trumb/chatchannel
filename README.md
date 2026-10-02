# ChannelChat (codename "Anansi")

A small client/server message-exchange MVP:

- **Server** — a Node.js (built-in modules only) HTTP/HTTPS service exposing `GET /healthz`
  and `POST /api/v1/exchange`.
- **Client** — a dependency-free Windows PowerShell client (runs as an ordinary user) that
  encodes a message, POSTs it, and verifies + decodes the response.
- **Codec** — an exactly-reversible 256-entry dictionary that maps each byte to a string,
  then GZip + Base64. Identical fingerprint in both languages.

Anansi is the deity of stories and communication; it is the system codename for ChannelChat.

> **Encoding, not encryption.** The dictionary/GZip/Base64 layers provide no confidentiality
> and no authenticated integrity. See [SECURITY.md](SECURITY.md). Use HTTPS when you need
> confidentiality or server authentication.

The protocol is specified in [PROTOCOL.md](PROTOCOL.md).

## Requirements

- **Server:** Node.js LTS. Developed and tested on **Node.js 22.x**; `package.json` pins
  `engines.node >= 20.0.0`. No third-party npm dependencies.
- **Client:** Windows PowerShell **5.1** (Windows 10 / Windows Server 2019) or PowerShell 7+.
  Built-in .NET only — no modules, NuGet, downloaded assemblies, or runtime compilation.

## Layout

```
data/dictionary.v1.json          256-entry default dictionary (generated, committed)
src/                             server + codec (dictionary, codec, protocol, server, limits, config)
src/bin/serve.mjs                server entrypoint
client/ChannelChat.Core.ps1      dependency-free PS codec/dictionary/package core
client/ChannelChat.Client.ps1    PS transport + public functions
client/ChannelChat.psm1          DEV module (dot-sources the above)
client/build/build-client.mjs    builds the standalone client
client/dist/channelchat-client.ps1  generated standalone client (embedded package)
tools/                           dictionary, package, and vector generators
shared/                          golden vectors + dictionary fingerprint fixture
test/                            Node tests (*.test.mjs) + PowerShell harness (test/pwsh/)
config/                          server.local.json (8080), server.azure.json (80), https.example.json
```

## Build

```bash
# Regenerate the dictionary and shared fixtures (only if you change the dictionary source)
node tools/gen-dictionary.mjs
node tools/gen-vectors.mjs

# Build the standalone PowerShell client (embeds the current dictionary + public config)
node client/build/build-client.mjs                      # default endpoint http://127.0.0.1:8080/...
node client/build/build-client.mjs --endpoint http://server.example/api/v1/exchange
```

## Run the server

```bash
# Local development (binds 127.0.0.1:8080)
node src/bin/serve.mjs --config config/server.local.json

# Azure-facing HTTP on port 80 (see "Azure deployment notes" for binding to :80)
node src/bin/serve.mjs --config config/server.azure.json

# Optional HTTPS (point tls.certFile / tls.keyFile at real files first)
node src/bin/serve.mjs --config config/https.example.json
# or via env:
ANANSI_TLS_CERT=/path/cert.pem ANANSI_TLS_KEY=/path/key.pem ANANSI_PORT=8443 node src/bin/serve.mjs
```

Environment overrides: `ANANSI_HOST`, `ANANSI_PORT`, `ANANSI_DICTIONARY`, `ANANSI_TLS_CERT`,
`ANANSI_TLS_KEY` (both TLS vars together enable HTTPS).

Check it:

```bash
curl http://127.0.0.1:8080/healthz
```

## Use the client

Dot-source the standalone client (it loads the embedded dictionary automatically), then call
the functions. The URL scheme selects HTTP vs HTTPS.

```powershell
# Load the self-contained client
. .\client\dist\channelchat-client.ps1

# 1) Text exchange over HTTP
Send-ChannelMessage -Text 'hello world' -Endpoint 'http://server.example/api/v1/exchange'

# 2) Text exchange over HTTPS (when the server has a trusted certificate)
Send-ChannelMessage -Text 'hello world' -Endpoint 'https://server.example/api/v1/exchange'

# 3) Unicode + multiline content
Send-ChannelMessage -Text "Anansi weaves`r`nline two`ttab 🕷" -Endpoint 'http://server.example/api/v1/exchange'

# 4) Binary round trip (returns the decoded bytes)
$bytes = [byte[]](0..255)
$r = Send-ChannelMessage -Bytes $bytes -Endpoint 'http://server.example/api/v1/exchange' -AsByteArray
$r.Bytes.Length    # 256

# 5) Liveness probe
Test-ChannelEndpoint -Endpoint 'http://server.example/api/v1/exchange'

# Codec without the network:
$tokens = ConvertTo-ChannelTokens -Text 'hello'          # -> string[] token array
$text   = ConvertFrom-ChannelTokens -Tokens $tokens      # -> 'hello'
$raw    = ConvertFrom-ChannelTokens -Tokens $tokens -AsByteArray
```

One-shot (no dot-sourcing):

```powershell
.\client\dist\channelchat-client.ps1 -Endpoint 'http://server.example/api/v1/exchange' -SendText 'hello'
.\client\dist\channelchat-client.ps1 -Endpoint 'http://server.example/api/v1/exchange' -HealthCheck
```

`Send-ChannelMessage` returns a structured object (`Ok`, `Text`, `Bytes`, `Kind`,
`RequestMessageId`, `ResponseMessageId`, `InReplyTo`, `DictionaryId`, `HttpStatus`,
`Endpoint`). Library functions return data or throw terminating errors; they do not mix
`Write-Host` into returned data. An explicit `-Endpoint` always overrides the packaged
default.

The DEV module (`client/ChannelChat.psm1`) is for working inside this repo; the standalone
`client/dist/channelchat-client.ps1` is the artifact to copy to a client machine and imports
nothing project-local.

## Test

```bash
# Server + codec + protocol + HTTP integration + HTTPS + interop (Node built-in runner)
npm test                      # node --test

# Just the cross-language + end-to-end interop tests (spawns pwsh)
npm run test:interop

# Dependency-free PowerShell client harness
npm run test:ps               # pwsh -NoProfile -File test/pwsh/run-tests.ps1
#   on Windows PowerShell 5.1:  powershell.exe -NoProfile -File test\pwsh\run-tests.ps1
```

See the "Test status" section below for what is and is not exercised in this environment.

## Windows compatibility and standard-user verification

The client is written against built-in .NET Framework APIs that are also present in .NET 5+,
avoids PowerShell 7-only syntax, makes outbound requests only, requires no inbound listener,
and needs no service, scheduled task, registry change, or firewall change. Loading built-in
framework assemblies is the only assembly use; nothing is downloaded or compiled.

To verify on Windows as an ordinary (non-admin) user:

```powershell
# As a standard user on Windows 10 / Server 2019, Windows PowerShell 5.1:
$PSVersionTable.PSVersion            # record this
[Environment]::Version               # record the .NET version
whoami /groups                       # confirm NOT running as administrator

# Run the client test harness (no modules required)
powershell.exe -NoProfile -File test\pwsh\run-tests.ps1

# Exercise a live exchange against your server
. .\client\dist\channelchat-client.ps1
Test-ChannelEndpoint  -Endpoint 'http://your-server/api/v1/exchange'
Send-ChannelMessage   -Text 'hello' -Endpoint 'http://your-server/api/v1/exchange'
```

If execution policy or application control (WDAC/AppLocker) blocks the script, that failure
is reported clearly — the client does not attempt to bypass it. Run per policy, e.g.
`powershell.exe -ExecutionPolicy Bypass -File ...` only where you are permitted to, or have
the script allow-listed.

## Azure deployment notes (no deployment performed here)

This repository is implemented and tested locally only. Nothing here deploys to Azure,
changes firewall rules, modifies cloud resources, installs services, or stops processes.

To run the server on the Azure VM on port 80:

- **Binding to :80** is a server-side privilege concern (the non-admin requirement applies to
  the Windows *client*, not the server). Options, to be arranged by an operator:
  - run the Node process under a user/service permitted to bind low ports, or
  - grant the capability on Linux (`setcap 'cap_net_bind_service=+ep' $(command -v node)`), or
  - put the app on a high port (e.g. 8080) behind an existing reverse proxy that owns :80.
- **Network prerequisites** (NSG / cloud firewall allowing inbound 80/443, DNS) must already
  be provisioned. This project does not create or modify them.
- An existing listener may already own :80 on the VM (for example a reverse proxy). Do not
  add a second conflicting listener; integrate behind it or choose another port.
- For HTTPS, supply real certificate/key files via `config/https.example.json` or the
  `ANANSI_TLS_*` env vars. Keep normal certificate validation on the client.

## Test status

| Area | Status in this environment |
|------|----------------------------|
| Node server, codec, protocol, HTTP integration, limits/timeouts/concurrency | RUN — `node --test`, all pass |
| HTTPS cert rejection + trusted round trip (Node + PS client) | RUN — openssl-minted self-signed cert on Linux |
| Cross-language interop (PS↔JS) and end-to-end (PS client → server) | RUN — on **PowerShell 7.6.6 / Linux** |
| PowerShell dependency-free client harness | RUN — on **PowerShell 7.6.6 / Linux** |
| **Windows PowerShell 5.1** | **NOT RUN** — no Windows host available here. Repro: `powershell.exe -NoProfile -File test\pwsh\run-tests.ps1` on Windows 10 / Server 2019, plus a live `Send-ChannelMessage`. |
| **Standard-user on Windows** | **NOT RUN** — see "Windows compatibility" above for exact commands. |
| **Server bound to port 80** | **NOT RUN as privileged bind** — verified on a high port; `config/server.azure.json` targets :80. Binding :80 requires the server-side privilege arranged by an operator. |

A platform is never reported as tested because another platform passed. Windows and
privileged-bind checks are the operator's to complete with the commands above.

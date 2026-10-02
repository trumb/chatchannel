# Security and Limitations

ChannelChat ("Anansi") is a message-exchange MVP with a reversible dictionary codec. This
document states plainly what protection each mode does and does not provide.

## What the encoding is — and is not

The dictionary codec substitutes each byte for a string, then GZip-compresses and Base64-
encodes the result. **This is an encoding, not encryption.** Base64, GZip, and dictionary
substitution provide **no confidentiality** and **no authenticated integrity**. Anyone who
has the dictionary (it is embedded in the client and returned by `/healthz` as a
fingerprint) can decode the traffic. Do not describe any of these layers as encryption.

The dictionary fingerprint (`dictionaryId`) identifies dictionary **contents** so both ends
can confirm they share the same table. It is **not** proof of authenticity or a signature.

## Protection by mode

| Mode | Confidentiality | Server authentication | Integrity |
|------|-----------------|-----------------------|-----------|
| Plain HTTP (port 80) | None | None | None (transport only) |
| HTTPS | TLS session confidentiality | TLS certificate validation (not bypassed) | TLS transport integrity |

Plain HTTP plus dictionary encoding does **not** protect message contents. Use HTTPS when
confidentiality or server authentication matters, and keep normal certificate validation.

Authentication and confidentiality are intentionally **separate** from encoding and
transport. The MVP does not add mandatory TLS, mandatory keys, or a new authentication
framework. If integrated into an existing server, that server's authentication is preserved.

## Data, not executable payloads

Received messages and the embedded compressed package are treated strictly as **data**.
The implementation contains no remote command execution, no `Invoke-Expression`, no dynamic
evaluation of received strings, and no assembly loading from received bytes. The embedded
package contains the dictionary and public configuration only — no executable code and no
credentials.

## Resource limits (defaults)

All limits are named and configurable in `src/limits.js` (the client honors the client-
relevant subset, shipped inside the embedded package). Limits are enforced **while** reading
and decompressing, not only after full allocation. `Content-Length` is never trusted on its
own; chunked and oversized bodies are rejected during the read. Bounded GZip decompression
(`maxOutputLength` in Node; a capped read loop in PowerShell) prevents decompression bombs.

| Limit | Default |
|-------|---------|
| HTTP request body | 1 MiB |
| HTTP response body (client accepts) | 4 MiB |
| Base64 payload length | 1,500,000 chars |
| Compressed payload | 1 MiB |
| Decompressed token JSON | 8 MiB |
| Package compressed / decompressed | 512 KiB / 4 MiB |
| Dictionary entry length | 256 UTF-8 bytes |
| Token count | 2,000,000 |
| Reconstructed bytes | 8 MiB |
| JSON nesting depth (envelope) | 8 |
| Concurrent requests | 64 |
| Request timeout (server) | 15 s |
| Client timeout | 30 s |

Streams and network resources are disposed on both success and failure. On timeout or a
size-limit breach, processing stops and resources are released.

## Logging

The server logs request IDs, result codes, durations, and byte counts. It does **not** log
message contents or the full embedded package.

## Transport integrity rules

- The endpoint URL scheme alone selects HTTP or HTTPS; there is no contradicting flag.
- Redirects are rejected (`CLIENT_REDIRECT_REJECTED`); the client never follows a 3xx to a
  different destination, and never falls back from HTTPS to HTTP.
- The client connects directly and does not route through an ambient system proxy (which
  could silently redirect the request).
- HTTPS certificate validation is never disabled; an untrusted certificate fails the
  request rather than succeeding.

## Known limitations

- Echo-only application behavior in the MVP (no business logic yet).
- No message queue, retries, or exactly-once delivery. A duplicate POST is a duplicate
  message.
- The dictionary is static (no rotation in v1).
- Interoperability is **semantic**: GZip bytes need not be identical across runtimes, but
  the dictionary fingerprint is stable and both codecs decode each other's output.

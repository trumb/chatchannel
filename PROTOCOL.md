# ChannelChat Protocol v1 (codename "Anansi")

A synchronous request/response message exchange. The client encodes a message, POSTs it to
the server, the server decodes and re-encodes it (MVP behavior is an exact echo), and
returns the response in the same HTTP request. HTTP framing is used; there is no raw-TCP
length prefix.

## Transport

- `GET  /healthz` — liveness. Returns `{ "status": "ok", "protocolVersion": 1, "dictionaryId": "sha256:..." }`.
- `POST /api/v1/exchange` — the message exchange.

The transport (HTTP vs HTTPS) is determined solely by the endpoint URL scheme:

```
http://server.example:80/api/v1/exchange
https://server.example/api/v1/exchange
```

There is no separate `UseTls` flag. The client does not upgrade HTTP, downgrade HTTPS, or
follow redirects — a 3xx response is rejected with `CLIENT_REDIRECT_REJECTED`. When HTTPS is
used, normal certificate validation applies and is never bypassed.

All responses set `Content-Type: application/json; charset=utf-8` and `Cache-Control: no-store`.

## Request envelope

UTF-8 JSON:

```json
{
  "protocolVersion": 1,
  "dictionaryId": "sha256:<hex>",
  "messageId": "<UUID>",
  "kind": "text",
  "payloadEncoding": "dictionary-json+gzip+base64",
  "payload": "<Base64 string>"
}
```

- `kind` is `"text"` or `"bytes"`.
- `payloadEncoding` is always `"dictionary-json+gzip+base64"` in v1.
- `messageId` is an RFC-4122 UUID.

## Response envelope

```json
{
  "protocolVersion": 1,
  "dictionaryId": "sha256:<hex>",
  "messageId": "<new UUID>",
  "inReplyTo": "<request messageId>",
  "kind": "text",
  "payloadEncoding": "dictionary-json+gzip+base64",
  "payload": "<Base64 string>"
}
```

The client verifies, before returning decoded content: `protocolVersion`, `dictionaryId`
(must equal the client's dictionary fingerprint), `inReplyTo` (must equal the request
`messageId`), `kind`, and `payloadEncoding`.

v1 does NOT auto-retry POSTs. A message ID does not by itself establish exactly-once
delivery.

## Payload construction

```
original bytes
  -> dictionary token array        (byte i -> entries[i]; index IS the byte value)
  -> UTF-8 JSON                     (a JSON array of strings)
  -> GZip
  -> Base64
```

Receiving reverses this. The GZip layer lives INSIDE the `payload` field; it is not HTTP
`Content-Encoding`.

- Text mode: input is strict UTF-8; well-formed Unicode only. Unpaired UTF-16 surrogates
  and malformed UTF-8 are rejected.
- Bytes mode: arbitrary bytes; all 256 values are supported.
- Case, punctuation, whitespace, newlines, tabs, nulls, and valid Unicode are preserved
  exactly, with no normalization. Dictionary tokens may contain spaces, punctuation, and
  Unicode; decoding uses exact (ordinal) token matching, never whitespace splitting.
- Unknown tokens are a hard error (`CODEC_UNKNOWN_TOKEN`), never passed through.

## Dictionary and fingerprint

The dictionary (schemaVersion 1) is an array of exactly 256 unique strings; the array index
is the byte value. The fingerprint ("dictionaryId") is computed identically in JavaScript
and PowerShell:

```
SHA-256 over:
  UTF-8 bytes of "ChannelChat.Dictionary.v1", then one 0x00 byte,
  then for each entry in index order:
    its UTF-8 byte length as a uint32 big-endian, then its exact UTF-8 bytes.
id = "sha256:" + lowercase-hex
```

The default dictionary's id is
`sha256:c086524028b0dd375fb50622076755b293a478009a3c99cc44003b79f1781425`.

A fingerprint identifies dictionary CONTENTS. It is not proof of authenticity.

## Errors

Errors return a bounded JSON object with a stable machine-readable code:

```json
{ "error": { "code": "PROTO_DICTIONARY_MISMATCH", "message": "short, bounded text" } }
```

Stack traces are never returned, and untrusted payloads are never reflected in full.

| HTTP status | Meaning | Example codes |
|-------------|---------|---------------|
| 400 | malformed / unsupported request | `PROTO_BODY_INVALID_JSON`, `PROTO_VERSION_UNSUPPORTED`, `PROTO_KIND_UNSUPPORTED`, `PROTO_MESSAGEID_INVALID`, `PAYLOAD_GZIP_INVALID`, `CODEC_UNKNOWN_TOKEN` |
| 405 | wrong method on a known path | `SERVER_METHOD_NOT_ALLOWED` |
| 404 | unknown path | `SERVER_NOT_FOUND` |
| 409 | dictionary mismatch | `PROTO_DICTIONARY_MISMATCH` |
| 413 | too large | `PROTO_BODY_TOO_LARGE`, `PAYLOAD_DECOMPRESSED_TOO_LARGE`, `CODEC_TOO_MANY_TOKENS` |
| 415 | unsupported payload encoding | `PROTO_ENCODING_UNSUPPORTED` |
| 503 | busy / timed out | `SERVER_BUSY`, `SERVER_TIMEOUT` |
| 500 | internal error | `SERVER_INTERNAL` |

Client-side-only codes: `CLIENT_REDIRECT_REJECTED`, `CLIENT_CORRELATION_MISMATCH`,
`CLIENT_TIMEOUT`, `CLIENT_TRANSPORT`, `CLIENT_RESPONSE_TOO_LARGE`.

// Exactly-reversible dictionary codec + payload packing (JavaScript side).
//
// Byte <-> token:        entries[byte]  (encode)    byteOf.get(token)  (decode)
// Text mode:             strict UTF-8, well-formed Unicode only (no lone surrogates).
// Binary mode:           arbitrary bytes, all 256 values.
// Payload packing:       tokens -> UTF-8 JSON -> GZip -> Base64   (and the exact reverse).
//
// Reverse token lookup uses a Map with exact, case-sensitive (ordinal) keys, so entries
// like "__proto__" or "constructor" are handled as ordinary data and never hit the
// prototype chain. Unknown tokens produce an explicit error (never pass-through).

import { gzipSync, gunzipSync } from "node:zlib";
import { CODES, fail } from "./errors.js";
import { DEFAULT_LIMITS } from "./limits.js";
import { hasLoneSurrogate } from "./unicode.js";

const BASE64_RE = /^[A-Za-z0-9+/]*={0,2}$/;

// --- text <-> bytes -------------------------------------------------------

export function textToBytes(text) {
  if (typeof text !== "string") fail(CODES.PROTO_FIELD_TYPE, "text must be a string");
  if (hasLoneSurrogate(text)) {
    fail(CODES.CODEC_LONE_SURROGATE, "text contains an unpaired UTF-16 surrogate");
  }
  return Buffer.from(text, "utf8");
}

export function bytesToTextStrict(bytes) {
  // fatal:true throws on malformed UTF-8; ignoreBOM:true preserves a leading BOM exactly.
  const dec = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true });
  try {
    return dec.decode(bytes);
  } catch {
    fail(CODES.CODEC_INVALID_UTF8, "bytes are not valid UTF-8");
  }
}

// --- bytes <-> tokens -----------------------------------------------------

// bytes: Buffer/Uint8Array. entries: validated string[256]. Returns string[].
export function encodeBytesToTokens(bytes, entries, limits = DEFAULT_LIMITS) {
  if (!(bytes instanceof Uint8Array)) fail(CODES.PROTO_FIELD_TYPE, "bytes must be a Uint8Array");
  if (bytes.length > limits.maxReconstructedBytes) {
    fail(CODES.CODEC_RECONSTRUCTED_TOO_LARGE, `input exceeds ${limits.maxReconstructedBytes} bytes`);
  }
  if (bytes.length > limits.maxTokenCount) {
    fail(CODES.CODEC_TOO_MANY_TOKENS, `input exceeds ${limits.maxTokenCount} tokens`);
  }
  const tokens = new Array(bytes.length); // preallocate; no quadratic concat
  for (let i = 0; i < bytes.length; i++) {
    tokens[i] = entries[bytes[i]];
  }
  return tokens;
}

// tokens: string[]. byteOf: Map<string,number>. Returns Buffer.
export function decodeTokensToBytes(tokens, byteOf, limits = DEFAULT_LIMITS) {
  if (!Array.isArray(tokens)) fail(CODES.CODEC_TOKENS_NOT_ARRAY, "tokens must be an array");
  if (tokens.length > limits.maxTokenCount) {
    fail(CODES.CODEC_TOO_MANY_TOKENS, `token count exceeds ${limits.maxTokenCount}`);
  }
  if (tokens.length > limits.maxReconstructedBytes) {
    fail(CODES.CODEC_RECONSTRUCTED_TOO_LARGE, `reconstructed size exceeds ${limits.maxReconstructedBytes} bytes`);
  }
  const out = Buffer.allocUnsafe(tokens.length);
  for (let i = 0; i < tokens.length; i++) {
    const t = tokens[i];
    if (typeof t !== "string") fail(CODES.CODEC_TOKEN_NOT_STRING, `token at index ${i} is not a string`);
    const b = byteOf.get(t);
    if (b === undefined) {
      fail(CODES.CODEC_UNKNOWN_TOKEN, `unknown token at index ${i}`);
    }
    out[i] = b;
  }
  return out;
}

// --- payload packing: tokens <-> base64(gzip(json)) -----------------------

export function packTokensToPayload(tokens, limits = DEFAULT_LIMITS) {
  const json = Buffer.from(JSON.stringify(tokens), "utf8");
  if (json.length > limits.maxDecompressedBytes) {
    fail(CODES.PAYLOAD_DECOMPRESSED_TOO_LARGE, `token JSON exceeds ${limits.maxDecompressedBytes} bytes`);
  }
  const gz = gzipSync(json);
  if (gz.length > limits.maxCompressedBytes) {
    fail(CODES.PAYLOAD_COMPRESSED_TOO_LARGE, `compressed payload exceeds ${limits.maxCompressedBytes} bytes`);
  }
  const b64 = gz.toString("base64");
  if (b64.length > limits.maxBase64Chars) {
    fail(CODES.PAYLOAD_BASE64_TOO_LONG, `base64 payload exceeds ${limits.maxBase64Chars} chars`);
  }
  return b64;
}

export function unpackPayloadToTokens(b64, limits = DEFAULT_LIMITS) {
  if (typeof b64 !== "string") fail(CODES.PROTO_FIELD_TYPE, "payload must be a string");
  if (b64.length > limits.maxBase64Chars) {
    fail(CODES.PAYLOAD_BASE64_TOO_LONG, `base64 payload exceeds ${limits.maxBase64Chars} chars`);
  }
  const compressed = decodeBase64Strict(b64);
  if (compressed.length > limits.maxCompressedBytes) {
    fail(CODES.PAYLOAD_COMPRESSED_TOO_LARGE, `compressed payload exceeds ${limits.maxCompressedBytes} bytes`);
  }
  let json;
  try {
    // maxOutputLength bounds decompression as it runs (throws before full allocation).
    json = gunzipSync(compressed, { maxOutputLength: limits.maxDecompressedBytes });
  } catch (e) {
    if (e && e.code === "ERR_BUFFER_TOO_LARGE") {
      fail(CODES.PAYLOAD_DECOMPRESSED_TOO_LARGE, `decompressed payload exceeds ${limits.maxDecompressedBytes} bytes`);
    }
    fail(CODES.PAYLOAD_GZIP_INVALID, "payload is not valid gzip");
  }
  let tokens;
  try {
    tokens = JSON.parse(bytesToTextStrict(json));
  } catch {
    fail(CODES.PAYLOAD_JSON_INVALID, "token JSON is invalid");
  }
  if (!Array.isArray(tokens)) fail(CODES.CODEC_TOKENS_NOT_ARRAY, "token JSON is not an array");
  return tokens;
}

// Strict base64: canonical standard alphabet, correct padding, no whitespace.
// Rejects anything a permissive decoder would silently accept.
export function decodeBase64Strict(b64) {
  if (b64.length % 4 !== 0 || !BASE64_RE.test(b64)) {
    fail(CODES.PAYLOAD_BASE64_INVALID, "payload is not valid canonical base64");
  }
  const buf = Buffer.from(b64, "base64");
  // Canonical round-trip check: catch non-canonical trailing bits/padding.
  if (buf.toString("base64") !== b64) {
    fail(CODES.PAYLOAD_BASE64_INVALID, "payload base64 is not canonical");
  }
  return buf;
}

// --- message-level helpers (kind-aware) -----------------------------------

// Encode a message to a payload string, given a validated dictionary { entries }.
//   kind "text":  input.text (string) -> strict UTF-8 bytes
//   kind "bytes": input.bytes (Uint8Array)
export function encodeMessagePayload(kind, input, dict, limits = DEFAULT_LIMITS) {
  const bytes = toBytesForKind(kind, input);
  const tokens = encodeBytesToTokens(bytes, dict.entries, limits);
  return packTokensToPayload(tokens, limits);
}

// Decode a payload string to { bytes, text? } given a validated dictionary { byteOf }.
export function decodeMessagePayload(kind, b64, dict, limits = DEFAULT_LIMITS) {
  const tokens = unpackPayloadToTokens(b64, limits);
  const bytes = decodeTokensToBytes(tokens, dict.byteOf, limits);
  if (kind === "text") {
    return { bytes, text: bytesToTextStrict(bytes) };
  }
  return { bytes };
}

function toBytesForKind(kind, input) {
  if (kind === "text") return textToBytes(input.text);
  if (kind === "bytes") {
    if (!(input.bytes instanceof Uint8Array)) fail(CODES.PROTO_FIELD_TYPE, "bytes must be a Uint8Array");
    return input.bytes;
  }
  fail(CODES.PROTO_KIND_UNSUPPORTED, `unsupported kind "${kind}"`);
}

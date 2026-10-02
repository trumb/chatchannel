// Wire protocol: envelope validation, the echo application behavior, and error->status mapping.
//
// Request envelope (UTF-8 JSON):
//   {
//     "protocolVersion": 1,
//     "dictionaryId": "sha256:<hex>",
//     "messageId": "<UUID>",
//     "kind": "text" | "bytes",
//     "payloadEncoding": "dictionary-json+gzip+base64",
//     "payload": "<base64>"
//   }
//
// Response envelope adds "inReplyTo" (the request messageId) and a fresh "messageId".
// The echo DECODES the request and RE-ENCODES the same data, exercising both codecs.

import { randomUUID } from "node:crypto";
import { CODES, ChannelError, fail } from "./errors.js";
import { DEFAULT_LIMITS } from "./limits.js";
import { decodeMessagePayload, encodeMessagePayload } from "./codec.js";

export const PROTOCOL_VERSION = 1;
export const PAYLOAD_ENCODING = "dictionary-json+gzip+base64";
export const SUPPORTED_KINDS = Object.freeze(["text", "bytes"]);
const UUID_RE = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;
const MAX_MESSAGE_ID_LEN = 64;

// Reject envelopes nested deeper than the limit (defense against deeply nested JSON).
export function assertJsonDepth(value, maxDepth, depth = 1) {
  if (depth > maxDepth) fail(CODES.PROTO_JSON_TOO_DEEP, `JSON nested deeper than ${maxDepth}`);
  if (value === null || typeof value !== "object") return;
  for (const v of Array.isArray(value) ? value : Object.values(value)) {
    assertJsonDepth(v, maxDepth, depth + 1);
  }
}

// Parse + structurally validate the request body (a Buffer of raw bytes). Returns the
// validated envelope object. Throws ChannelError with a stable code on any problem.
export function parseRequestEnvelope(bodyBuf, limits = DEFAULT_LIMITS) {
  let text;
  try {
    text = new TextDecoder("utf-8", { fatal: true }).decode(bodyBuf);
  } catch {
    fail(CODES.PROTO_BODY_INVALID_JSON, "request body is not valid UTF-8");
  }
  let env;
  try {
    env = JSON.parse(text);
  } catch {
    fail(CODES.PROTO_BODY_INVALID_JSON, "request body is not valid JSON");
  }
  assertJsonDepth(env, limits.maxJsonDepth);

  if (env === null || typeof env !== "object" || Array.isArray(env)) {
    fail(CODES.PROTO_FIELD_TYPE, "envelope must be a JSON object");
  }
  requireType(env, "protocolVersion", "number");
  if (env.protocolVersion !== PROTOCOL_VERSION) {
    fail(CODES.PROTO_VERSION_UNSUPPORTED, `unsupported protocolVersion ${env.protocolVersion}`);
  }
  requireType(env, "dictionaryId", "string");
  requireType(env, "messageId", "string");
  if (env.messageId.length > MAX_MESSAGE_ID_LEN || !UUID_RE.test(env.messageId)) {
    fail(CODES.PROTO_MESSAGEID_INVALID, "messageId must be a UUID");
  }
  requireType(env, "kind", "string");
  if (!SUPPORTED_KINDS.includes(env.kind)) {
    fail(CODES.PROTO_KIND_UNSUPPORTED, `unsupported kind "${env.kind}"`);
  }
  requireType(env, "payloadEncoding", "string");
  if (env.payloadEncoding !== PAYLOAD_ENCODING) {
    fail(CODES.PROTO_ENCODING_UNSUPPORTED, `unsupported payloadEncoding "${env.payloadEncoding}"`);
  }
  requireType(env, "payload", "string");
  return env;
}

// The MVP application behavior: exact echo.
// `dict` is a validated dictionary ({ id, entries, byteOf }). Returns the response envelope.
export function handleExchange(env, dict, limits = DEFAULT_LIMITS) {
  if (env.dictionaryId !== dict.id) {
    fail(CODES.PROTO_DICTIONARY_MISMATCH, "request dictionaryId does not match server dictionary");
  }
  // Decode incoming data...
  const decoded = decodeMessagePayload(env.kind, env.payload, dict, limits);
  // ...then RE-ENCODE the same data (do not reflect the original payload bytes).
  const payload =
    env.kind === "text"
      ? encodeMessagePayload("text", { text: decoded.text }, dict, limits)
      : encodeMessagePayload("bytes", { bytes: decoded.bytes }, dict, limits);

  return {
    protocolVersion: PROTOCOL_VERSION,
    dictionaryId: dict.id,
    messageId: randomUUID(),
    inReplyTo: env.messageId,
    kind: env.kind,
    payloadEncoding: PAYLOAD_ENCODING,
    payload,
  };
}

export function statusForCode(code) {
  switch (code) {
    case CODES.PROTO_BODY_TOO_LARGE:
    case CODES.PAYLOAD_BASE64_TOO_LONG:
    case CODES.PAYLOAD_COMPRESSED_TOO_LARGE:
    case CODES.PAYLOAD_DECOMPRESSED_TOO_LARGE:
    case CODES.CODEC_TOO_MANY_TOKENS:
    case CODES.CODEC_RECONSTRUCTED_TOO_LARGE:
      return 413;
    case CODES.PROTO_ENCODING_UNSUPPORTED:
      return 415;
    case CODES.PROTO_DICTIONARY_MISMATCH:
      return 409;
    case CODES.SERVER_METHOD_NOT_ALLOWED:
      return 405;
    case CODES.SERVER_NOT_FOUND:
      return 404;
    case CODES.SERVER_BUSY:
    case CODES.SERVER_TIMEOUT:
      return 503;
    case CODES.SERVER_INTERNAL:
      return 500;
    default:
      return 400; // malformed / unsupported / dictionary/codec validation failures
  }
}

// Bounded, safe error body: stable code + short message, never a stack trace or the payload.
export function errorBody(code, message) {
  const safe = typeof message === "string" ? message.slice(0, 200) : "";
  return { error: { code, message: safe } };
}

function requireType(obj, field, type) {
  if (!(field in obj)) fail(CODES.PROTO_FIELD_MISSING, `missing field "${field}"`);
  const v = obj[field];
  const ok = type === "number" ? typeof v === "number" && Number.isFinite(v) : typeof v === type;
  if (!ok) fail(CODES.PROTO_FIELD_TYPE, `field "${field}" must be ${type}`);
}

export { ChannelError };

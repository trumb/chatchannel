import { test } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { gzipSync } from "node:zlib";
import { loadDictionaryFile } from "../src/dictionary.js";
import { createLimits } from "../src/limits.js";
import { encodeMessagePayload, encodeBytesToTokens } from "../src/codec.js";
import {
  PAYLOAD_ENCODING,
  handleExchange,
  parseRequestEnvelope,
  assertJsonDepth,
  statusForCode,
} from "../src/protocol.js";

const dict = loadDictionaryFile(new URL("../data/dictionary.v1.json", import.meta.url).pathname);

function envelope(overrides = {}) {
  return {
    protocolVersion: 1,
    dictionaryId: dict.id,
    messageId: randomUUID(),
    kind: "text",
    payloadEncoding: PAYLOAD_ENCODING,
    payload: encodeMessagePayload("text", { text: "hi" }, dict),
    ...overrides,
  };
}

function parse(env) {
  return parseRequestEnvelope(Buffer.from(JSON.stringify(env), "utf8"));
}

test("valid envelope parses", () => {
  const env = parse(envelope());
  assert.equal(env.kind, "text");
});

test("non-UTF-8 and non-JSON bodies rejected", () => {
  assert.throws(() => parseRequestEnvelope(Buffer.from([0xff, 0xff])), /PROTO_BODY_INVALID_JSON/);
  assert.throws(() => parseRequestEnvelope(Buffer.from("not json", "utf8")), /PROTO_BODY_INVALID_JSON/);
});

test("missing and mistyped fields rejected", () => {
  const e = envelope();
  delete e.payload;
  assert.throws(() => parse(e), /PROTO_FIELD_MISSING/);
  assert.throws(() => parse(envelope({ protocolVersion: "1" })), /PROTO_FIELD_TYPE/);
});

test("unsupported version, kind, encoding, and bad messageId rejected", () => {
  assert.throws(() => parse(envelope({ protocolVersion: 2 })), /PROTO_VERSION_UNSUPPORTED/);
  assert.throws(() => parse(envelope({ kind: "video" })), /PROTO_KIND_UNSUPPORTED/);
  assert.throws(() => parse(envelope({ payloadEncoding: "rot13" })), /PROTO_ENCODING_UNSUPPORTED/);
  assert.throws(() => parse(envelope({ messageId: "not-a-uuid" })), /PROTO_MESSAGEID_INVALID/);
});

test("deeply nested JSON rejected", () => {
  assert.throws(() => assertJsonDepth({ a: { b: { c: { d: {} } } } }, 2), /PROTO_JSON_TOO_DEEP/);
});

test("handleExchange echoes with correlation and fresh messageId", () => {
  const req = parse(envelope({ messageId: "11111111-2222-3333-4444-555555555555" }));
  const res = handleExchange(req, dict);
  assert.equal(res.inReplyTo, "11111111-2222-3333-4444-555555555555");
  assert.notEqual(res.messageId, res.inReplyTo);
  assert.equal(res.kind, "text");
  assert.equal(res.dictionaryId, dict.id);
});

test("handleExchange rejects dictionary mismatch", () => {
  const req = parse(envelope({ dictionaryId: "sha256:deadbeef" }));
  assert.throws(() => handleExchange(req, dict), /PROTO_DICTIONARY_MISMATCH/);
});

test("echo truly decodes + re-encodes (not a byte passthrough of the request payload)", () => {
  // Build a payload with a DIFFERENT gzip level so the server's canonical re-encode differs.
  const tokens = encodeBytesToTokens(Buffer.from("decode me please", "utf8"), dict.entries);
  const json = Buffer.from(JSON.stringify(tokens), "utf8");
  const oddlyCompressed = gzipSync(json, { level: 1 }).toString("base64");
  const env = parse(envelope({ kind: "text", payload: oddlyCompressed }));
  const res = handleExchange(env, dict);
  // Response payload is the server's re-encode; with default gzip level it differs from
  // the level-1 request payload, proving the server decoded and re-encoded.
  assert.notEqual(res.payload, oddlyCompressed);
});

test("statusForCode maps categories correctly", () => {
  assert.equal(statusForCode("PROTO_DICTIONARY_MISMATCH"), 409);
  assert.equal(statusForCode("PROTO_ENCODING_UNSUPPORTED"), 415);
  assert.equal(statusForCode("PROTO_BODY_TOO_LARGE"), 413);
  assert.equal(statusForCode("PAYLOAD_DECOMPRESSED_TOO_LARGE"), 413);
  assert.equal(statusForCode("SERVER_NOT_FOUND"), 404);
  assert.equal(statusForCode("PROTO_VERSION_UNSUPPORTED"), 400);
});

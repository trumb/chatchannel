import { test } from "node:test";
import assert from "node:assert/strict";
import { gzipSync } from "node:zlib";
import { loadDictionaryFile, validateDictionary } from "../src/dictionary.js";
import { createLimits } from "../src/limits.js";
import {
  encodeBytesToTokens,
  decodeTokensToBytes,
  textToBytes,
  bytesToTextStrict,
  packTokensToPayload,
  unpackPayloadToTokens,
  decodeBase64Strict,
  encodeMessagePayload,
  decodeMessagePayload,
} from "../src/codec.js";

const dict = loadDictionaryFile(new URL("../data/dictionary.v1.json", import.meta.url).pathname);

function roundtripBytes(bytes) {
  const tokens = encodeBytesToTokens(Buffer.from(bytes), dict.entries);
  const back = decodeTokensToBytes(tokens, dict.byteOf);
  assert.deepEqual([...back], [...bytes]);
}

test("empty, single, and all-256 byte round trips", () => {
  roundtripBytes([]);
  roundtripBytes([0]);
  roundtripBytes([255]);
  roundtripBytes(Array.from({ length: 256 }, (_, i) => i));
});

test("whitespace, CRLF, LF, tabs, nulls preserved", () => {
  roundtripBytes([0, 13, 10, 9, 32, 32, 0, 65, 10]);
});

test("text mode: unicode, supplementary, combining preserved without normalization", () => {
  for (const s of ["café", "😀🕷𝐀", "é ñ", "Ωμέγα", ""]) {
    const p = encodeMessagePayload("text", { text: s }, dict);
    assert.equal(decodeMessagePayload("text", p, dict).text, s);
  }
});

test("input equal to a token is treated as bytes, not matched as a word", () => {
  const s = "alfa";
  const p = encodeMessagePayload("text", { text: s }, dict);
  assert.equal(decodeMessagePayload("text", p, dict).text, s);
});

test("text mode rejects lone surrogates", () => {
  assert.throws(() => textToBytes("\ud800"), /CODEC_LONE_SURROGATE/);
  assert.throws(() => textToBytes("a\udc00b"), /CODEC_LONE_SURROGATE/);
});

test("strict UTF-8 decode rejects malformed bytes", () => {
  assert.throws(() => bytesToTextStrict(Buffer.from([0xff, 0xfe, 0xfd])), /CODEC_INVALID_UTF8/);
  assert.throws(() => bytesToTextStrict(Buffer.from([0xc0])), /CODEC_INVALID_UTF8/);
});

test("unknown token and non-string token rejected", () => {
  assert.throws(() => decodeTokensToBytes(["nope-not-a-token"], dict.byteOf), /CODEC_UNKNOWN_TOKEN/);
  assert.throws(() => decodeTokensToBytes([123], dict.byteOf), /CODEC_TOKEN_NOT_STRING/);
  assert.throws(() => decodeTokensToBytes("notarray", dict.byteOf), /CODEC_TOKENS_NOT_ARRAY/);
});

test("__proto__/constructor and tricky tokens round-trip via Map lookup", () => {
  const e = Array.from({ length: 256 }, (_, i) => "t" + i);
  e[0] = "__proto__";
  e[1] = "constructor";
  e[2] = 'quo"te';
  e[3] = "back\\slash";
  e[4] = "ünïcödé★";
  const d = validateDictionary({ schemaVersion: 1, entries: e });
  roundtripVia(d, [0, 1, 2, 3, 4, 200]);
});

function roundtripVia(d, bytes) {
  const tokens = encodeBytesToTokens(Buffer.from(bytes), d.entries);
  const back = decodeTokensToBytes(tokens, d.byteOf);
  assert.deepEqual([...back], bytes);
}

test("strict base64 rejects non-canonical / wrong length / whitespace", () => {
  assert.throws(() => decodeBase64Strict("AAA"), /PAYLOAD_BASE64_INVALID/); // len % 4 != 0
  assert.throws(() => decodeBase64Strict("A A="), /PAYLOAD_BASE64_INVALID/); // space
  assert.throws(() => decodeBase64Strict("====") , /PAYLOAD_BASE64_INVALID/);
  // non-canonical trailing bits: "QUJD" is canonical "ABC"; a mangled variant must fail round-trip
  assert.throws(() => decodeBase64Strict("QUJE="), /PAYLOAD_BASE64_INVALID/);
});

test("corrupted/truncated gzip rejected", () => {
  const b64 = Buffer.from([1, 2, 3, 4, 5, 6, 7, 8]).toString("base64");
  assert.throws(() => unpackPayloadToTokens(b64), /PAYLOAD_GZIP_INVALID/);
  // valid gzip header then truncated
  const good = gzipSync(Buffer.from('["t0"]'));
  const truncated = good.subarray(0, good.length - 3).toString("base64");
  assert.throws(() => unpackPayloadToTokens(truncated), /PAYLOAD_GZIP_INVALID/);
});

test("decompression bomb rejected by maxDecompressedBytes", () => {
  const big = Buffer.alloc(1_000_000, 0x61); // compresses tiny, expands large
  const gz = gzipSync(big).toString("base64");
  const limits = createLimits({ maxDecompressedBytes: 1024, maxCompressedBytes: 1_000_000 });
  assert.throws(() => unpackPayloadToTokens(gz, limits), /PAYLOAD_DECOMPRESSED_TOO_LARGE/);
});

test("token JSON that is not an array is rejected", () => {
  const gz = gzipSync(Buffer.from('{"not":"array"}')).toString("base64");
  assert.throws(() => unpackPayloadToTokens(gz), /CODEC_TOKENS_NOT_ARRAY/);
});

test("pack then unpack returns identical tokens", () => {
  const tokens = encodeBytesToTokens(Buffer.from([1, 2, 3, 0, 255]), dict.entries);
  const b64 = packTokensToPayload(tokens);
  assert.deepEqual(unpackPayloadToTokens(b64), tokens);
});

#!/usr/bin/env node
// Generates shared cross-language test fixtures:
//   shared/dictionary-fixture.json  — expected dictionary fingerprint
//   shared/vectors.json             — golden byte<->token vectors (deterministic)
//
// Vectors assert on the TOKEN ARRAY (deterministic) and the dictionary id, NOT on gzip
// bytes (which need not be byte-identical across runtimes).
//
// Run: node tools/gen-vectors.mjs
import { writeFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { loadDictionaryFile } from "../src/dictionary.js";
import { encodeBytesToTokens } from "../src/codec.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const root = join(__dirname, "..");
const dict = loadDictionaryFile(join(root, "data", "dictionary.v1.json"));

function vecFromBytes(name, bytes, { text = null } = {}) {
  const buf = Buffer.from(bytes);
  return {
    name,
    inputBase64: buf.toString("base64"),
    text, // non-null only when the bytes are the strict UTF-8 of this text
    tokens: encodeBytesToTokens(buf, dict.entries),
  };
}

function vecFromText(name, text) {
  return vecFromBytes(name, Buffer.from(text, "utf8"), { text });
}

const all256 = Buffer.from(Array.from({ length: 256 }, (_, i) => i));

const vectors = [
  vecFromBytes("empty", []),
  vecFromBytes("single-byte-0", [0]),
  vecFromBytes("single-byte-255", [255]),
  vecFromBytes("all-256-bytes", all256),
  vecFromBytes("nulls-and-newlines", [0, 13, 10, 9, 0, 32, 32, 65]),
  vecFromText("ascii-hello", "Hello, World!"),
  vecFromText("mixed-case-punct", "AbC! x_y-z? (ok) [yes] {no}"),
  vecFromText("repeated-spaces-tabs", "a    b\t\tc\r\nd"),
  vecFromText("unicode-bmp", "café — naïve — Ωμέγα"),
  vecFromText("unicode-supplementary", "emoji 😀🕷 and 𝐀𝐁 math"),
  vecFromText("combining", "é à ñ"), // e+combining acute, etc. (no normalization)
  vecFromText("equals-a-token", "alfa"), // input text equal to dictionary token
  vecFromText("tokens-concatenated", "alfabravo"), // must NOT split on tokens
];

const dictFixture = {
  prefix: "ChannelChat.Dictionary.v1",
  dictionaryId: dict.id,
  entryCount: dict.entries.length,
};

writeFileSync(
  join(root, "shared", "dictionary-fixture.json"),
  JSON.stringify(dictFixture, null, 2) + "\n",
  "utf8",
);
writeFileSync(
  join(root, "shared", "vectors.json"),
  JSON.stringify({ dictionaryId: dict.id, vectors }, null, 2) + "\n",
  "utf8",
);
console.log(`wrote shared/dictionary-fixture.json (${dict.id})`);
console.log(`wrote shared/vectors.json (${vectors.length} vectors)`);

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { computeDictionaryId, validateDictionary, loadDictionaryFile } from "../src/dictionary.js";
import { createLimits } from "../src/limits.js";

const fixture = JSON.parse(readFileSync(new URL("../shared/dictionary-fixture.json", import.meta.url)));

function baseEntries() {
  return Array.from({ length: 256 }, (_, i) => "t" + i);
}

test("default dictionary matches the shared fingerprint fixture", () => {
  const dict = loadDictionaryFile(new URL("../data/dictionary.v1.json", import.meta.url).pathname);
  assert.equal(dict.id, fixture.dictionaryId);
  assert.equal(dict.entries.length, 256);
});

test("fingerprint is independent of JSON formatting", () => {
  const entries = baseEntries();
  const a = computeDictionaryId(entries);
  // Same entries, different array identity/formatting -> same id.
  const b = computeDictionaryId(entries.slice());
  assert.equal(a, b);
});

test("fingerprint changes when any entry changes", () => {
  const e1 = baseEntries();
  const e2 = baseEntries();
  e2[42] = "different";
  assert.notEqual(computeDictionaryId(e1), computeDictionaryId(e2));
});

test("rejects wrong entry count", () => {
  assert.throws(() => validateDictionary({ schemaVersion: 1, entries: baseEntries().slice(0, 255) }), /DICT_ENTRY_COUNT/);
});

test("rejects duplicate entries", () => {
  const e = baseEntries();
  e[5] = e[6];
  assert.throws(() => validateDictionary({ schemaVersion: 1, entries: e }), /DICT_DUPLICATE_ENTRY/);
});

test("rejects non-string entries", () => {
  const e = baseEntries();
  e[7] = 7;
  assert.throws(() => validateDictionary({ schemaVersion: 1, entries: e }), /DICT_ENTRY_TYPE/);
});

test("rejects entries with lone surrogates", () => {
  const e = baseEntries();
  e[8] = "\ud800"; // lone high surrogate
  assert.throws(() => validateDictionary({ schemaVersion: 1, entries: e }), /DICT_ENTRY_INVALID_UNICODE/);
});

test("rejects over-long entries", () => {
  const e = baseEntries();
  e[9] = "x".repeat(10);
  const limits = createLimits({ maxDictionaryEntryBytes: 4 });
  assert.throws(() => validateDictionary({ schemaVersion: 1, entries: e }, limits), /DICT_ENTRY_TOO_LONG/);
});

test("rejects wrong schemaVersion and non-object", () => {
  assert.throws(() => validateDictionary({ schemaVersion: 2, entries: baseEntries() }), /DICT_SCHEMA_INVALID/);
  assert.throws(() => validateDictionary([1, 2, 3]), /DICT_SCHEMA_INVALID/);
  assert.throws(() => validateDictionary(null), /DICT_SCHEMA_INVALID/);
});

test("accepts entries with spaces, quotes, backslashes, unicode, __proto__, constructor", () => {
  const e = baseEntries();
  e[0] = "__proto__";
  e[1] = "constructor";
  e[2] = 'a "quoted" \\ value';
  e[3] = "spa ce\twith tab";
  e[4] = "ünïcödé★";
  const dict = validateDictionary({ schemaVersion: 1, entries: e });
  assert.equal(dict.byteOf.get("__proto__"), 0);
  assert.equal(dict.byteOf.get("constructor"), 1);
  assert.equal(dict.byteOf.get("ünïcödé★"), 4);
});

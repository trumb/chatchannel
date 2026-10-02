import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { loadDictionaryFile } from "../src/dictionary.js";
import { encodeBytesToTokens, decodeTokensToBytes, bytesToTextStrict } from "../src/codec.js";

const dict = loadDictionaryFile(new URL("../data/dictionary.v1.json", import.meta.url).pathname);
const golden = JSON.parse(readFileSync(new URL("../shared/vectors.json", import.meta.url)));

test("golden vectors: dictionary id matches", () => {
  assert.equal(golden.dictionaryId, dict.id);
});

for (const v of golden.vectors) {
  test(`golden vector [${v.name}]: bytes -> tokens matches`, () => {
    const bytes = Buffer.from(v.inputBase64, "base64");
    const tokens = encodeBytesToTokens(bytes, dict.entries);
    assert.deepEqual(tokens, v.tokens);
  });

  test(`golden vector [${v.name}]: tokens -> bytes matches`, () => {
    const bytes = decodeTokensToBytes(v.tokens, dict.byteOf);
    assert.equal(bytes.toString("base64"), v.inputBase64);
    if (v.text !== null && v.text !== undefined) {
      assert.equal(bytesToTextStrict(bytes), v.text);
    }
  });
}

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { gunzipSync } from "node:zlib";
import { buildPackage } from "../tools/build-package.mjs";

const distPath = new URL("../client/dist/channelchat-client.ps1", import.meta.url).pathname;
const dictionaryPath = new URL("../data/dictionary.v1.json", import.meta.url).pathname;

// Extracts the embedded base64 package from the generated standalone client.
function extractEmbeddedBase64(text) {
  const m = text.match(/\$ChannelEmbeddedPackage\s*=\s*'([A-Za-z0-9+/]*={0,2})'/);
  if (!m) throw new Error("could not find embedded package in standalone client");
  return m[1];
}

test("standalone client's embedded dictionary is not stale", () => {
  let scriptText;
  try {
    scriptText = readFileSync(distPath, "utf8");
  } catch {
    assert.fail("client/dist/channelchat-client.ps1 is missing; run: node client/build/build-client.mjs");
  }

  const embeddedB64 = extractEmbeddedBase64(scriptText);
  const embeddedPkg = JSON.parse(gunzipSync(Buffer.from(embeddedB64, "base64")).toString("utf8"));

  // Rebuild the package from the CURRENT source dictionary (semantic comparison; gzip bytes
  // need not match across runs).
  const fresh = buildPackage({ dictionaryPath });

  assert.equal(embeddedPkg.dictionaryId, fresh.dictionaryId, "embedded dictionaryId is stale — rebuild the client");
  assert.deepEqual(embeddedPkg.dictionary.entries, fresh.entries, "embedded dictionary entries are stale — rebuild the client");
});

// The build inlines the two client source files verbatim between banner comments. If either
// source changes without a rebuild, the dist carries old code (this happened once: a stale
// CLIENT_TIMEOUT where the source said CLIENT_TRANSPORT) while the dictionary check above
// still passes.
function readDist() {
  try {
    return readFileSync(distPath, "utf8");
  } catch {
    assert.fail("client/dist/channelchat-client.ps1 is missing; run: node client/build/build-client.mjs");
  }
}

function readClientSource(name) {
  return readFileSync(new URL(`../client/${name}`, import.meta.url).pathname, "utf8");
}

test("standalone client's inlined ChannelChat.Core.ps1 is not stale", () => {
  const dist = readDist();
  const core = readClientSource("ChannelChat.Core.ps1");
  assert.ok(dist.includes(core), "inlined ChannelChat.Core.ps1 differs from client/ChannelChat.Core.ps1 — rebuild the client");
});

test("standalone client's inlined ChannelChat.Client.ps1 is not stale", () => {
  const dist = readDist();
  const client = readClientSource("ChannelChat.Client.ps1");
  assert.ok(dist.includes(client), "inlined ChannelChat.Client.ps1 differs from client/ChannelChat.Client.ps1 — rebuild the client");
});

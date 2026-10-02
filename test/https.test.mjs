import { test } from "node:test";
import assert from "node:assert/strict";
import https from "node:https";
import http from "node:http";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import { loadDictionaryFile } from "../src/dictionary.js";
import { buildServer } from "../src/server.js";
import { PAYLOAD_ENCODING } from "../src/protocol.js";
import { encodeMessagePayload, decodeMessagePayload } from "../src/codec.js";

const dict = loadDictionaryFile(new URL("../data/dictionary.v1.json", import.meta.url).pathname);

// Try to generate a self-signed cert/key with openssl. Returns null if unavailable.
function makeSelfSignedCert() {
  let dir;
  try {
    dir = mkdtempSync(join(tmpdir(), "anansi-tls-"));
    const key = join(dir, "key.pem");
    const cert = join(dir, "cert.pem");
    execFileSync(
      "openssl",
      [
        "req", "-x509", "-newkey", "rsa:2048", "-nodes",
        "-keyout", key, "-out", cert, "-days", "2",
        "-subj", "/CN=localhost",
        "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1",
      ],
      { stdio: "ignore" },
    );
    return { dir, key: readFileSync(key), cert: readFileSync(cert) };
  } catch {
    if (dir) try { rmSync(dir, { recursive: true, force: true }); } catch { /* ignore */ }
    return null;
  }
}

function makeEnvelope() {
  return JSON.stringify({
    protocolVersion: 1,
    dictionaryId: dict.id,
    messageId: randomUUID(),
    kind: "text",
    payloadEncoding: PAYLOAD_ENCODING,
    payload: encodeMessagePayload("text", { text: "secure hello" }, dict),
  });
}

test("HTTP-only startup works with NO TLS files configured", async () => {
  const app = buildServer({ dict, logger: () => {} });
  assert.equal(app.isTls, false);
  const addr = await app.listen(0, "127.0.0.1");
  try {
    const status = await new Promise((resolve, reject) => {
      http.get({ host: "127.0.0.1", port: addr.port, path: "/healthz" }, (r) => {
        r.resume();
        resolve(r.statusCode);
      }).on("error", reject);
    });
    assert.equal(status, 200);
  } finally {
    await app.close();
  }
});

const tls = makeSelfSignedCert();

test("HTTPS: certificate is REJECTED by a client that does not trust it (no bypass)", { skip: tls ? false : "NOT RUN: openssl unavailable to mint a test certificate" }, async () => {
  const app = buildServer({ dict, tls: { key: tls.key, cert: tls.cert }, logger: () => {} });
  const addr = await app.listen(0, "127.0.0.1");
  try {
    const err = await new Promise((resolve) => {
      const req = https.request(
        { host: "127.0.0.1", port: addr.port, servername: "localhost", path: "/healthz", method: "GET" },
        (r) => { r.resume(); resolve(null); },
      );
      req.on("error", (e) => resolve(e));
      req.end();
    });
    assert.ok(err, "expected a TLS validation error for the untrusted self-signed cert");
    assert.match(String(err.code || err.message), /SELF_SIGNED|UNABLE_TO_VERIFY|DEPTH_ZERO|self-signed/i);
  } finally {
    await app.close();
  }
});

test("HTTPS: same protocol + codec works when the cert is trusted", { skip: tls ? false : "NOT RUN: openssl unavailable to mint a test certificate" }, async () => {
  const app = buildServer({ dict, tls: { key: tls.key, cert: tls.cert }, logger: () => {} });
  const addr = await app.listen(0, "127.0.0.1");
  try {
    const body = makeEnvelope();
    const res = await new Promise((resolve, reject) => {
      const req = https.request(
        {
          host: "127.0.0.1", port: addr.port, servername: "localhost",
          path: "/api/v1/exchange", method: "POST",
          headers: { "content-type": "application/json", "content-length": Buffer.byteLength(body) },
          ca: tls.cert, // trust our self-signed CA for THIS request only (no global trust change)
        },
        (r) => {
          const chunks = [];
          r.on("data", (c) => chunks.push(c));
          r.on("end", () => resolve({ status: r.statusCode, body: Buffer.concat(chunks).toString("utf8") }));
        },
      );
      req.on("error", reject);
      req.end(body);
    });
    assert.equal(res.status, 200);
    const env = JSON.parse(res.body);
    assert.equal(decodeMessagePayload("text", env.payload, dict).text, "secure hello");
  } finally {
    await app.close();
  }
});

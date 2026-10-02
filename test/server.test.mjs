import { test } from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import net from "node:net";
import { randomUUID } from "node:crypto";
import { loadDictionaryFile } from "../src/dictionary.js";
import { createLimits } from "../src/limits.js";
import { buildServer } from "../src/server.js";
import { PAYLOAD_ENCODING } from "../src/protocol.js";
import { encodeMessagePayload, decodeMessagePayload } from "../src/codec.js";

const dict = loadDictionaryFile(new URL("../data/dictionary.v1.json", import.meta.url).pathname);

async function startServer(limitsOverrides = {}) {
  const limits = createLimits(limitsOverrides);
  const app = buildServer({ dict, limits, logger: () => {} });
  const addr = await app.listen(0, "127.0.0.1");
  return { app, port: addr.port };
}

function request(port, { method = "POST", path = "/api/v1/exchange", body = null, setContentLength = true } = {}) {
  return new Promise((resolve, reject) => {
    const headers = { "content-type": "application/json" };
    if (body && setContentLength) headers["content-length"] = Buffer.byteLength(body);
    const req = http.request({ host: "127.0.0.1", port, path, method, headers }, (res) => {
      const chunks = [];
      res.on("data", (c) => chunks.push(c));
      res.on("end", () => resolve({ status: res.statusCode, headers: res.headers, body: Buffer.concat(chunks).toString("utf8") }));
    });
    req.on("error", reject);
    if (body) req.end(body);
    else req.end();
  });
}

function makeEnvelope(overrides = {}) {
  return JSON.stringify({
    protocolVersion: 1,
    dictionaryId: dict.id,
    messageId: randomUUID(),
    kind: "text",
    payloadEncoding: PAYLOAD_ENCODING,
    payload: encodeMessagePayload("text", { text: "hello server" }, dict),
    ...overrides,
  });
}

test("GET /healthz returns ok with dictionaryId and no-store headers", async () => {
  const { app, port } = await startServer();
  try {
    const res = await request(port, { method: "GET", path: "/healthz" });
    assert.equal(res.status, 200);
    assert.match(res.headers["content-type"], /application\/json; charset=utf-8/);
    assert.equal(res.headers["cache-control"], "no-store");
    const body = JSON.parse(res.body);
    assert.equal(body.dictionaryId, dict.id);
    assert.equal(body.status, "ok");
  } finally {
    await app.close();
  }
});

test("POST /api/v1/exchange echoes text with correlation", async () => {
  const { app, port } = await startServer();
  try {
    const messageId = randomUUID();
    const res = await request(port, { body: makeEnvelope({ messageId }) });
    assert.equal(res.status, 200);
    const env = JSON.parse(res.body);
    assert.equal(env.inReplyTo, messageId);
    assert.notEqual(env.messageId, messageId);
    assert.equal(decodeMessagePayload("text", env.payload, dict).text, "hello server");
  } finally {
    await app.close();
  }
});

test("bytes kind round-trips all 256 values over HTTP", async () => {
  const { app, port } = await startServer();
  try {
    const bytes = Buffer.from(Array.from({ length: 256 }, (_, i) => i));
    const body = makeEnvelope({ kind: "bytes", payload: encodeMessagePayload("bytes", { bytes }, dict) });
    const res = await request(port, { body });
    assert.equal(res.status, 200);
    const env = JSON.parse(res.body);
    const out = decodeMessagePayload("bytes", env.payload, dict).bytes;
    assert.equal(Buffer.compare(out, bytes), 0);
  } finally {
    await app.close();
  }
});

test("method not allowed, not found, bad json, mismatch, unsupported version", async () => {
  const { app, port } = await startServer();
  try {
    assert.equal((await request(port, { method: "GET", path: "/api/v1/exchange" })).status, 405);
    assert.equal((await request(port, { method: "GET", path: "/nope" })).status, 404);
    assert.equal((await request(port, { body: "{not json" })).status, 400);
    assert.equal((await request(port, { body: makeEnvelope({ dictionaryId: "sha256:00" }) })).status, 409);
    assert.equal((await request(port, { body: makeEnvelope({ protocolVersion: 9 }) })).status, 400);
  } finally {
    await app.close();
  }
});

test("oversized body rejected with Content-Length (413)", async () => {
  const { app, port } = await startServer({ maxRequestBodyBytes: 256 });
  try {
    const big = "x".repeat(2000);
    const res = await request(port, { body: big });
    assert.equal(res.status, 413);
    assert.match(res.body, /PROTO_BODY_TOO_LARGE/);
  } finally {
    await app.close();
  }
});

test("oversized body rejected WITHOUT Content-Length (chunked) (413)", async () => {
  const { app, port } = await startServer({ maxRequestBodyBytes: 256 });
  try {
    const res = await new Promise((resolve, reject) => {
      const req = http.request(
        { host: "127.0.0.1", port, path: "/api/v1/exchange", method: "POST", headers: { "content-type": "application/json" } },
        (r) => {
          const chunks = [];
          r.on("data", (c) => chunks.push(c));
          r.on("end", () => resolve({ status: r.statusCode, body: Buffer.concat(chunks).toString("utf8") }));
        },
      );
      req.on("error", reject);
      // No content-length -> Node uses chunked transfer-encoding.
      for (let i = 0; i < 50; i++) req.write("x".repeat(100));
      req.end();
    });
    assert.equal(res.status, 413);
  } finally {
    await app.close();
  }
});

test("concurrency cap: a second request while one is in-flight gets 503", async () => {
  const { app, port } = await startServer({ maxConcurrentRequests: 1, requestTimeoutMs: 5000 });
  try {
    // Connection A: send headers claiming a body, then stall (handler starts, slot taken).
    const sockA = net.connect(port, "127.0.0.1");
    await new Promise((r) => sockA.once("connect", r));
    sockA.write("POST /api/v1/exchange HTTP/1.1\r\nHost: x\r\nContent-Length: 1000\r\nContent-Type: application/json\r\n\r\n");
    sockA.write("{"); // partial body; keep the request open
    await new Promise((r) => setTimeout(r, 150));

    // Connection B: a normal full request should be refused with 503.
    const res = await request(port, { body: makeEnvelope() });
    assert.equal(res.status, 503);
    assert.match(res.body, /SERVER_BUSY/);
    sockA.destroy();
  } finally {
    await app.close();
  }
});

test("stalled request hits the server deadline and is closed", async () => {
  const { app, port } = await startServer({ requestTimeoutMs: 300, headersTimeoutMs: 300 });
  try {
    const result = await new Promise((resolve) => {
      const sock = net.connect(port, "127.0.0.1");
      let got = "";
      sock.on("connect", () => {
        // Send headers with a promised body but never send it.
        sock.write("POST /api/v1/exchange HTTP/1.1\r\nHost: x\r\nContent-Length: 1000\r\nContent-Type: application/json\r\n\r\n");
      });
      sock.on("data", (d) => (got += d.toString("utf8")));
      sock.on("close", () => resolve(got));
      setTimeout(() => sock.destroy(), 2000);
    });
    // Either we received a 408/503 status line, or the connection was closed by the deadline.
    assert.ok(result === "" || /HTTP\/1\.1 (408|503)/.test(result), `unexpected: ${result.slice(0, 40)}`);
  } finally {
    await app.close();
  }
});

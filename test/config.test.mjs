import { test } from "node:test";
import assert from "node:assert/strict";
import { loadConfig } from "../src/config.js";

const dir = new URL("../config/", import.meta.url).pathname;

test("Azure config targets HTTP on port 80 with no TLS", () => {
  const cfg = loadConfig({ configPath: dir + "server.azure.json", env: {} });
  assert.equal(cfg.port, 80);
  assert.equal(cfg.host, "0.0.0.0");
  assert.equal(cfg.tls, null);
});

test("local config targets the high development port 8080", () => {
  const cfg = loadConfig({ configPath: dir + "server.local.json", env: {} });
  assert.equal(cfg.port, 8080);
  assert.equal(cfg.tls, null);
});

test("https example config carries tls cert/key paths", () => {
  const cfg = loadConfig({ configPath: dir + "https.example.json", env: {} });
  assert.ok(cfg.tls && cfg.tls.certFile && cfg.tls.keyFile);
});

test("environment overrides apply and port is range-checked", () => {
  const cfg = loadConfig({ configPath: dir + "server.local.json", env: { ANANSI_PORT: "80", ANANSI_HOST: "0.0.0.0" } });
  assert.equal(cfg.port, 80);
  assert.equal(cfg.host, "0.0.0.0");
  assert.throws(() => loadConfig({ configPath: dir + "server.local.json", env: { ANANSI_PORT: "70000" } }), /invalid port/);
});

test("both TLS env vars together enable HTTPS", () => {
  const cfg = loadConfig({ configPath: dir + "server.local.json", env: { ANANSI_TLS_CERT: "/c.pem", ANANSI_TLS_KEY: "/k.pem" } });
  assert.deepEqual(cfg.tls, { certFile: "/c.pem", keyFile: "/k.pem" });
});

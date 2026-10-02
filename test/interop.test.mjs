// Cross-language interop + end-to-end tests. These spawn PowerShell (pwsh).
//
// IMPORTANT: this harness runs on whatever PowerShell `pwsh` resolves to (PowerShell 7 in
// CI/dev here). Windows PowerShell 5.1 and standard-user-on-Windows execution are NOT
// exercised here and are reported NOT RUN (see README "Windows verification").
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync, execFile } from "node:child_process";
import { promisify } from "node:util";
import { readFileSync, mkdtempSync, copyFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { dirname } from "node:path";
import http from "node:http";
import { execSync } from "node:child_process";
import { loadDictionaryFile } from "../src/dictionary.js";
import { buildServer } from "../src/server.js";
import { encodeMessagePayload, decodeMessagePayload, unpackPayloadToTokens, decodeTokensToBytes } from "../src/codec.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const root = join(__dirname, "..");
const helper = join(__dirname, "pwsh", "interop-helper.ps1");
const dictPath = join(root, "data", "dictionary.v1.json");
const standalone = join(root, "client", "dist", "channelchat-client.ps1");
const dict = loadDictionaryFile(dictPath);
const golden = JSON.parse(readFileSync(join(root, "shared", "vectors.json")));

function pwshInfo() {
  try {
    const v = execFileSync("pwsh", ["-NoProfile", "-Command", "$PSVersionTable.PSVersion.ToString()"], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    });
    return v.trim();
  } catch {
    return null;
  }
}

const PWSH = pwshInfo();
const skip = PWSH ? false : "NOT RUN: pwsh not found on PATH";

const execFileAsync = promisify(execFile);

// Async so the in-process HTTP server's event loop keeps running while pwsh executes
// (a synchronous spawn would block the loop and deadlock the e2e round trip).
async function runHelper(args) {
  const { stdout } = await execFileAsync("pwsh", ["-NoProfile", "-File", helper, ...args], { encoding: "utf8" });
  const line = stdout.trim().split(/\r?\n/).filter(Boolean).pop();
  return JSON.parse(line);
}

test(`interop: PowerShell (${PWSH || "n/a"}) fingerprint equals JavaScript`, { skip }, async () => {
  const res = await runHelper(["-Command", "fingerprint", "-Root", root, "-DictPath", dictPath]);
  assert.equal(res.dictionaryId, dict.id);
});

test("interop: PowerShell encode -> JavaScript decode (all golden vectors)", { skip }, async () => {
  for (const v of golden.vectors) {
    const res = await runHelper(["-Command", "encode", "-Root", root, "-DictPath", dictPath, "-Kind", "bytes", "-InputBase64", v.inputBase64]);
    const tokens = unpackPayloadToTokens(res.payload);
    const bytes = decodeTokensToBytes(tokens, dict.byteOf);
    assert.equal(bytes.toString("base64"), v.inputBase64, `vector ${v.name}`);
  }
});

test("interop: JavaScript encode -> PowerShell decode (all golden vectors)", { skip }, async () => {
  for (const v of golden.vectors) {
    const bytes = Buffer.from(v.inputBase64, "base64");
    const payload = encodeMessagePayload("bytes", { bytes }, dict);
    const res = await runHelper(["-Command", "decode", "-Root", root, "-DictPath", dictPath, "-InputBase64", payload]);
    assert.equal(res.outBase64, v.inputBase64, `vector ${v.name}`);
  }
});

test("interop e2e: standalone client -> HTTP server -> standalone client round-trips", { skip }, async () => {
  const app = buildServer({ dict, logger: () => {} });
  const addr = await app.listen(0, "127.0.0.1");
  const endpoint = `http://127.0.0.1:${addr.port}/api/v1/exchange`;
  try {
    // text (unicode + multiline)
    const text = "Anansi 🕷\nsecond\tline";
    const tb64 = Buffer.from(text, "utf8").toString("base64");
    const r1 = await runHelper(["-Command", "e2e", "-Standalone", standalone, "-Endpoint", endpoint, "-Kind", "text", "-InputBase64", tb64]);
    assert.ok(r1.ok && r1.inReplyToMatches && r1.newId, "correlation/metadata checks");
    assert.equal(Buffer.from(r1.outBase64, "base64").toString("utf8"), text);

    // all 256 bytes
    const allb64 = Buffer.from(Array.from({ length: 256 }, (_, i) => i)).toString("base64");
    const r2 = await runHelper(["-Command", "e2e", "-Standalone", standalone, "-Endpoint", endpoint, "-Kind", "bytes", "-InputBase64", allb64]);
    assert.equal(r2.outBase64, allb64);
    assert.equal(r2.kind, "bytes");

    // empty text
    const r3 = await runHelper(["-Command", "e2e", "-Standalone", standalone, "-Endpoint", endpoint, "-Kind", "text", "-InputBase64", ""]);
    assert.equal(r3.outBase64, "");
  } finally {
    await app.close();
  }
});

test("interop e2e: standalone client works when copied ALONE (no project-local files)", { skip }, async () => {
  const app = buildServer({ dict, logger: () => {} });
  const addr = await app.listen(0, "127.0.0.1");
  const endpoint = `http://127.0.0.1:${addr.port}/api/v1/exchange`;
  const dir = mkdtempSync(join(tmpdir(), "anansi-standalone-"));
  const copied = join(dir, "channelchat-client.ps1");
  try {
    copyFileSync(standalone, copied);
    // Helper dot-sources ONLY the copied file (which imports nothing project-local).
    const text = "copied-alone-works";
    const tb64 = Buffer.from(text, "utf8").toString("base64");
    const r = await runHelper(["-Command", "e2e", "-Standalone", copied, "-Endpoint", endpoint, "-Kind", "text", "-InputBase64", tb64]);
    assert.ok(r.ok);
    assert.equal(Buffer.from(r.outBase64, "base64").toString("utf8"), text);
  } finally {
    rmSync(dir, { recursive: true, force: true });
    await app.close();
  }
});

test("interop: PowerShell client REJECTS an HTTP redirect (no silent follow)", { skip }, async () => {
  const redirector = http.createServer((req, res) => {
    res.writeHead(301, { Location: "http://127.0.0.1:1/api/v1/exchange" });
    res.end();
  });
  await new Promise((r) => redirector.listen(0, "127.0.0.1", r));
  const port = redirector.address().port;
  try {
    const res = await runHelper(["-Command", "sendcatch", "-Standalone", standalone, "-Endpoint", `http://127.0.0.1:${port}/api/v1/exchange`]);
    assert.equal(res.ok, false);
    assert.equal(res.code, "CLIENT_REDIRECT_REJECTED");
  } finally {
    await new Promise((r) => redirector.close(r));
  }
});

test("interop: PowerShell client does NOT fall back from HTTPS to HTTP", { skip }, async () => {
  // Plain HTTP server, but the client is pointed at an https:// URL for that port.
  const app = buildServer({ dict, logger: () => {} });
  const addr = await app.listen(0, "127.0.0.1");
  try {
    const res = await runHelper(["-Command", "sendcatch", "-Standalone", standalone, "-Endpoint", `https://127.0.0.1:${addr.port}/api/v1/exchange`]);
    // The guarantee: it does NOT succeed and does NOT downgrade to HTTP. The exact code is
    // platform-dependent (CLIENT_TRANSPORT on Windows; may be CLIENT_TIMEOUT on .NET/Linux).
    assert.equal(res.ok, false);
    assert.ok(["CLIENT_TRANSPORT", "CLIENT_TIMEOUT"].includes(res.code), `got ${res.code}`);
  } finally {
    await app.close();
  }
});

function trySelfSigned() {
  try {
    const dir = execSync("mktemp -d").toString().trim();
    execSync(
      `openssl req -x509 -newkey rsa:2048 -nodes -keyout ${dir}/key.pem -out ${dir}/cert.pem -days 2 -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"`,
      { stdio: "ignore" },
    );
    return dir;
  } catch {
    return null;
  }
}

const certDir = PWSH ? trySelfSigned() : null;
const httpsSkip = !PWSH ? skip : certDir ? false : "NOT RUN: openssl unavailable to mint a test certificate";

test("interop: PowerShell client REJECTS an untrusted HTTPS certificate (no bypass)", { skip: httpsSkip }, async () => {
  const { readFileSync: rf } = await import("node:fs");
  const tls = { key: rf(`${certDir}/key.pem`), cert: rf(`${certDir}/cert.pem`) };
  const app = buildServer({ dict, tls, logger: () => {} });
  const addr = await app.listen(0, "127.0.0.1");
  try {
    // Use the hostname 'localhost' (matches the cert SAN) but the client has no trust root
    // for this self-signed CA, so validation must fail.
    const res = await runHelper(["-Command", "sendcatch", "-Standalone", standalone, "-Endpoint", `https://localhost:${addr.port}/api/v1/exchange`]);
    // Untrusted self-signed cert must be rejected (no bypass). Exact code is platform
    // dependent (CLIENT_TRANSPORT on Windows; may be CLIENT_TIMEOUT on .NET/Linux).
    assert.equal(res.ok, false);
    assert.ok(["CLIENT_TRANSPORT", "CLIENT_TIMEOUT"].includes(res.code), `got ${res.code}`);
  } finally {
    await app.close();
  }
});

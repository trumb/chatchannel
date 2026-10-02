#!/usr/bin/env node
// ChannelChat ("Anansi") server entrypoint.
//
// Usage:
//   node src/bin/serve.mjs --config config/server.local.json
//   ANANSI_PORT=80 node src/bin/serve.mjs --config config/server.azure.json
//
// HTTP (no TLS) is fully supported. For HTTPS, point the config tls.{certFile,keyFile}
// at real certificate/key files, or set ANANSI_TLS_CERT / ANANSI_TLS_KEY.

import { loadConfig, resolveTls } from "../config.js";
import { loadDictionaryFile } from "../dictionary.js";
import { buildServer } from "../server.js";

function argValue(flag) {
  const i = process.argv.indexOf(flag);
  return i >= 0 && i + 1 < process.argv.length ? process.argv[i + 1] : null;
}

async function main() {
  const configPath = argValue("--config");
  const cfg = loadConfig({ configPath });
  const dict = loadDictionaryFile(cfg.dictionaryPath, cfg.limits);
  const tls = resolveTls(cfg);

  const app = buildServer({ dict, limits: cfg.limits, tls });
  const addr = await app.listen(cfg.port, cfg.host);
  const scheme = app.isTls ? "https" : "http";
  process.stdout.write(
    JSON.stringify({
      event: "listening",
      scheme,
      host: addr.address,
      port: addr.port,
      dictionaryId: dict.id,
    }) + "\n",
  );

  for (const sig of ["SIGINT", "SIGTERM"]) {
    process.on(sig, async () => {
      await app.close();
      process.exit(0);
    });
  }
}

main().catch((e) => {
  process.stderr.write(`fatal: ${e.message}\n`);
  process.exit(1);
});

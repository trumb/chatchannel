// Server configuration loading. Host and port are configurable; HTTPS is optional.
//
// Precedence (low -> high): built-in defaults < config file < environment variables.
// Environment:
//   ANANSI_HOST, ANANSI_PORT, ANANSI_DICTIONARY,
//   ANANSI_TLS_CERT, ANANSI_TLS_KEY (presence of BOTH enables HTTPS)

import { readFileSync } from "node:fs";
import { createLimits } from "./limits.js";

const BUILTIN = {
  host: "127.0.0.1",
  port: 8080,
  dictionaryPath: "data/dictionary.v1.json",
  tls: null, // { certFile, keyFile } to enable HTTPS
  limits: {},
};

export function loadConfig({ configPath = null, env = process.env } = {}) {
  let fileCfg = {};
  if (configPath) {
    try {
      fileCfg = JSON.parse(readFileSync(configPath, "utf8"));
    } catch (e) {
      throw new Error(`could not read config file ${configPath}: ${e.message}`);
    }
  }
  const cfg = { ...BUILTIN, ...fileCfg };

  if (env.ANANSI_HOST) cfg.host = env.ANANSI_HOST;
  if (env.ANANSI_PORT) cfg.port = Number(env.ANANSI_PORT);
  if (env.ANANSI_DICTIONARY) cfg.dictionaryPath = env.ANANSI_DICTIONARY;
  if (env.ANANSI_TLS_CERT && env.ANANSI_TLS_KEY) {
    cfg.tls = { certFile: env.ANANSI_TLS_CERT, keyFile: env.ANANSI_TLS_KEY };
  }

  if (!Number.isInteger(cfg.port) || cfg.port < 0 || cfg.port > 65535) {
    throw new Error(`invalid port: ${cfg.port}`);
  }
  cfg.limits = createLimits(cfg.limits || {});
  return cfg;
}

// Resolve TLS config into { key, cert } buffers, or null for plain HTTP.
export function resolveTls(cfg) {
  if (!cfg.tls) return null;
  const { certFile, keyFile } = cfg.tls;
  if (!certFile || !keyFile) {
    throw new Error("tls config requires both certFile and keyFile");
  }
  return {
    cert: readFileSync(certFile),
    key: readFileSync(keyFile),
  };
}

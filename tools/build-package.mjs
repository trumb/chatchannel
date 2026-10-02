// Builds the embedded standalone-client package (dictionary + public config) and returns
// both the package object and its gzip+base64 encoding.
//
// The package contains DATA ONLY: the dictionary and public configuration. It contains no
// executable code and no credentials.

import { gzipSync } from "node:zlib";
import { loadDictionaryFile } from "../src/dictionary.js";
import { DEFAULT_LIMITS } from "../src/limits.js";
import { PAYLOAD_ENCODING, PROTOCOL_VERSION } from "../src/protocol.js";

// Deterministic JSON with sorted object keys (stable embedded output).
export function stableStringify(value) {
  if (value === null || typeof value !== "object") return JSON.stringify(value);
  if (Array.isArray(value)) return "[" + value.map(stableStringify).join(",") + "]";
  const keys = Object.keys(value).sort();
  return "{" + keys.map((k) => JSON.stringify(k) + ":" + stableStringify(value[k])).join(",") + "}";
}

// Public subset of limits that the client honors (no server-only time/concurrency fields).
function publicLimits(limits) {
  const keep = [
    "maxResponseBodyBytes",
    "maxBase64Chars",
    "maxCompressedBytes",
    "maxDecompressedBytes",
    "maxPackageCompressedBytes",
    "maxPackageDecompressedBytes",
    "maxDictionaryEntryBytes",
    "dictionaryEntryCount",
    "maxTokenCount",
    "maxReconstructedBytes",
    "clientTimeoutMs",
  ];
  const out = {};
  for (const k of keep) out[k] = limits[k];
  return out;
}

export function buildPackage({
  dictionaryPath = "data/dictionary.v1.json",
  defaultEndpoint = "http://127.0.0.1:8080/api/v1/exchange",
  limits = DEFAULT_LIMITS,
  generatedAtUtc = null,
} = {}) {
  const dict = loadDictionaryFile(dictionaryPath, limits);
  const pkg = {
    schemaVersion: 1,
    dictionaryId: dict.id,
    dictionary: { schemaVersion: 1, entries: dict.entries },
    config: {
      defaultEndpoint,
      protocolVersion: PROTOCOL_VERSION,
      payloadEncoding: PAYLOAD_ENCODING,
      limits: publicLimits(limits),
    },
    generatedAtUtc: generatedAtUtc || new Date().toISOString(),
  };
  const json = Buffer.from(stableStringify(pkg), "utf8");
  const gz = gzipSync(json);
  if (gz.length > limits.maxPackageCompressedBytes) {
    throw new Error(`package compressed size ${gz.length} exceeds limit ${limits.maxPackageCompressedBytes}`);
  }
  const base64 = gz.toString("base64");
  return { package: pkg, dictionaryId: dict.id, entries: dict.entries, base64, compressedBytes: gz.length, jsonBytes: json.length };
}

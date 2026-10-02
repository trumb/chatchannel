// Named, configurable resource limits for the ChannelChat (codename "Anansi") server and codec.
//
// These are CONSERVATIVE defaults. Every limit is enforced while reading/decompressing,
// not only after full allocation. Override per-field via createLimits({...}).
//
// Sizes are in bytes unless the name says otherwise.

export const DEFAULT_LIMITS = Object.freeze({
  // HTTP I/O
  maxRequestBodyBytes: 1 * 1024 * 1024, // 1 MiB raw HTTP request body (the JSON envelope)
  maxResponseBodyBytes: 4 * 1024 * 1024, // 4 MiB raw HTTP response body the client will accept

  // Payload layers (inside the envelope "payload" field)
  maxBase64Chars: 1_500_000, // upper bound on the base64 payload string length
  maxCompressedBytes: 1 * 1024 * 1024, // gzip bytes after base64 decode
  maxDecompressedBytes: 8 * 1024 * 1024, // token-JSON bytes after bounded gunzip

  // Embedded standalone-client package (dictionary + public config)
  maxPackageCompressedBytes: 512 * 1024,
  maxPackageDecompressedBytes: 4 * 1024 * 1024,

  // Dictionary
  maxDictionaryEntryBytes: 256, // UTF-8 byte length per entry
  dictionaryEntryCount: 256, // exact

  // Token stream
  maxTokenCount: 2_000_000, // tokens in one message
  maxReconstructedBytes: 8 * 1024 * 1024, // bytes rebuilt from tokens

  // JSON structure
  maxJsonDepth: 8, // nesting depth allowed in the outer envelope
  maxJsonStringBytes: 1_500_000, // longest single JSON string value (e.g. payload)

  // Concurrency & time (server)
  maxConcurrentRequests: 64,
  requestTimeoutMs: 15_000, // whole-request deadline, server side
  headersTimeoutMs: 10_000,

  // Client timeouts (documented defaults; applied by the PowerShell client too)
  clientTimeoutMs: 30_000,
});

export function createLimits(overrides = {}) {
  const merged = { ...DEFAULT_LIMITS, ...overrides };
  for (const [k, v] of Object.entries(merged)) {
    if (typeof v !== "number" || !Number.isFinite(v) || v < 0) {
      throw new Error(`limit "${k}" must be a non-negative finite number`);
    }
  }
  if (merged.dictionaryEntryCount !== 256) {
    throw new Error('limit "dictionaryEntryCount" must be 256 for schemaVersion 1');
  }
  return Object.freeze(merged);
}

// Dictionary load, strict validation, and deterministic fingerprint.
//
// The dictionary is a byte-to-string table for schemaVersion 1:
//   entries[0] represents byte 0 ... entries[255] represents byte 255.
//
// Fingerprint (identical in PowerShell and JavaScript):
//   SHA-256 over:
//     UTF-8 bytes of "ChannelChat.Dictionary.v1", then one 0x00 byte,
//     then for each entry in index order:
//       its UTF-8 byte length as uint32 big-endian, then its exact UTF-8 bytes.
//   ID = "sha256:" + lowercase hex.
//
// A fingerprint identifies dictionary CONTENTS. It is not proof of authenticity.

import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { CODES, fail } from "./errors.js";
import { DEFAULT_LIMITS } from "./limits.js";
import { hasLoneSurrogate, utf8ByteLength } from "./unicode.js";

const FINGERPRINT_PREFIX = "ChannelChat.Dictionary.v1";

export function computeDictionaryId(entries) {
  const hash = createHash("sha256");
  hash.update(Buffer.from(FINGERPRINT_PREFIX, "utf8"));
  hash.update(Buffer.from([0x00]));
  const lenBuf = Buffer.allocUnsafe(4);
  for (const entry of entries) {
    const bytes = Buffer.from(entry, "utf8");
    lenBuf.writeUInt32BE(bytes.length, 0);
    hash.update(lenBuf);
    hash.update(bytes);
  }
  return "sha256:" + hash.digest("hex");
}

// Validates a parsed dictionary document. Returns { entries, id, byteOf }.
//   - entries: the validated string[] (index = byte value)
//   - id: "sha256:..." fingerprint
//   - byteOf: Map<string, number> ordinal reverse lookup (token -> byte)
export function validateDictionary(doc, limits = DEFAULT_LIMITS) {
  if (doc === null || typeof doc !== "object" || Array.isArray(doc)) {
    fail(CODES.DICT_SCHEMA_INVALID, "dictionary must be a JSON object");
  }
  if (doc.schemaVersion !== 1) {
    fail(CODES.DICT_SCHEMA_INVALID, "dictionary.schemaVersion must be 1");
  }
  const entries = doc.entries;
  if (!Array.isArray(entries)) {
    fail(CODES.DICT_SCHEMA_INVALID, "dictionary.entries must be an array");
  }
  if (entries.length !== limits.dictionaryEntryCount) {
    fail(
      CODES.DICT_ENTRY_COUNT,
      `dictionary.entries must have exactly ${limits.dictionaryEntryCount} entries, got ${entries.length}`,
    );
  }

  // Build reverse map with ordinal (exact, case-sensitive) matching and detect duplicates.
  const byteOf = new Map();
  for (let i = 0; i < entries.length; i++) {
    const e = entries[i];
    if (typeof e !== "string") {
      fail(CODES.DICT_ENTRY_TYPE, `dictionary entry at index ${i} is not a string`);
    }
    if (hasLoneSurrogate(e)) {
      fail(
        CODES.DICT_ENTRY_INVALID_UNICODE,
        `dictionary entry at index ${i} contains an unpaired surrogate`,
      );
    }
    if (utf8ByteLength(e) > limits.maxDictionaryEntryBytes) {
      fail(
        CODES.DICT_ENTRY_TOO_LONG,
        `dictionary entry at index ${i} exceeds ${limits.maxDictionaryEntryBytes} UTF-8 bytes`,
      );
    }
    if (byteOf.has(e)) {
      fail(CODES.DICT_DUPLICATE_ENTRY, `dictionary entry "${truncate(e)}" is duplicated`);
    }
    byteOf.set(e, i);
  }

  const id = computeDictionaryId(entries);
  return { entries, id, byteOf };
}

export function loadDictionaryFile(path, limits = DEFAULT_LIMITS) {
  let parsed;
  try {
    parsed = JSON.parse(readFileSync(path, "utf8"));
  } catch (e) {
    fail(CODES.DICT_SCHEMA_INVALID, `could not read/parse dictionary file: ${e.message}`);
  }
  return validateDictionary(parsed, limits);
}

function truncate(s, n = 32) {
  return s.length > n ? s.slice(0, n) + "..." : s;
}

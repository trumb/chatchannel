// Unicode helpers shared by the dictionary and codec layers.

// Returns true if the JS (UTF-16) string contains an unpaired surrogate code unit.
// JSON.parse can produce these from "\uD800" etc., and Buffer.from(str,"utf8") would
// silently turn them into U+FFFD. We reject them instead.
export function hasLoneSurrogate(str) {
  for (let i = 0; i < str.length; i++) {
    const c = str.charCodeAt(i);
    if (c >= 0xd800 && c <= 0xdbff) {
      // high surrogate: must be followed by a low surrogate
      const next = i + 1 < str.length ? str.charCodeAt(i + 1) : 0;
      if (next < 0xdc00 || next > 0xdfff) return true;
      i++; // valid pair, skip the low surrogate
    } else if (c >= 0xdc00 && c <= 0xdfff) {
      // low surrogate without a preceding high surrogate
      return true;
    }
  }
  return false;
}

// UTF-8 byte length of a string that is already known to be well-formed.
export function utf8ByteLength(str) {
  return Buffer.byteLength(str, "utf8");
}

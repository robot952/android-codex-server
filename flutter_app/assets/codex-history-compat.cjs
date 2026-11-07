"use strict";

// Compatibility at the Responses request boundary only. This does not rewrite
// stored history, unwrap opaque encryption, or interpret strings elsewhere.
function normalizeResponsesHistory(value) {
  function decodeKnownPlaintext(encoded) {
    const prefix = "c2a-msg-v1:";
    if (typeof encoded !== "string" || !encoded.startsWith(prefix)) return null;

    const payload = encoded.slice(prefix.length);
    if (!/^[A-Za-z0-9_-]+={0,2}$/.test(payload)) return null;
    const unpadded = payload.replace(/=+$/, "");
    const paddingLength = payload.length - unpadded.length;
    const remainder = unpadded.length % 4;
    if (remainder === 1) return null;
    if (paddingLength &&
        (payload.length % 4 !== 0 || paddingLength !== (4 - remainder) % 4)) {
      return null;
    }

    try {
      const bytes = Buffer.from(unpadded, "base64url");
      // Buffer's decoder is permissive. A round trip rejects alternate alphabets,
      // invalid padding and nonzero unused bits instead of guessing their meaning.
      if (bytes.toString("base64url") !== unpadded) return null;
      const decoded = bytes.toString("utf8");
      // Invalid UTF-8 introduces replacement characters and cannot round trip.
      // A replacement character that was actually present in valid UTF-8 is kept.
      if (!Buffer.from(decoded, "utf8").equals(bytes)) return null;
      return decoded;
    } catch (_) {
      return null;
    }
  }

  function mislabelledAgentProse(encoded) {
    if (typeof encoded !== "string") return null;
    const candidate = encoded.trim();
    // A token mentioned *within* prose is ordinary text. A token/envelope at
    // the start remains opaque, including unknown versions and broken c2a data.
    if (/^(?:gAAAA|[A-Za-z0-9_-]+:)/.test(candidate)) return null;
    if (/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/.test(encoded) ||
        Buffer.from(encoded, "utf8").toString("utf8") !== encoded) return null;
    // Limit recovery to unmistakable English prose like the reported child
    // reply. Do not guess short strings, wrapped base64 or structured payloads.
    if (!/^[A-Za-z]+(?:[ \t]+[A-Za-z]+){2}(?=[ \t.,;:!?])/.test(candidate) ||
        !/[.!?;:](?:\s|$)/.test(candidate)) return null;
    return encoded;
  }

  if (!value || typeof value !== "object" || Array.isArray(value) ||
      !Array.isArray(value.input)) {
    return { value, converted: 0 };
  }

  let input = null;
  let converted = 0;
  for (let index = 0; index < value.input.length; index++) {
    const item = value.input[index];
    if (!item || typeof item !== "object" || Array.isArray(item) ||
        item.type !== "agent_message" || !Array.isArray(item.content)) continue;

    let content = null;
    for (let blockIndex = 0; blockIndex < item.content.length; blockIndex++) {
      const block = item.content[blockIndex];
      if (!block || typeof block !== "object" || Array.isArray(block) ||
          block.type !== "encrypted_content") continue;
      const decoded = decodeKnownPlaintext(block.encrypted_content) ??
        mislabelledAgentProse(block.encrypted_content);
      if (decoded === null) continue;

      if (!content) content = item.content.slice();
      // input_text has a different schema: do not carry encryption-specific or
      // unknown block fields into it. Preserve every field of the outer item.
      content[blockIndex] = { type: "input_text", text: decoded };
      converted++;
    }
    if (!content) continue;
    if (!input) input = value.input.slice();
    input[index] = { ...item, content };
  }

  return { value: input ? { ...value, input } : value, converted };
}

Object.assign(module.exports, { normalizeResponsesHistory });

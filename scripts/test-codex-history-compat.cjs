"use strict";

// Synthetic fixtures only. Never load user history or contact a model provider.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { normalizeResponsesHistory } = require("../flutter_app/assets/codex-history-compat.cjs");

let scenarios = 0;
function scenario(name, run) {
  run();
  scenarios++;
  console.log(`PASS ${name}`);
}

function encoded(text) {
  return `c2a-msg-v1:${Buffer.from(text, "utf8").toString("base64url")}`;
}

function encrypted(payload, extra = {}) {
  return { type: "encrypted_content", encrypted_content: payload, ...extra };
}

function request(blocks, extra = {}) {
  return {
    model: "synthetic-model",
    input: [{ type: "agent_message", content: blocks, ...extra }],
  };
}

function freeze(value) {
  if (value && typeof value === "object" && !Object.isFrozen(value)) {
    Object.values(value).forEach(freeze);
    Object.freeze(value);
  }
  return value;
}

scenario("decodes multiple known plaintext blocks and preserves the outer message", () => {
  const text = "Synthetic body\n第二行 🙂";
  const existingText = { type: "input_text", text: "Already plain" };
  const legitimateEncryption = encrypted("c2c:v1:opaque-encryption");
  const source = freeze({
    ...request([
      encrypted(encoded(text), { signature: "obsolete", unknown: "do not transfer" }),
      existingText,
      legitimateEncryption,
      encrypted(encoded("Second synthetic message")),
    ], { id: "agent-item", sender: "/root/child", recipient: "/root", custom: { kept: true } }),
    metadata: { unchanged: true },
  });
  const before = JSON.stringify(source);
  const result = normalizeResponsesHistory(source);
  assert.equal(result.converted, 2);
  assert.notEqual(result.value, source);
  assert.notEqual(result.value.input, source.input);
  assert.notEqual(result.value.input[0], source.input[0]);
  assert.notEqual(result.value.input[0].content, source.input[0].content);
  assert.deepEqual(result.value.input[0].content[0], { type: "input_text", text });
  assert.equal(result.value.input[0].content[1], existingText);
  assert.equal(result.value.input[0].content[2], legitimateEncryption);
  assert.deepEqual(result.value.input[0].content[3], {
    type: "input_text", text: "Second synthetic message",
  });
  assert.equal(result.value.input[0].type, "agent_message");
  for (const key of ["id", "sender", "recipient", "custom"]) {
    assert.equal(result.value.input[0][key], source.input[0][key]);
  }
  assert.equal(result.value.metadata, source.metadata);
  assert.equal(JSON.stringify(source), before);
});

scenario("copies only changed paths and is idempotent", () => {
  const unchanged = { type: "message", role: "user", content: "Synthetic prompt" };
  const secondAgent = { type: "agent_message", content: [encrypted("c2c:v1:valid")] };
  const source = freeze({ input: [unchanged, request([encrypted(encoded("Reply"))]).input[0], secondAgent] });
  const first = normalizeResponsesHistory(source);
  assert.equal(first.converted, 1);
  assert.equal(first.value.input[0], unchanged);
  assert.equal(first.value.input[2], secondAgent);
  const second = normalizeResponsesHistory(first.value);
  assert.equal(second.converted, 0);
  assert.equal(second.value, first.value);
});

scenario("keeps legitimate encryption, c2c summaries and normal history unchanged", () => {
  const source = freeze(request([
    encrypted("c2c:v1:opaque-summary"),
    encrypted("opaque-legitimate-ciphertext"),
    { type: "input_text", text: "c2a-msg-v1:Zg==" },
    { type: "output_text", text: encoded("Ordinary text") },
  ]));
  assert.deepEqual(normalizeResponsesHistory(source), { value: source, converted: 0 });
  assert.equal(normalizeResponsesHistory(source).value, source);
});

scenario("does not recurse into nested history or interpret non-agent messages", () => {
  const block = encrypted(encoded("Synthetic nested body"));
  const source = freeze({
    input: [
      { type: "message", role: "assistant", content: [block] },
      { type: "message", role: "user", content: [block] },
      { type: "reasoning", content: [block] },
      { type: "Agent_message", content: [block] },
      { type: "agent_message", content: encoded("String content") },
      { type: "agent_message", content: [{ type: "Encrypted_content", encrypted_content: encoded("Wrong block type") }] },
      { type: "agent_message", content: [{ type: "input_text", text: encoded("Marker in text") }] },
      null,
      [],
    ],
    guardian_history: { input: [request([block]).input[0]] },
    nested: { input: [request([block]).input[0]] },
  });
  const result = normalizeResponsesHistory(source);
  assert.equal(result.converted, 0);
  assert.equal(result.value, source);
});

scenario("requires a Responses root object with an input array", () => {
  for (const source of [null, undefined, false, 0, "c2a-msg-v1:Zg", [], {}, { input: null },
    { input: "c2a-msg-v1:Zg" }, { nested: request([encrypted(encoded("Nested"))]) }]) {
    const result = normalizeResponsesHistory(source);
    assert.equal(result.converted, 0);
    assert.equal(result.value, source);
  }
});

scenario("accepts canonical Base64URL with no padding or exactly valid padding", () => {
  for (const [text, payload] of [
    ["f", "Zg"], ["f", "Zg=="], ["fo", "Zm8"], ["fo", "Zm8="],
    ["foo", "Zm9v"], ["foob", "Zm9vYg"], ["foob", "Zm9vYg=="],
    ["\u083e\u083f", "4KC-4KC_"],
  ]) {
    const result = normalizeResponsesHistory(freeze(request([encrypted(`c2a-msg-v1:${payload}`)])));
    assert.equal(result.converted, 1, payload);
    assert.deepEqual(result.value.input[0].content, [{ type: "input_text", text }]);
  }
});

scenario("preserves empty, invalid or noncanonical encoded contents", () => {
  for (const payload of [
    "", " ", "Zg ", " Zg", "Zg\n", "Zg\r\n", "Zg\t", "+w", "/w", "A", "AAAAA",
    "Zg=", "Zg===", "Zm8==", "Zm9v=", "Zm9v====", "Z=g", "=Zg", "====",
    "Zh", "Zh==", "Zm9", "Zm9=", "Zg!", "Zg%3D%3D", "ZgＡ",
  ]) {
    const source = freeze(request([encrypted(`c2a-msg-v1:${payload}`)]));
    const result = normalizeResponsesHistory(source);
    assert.equal(result.converted, 0, JSON.stringify(payload));
    assert.equal(result.value, source);
  }
  for (const payload of ["C2a-msg-v1:Zg", " c2a-msg-v1:Zg", "c2a-msg-v1:Zg:extra", "prefix-c2a-msg-v1:Zg"]) {
    const source = freeze(request([encrypted(payload)]));
    assert.equal(normalizeResponsesHistory(source).value, source);
  }
});

scenario("rejects malformed UTF-8 instead of introducing replacement characters", () => {
  for (const bytes of [
    [0x80], [0xc0, 0xaf], [0xe2, 0x28, 0xa1], [0xed, 0xa0, 0x80],
    [0xf4, 0x90, 0x80, 0x80], [0xe2, 0x82], [0xff],
  ]) {
    const source = freeze(request([encrypted(`c2a-msg-v1:${Buffer.from(bytes).toString("base64url")}`)]));
    assert.equal(normalizeResponsesHistory(source).converted, 0);
    assert.equal(normalizeResponsesHistory(source).value, source);
  }
});

scenario("preserves valid UTF-8 replacement characters, BOM, controls and whitespace", () => {
  for (const text of ["\ufffd", "\ufeffSynthetic body", "\u0000\n\t", " ", "\r\n"]) {
    const result = normalizeResponsesHistory(freeze(request([encrypted(encoded(text))])));
    assert.equal(result.converted, 1);
    assert.equal(result.value.input[0].content[0].text, text);
  }
});

scenario("ignores wrong content shapes and values without losing other blocks", () => {
  const source = freeze(request([
    null, [], "c2a-msg-v1:Zg", {}, { type: "encrypted_content" },
    encrypted(null), encrypted(42), encrypted({ value: encoded("Not a string") }),
    encrypted(encoded("Synthetic valid body")),
  ]));
  const result = normalizeResponsesHistory(source);
  assert.equal(result.converted, 1);
  source.input[0].content.slice(0, -1).forEach((block, index) => {
    assert.equal(result.value.input[0].content[index], block);
  });
});

scenario("can be concatenated into a relay while preserving existing exports", () => {
  const source = fs.readFileSync(path.join(__dirname, "../flutter_app/assets/codex-history-compat.cjs"), "utf8");
  const sandbox = { Buffer, module: { exports: { sentinel: true } } };
  vm.runInNewContext(`"use strict";\nconst fs = null, path = null, prefix = null, integer = null;\n${source}`, sandbox);
  assert.equal(sandbox.module.exports.sentinel, true);
  assert.equal(typeof sandbox.module.exports.normalizeResponsesHistory, "function");
  assert.deepEqual(Object.keys(sandbox).sort(), ["Buffer", "module", "normalizeResponsesHistory"].sort());
  const result = sandbox.module.exports.normalizeResponsesHistory(request([encrypted(encoded("Synthetic body"))]));
  assert.equal(result.converted, 1);
  assert.equal(result.value.input[0].content[0].text, "Synthetic body");
});

console.log(`${scenarios} history compatibility scenarios passed`);

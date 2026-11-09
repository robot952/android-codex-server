"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { providerConfigOverrides } = require("../flutter_app/assets/codex-history-proxy.cjs");
const { createHistoryRpcBridge } = require("../flutter_app/assets/codex-history-relay.cjs");
global.providerConfigOverrides = providerConfigOverrides;

test("mobile item pages bound a single huge turn, retain every cursor, and hydrate exact items", async () => {
  const records = Array.from({ length: 57 }, (_, index) => ({
    turnId: index < 3 ? "older-turn" : "one-long-turn",
    item: { type: "commandExecution", id: `cmd-${index}`, status: "completed",
      command: `echo ${index}`, aggregatedOutput: "large output 中文\n".repeat(10000) },
  }));
  records.at(-1).item.aggregatedOutput = "x".repeat(9 * 1024 * 1024);
  const original = JSON.stringify(records);
  const visible = [];
  const requests = [];
  let bridge;
  bridge = createHistoryRpcBridge({
    proxy: null,
    output: chunk => visible.push(JSON.parse(chunk)),
    send(chunk) {
      const request = JSON.parse(chunk);
      requests.push(request);
      let result;
      if (request.method === "thread/read") result = { thread: { id: "fixture", status: { type: "idle" } } };
      if (request.method === "thread/turns/list") result = { data: [{ id: "one-long-turn", status: "completed", items: [] }] };
      if (request.method === "thread/items/list") {
        const p = request.params;
        const rows = records.filter(row => !p.turnId || row.turnId === p.turnId);
        const desc = p.sortDirection === "desc";
        let offset = p.cursor == null ? (desc ? rows.length - 1 : 0)
          : typeof p.cursor === "string" ? Number(p.cursor)
          : rows.findIndex(row => row.item.id === p.cursor.itemId) + (desc ? -1 : 1);
        const data = [];
        while (offset >= 0 && offset < rows.length && data.length < p.limit) {
          data.push(rows[offset]); offset += desc ? -1 : 1;
        }
        result = { data, nextCursor: offset >= 0 && offset < rows.length ? String(offset) : null,
          backwardsCursor: data.length ? String(rows.indexOf(data[0]) + (desc ? 1 : -1)) : null };
      }
      queueMicrotask(() => bridge.writeOutput(JSON.stringify({ id: request.id, result }) + "\n"));
    },
  });
  let id = 0;
  async function rpc(method, params) {
    const requestId = ++id;
    bridge.writeInput(JSON.stringify({ id: requestId, method, params }) + "\n");
    for (let spin = 0; spin < 100; spin++) {
      const message = visible.find(value => value.id === requestId);
      if (message) { assert(!message.error, JSON.stringify(message.error)); return message.result; }
      await new Promise(resolve => setImmediate(resolve));
    }
    throw new Error("fixture response missing");
  }
  try {
    const first = await rpc("codexRemote/history/open", { threadId: "fixture", readOnly: true });
    assert(Buffer.byteLength(JSON.stringify(first)) < 10 * 1024);
    assert(requests.every(r => !["thread/resume", "turn/start", "thread/inject_items"].includes(r.method)));
    const ids = [];
    let page = first.initialTurnsPage;
    do {
      for (const turn of page.data) ids.push(...turn.items.toReversed().map(item => item.id));
      if (!page.nextCursor) break;
      page = await rpc("codexRemote/history/page", { threadId: "fixture", cursor: page.nextCursor });
      assert(Buffer.byteLength(JSON.stringify(page)) < 96 * 1024);
    } while (true);
    assert.deepEqual(ids, records.toReversed().map(row => row.item.id));
    for (const index of [0, 3, 24, 56]) {
      const row = records[index];
      const detail = await rpc("codexRemote/history/item", { threadId: "fixture", turnId: row.turnId, itemId: row.item.id });
      if (index === 56) {
        const item = detail.data[0].items[0];
        assert.equal(item.id, row.item.id);
        assert.equal(item.command, row.item.command);
        assert.equal(item.aggregatedOutput.length, 512 * 1024);
        assert(item.aggregatedOutput.endsWith("完整输出仍保存在服务器]"));
        assert(Buffer.byteLength(JSON.stringify(detail)) < 1024 * 1024);
      } else assert.deepEqual(detail.data[0].items[0], row.item);
    }
    assert.equal(JSON.stringify(records), original, "UI projection must not mutate native history");
  } finally { bridge.close(); }
});

function fixture({ config, respond, timeoutMs } = {}) {
  const sent = [];
  const visible = [];
  let bridge;
  bridge = createHistoryRpcBridge({
    timeoutMs,
    proxy: { urlFor: (url) => typeof url === "string" ? `http://127.0.0.1/route/${encodeURIComponent(url)}` : null },
    send(chunk) {
      const message = JSON.parse(chunk.toString());
      sent.push(message);
      if (!String(message.id).startsWith("codex-history-")) return;
      const result = respond ? respond(message) : message.method === "thread/read"
        ? { thread: { cwd: "/project" } } : { config: config || {} };
      if (result === undefined) return;
      queueMicrotask(() => bridge.writeOutput(JSON.stringify({ id: message.id, result }) + "\n"));
    },
    output: (chunk) => visible.push(chunk),
  });
  return { bridge, sent, visible };
}

test("resume uses project provider settings without exposing private internal RPCs", async () => {
  const f = fixture({ config: {
    model_provider: "vendor.name", secret: "PRIVATE_CONFIG_FIXTURE",
    model_providers: { "vendor.name": {
      name: "Fixture", base_url: "https://provider.test/v1", env_key: "FIXTURE_KEY",
      http_headers: { "x-fixture": "unchanged" },
    } },
  } });
  f.bridge.writeInput('{"method":"initialized"}\n');
  const request = JSON.stringify({ id: 5, method: "thread/resume", params: {
    threadId: "synthetic-thread", config: { model: "fixture-model", approval_policy: "never" },
  } }) + "\n";
  for (const byte of Buffer.from(request)) f.bridge.writeInput(Buffer.from([byte]));
  await f.bridge.endInput();
  const resumed = f.sent.find((m) => m.id === 5);
  assert.equal(resumed.params.config.model, "fixture-model");
  assert.equal(resumed.params.config.approval_policy, "never");
  const provider = resumed.params.config.model_providers["vendor.name"];
  assert.match(provider.base_url, /^http:\/\/127\.0\.0\.1\//);
  assert.equal(provider.env_key, "FIXTURE_KEY");
  assert.deepEqual(provider.http_headers, { "x-fixture": "unchanged" });
  assert.equal(provider.supports_websockets, false);
  assert(f.sent.some((m) => m.method === "config/read" && m.params.cwd === "/project"));
  assert.equal(Buffer.concat(f.visible).length, 0);
  f.bridge.writeOutput('{"id":5,"result":{"thread":{"id":"synthetic-thread"}}}\n');
  assert(!Buffer.concat(f.visible).toString().includes("PRIVATE_CONFIG_FIXTURE"));
  assert.equal(JSON.parse(Buffer.concat(f.visible)).id, 5);
  f.bridge.close();
});

test("explicit provider overrides and unrelated config survive mapping", async () => {
  const f = fixture({ config: { model_providers: {
    vendor: { name: "Vendor", base_url: "https://old.test/v1", env_key: "OLD" },
    other: { name: "Other", base_url: "https://other.test/v1" },
  } } });
  f.bridge.writeInput(JSON.stringify({ id: 9, method: "thread/start", params: {
    cwd: "/project", config: {
      "model_providers.vendor.base_url": "https://new.test/v1",
      model_providers: { vendor: { env_key: "NEW" } }, "features.fixture": true,
    },
  } }) + "\n");
  await f.bridge.endInput();
  const config = f.sent.find((m) => m.id === 9).params.config;
  assert.equal(config.model_providers.vendor.base_url,
    "http://127.0.0.1/route/https%3A%2F%2Fnew.test%2Fv1");
  assert.equal(config.model_providers.vendor.env_key, "NEW");
  assert.equal(config.model_providers.vendor.name, "Vendor");
  assert.equal(config.model_providers.other.name, "Other");
  assert.equal(config["features.fixture"], true);
  assert(!Object.hasOwn(config, "model_providers.vendor.base_url"));
  f.bridge.close();
});

test("quoted TOML provider IDs and nested header overrides survive mapping", async () => {
  const f = fixture({ config: { model_providers: {
    "vendor.name": {
      name: "Vendor", base_url: "https://old.test/v1", env_key: "OLD",
      http_headers: { preserved: "original", "x.fixture": "old" },
    },
  } } });
  const overrides = {
    'model_providers."vendor\\u002ename".base_url': "https://new.test/v1",
    " model_providers . 'vendor.name' . http_headers . 'x.fixture' ": "updated",
    'model_providers."vendor.name".http_headers."x\\\"quoted"': "quoted value",
    'model_providers."new.vendor".base_url': "https://new-vendor.test/v1",
    'model_providers."new.vendor".name': "New vendor",
    "model_providers.'table.vendor'": { base_url: "https://table.test/v1", env_key: "TABLE_KEY" },
    "features.fixture": true,
  };
  f.bridge.writeInput(JSON.stringify({ id: 10, method: "thread/start", params: {
    cwd: "/project", config: overrides,
  } }) + "\n");
  await f.bridge.endInput();
  const config = f.sent.find((m) => m.id === 10).params.config;
  assert.equal(config.model_providers["vendor.name"].base_url,
    "http://127.0.0.1/route/https%3A%2F%2Fnew.test%2Fv1");
  assert.equal(config.model_providers["vendor.name"].env_key, "OLD");
  assert.deepEqual(config.model_providers["vendor.name"].http_headers, {
    preserved: "original", "x.fixture": "updated", 'x"quoted': "quoted value",
  });
  assert.equal(config.model_providers["new.vendor"].base_url,
    "http://127.0.0.1/route/https%3A%2F%2Fnew-vendor.test%2Fv1");
  assert.equal(config.model_providers["new.vendor"].name, "New vendor");
  assert.equal(config.model_providers["table.vendor"].env_key, "TABLE_KEY");
  assert.equal(config["features.fixture"], true);
  for (const key of Object.keys(overrides).filter((key) => key !== "features.fixture")) {
    assert(!Object.hasOwn(config, key), key);
  }
  f.bridge.close();
});

test("unsupported and conflicting TOML override keys are conservatively preserved", async () => {
  const f = fixture({ config: { model_providers: {
    vendor: { name: "Vendor", base_url: "https://old.test/v1", http_headers: "unexpected scalar" },
  } } });
  const untouched = {
    'model_providers."unterminated.base_url': "https://malformed.test/v1",
    'model_providers."bad\\q".base_url': "https://unsupported.test/v1",
    "model_providers.vendor.http_headers.fixture": "cannot merge into scalar",
  };
  f.bridge.writeInput(JSON.stringify({ id: 11, method: "thread/start", params: { config: untouched } }) + "\n");
  await f.bridge.endInput();
  const config = f.sent.find((m) => m.id === 11).params.config;
  for (const [key, value] of Object.entries(untouched)) assert.equal(config[key], value);
  assert.equal(config.model_providers.vendor.http_headers, "unexpected scalar");
  f.bridge.close();
});

test("ordinary protocol traffic preserves exact bytes and order", async () => {
  const chunks = [];
  const output = [];
  const bridge = createHistoryRpcBridge({ send: (b) => chunks.push(b), output: (b) => output.push(b), proxy: null });
  const original = Buffer.from(' {"id":1,"method":"turn/start","params":{"text":"中文"}}\r\ninvalid\n');
  bridge.writeInput(original.subarray(0, 61));
  bridge.writeInput(original.subarray(61));
  await bridge.endInput();
  assert.deepEqual(Buffer.concat(chunks), original);
  bridge.writeOutput(original.subarray(0, 62));
  bridge.writeOutput(original.subarray(62));
  bridge.close();
  assert.deepEqual(Buffer.concat(output), original);
});

test("child failures and parent notifications pass through during provider setup", async () => {
  const f = fixture({ respond: () => undefined, timeoutMs: 2000 });
  f.bridge.writeInput(JSON.stringify({ id: 20, method: "thread/start", params: { cwd: "/project" } }) + "\n");
  await new Promise(resolve => setImmediate(resolve));
  const configRead = f.sent.find(message => message.method === "config/read");
  assert(configRead, "Provider setup must be pending during interleaved notifications");
  const events = [
    { method: "turn/started", params: { threadId: "parent", turn: { id: "parent-turn", status: "inProgress" } } },
    { method: "error", params: { threadId: "child", turnId: "child-turn", willRetry: false,
      error: { message: "Synthetic child request failed" } } },
    { method: "turn/completed", params: { threadId: "child", turn: { id: "child-turn", status: "failed" } } },
    { method: "item/agentMessage/delta", params: { threadId: "parent", turnId: "parent-turn", itemId: "parent-item", delta: "父任务继续 🙂" } },
    { method: "turn/completed", params: { threadId: "parent", turn: { id: "parent-turn", status: "completed" } } },
  ];
  const original = Buffer.from(events.map(event => JSON.stringify(event) + "\r\n").join(""));
  for (let index = 0; index < original.length; index += 7) {
    f.bridge.writeOutput(original.subarray(index, index + 7));
  }
  f.bridge.writeOutput(JSON.stringify({ id: configRead.id, result: { config: {} } }) + "\n");
  await f.bridge.endInput();
  f.bridge.close();
  assert.deepEqual(Buffer.concat(f.visible), original, "Relay must not reinterpret errors, reorder events or lose child/parent IDs");
  assert.equal(f.sent.filter(message => message.id === 20).length, 1);
  assert(!f.sent.some(message => message.method === "turn/interrupt" || message.method === "turn/start"));
});

test("unavailable internal config forwards original request once and hides late secrets", async () => {
  const f = fixture({ respond: () => undefined, timeoutMs: 10 });
  const original = { id: 2, method: "thread/start", params: { cwd: "/project" } };
  f.bridge.writeInput(JSON.stringify(original) + "\n");
  const finished = f.bridge.endInput();
  await new Promise((resolve) => setTimeout(resolve, 25));
  await finished;
  assert.deepEqual(f.sent.filter((m) => m.id === 2), [original]);
  const internal = f.sent.find((m) => m.method === "config/read");
  f.bridge.writeOutput(JSON.stringify({ id: internal.id, result: { config: { key: "LATE_PRIVATE_FIXTURE" } } }) + "\n");
  assert.equal(f.visible.length, 0);
  f.bridge.close();
});

test("closing pending config releases endInput without forwarding stale requests", async () => {
  const f = fixture({ respond: () => undefined });
  f.bridge.writeInput('{"id":3,"method":"thread/start","params":{}}\n');
  const finished = f.bridge.endInput();
  await new Promise((resolve) => setImmediate(resolve));
  f.bridge.close();
  f.bridge.close();
  await finished;
  assert.equal(f.sent.filter((m) => m.id === 3).length, 0);
});

test("oversized native output remains byte-exact and does not block later output", () => {
  const output = [];
  const bridge = createHistoryRpcBridge({ send() {}, output: (b) => output.push(b) });
  const large = Buffer.alloc(8 * 1024 * 1024 + 1, 65);
  bridge.writeOutput(large);
  bridge.writeOutput(Buffer.from('\n{"method":"ready"}\n'));
  bridge.close();
  assert.deepEqual(Buffer.concat(output), Buffer.concat([large, Buffer.from('\n{"method":"ready"}\n')]));
});

for (const idFirst of [true, false]) {
  test(`oversized private config is hidden with its ID ${idFirst ? "before" : "after"} the secret`, async () => {
    const f = fixture({ respond: () => undefined });
    const original = { id: 12, method: "thread/start", params: { cwd: "/project" } };
    f.bridge.writeInput(JSON.stringify(original) + "\n");
    const finished = f.bridge.endInput();
    await new Promise((resolve) => setImmediate(resolve));
    const internal = f.sent.find((m) => m.method === "config/read");
    const encodedId = JSON.stringify(internal.id).replace("c", "\\u0063");
    const result = '"result":{"config":{"secret":"' + "PRIVATE_SECRET".repeat(750000) + '"}}';
    const response = Buffer.from(idFirst ? `{"id":${encodedId},${result}}\n` : `{${result},"id":${encodedId}}\n`);
    for (let start = 0; start < response.length; start += 32771) {
      f.bridge.writeOutput(response.subarray(start, start + 32771));
      assert.equal(f.visible.length, 0);
    }
    await finished;
    assert.deepEqual(f.sent.filter((m) => m.id === 12), [original]);
    f.bridge.writeOutput('{"method":"ready"}\n');
    assert.equal(Buffer.concat(f.visible).toString(), '{"method":"ready"}\n');
    f.bridge.close();
  });
}

test("late oversized internal IDs cannot expose secrets with a long suffix", async () => {
  const f = fixture({ respond: () => undefined, timeoutMs: 10 });
  f.bridge.writeInput('{"id":13,"method":"thread/start","params":{}}\n');
  const finished = f.bridge.endInput();
  await new Promise((resolve) => setTimeout(resolve, 25));
  await finished;
  const internal = f.sent.find((m) => m.method === "config/read");
  f.bridge.writeOutput(JSON.stringify({ result: { secret: "PRIVATE_SECRET".repeat(750000) }, id: internal.id + "x".repeat(5000) }) + "\n");
  f.bridge.close();
  assert.equal(f.visible.length, 0);
});

test("large ordinary history with a nested private-looking ID stays byte-exact", () => {
  const visible = [];
  const bridge = createHistoryRpcBridge({ send() {}, output: (chunk) => visible.push(chunk) });
  const body = Buffer.from(JSON.stringify({ result: {
    history: "历史\\\"".repeat(1100000), nested: { id: "codex-history-not-a-real-request" },
  }, id: 14 }) + "\n");
  assert(body.length > 8 * 1024 * 1024);
  for (let start = 0; start < body.length; start += 65537) bridge.writeOutput(body.subarray(start, start + 65537));
  assert(visible.every((chunk) => chunk.length <= 64 * 1024));
  bridge.close();
  assert.deepEqual(Buffer.concat(visible), body);
});

test("closing a partial oversized private response still hides its contents", async () => {
  const f = fixture({ respond: () => undefined });
  f.bridge.writeInput('{"id":15,"method":"thread/start","params":{}}\n');
  const finished = f.bridge.endInput();
  await new Promise((resolve) => setImmediate(resolve));
  const internal = f.sent.find((m) => m.method === "config/read");
  f.bridge.writeOutput('{"id":' + JSON.stringify(internal.id) + ',"result":{"secret":"' + "PRIVATE_SECRET".repeat(750000));
  f.bridge.close();
  await finished;
  assert.equal(f.visible.length, 0);
});

test("oversized spool setup stays private and cleans resources on failure", () => {
  const fs = require("node:fs");
  const originals = { mkdtempSync: fs.mkdtempSync, openSync: fs.openSync, unlinkSync: fs.unlinkSync };
  const directories = [];
  let failedUnlink = false;
  let descriptor;
  const visible = [];
  fs.mkdtempSync = (...args) => {
    const directory = originals.mkdtempSync(...args);
    directories.push(directory);
    assert.equal(fs.statSync(directory).mode & 0o777, 0o700);
    return directory;
  };
  fs.openSync = (...args) => {
    descriptor = originals.openSync(...args);
    assert.equal(fs.fstatSync(descriptor).mode & 0o777, 0o600);
    return descriptor;
  };
  fs.unlinkSync = (...args) => {
    if (!failedUnlink) { failedUnlink = true; throw new Error("synthetic unlink failure"); }
    return originals.unlinkSync(...args);
  };
  try {
    const bridge = createHistoryRpcBridge({ send() {}, output: (chunk) => visible.push(chunk) });
    bridge.writeOutput(Buffer.alloc(8 * 1024 * 1024 + 1, 65));
    bridge.close();
    assert.equal(visible.length, 0);
    assert.equal(directories.length, 1);
    assert(!fs.existsSync(directories[0]));
    assert.throws(() => fs.fstatSync(descriptor), { code: "EBADF" });
  } finally { Object.assign(fs, originals); }
});

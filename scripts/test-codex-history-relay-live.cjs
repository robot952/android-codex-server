"use strict";

// Real native Codex, synthetic persisted history, and a loopback-only provider.
// Never inherit credentials, read real sessions, or print request/history bodies.
const assert = require("node:assert/strict");
const { spawn } = require("node:child_process");
const fs = require("node:fs");
const http = require("node:http");
const os = require("node:os");
const path = require("node:path");
const readline = require("node:readline");

const binary = process.env.CODEX_TEST_BIN;
assert(binary, "Set CODEX_TEST_BIN to an installed Codex native binary");
assert(path.isAbsolute(binary), "Codex native binary path must be absolute");
fs.accessSync(binary, fs.constants.X_OK);

const root = path.resolve(__dirname, "..");
const home = fs.mkdtempSync(path.join(os.tmpdir(), "codex-history-relay-live-"));
const prefix = "c2a-msg-v1:";
const oldText = "Synthetic historical sub-agent result: compatibility fixture 中文正文.";
const oldEncoded = prefix + Buffer.from(oldText).toString("base64url");
const opaqueContent = "c2c:v1:synthetic-opaque-control";
const plainText = "Synthetic ordinary history content, preserved verbatim.";
const mislabelledText = "Your latest message arrived as an opaque gAAAA_SYNTHETIC token; I cannot read its instructions.";
const oldItem = {
  type: "agent_message",
  author: "/root/history_fixture_worker",
  recipient: "/root",
  content: [
    { type: "input_text", text: plainText },
    { type: "encrypted_content", encrypted_content: oldEncoded },
    { type: "encrypted_content", encrypted_content: opaqueContent },
    { type: "encrypted_content", encrypted_content: mislabelledText },
  ],
};
const liveItem = {
  type: "agent_message", author: "/root/live_fixture_worker", recipient: "/root",
  content: [{ type: "encrypted_content", encrypted_content: "The worker has finished: the synthetic checks passed.\n保留原文。" }],
};
let liveItemInjected = false;
const requests = [];
const fixtureErrors = [];
let upgrades = 0;
let activeClient;
let rejectNextResponse = false;

const sleep = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));
const quote = value => "'" + value.replaceAll("'", "'\"'\"'") + "'";

const api = http.createServer(async (request, response) => {
  try {
    if (request.method === "GET") {
      response.writeHead(200, { "content-type": "application/json" });
      response.end(JSON.stringify({ models: [], data: [] }));
      return;
    }
    if (request.method === "POST" && request.url === "/v1/analytics/codex/turn-costs") {
      request.resume();
      response.writeHead(200, { "content-type": "application/json" });
      response.end("{}");
      return;
    }
    assert.equal(request.method, "POST", "Unexpected fixture method");
    assert.equal(request.url, "/v1/responses", `Unexpected fixture route: ${request.url}`);
    const chunks = [];
    let length = 0;
    for await (const chunk of request) {
      length += chunk.length;
      assert(length <= 8 * 1024 * 1024, "Fixture request exceeds limit");
      chunks.push(chunk);
    }
    const body = JSON.parse(Buffer.concat(chunks, length).toString("utf8"));
    requests.push(body);
    const messages = body.input.filter(item => item?.type === "agent_message" &&
      item.author === oldItem.author && item.recipient === oldItem.recipient);
    assert.equal(messages.length, 1, "Native history must include the original agent_message");
    assert.deepEqual(messages[0].content, [
      { type: "input_text", text: plainText },
      { type: "input_text", text: oldText },
      { type: "encrypted_content", encrypted_content: opaqueContent },
      { type: "input_text", text: mislabelledText },
    ], "Only the malformed historical content should be normalized upstream");
    const liveMessages = body.input.filter(item => item?.type === "agent_message" && item.author === liveItem.author);
    assert.equal(liveMessages.length, liveItemInjected ? 1 : 0, "New child replies must remain in subsequent requests");
    if (liveItemInjected) {
      assert.equal(liveMessages[0].recipient, liveItem.recipient);
      assert.deepEqual(liveMessages[0].content, [{ type: "input_text", text: liveItem.content[0].encrypted_content }]);
    }
    assert.equal(body.model, "gpt-6-astra", "Relay must retain the selected model");
    if (rejectNextResponse) {
      rejectNextResponse = false;
      response.writeHead(400, { "content-type": "application/json" });
      response.end(JSON.stringify({ error: { message: "Upstream request failed", type: "invalid_request_error" } }));
      return;
    }
    const number = requests.length;
    const id = `resp-history-fixture-${number}`;
    const item = {
      type: "message", id: `msg-history-fixture-${number}`, role: "assistant", phase: "final_answer",
      content: [{ type: "output_text", text: `HISTORY_FIXTURE_OK_${number}` }],
    };
    response.writeHead(200, { "content-type": "text/event-stream" });
    const event = value => response.write(`data: ${JSON.stringify(value)}\n\n`);
    event({ type: "response.created", response: { id, model: body.model } });
    event({ type: "response.output_item.added", output_index: 0, item });
    event({ type: "response.output_item.done", output_index: 0, item });
    event({ type: "response.completed", response: { id, status: "completed", output: [item],
      usage: { input_tokens: 12, output_tokens: 3, total_tokens: 15,
        input_tokens_details: { cached_tokens: 2 } } } });
    response.end();
  } catch (error) {
    // Assertions can include synthetic bodies internally, but only emit a label.
    fixtureErrors.push(error);
    response.writeHead(400, { "content-type": "application/json" });
    response.end(JSON.stringify({ error: { message: "Synthetic history fixture rejected", type: "invalid_request_error" } }));
  }
});
api.on("upgrade", (request, socket) => {
  upgrades += 1;
  socket.end("HTTP/1.1 426 Upgrade Required\r\nConnection: close\r\nContent-Length: 0\r\n\r\n");
});

function client(command, args, environment) {
  const child = spawn(command, args, { cwd: home, env: environment, stdio: ["pipe", "pipe", "pipe"] });
  const pending = new Map();
  const events = [];
  let sequence = 0;
  let stderrBytes = 0;
  let launchError;
  const done = new Promise(resolve => {
    child.once("error", error => { launchError = error; resolve(); });
    child.once("exit", resolve);
  });
  child.stderr.on("data", data => { stderrBytes += data.length; });
  child.stdin.on("error", () => {});
  const reader = readline.createInterface({ input: child.stdout });
  reader.on("line", line => {
    let value;
    try { value = JSON.parse(line); } catch (_) { return; }
    const resolve = pending.get(value.id);
    if (resolve && !value.method) {
      pending.delete(value.id);
      resolve(value);
    } else events.push(value);
  });
  const write = message => child.stdin.write(`${JSON.stringify(message)}\n`);
  const rpc = (method, params) => new Promise((resolve, reject) => {
    const id = ++sequence;
    const timer = setTimeout(() => {
      pending.delete(id);
      reject(new Error(`Native RPC timed out: ${method}`));
    }, 12000);
    pending.set(id, value => {
      clearTimeout(timer);
      if (value.error) reject(new Error(`Native RPC rejected: ${method}; code=${value.error.code}; reason=${value.error.message}`));
      else resolve(value.result);
    });
    write({ id, method, params });
    void done.then(() => {
      if (!pending.delete(id)) return;
      clearTimeout(timer);
      reject(new Error(`Native exited during ${method}; launchError=${Boolean(launchError)}; stderrBytes=${stderrBytes}`));
    });
  });
  return {
    child, events, rpc,
    async initialize() {
      await rpc("initialize", { clientInfo: { name: "history_relay_fixture", version: "1" },
        capabilities: { experimentalApi: true } });
      write({ method: "initialized", params: {} });
    },
    async completed(threadId, turnId) {
      const deadline = Date.now() + 18000;
      while (Date.now() < deadline) {
        const event = events.find(value => value.method === "turn/completed" &&
          value.params?.threadId === threadId && value.params.turn?.id === turnId);
        if (event) return event.params.turn;
        if (launchError || child.exitCode !== null) throw new Error("Native exited before turn completion");
        await sleep(20);
      }
      throw new Error(`Native turn did not complete; requests=${requests.length}; fixtureErrors=${fixtureErrors.length}; stderrBytes=${stderrBytes}`);
    },
    async stop() {
      if (child.exitCode === null && !launchError) child.kill("SIGTERM");
      const timer = setTimeout(() => child.kill("SIGKILL"), 2000);
      timer.unref();
      await done;
      clearTimeout(timer);
      reader.close();
    },
  };
}

function rolloutPaths(directory) {
  if (!fs.existsSync(directory)) return [];
  return fs.readdirSync(directory, { withFileTypes: true }).flatMap(entry => {
    const filename = path.join(directory, entry.name);
    return entry.isDirectory() ? rolloutPaths(filename) : entry.isFile() && filename.endsWith(".jsonl") ? [filename] : [];
  });
}

function persistedOldItems(threadId) {
  const filenames = rolloutPaths(path.join(home, "sessions")).filter(filename => filename.includes(threadId));
  return filenames.flatMap(filename => fs.readFileSync(filename, "utf8").split("\n").flatMap(line => {
    if (!line) return [];
    const value = JSON.parse(line);
    return value.type === "response_item" && value.payload?.type === "agent_message" ? [value.payload] : [];
  }));
}

async function main() {
  try {
    await new Promise((resolve, reject) => { api.once("error", reject); api.listen(0, "127.0.0.1", resolve); });
    const baseUrl = `http://127.0.0.1:${api.address().port}/v1`;
    const overrides = {
      model_provider: "history_fixture", model: "gpt-6-astra",
      "model_providers.history_fixture.name": "Loopback history fixture only",
      "model_providers.history_fixture.base_url": baseUrl,
      "model_providers.history_fixture.wire_api": "responses",
      "model_providers.history_fixture.requires_openai_auth": false,
      "model_providers.history_fixture.supports_websockets": false,
      "features.shell_tool": false, "features.multi_agent": false,
      suppress_unstable_features_warning: true, "otel.log_user_prompt": false,
    };
    const args = Object.entries(overrides).flatMap(([key, value]) => ["-c", `${key}=${JSON.stringify(value)}`]);
    args.push("app-server", "--listen", "stdio://");
    const environment = {
      PATH: process.env.PATH, HOME: home, CODEX_HOME: home, RUST_LOG: "error",
      HTTP_PROXY: "http://127.0.0.1:9", HTTPS_PROXY: "http://127.0.0.1:9",
      http_proxy: "http://127.0.0.1:9", https_proxy: "http://127.0.0.1:9",
      NO_PROXY: "127.0.0.1,localhost", no_proxy: "127.0.0.1,localhost",
    };

    // Let the native server produce its own valid rollout and append raw items
    // through the documented experimental API, rather than guessing file layout.
    activeClient = client(binary, args, environment);
    await activeClient.initialize();
    const initial = await activeClient.rpc("thread/start", { cwd: home, approvalPolicy: "on-request", sandbox: "read-only" });
    const threadId = initial.thread.id;
    await activeClient.rpc("thread/inject_items", { threadId, items: [oldItem] });
    const persistDeadline = Date.now() + 4000;
    while (Date.now() < persistDeadline && !persistedOldItems(threadId).length) await sleep(20);
    const persistedFixture = persistedOldItems(threadId);
    assert.equal(persistedFixture.length, 1, "Native must persist exactly one old history fixture");
    assert.equal(persistedFixture[0].type, oldItem.type);
    assert.equal(persistedFixture[0].author, oldItem.author);
    assert.equal(persistedFixture[0].recipient, oldItem.recipient);
    assert.deepEqual(persistedFixture[0].content, oldItem.content, "Native must preserve injected historical content");
    await activeClient.stop();
    activeClient = null;
    assert.equal(requests.length, 0, "Fixture creation must not call a provider");

    const assets = ["codex-history-compat.cjs", "codex-history-proxy.cjs", "codex-history-relay.cjs", "codex-request-metrics.cjs"];
    const source = assets.map(filename => fs.readFileSync(path.join(root, "flutter_app/assets", filename), "utf8")).join("\n");
    const command = [binary, ...args].map(quote).join(" ");
    activeClient = client(process.execPath, ["-e", `${source}\nrunRelay(process.argv[1]).catch(() => { process.exitCode = 1; });`, command], environment);
    await activeClient.initialize();
    const resumed = await activeClient.rpc("thread/resume", { threadId, cwd: home, approvalPolicy: "on-request", sandbox: "read-only" });
    assert.equal(resumed.thread.id, threadId, "Relay must resume the same persisted thread");
    assert.equal(resumed.modelProvider, "history_fixture", "Relay must preserve provider selection");
    rejectNextResponse = true;
    const failedResult = await activeClient.rpc("turn/start", { threadId,
      input: [{ type: "text", text: "Synthetic HTTP 400 recovery request." }] });
    const failedTurn = await activeClient.completed(threadId, failedResult.turn.id);
    assert.equal(failedTurn.status, "failed", "HTTP 400 must terminate the failed turn");
    assert.equal(fixtureErrors.length, 0, "The failed request must still normalize its old history correctly");
    assert(activeClient.events.some(value => value.method === "error" &&
      value.params?.turnId === failedResult.turn.id && value.params.willRetry === false),
    "HTTP 400 must report a terminal error instead of retrying indefinitely");
    await sleep(200);
    assert.equal(requests.length, 1, "HTTP 400 must not automatically retry the invalid request");
    for (let number = 1; number <= 2; number += 1) {
      if (number === 2) {
        await activeClient.rpc("thread/inject_items", { threadId, items: [liveItem] });
        liveItemInjected = true;
      }
      const result = await activeClient.rpc("turn/start", { threadId,
        input: [{ type: "text", text: `Synthetic continued request ${number}.` }] });
      const turn = await activeClient.completed(threadId, result.turn.id);
      assert.equal(turn.status, "completed", `Continued turn ${number} must complete`);
      assert.equal(fixtureErrors.length, 0, `Continued turn ${number} failed fixture validation: ${
        fixtureErrors[0]?.message.split("\n")[0] || "unknown"}`);
      assert(activeClient.events.some(value => value.method === "item/completed" &&
        value.params?.turnId === result.turn.id && value.params.item?.text === `HISTORY_FIXTURE_OK_${number + 1}`),
      `Continued turn ${number} must deliver its assistant response`);
    }
    assert.equal(requests.length, 3, "One failed and two continued turns must make exactly three provider requests");
    // Exercise native cross-turn item cursors (not a mocked cursor codec),
    // oversized message previews, and exclusive-anchor detail reads.
    for (let index = 0; index < 10; index++) {
      const turn = await activeClient.rpc("turn/start", { threadId,
        input: [{ type: "text", text: `Synthetic large history input ${index}: ` + "x".repeat(6000) }] });
      assert.equal((await activeClient.completed(threadId, turn.turn.id)).status, "completed");
    }
    const nativeItems = await activeClient.rpc("thread/items/list", { threadId, limit: 100, sortDirection: "desc" });
    assert(nativeItems.data.length > 20);
    const opened = await activeClient.rpc("codexRemote/history/open", { threadId, readOnly: true });
    let page = opened.initialTurnsPage;
    const projectedIds = [];
    do {
      assert(Buffer.byteLength(JSON.stringify(page)) <= 96 * 1024);
      for (const turn of page.data) projectedIds.push(...turn.items.toReversed().map(item => item.id));
      if (!page.nextCursor) break;
      page = await activeClient.rpc("codexRemote/history/page", { threadId, cursor: page.nextCursor });
    } while (true);
    assert.deepEqual(projectedIds, nativeItems.data.map(record => record.item.id));
    for (const record of [nativeItems.data[0], nativeItems.data[1], nativeItems.data.at(-1)]) {
      const detail = await activeClient.rpc("codexRemote/history/item", { threadId, turnId: record.turnId, itemId: record.item.id });
      assert.deepEqual(detail.data[0].items[0], record.item, "Native anchor must hydrate exactly this item");
    }
    const mobileResume = await activeClient.rpc("codexRemote/history/open", { threadId, approvalPolicy: "on-request" });
    assert.equal(mobileResume.thread.id, threadId);
    assert.equal(mobileResume.modelProvider, "history_fixture");
    assert.equal(mobileResume.initialTurnsPage.data.flatMap(turn => turn.items).length, 20);
    console.log(`Native item history: ${nativeItems.data.length} records paginated without gaps; tail response ${Buffer.byteLength(JSON.stringify(mobileResume))} bytes; exact detail anchors verified.`);
    const legacy = await activeClient.rpc("thread/start", { cwd: home, approvalPolicy: "on-request", sandbox: "read-only", historyMode: "legacy" });
    const legacyRead = await activeClient.rpc("codexRemote/history/open", { threadId: legacy.thread.id, readOnly: true });
    assert.equal(legacyRead.thread.id, legacy.thread.id);
    await activeClient.rpc("thread/inject_items", { threadId: legacy.thread.id, items: [oldItem, liveItem] });
    const legacyTurn = await activeClient.rpc("turn/start", { threadId: legacy.thread.id,
      input: [{ type: "text", text: "Synthetic legacy history request." }] });
    assert.equal((await activeClient.completed(legacy.thread.id, legacyTurn.turn.id)).status, "completed");
    await assert.rejects(activeClient.rpc("codexRemote/history/open", { threadId: legacy.thread.id, readOnly: true }),
      /code=-32601; reason=thread\/items\/list is not supported yet/);
    const populatedLegacy = await activeClient.rpc("thread/turns/list", { threadId: legacy.thread.id, limit: 1, sortDirection: "desc", itemsView: "full" });
    assert(populatedLegacy.data.flatMap(turn => turn.items).length >= 2);
    assert.equal(upgrades, 0, "Compatibility route must use the supported Responses transport");
    await activeClient.stop();
    activeClient = null;
    const persistedAfter = persistedOldItems(threadId);
    assert.deepEqual(persistedAfter.filter(item => item.author === oldItem.author), persistedFixture,
      "Compatibility must leave the original history intact");
    const persistedLive = persistedAfter.filter(item => item.author === liveItem.author);
    assert.equal(persistedLive.length, 1, "The live child reply must be persisted once");
    assert.equal(persistedLive[0].recipient, liveItem.recipient);
    assert.deepEqual(persistedLive[0].content, liveItem.content, "Request normalization must leave new persisted replies intact");
    console.log("Real Codex history relay: old and live child replies normalized; HTTP 400 terminated without retries; 2 consecutive replies after failure; opaque content and persisted history preserved.");
  } finally {
    if (activeClient) await activeClient.stop();
    api.closeAllConnections();
    await new Promise(resolve => api.close(resolve));
    fs.rmSync(home, { recursive: true, force: true });
  }
}

main().catch(error => {
  // Failure messages identify stages without reflecting native/user content.
  console.error(error.message);
  process.exitCode = 1;
});

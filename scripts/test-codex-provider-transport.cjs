"use strict";

// Real Codex plus loopback-only Responses. No user configuration or credentials.
const assert = require("node:assert/strict");
const { spawn } = require("node:child_process");
const fs = require("node:fs");
const http = require("node:http");
const path = require("node:path");
const readline = require("node:readline");

const binary = process.env.CODEX_PROVIDER_TRANSPORT_TEST_BIN;
assert(binary, "Set CODEX_PROVIDER_TRANSPORT_TEST_BIN to an installed Codex binary");
assert(path.isAbsolute(binary), "Codex binary path must be absolute");
fs.accessSync(binary, fs.constants.X_OK);
const root = path.resolve(__dirname, "..");
fs.mkdirSync(path.join(root, ".workflow-cache"), { recursive: true });
const temporary = fs.mkdtempSync(path.join(root, ".workflow-cache/provider-transport-"));
const cases = [
  { name: "baseline", upgrades: true, overrides: {} },
  { name: "feature-v2-disabled", upgrades: true, overrides: { "features.responses_websockets_v2": false } },
  { name: "provider-disabled-no-name", rejected: true, overrides: { "model_providers.openai.supports_websockets": false } },
  { name: "provider-disabled-with-name", rejected: true, overrides: {
    "model_providers.openai.name": "OpenAI",
    "model_providers.openai.supports_websockets": false,
  } },
  { name: "both-features-disabled", upgrades: true, overrides: {
    "features.responses_websockets": false,
    "features.responses_websockets_v2": false,
  } },
  { name: "thread-provider-disabled", rejected: true, overrides: {}, threadConfig: {
    "model_providers.openai.name": "OpenAI",
    "model_providers.openai.supports_websockets": false,
  } },
  { name: "custom-provider-disabled", provider: "transport_fixture", upgrades: false, overrides: {
    model_provider: "transport_fixture",
    "model_providers.transport_fixture.name": "Loopback transport test",
    "model_providers.transport_fixture.requires_openai_auth": false,
    "model_providers.transport_fixture.supports_websockets": false,
  } },
];
let active;
const api = http.createServer(async (req, res) => {
  try {
    assert(active, "Request outside a scenario");
    if (req.method === "GET") {
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ models: [], data: [] }));
      return;
    }
    assert.equal(req.url, "/v1/responses");
    const chunks = [];
    let bytes = 0;
    for await (const chunk of req) {
      bytes += chunk.length;
      assert(bytes < 8 * 1024 * 1024, "Fixture request too large");
      chunks.push(chunk);
    }
    const body = JSON.parse(Buffer.concat(chunks).toString());
    active.http += 1;
    const id = `resp-${active.http}`;
    const item = { type: "message", id: `msg-${active.http}`, role: "assistant", phase: "final_answer",
      content: [{ type: "output_text", text: "TRANSPORT_FIXTURE_OK" }] };
    res.writeHead(200, { "content-type": "text/event-stream" });
    const event = value => res.write(`data: ${JSON.stringify(value)}\n\n`);
    event({ type: "response.created", response: { id, model: body.model } });
    event({ type: "response.output_item.added", output_index: 0, item });
    event({ type: "response.output_item.done", output_index: 0, item });
    event({ type: "response.completed", response: { id, status: "completed", output: [item],
      usage: { input_tokens: 1, output_tokens: 1, total_tokens: 2,
        input_tokens_details: { cached_tokens: 0 } } } });
    res.end();
  } catch (error) {
    res.writeHead(500);
    res.end(String(error));
  }
});
api.on("upgrade", (req, socket) => {
  if (active) active.upgrades += 1;
  socket.end("HTTP/1.1 426 Upgrade Required\r\nConnection: close\r\nContent-Length: 0\r\n\r\n");
});

async function scenario(test, port) {
  const home = path.join(temporary, test.name);
  fs.mkdirSync(home, { mode: 0o700 });
  fs.writeFileSync(path.join(home, "auth.json"), JSON.stringify({ OPENAI_API_KEY: "fixture-not-a-real-key" }), { mode: 0o600 });
  const overrides = {
    model: "gpt-6-astra", openai_base_url: `http://127.0.0.1:${port}/v1`,
    "features.shell_tool": false, "features.multi_agent": false,
    suppress_unstable_features_warning: true, ...test.overrides,
  };
  if (test.provider) overrides[`model_providers.${test.provider}.base_url`] = `http://127.0.0.1:${port}/v1`;
  const args = Object.entries(overrides).flatMap(([key, value]) => ["-c", `${key}=${JSON.stringify(value)}`]);
  args.push("app-server", "--listen", "stdio://");
  const child = spawn(binary, args, {
    cwd: home,
    env: { PATH: process.env.PATH, HOME: home, CODEX_HOME: home, RUST_LOG: "error",
      HTTP_PROXY: "http://127.0.0.1:9", HTTPS_PROXY: "http://127.0.0.1:9", NO_PROXY: "127.0.0.1,localhost" },
    stdio: ["pipe", "pipe", "pipe"],
  });
  active = { name: test.name, http: 0, upgrades: 0 };
  const messages = [];
  const pending = new Map();
  let stderr = "";
  let sequence = 0;
  child.stderr.on("data", data => { stderr = (stderr + data).slice(-16000); });
  child.stdin.on("error", () => {});
  const childDone = new Promise(resolve => child.once("exit", resolve));
  readline.createInterface({ input: child.stdout }).on("line", line => {
    let value;
    try { value = JSON.parse(line); } catch { return; }
    if (pending.has(value.id)) {
      pending.get(value.id)(value);
      pending.delete(value.id);
    } else messages.push(value);
  });
  const rpc = (method, params) => new Promise((resolve, reject) => {
    const id = ++sequence;
    const timer = setTimeout(() => { pending.delete(id); reject(new Error(`${method} timed out`)); }, 8000);
    pending.set(id, value => {
      clearTimeout(timer);
      value.error ? reject(new Error(JSON.stringify(value.error))) : resolve(value.result);
    });
    child.stdin.write(`${JSON.stringify({ id, method, params })}\n`);
    void childDone.then(() => {
      if (!pending.has(id)) return;
      pending.delete(id);
      clearTimeout(timer);
      reject(new Error(`Codex exited during ${method}`));
    });
  });
  const waitFor = async predicate => {
    const deadline = Date.now() + 18000;
    while (Date.now() < deadline) {
      const result = messages.find(predicate);
      if (result) return result;
      if (child.exitCode !== null) throw new Error(`Codex exited ${child.exitCode}`);
      await new Promise(resolve => setTimeout(resolve, 20));
    }
    throw new Error("No completed turn");
  };
  try {
    await rpc("initialize", { clientInfo: { name: "transport_fixture", version: "1" },
      capabilities: { experimentalApi: true } });
    child.stdin.write(`${JSON.stringify({ method: "initialized", params: {} })}\n`);
    const result = await rpc("thread/start", { cwd: home, approvalPolicy: "on-request", sandbox: "read-only",
      config: test.threadConfig });
    active.provider = result.thread.modelProvider;
    await rpc("turn/start", { threadId: result.thread.id,
      input: [{ type: "text", text: "Return the fixture result." }] });
    const completion = await waitFor(value => value.method === "turn/completed" && value.params.threadId === result.thread.id);
    active.status = completion.params.turn.status;
    active.finalReceived = messages.some(value => value.method === "item/completed" &&
      value.params.item?.text === "TRANSPORT_FIXTURE_OK");
    active.warnings = messages.filter(value => value.method === "warning").map(value => value.params.message);
  } catch (error) {
    active.error = String(error);
    active.stderr = stderr.slice(-2500);
  } finally {
    child.kill("SIGTERM");
    const killTimer = setTimeout(() => child.kill("SIGKILL"), 2000);
    await childDone;
    clearTimeout(killTimer);
  }
  const evidence = active;
  active = undefined;
  console.log(JSON.stringify(evidence));
  return evidence;
}

async function main() {
  await new Promise((resolve, reject) => {
    api.once("error", reject);
    api.listen(0, "127.0.0.1", resolve);
  });
  try {
    const results = [];
    for (const test of cases) {
      const result = await scenario(test, api.address().port);
      results.push(result);
      if (test.rejected) {
        assert(result.error, `${test.name}: reserved provider override must fail`);
        assert.match(`${result.error}\n${result.stderr}`, /Built-in providers cannot be overridden/);
        assert.equal(result.http, 0);
        assert.equal(result.upgrades, 0);
      } else {
        assert.equal(result.error, undefined, `${test.name}: unexpected failure`);
        assert.equal(result.provider, test.provider || "openai");
        assert.equal(result.status, "completed");
        assert.equal(result.finalReceived, true);
        assert.equal(result.http, 1);
        assert.equal(result.upgrades > 0, test.upgrades);
      }
    }
    fs.writeFileSync(path.join(root, ".workflow-cache/provider-transport-latest.json"), JSON.stringify(results, null, 2));
  } finally {
    api.closeAllConnections();
    await new Promise(resolve => api.close(resolve));
    fs.rmSync(temporary, { recursive: true, force: true });
  }
}

main().catch(error => { console.error(error); process.exitCode = 1; });

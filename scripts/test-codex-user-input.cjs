"use strict";

// Real Codex core + loopback-only synthetic Responses server. No credentials or
// external model calls. --serve keeps the fixture alive for Android UI testing.
const assert = require("node:assert/strict");
const { spawn } = require("node:child_process");
const fs = require("node:fs");
const http = require("node:http");
const net = require("node:net");
const os = require("node:os");
const path = require("node:path");
const readline = require("node:readline");

const binary = process.env.CODEX_USER_INPUT_TEST_BIN;
assert(binary, "Set CODEX_USER_INPUT_TEST_BIN to a real Codex executable");
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), "codex-question-test-"));
const questions = [{
  id: "drink", header: "饮品", question: "你今天更想喝哪种饮品？",
  isOther: true, isSecret: false,
  options: [{ label: "茶", description: "测试选项，不会购买任何商品。" },
    { label: "白开水", description: "另一个测试选项。" }],
}];
const requests = [];
const messages = [];
const pending = new Map();
let child;
let stderr = "";
let sequence = 0;
let stopping = false;

async function listen(server) {
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  return server.address().port;
}

const api = http.createServer(async (req, res) => {
  try {
    const chunks = [];
    let bytes = 0;
    for await (const chunk of req) {
      bytes += chunk.length;
      assert(bytes <= 8 * 1024 * 1024, "Fixture request too large");
      chunks.push(chunk);
    }
    const body = JSON.parse(Buffer.concat(chunks).toString());
    requests.push(body);
    const input = body.input || [];
    const lastUser = input.findLastIndex(x => x.role === "user");
    const outputs = input.slice(lastUser + 1).filter(x => x.type === "function_call_output");
    const output = outputs.at(-1);
    const item = output ? {
      type: "message", id: "msg-question", role: "assistant", phase: "final_answer",
      content: [{ type: "output_text", text: `QUESTION_RESULT ${output.output}` }],
    } : {
      type: "function_call", id: "fc-question", call_id: "call-question",
      name: "request_user_input", arguments: JSON.stringify({ questions }),
    };
    const id = `resp-question-${requests.length}`;
    res.writeHead(200, { "content-type": "text/event-stream" });
    const event = value => res.write(`data: ${JSON.stringify(value)}\n\n`);
    event({ type: "response.created", response: { id, model: body.model } });
    event({ type: "response.output_item.added", output_index: 0, item });
    event({ type: "response.output_item.done", output_index: 0, item });
    event({ type: "response.completed", response: {
      id, status: "completed", output: [item],
      usage: { input_tokens: 1, output_tokens: 1, total_tokens: 2,
        input_tokens_details: { cached_tokens: 0 } },
    } });
    res.end();
  } catch (error) {
    res.writeHead(500);
    res.end(String(error));
  }
});

function send(value) { child.stdin.write(`${JSON.stringify(value)}\n`); }
function rpc(method, params) {
  const id = ++sequence;
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      pending.delete(id);
      reject(new Error(`Timed out: ${method}\n${stderr.slice(-2500)}`));
    }, 15000);
    pending.set(id, value => {
      clearTimeout(timer);
      value.error ? reject(new Error(JSON.stringify(value.error))) : resolve(value.result);
    });
    send({ id, method, params });
  });
}

async function waitFor(predicate) {
  const deadline = Date.now() + 20000;
  while (Date.now() < deadline) {
    const match = messages.find(predicate);
    if (match) return match;
    await new Promise(resolve => setTimeout(resolve, 20));
  }
  throw new Error(`Timed out waiting for question/turn\n${stderr.slice(-2500)}`);
}

function start(apiPort, websocketPort) {
  const overrides = {
    model_provider: "question_fixture", model: "fixture-model",
    "model_providers.question_fixture.name": "Loopback test only",
    "model_providers.question_fixture.base_url": `http://127.0.0.1:${apiPort}/v1`,
    "model_providers.question_fixture.wire_api": "responses",
    "model_providers.question_fixture.requires_openai_auth": false,
    "model_providers.question_fixture.supports_websockets": false,
    "features.default_mode_request_user_input": false,
    "features.shell_tool": false,
  };
  const args = Object.entries(overrides).flatMap(([key, value]) => ["-c", `${key}=${JSON.stringify(value)}`]);
  args.push("app-server", "--listen", websocketPort ? `ws://127.0.0.1:${websocketPort}` : "stdio://");
  child = spawn(binary, args, {
    cwd: temporary,
    // Deliberately do not inherit provider keys, HOME or proxy environment.
    env: { PATH: process.env.PATH, HOME: temporary, CODEX_HOME: temporary, RUST_LOG: "error" },
    stdio: ["pipe", "pipe", "pipe"],
  });
  child.stderr.on("data", chunk => { stderr = (stderr + chunk).slice(-16000); });
  child.on("error", error => { stderr += String(error); });
  readline.createInterface({ input: child.stdout }).on("line", line => {
    let value;
    try { value = JSON.parse(line); } catch { return; }
    if (!value.method && pending.has(value.id)) {
      pending.get(value.id)(value);
      pending.delete(value.id);
    } else messages.push(value);
  });
}

async function stop() {
  if (stopping) return;
  stopping = true;
  if (child && child.exitCode === null) {
    child.kill("SIGTERM");
    await new Promise(resolve => {
      const killTimer = setTimeout(() => child.kill("SIGKILL"), 2000);
      child.once("exit", () => { clearTimeout(killTimer); resolve(); });
    });
  }
  api.closeAllConnections();
  await new Promise(resolve => api.close(resolve));
  fs.rmSync(temporary, { recursive: true, force: true });
}

async function main() {
  const apiPort = await listen(api);
  if (process.argv.includes("--serve")) {
    const probe = net.createServer();
    const port = await listen(probe);
    await new Promise(resolve => probe.close(resolve));
    start(apiPort, port);
    console.log(`CODEX_QUESTION_WS_PORT=${port}`);
    for (const signal of ["SIGINT", "SIGTERM"]) process.on(signal, () => void stop());
    // Hard limit: do not leave an unattended fixture running indefinitely.
    setTimeout(() => void stop(), 15 * 60 * 1000).unref();
    return;
  }
  try {
    start(apiPort);
    await rpc("initialize", { clientInfo: { name: "question_fixture", version: "1" },
      capabilities: { experimentalApi: true } });
    send({ method: "initialized", params: {} });
    for (const enabled of [false, true]) {
      const result = await rpc("thread/start", {
        cwd: temporary, approvalPolicy: "on-request", sandbox: "read-only",
        config: { "features.default_mode_request_user_input": enabled },
      });
      const threadId = result.thread.id;
      await rpc("turn/start", { threadId, input: [{ type: "text", text: "Ask the fixture question." }] });
      if (enabled) {
        const question = await waitFor(x => x.method === "item/tool/requestUserInput" && x.params.threadId === threadId);
        assert.deepEqual(question.params.questions, questions);
        send({ id: question.id, result: { answers: { drink: { answers: ["茶"] } } } });
      }
      await waitFor(x => x.method === "turn/completed" && x.params.threadId === threadId);
      const modelResult = requests.at(-1).input.findLast(x => x.type === "function_call_output").output;
      if (enabled) assert.match(modelResult, /茶/);
      else {
        assert.match(modelResult, /unavailable in Default mode/);
        assert(!messages.some(x => x.method === "item/tool/requestUserInput" && x.params.threadId === threadId));
      }
      console.log(`Real Codex Default mode: feature=${enabled}, ${enabled ? "question answered" : "restriction reproduced"}`);
      if (!enabled) {
        await rpc("thread/unsubscribe", { threadId });
        await rpc("thread/resume", { threadId,
          config: { "features.default_mode_request_user_input": true } });
        // Start a new user turn; only answer outputs after its last user input
        // belong to the synthetic model's current turn.
        await rpc("turn/start", { threadId, input: [{ type: "text", text: "Ask again after resume." }] });
        const question = await waitFor(x => x.method === "item/tool/requestUserInput" && x.params.threadId === threadId);
        send({ id: question.id, result: { answers: { drink: { answers: ["白开水"] } } } });
        await waitFor(x => x.method === "turn/completed" && x.params.threadId === threadId && x.params.turn.id === question.params.turnId);
        assert.match(requests.at(-1).input.findLast(x => x.type === "function_call_output").output, /白开水/);
        console.log("Real Codex resumed thread: Default question override applied");
      }
    }
  } finally { await stop(); }
}
main().catch(async error => { console.error(error); process.exitCode = 1; await stop(); });

"use strict";
// Isolated, loopback-only probe. Never inherit credentials or the user's HOME.
const { spawn } = require("node:child_process");
const fs = require("node:fs");
const http = require("node:http");
const os = require("node:os");
const path = require("node:path");
const readline = require("node:readline");
const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const websocket = process.argv.includes("--ws");
const relay = path.resolve(__dirname, "../flutter_app/assets/codex-request-metrics.cjs");
assert(process.env.CODEX_TEST_BIN, "Set CODEX_TEST_BIN to an installed Codex binary; this fixture uses no credentials");
const home = fs.mkdtempSync(path.join(os.tmpdir(), "codex-timing-fixture-"));
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const pending = new Map();
const events = [];
let child;
let seq = 0;
let stderr = "";
let calls = 0;
const listen = server => new Promise(resolve => server.listen(0, "127.0.0.1", () => resolve(server.address().port)));
async function respond(request, event) {
  const id = `resp-fixture-${++calls}`;
  await sleep(150);
  event({ type: "response.created", response: { id, model: request.model } });
  const item = { type: "message", id: "msg-fixture", role: "assistant", phase: "final_answer", content: [] };
  event({ type: "response.output_item.added", output_index: 0, item });
  await sleep(200);
  event({ type: "response.output_text.delta", item_id: item.id, output_index: 0, content_index: 0, delta: "Hello" });
  await sleep(300);
  item.content = [{ type: "output_text", text: "Hello" }];
  event({ type: "response.output_item.done", output_index: 0, item });
  event({ type: "response.completed", response: { id, status: "completed", output: [item],
    usage: { input_tokens: 2, output_tokens: 1, total_tokens: 3, input_tokens_details: { cached_tokens: 0 } } } });
}
const api = http.createServer(async (req, res) => {
  let body = "";
  for await (const chunk of req) body += chunk;
  const request = JSON.parse(body);
  res.writeHead(200, { "content-type": "text/event-stream" });
  const event = value => res.write(`data: ${JSON.stringify(value)}\n\n`);
  await respond(request, event);
  res.end();
});
const sockets = new Set();
api.on("upgrade", (req, socket, head) => {
  sockets.add(socket);
  socket.once("close", () => sockets.delete(socket));
  const accept = crypto.createHash("sha1").update(req.headers["sec-websocket-key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest("base64");
  socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
  let buffer = head;
  const event = value => {
    const payload = Buffer.from(JSON.stringify(value));
    const header = Buffer.alloc(payload.length < 126 ? 2 : 4);
    header[0] = 0x81;
    if (header.length === 2) header[1] = payload.length;
    else { header[1] = 126; header.writeUInt16BE(payload.length, 2); }
    socket.write(Buffer.concat([header, payload]));
  };
  socket.on("data", chunk => {
    buffer = Buffer.concat([buffer, chunk]);
    while (buffer.length >= 2) {
      const opcode = buffer[0] & 15;
      const masked = buffer[1] & 128;
      let length = buffer[1] & 127;
      let offset = 2;
      if (length === 126) { if (buffer.length < 4) return; length = buffer.readUInt16BE(2); offset = 4; }
      if (length === 127) { if (buffer.length < 10) return; length = Number(buffer.readBigUInt64BE(2)); offset = 10; }
      assert(length <= 8 * 1024 * 1024);
      if (buffer.length < offset + (masked ? 4 : 0) + length) return;
      const mask = buffer.subarray(offset, offset + 4);
      if (masked) offset += 4;
      const payload = Buffer.from(buffer.subarray(offset, offset + length));
      if (masked) for (let i = 0; i < payload.length; i++) payload[i] ^= mask[i % 4];
      buffer = buffer.subarray(offset + length);
      if (opcode === 8) { socket.end(); return; }
      if (opcode === 1) void respond(JSON.parse(payload.toString()), event);
    }
  });
});
function send(message) { child.stdin.write(JSON.stringify(message) + "\n"); }
function rpc(method, params) {
  return new Promise((resolve, reject) => {
    const id = ++seq;
    const timer = setTimeout(() => reject(new Error("RPC timeout " + method)), 10000);
    pending.set(id, message => { clearTimeout(timer); message.error ? reject(new Error(JSON.stringify(message.error))) : resolve(message.result); });
    send({ id, method, params });
  });
}
async function main() {
  try {
    const apiPort = await listen(api);
    const overrides = {
      model_provider: "fixture", model: "gpt-6-astra",
      "model_providers.fixture.name": "Loopback fixture only",
      "model_providers.fixture.base_url": `http://127.0.0.1:${apiPort}/v1`,
      "model_providers.fixture.wire_api": "responses",
      "model_providers.fixture.requires_openai_auth": false,
      "model_providers.fixture.supports_websockets": websocket,
      "features.shell_tool": false,
      "otel.log_user_prompt": false,
    };
    const args = Object.entries(overrides).flatMap(([key, value]) => ["-c", `${key}=${JSON.stringify(value)}`]);
    args.push("app-server", "--listen", "stdio://");
    const quote = value => "'" + value.replaceAll("'", "'\"'\"'") + "'";
    const command = [process.env.CODEX_TEST_BIN, ...args].map(quote).join(" ");
    child = spawn(process.execPath, [relay, command], { cwd: home, stdio: ["pipe", "pipe", "pipe"],
      env: { PATH: process.env.PATH, HOME: home, CODEX_HOME: home, RUST_LOG: "error",
        HTTP_PROXY: "http://127.0.0.1:9", HTTPS_PROXY: "http://127.0.0.1:9", NO_PROXY: "127.0.0.1,localhost" } });
    child.stderr.on("data", data => { stderr = (stderr + data).slice(-8000); });
    const reader = readline.createInterface({ input: child.stdout });
    reader.on("line", line => {
      const message = JSON.parse(line);
      if (!message.method && pending.has(message.id)) { pending.get(message.id)(message); pending.delete(message.id); }
      else events.push(message);
    });
    await rpc("initialize", { clientInfo: { name: "timing_fixture", version: "1" }, capabilities: { experimentalApi: true } });
    send({ method: "initialized", params: {} });
    const result = await rpc("thread/start", { cwd: home, approvalPolicy: "on-request", sandbox: "read-only" });
    assert.equal(result.modelProvider, "fixture", "Relay must preserve the configured provider");
    assert.equal(result.model, "gpt-6-astra", "Relay must preserve the configured model");
    await rpc("turn/start", { threadId: result.thread.id, input: [{ type: "text", text: "Say hello." }] });
    // Simulate a backgrounded phone that cannot consume its SSH stream yet.
    reader.pause();
    await sleep(3000);
    reader.resume();
    for (let i = 0; i < 200 && !events.some(x => x.method === "turn/completed"); i++) await sleep(50);
    for (let i = 0; i < 120 && !events.some(x => x.method === "thread/requestMetrics/updated"); i++) await sleep(50);
    assert(events.some(x => x.method === "turn/completed"), `fixture should complete; calls=${calls}; events=${JSON.stringify(events)}; stderr=${stderr}`);
    const metrics = events.filter(x => x.method === "thread/requestMetrics/updated").at(-1)?.params.requestMetrics;
    assert(metrics, `Missing server timing: ${stderr.slice(-2500)}`);
    assert(metrics.firstTokenMillis >= 300 && metrics.firstTokenMillis < 1200, JSON.stringify(metrics));
    assert(metrics.durationMillis >= 600 && metrics.durationMillis < 1600, JSON.stringify(metrics));
    assert.equal(metrics.source, "server");
    assert.equal(metrics.model, "gpt-6-astra");
    console.log(`${websocket ? "WebSocket" : "HTTPS/SSE"} real Codex + server relay: TTFT=${metrics.firstTokenMillis}ms, duration=${metrics.durationMillis}ms; 3000ms delayed phone reader excluded`);
  } finally {
    if (child && child.exitCode === null) {
      child.kill("SIGTERM");
      await new Promise(resolve => { const timer = setTimeout(() => { child.kill("SIGKILL"); resolve(); }, 2000); child.once("exit", () => { clearTimeout(timer); resolve(); }); });
    }
    for (const socket of sockets) socket.destroy();
    api.closeAllConnections();
    await new Promise(r => api.close(r));
    fs.rmSync(home, { recursive: true, force: true });
  }
}
main().catch(error => { console.error(error); process.exitCode = 1; });

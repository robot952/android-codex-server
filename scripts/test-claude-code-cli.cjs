"use strict";

// Real Claude CLI, isolated credentials/configuration, and a local Anthropic SSE
// fixture. No model service or user Claude session is used by this test.
const assert = require("node:assert/strict");
const { spawn } = require("node:child_process");
const fs = require("node:fs");
const http = require("node:http");
const os = require("node:os");
const path = require("node:path");
const readline = require("node:readline");

const repository = path.resolve(__dirname, "..");
const bridgePath = path.join(repository, "flutter_app/assets/claude-code-bridge.cjs");
const claudeBin = process.env.CLAUDE_CODE_TEST_BIN;
assert(claudeBin, "Set CLAUDE_CODE_TEST_BIN to an installed Claude Code executable");
const temporaryRoot = fs.mkdtempSync(path.join(os.tmpdir(), "claude-bridge-cli-"));
const workspace = path.join(temporaryRoot, "workspace");
const fixtureKey = "claude-bridge-fixture-not-real";
const requests = [];
let messageSequence = 0;
fs.mkdirSync(workspace);

function contentBlocks(message) {
  return Array.isArray(message.content)
    ? message.content
    : [{ type: "text", text: String(message.content || "") }];
}

function respondMessage(response, input, content) {
  const id = `msg_fixture_${++messageSequence}`;
  const message = {
    id, type: "message", role: "assistant", model: "claude-sonnet-4-6",
    content: [content], stop_reason: content.type === "tool_use" ? "tool_use" : "end_turn",
    stop_sequence: null, usage: { input_tokens: 10, output_tokens: 10 },
  };
  if (!input.stream) {
    response.writeHead(200, { "content-type": "application/json" });
    response.end(JSON.stringify(message));
    return;
  }
  response.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-cache" });
  const event = (type, value) => {
    response.write(`event: ${type}\ndata: ${JSON.stringify({ type, ...value })}\n\n`);
  };
  event("message_start", { message: {
    ...message, content: [], stop_reason: null,
    usage: { input_tokens: 10, output_tokens: 0 },
  } });
  event("content_block_start", { index: 0, content_block: content.type === "tool_use"
    ? { ...content, input: {} } : { type: "text", text: "" } });
  event("content_block_delta", { index: 0, delta: content.type === "tool_use"
    ? { type: "input_json_delta", partial_json: JSON.stringify(content.input) }
    : { type: "text_delta", text: content.text } });
  event("content_block_stop", { index: 0 });
  event("message_delta", { delta: { stop_reason: message.stop_reason, stop_sequence: null }, usage: { output_tokens: 10 } });
  event("message_stop", {});
  response.end();
}

const apiServer = http.createServer((request, response) => {
  let bytes = 0;
  const chunks = [];
  request.on("data", chunk => {
    bytes += chunk.length;
    if (bytes > 8 * 1024 * 1024) request.destroy(new Error("Fixture request too large"));
    else chunks.push(chunk);
  });
  request.on("end", () => {
    try {
      const body = Buffer.concat(chunks).toString("utf8");
      const input = body ? JSON.parse(body) : {};
      if (request.url.includes("count_tokens")) {
        response.writeHead(200, { "content-type": "application/json" });
        response.end(JSON.stringify({ input_tokens: 10 }));
        return;
      }
      if (!request.url.startsWith("/v1/messages")) {
        response.writeHead(404, { "content-type": "application/json" });
        response.end("{}");
        return;
      }
      assert.equal(request.headers["x-api-key"], fixtureKey);
      const messages = input.messages || [];
      let mode, promptIndex = -1;
      for (let index = messages.length - 1; index >= 0; index--) {
        const match = contentBlocks(messages[index])
          .map(block => block.text || "").join("\n")
          .match(/CLAUDE_BRIDGE_FIXTURE:(allow|deny|interrupt|image|resume)/);
        if (match) { mode = match[1]; promptIndex = index; break; }
      }
      assert(mode, "Model request did not contain the controlled prompt");
      requests.push({ mode, input });
      const hasResult = messages.slice(promptIndex + 1)
        .some(message => contentBlocks(message).some(block => block.type === "tool_result"));
      const content = mode === "resume" || hasResult
        ? { type: "text", text: `CLAUDE_BRIDGE_${mode.toUpperCase()}_OK` }
        : { type: "tool_use", id: `toolu_fixture_${mode}`, name: "Write", input: {
          file_path: path.join(workspace, `${mode}.txt`),
          content: `Only the approved ${mode} fixture may write this file.\n`,
        } };
      respondMessage(response, input, content);
    } catch (error) {
      response.writeHead(500, { "content-type": "application/json" });
      response.end(JSON.stringify({ error: { type: "api_error", message: String(error) } }));
    }
  });
});

class BridgePeer {
  constructor(apiPort) {
    this.messages = [];
    this.waiters = new Set();
    this.pending = new Map();
    this.nextId = 1;
    this.stderr = "";
    this.approvalAction = null;
    // Deliberately do not inherit provider credentials, proxies, or CLAUDECODE.
    this.process = spawn(process.execPath, [bridgePath, "--directory", workspace], {
      cwd: workspace,
      env: {
        PATH: process.env.PATH, HOME: temporaryRoot, USER: "claude-bridge-fixture",
        CLAUDE_BIN: claudeBin,
        CLAUDE_CONFIG_DIR: path.join(temporaryRoot, "claude-config"),
        CODEX_REMOTE_CLAUDE_STATE: path.join(temporaryRoot, "bridge-state.json"),
        ANTHROPIC_API_KEY: fixtureKey, ANTHROPIC_BASE_URL: `http://127.0.0.1:${apiPort}`,
        CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: "1", DISABLE_AUTOUPDATER: "1", DISABLE_TELEMETRY: "1",
      },
      stdio: ["pipe", "pipe", "pipe"],
    });
    this.exit = new Promise(resolve => this.process.once("close", (code, signal) => {
      this.closed = true;
      for (const waiter of this.waiters) waiter.reject(new Error(`Bridge exited ${code}/${signal}: ${this.stderr}`));
      for (const waiter of this.pending.values()) waiter.reject(new Error(`Bridge exited ${code}/${signal}: ${this.stderr}`));
      resolve({ code, signal });
    }));
    this.process.stderr.on("data", chunk => { this.stderr = (this.stderr + chunk).slice(-8000); });
    this.process.stdin.on("error", () => {});
    readline.createInterface({ input: this.process.stdout, crlfDelay: Infinity }).on("line", line => {
      let message;
      try { message = JSON.parse(line); } catch { return; }
      this.messages.push(message);
      if (message.id != null && !message.method) {
        const waiter = this.pending.get(message.id);
        if (waiter) {
          this.pending.delete(message.id);
          if (message.error) waiter.reject(new Error(JSON.stringify(message.error)));
          else waiter.resolve(message.result);
        }
      }
      if (message.method === "item/permissions/requestApproval" && this.approvalAction) {
        const action = this.approvalAction;
        if (action === "accept" || action === "decline") {
          this.send({ id: message.id, result: {
            permissions: action === "accept" ? message.params.permissions : {}, scope: "turn",
          } });
        }
      }
      for (const waiter of [...this.waiters]) {
        if (waiter.predicate(message)) { this.waiters.delete(waiter); waiter.resolve(message); }
      }
    });
  }

  send(message) { this.process.stdin.write(JSON.stringify(message) + "\n"); }

  rpc(method, params = {}) {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`RPC timeout: ${method}\n${this.stderr}`));
      }, 20000);
      this.pending.set(id, {
        resolve: result => { clearTimeout(timer); resolve(result); },
        reject: error => { clearTimeout(timer); reject(error); },
      });
      this.send({ id, method, params });
    });
  }

  wait(method, predicate = () => true, after = 0) {
    const matches = message => message.method === method && predicate(message.params || {});
    const existing = this.messages.slice(after).find(matches);
    if (existing) return Promise.resolve(existing);
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.waiters.delete(waiter);
        reject(new Error(`Notification timeout: ${method}\n${this.stderr}`));
      }, 20000);
      const waiter = {
        predicate: matches,
        resolve: message => { clearTimeout(timer); resolve(message); },
        reject: error => { clearTimeout(timer); reject(error); },
      };
      this.waiters.add(waiter);
    });
  }

  async close() {
    if (this.closed) return this.exit;
    this.process.stdin.end();
    const terminate = setTimeout(() => this.process.kill("SIGTERM"), 8000);
    const kill = setTimeout(() => this.process.kill("SIGKILL"), 10000);
    try { return await this.exit; }
    finally { clearTimeout(terminate); clearTimeout(kill); }
  }
}

async function main() {
  await new Promise((resolve, reject) => {
    apiServer.once("error", reject);
    apiServer.listen(0, "127.0.0.1", resolve);
  });
  const port = apiServer.address().port;
  let peer = new BridgePeer(port);
  const threadIds = new Map();
  try {
    await peer.rpc("initialize", { clientInfo: { name: "claude-cli-fixture", version: "1" } });
    for (const mode of ["allow", "deny", "interrupt", "image"]) {
      peer.approvalAction = mode === "deny" ? "decline" : mode === "interrupt" ? null : "accept";
      const created = await peer.rpc("thread/start", { cwd: workspace });
      const threadId = created.thread.id;
      threadIds.set(mode, threadId);
      const startIndex = peer.messages.length;
      const input = [{ type: "text", text: `CLAUDE_BRIDGE_FIXTURE:${mode}` }];
      if (mode === "image") {
        const imagePath = path.join(workspace, "fixture.png");
        fs.writeFileSync(imagePath, Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aL1EAAAAASUVORK5CYII=", "base64"));
        input.push({ type: "localImage", path: imagePath });
      }
      const started = await peer.rpc("turn/start", {
        threadId, input, model: "claude-sonnet-4-6", approvalPolicy: "on-request",
      });
      assert(started.turn.id);
      const approval = await peer.wait("item/permissions/requestApproval", params => params.threadId === threadId, startIndex);
      assert.equal(approval.params.permissions.claudeTool.name, "Write");
      if (mode === "interrupt") await peer.rpc("turn/interrupt", { threadId, turnId: started.turn.id });
      const completed = await peer.wait("turn/completed", params => params.threadId === threadId && params.turn.id === started.turn.id, startIndex);
      assert.equal(completed.params.turn.status, mode === "interrupt" ? "interrupted" : "completed");
      const target = path.join(workspace, `${mode}.txt`);
      if (mode === "allow" || mode === "image") assert.equal(fs.readFileSync(target, "utf8"), `Only the approved ${mode} fixture may write this file.\n`);
      else assert(!fs.existsSync(target), `${mode} must not run the rejected tool`);
      if (mode !== "interrupt") {
        const output = peer.messages.slice(startIndex)
          .filter(message => message.method === "item/agentMessage/delta")
          .map(message => message.params.delta).join("");
        assert.equal(output, `CLAUDE_BRIDGE_${mode.toUpperCase()}_OK`, "Partial and complete assistant messages must not duplicate text");
      }
    }
    assert(requests.some(request => request.mode === "image" && request.input.messages.some(message => contentBlocks(message).some(block => block.type === "image"))), "Image bytes were not forwarded to Claude");

    const beforeRestart = await peer.rpc("thread/read", { threadId: threadIds.get("allow"), includeTurns: true });
    assert(JSON.stringify(beforeRestart).includes("CLAUDE_BRIDGE_ALLOW_OK"));
    const firstExit = await peer.close();
    assert.equal(firstExit.code, 0, "Bridge must exit gracefully on input EOF");
    peer = new BridgePeer(port);
    peer.approvalAction = "accept";
    await peer.rpc("initialize");
    const listed = await peer.rpc("thread/list", { limit: 20 });
    assert(listed.data.some(thread => thread.id === threadIds.get("allow")), "Restart lost persisted thread");
    const resumed = await peer.rpc("thread/resume", { threadId: threadIds.get("allow") });
    assert(JSON.stringify(resumed).includes("CLAUDE_BRIDGE_ALLOW_OK"), "Resume lost completed assistant history");
    const resumedStart = peer.messages.length;
    const nextTurn = await peer.rpc("turn/start", {
      threadId: threadIds.get("allow"), model: "claude-sonnet-4-6",
      input: [{ type: "text", text: "CLAUDE_BRIDGE_FIXTURE:resume" }], approvalPolicy: "on-request",
    });
    const completion = await peer.wait("turn/completed", params => params.turn.id === nextTurn.turn.id, resumedStart);
    assert.equal(completion.params.turn.status, "completed");
    const resumedRequest = requests.find(request => request.mode === "resume");
    assert(resumedRequest && resumedRequest.input.messages.some(message => message.role === "assistant" && contentBlocks(message).some(block => block.text === "CLAUDE_BRIDGE_ALLOW_OK")), "CLI resume must preserve model context, not just UI history");
    const finalExit = await peer.close();
    assert.equal(finalExit.code, 0);
    console.log("Claude Code real CLI integration: allow, deny, interrupt, image, streaming, persistence, and resumed model context passed (local mock API)");
  } finally {
    await peer.close();
    apiServer.closeAllConnections();
    await new Promise(resolve => apiServer.close(resolve));
    fs.rmSync(temporaryRoot, { recursive: true, force: true });
  }
}

main().catch(error => { console.error(error.stack || error); process.exitCode = 1; });

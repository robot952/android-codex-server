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
const nativeConfig = path.join(temporaryRoot, "claude-config");
fs.mkdirSync(nativeConfig);
fs.writeFileSync(path.join(nativeConfig, "settings.json"), JSON.stringify({
  effortLevel: "high", env: { CLAUDE_CODE_EFFORT_LEVEL: "high" },
}));

function contentBlocks(message) {
  return Array.isArray(message.content)
    ? message.content
    : [{ type: "text", text: String(message.content || "") }];
}

function respondMessage(response, input, content) {
  const id = `msg_fixture_${++messageSequence}`;
  const message = {
    id, type: "message", role: "assistant", model: input.model || "claude-sonnet-4-6",
    content: [content], stop_reason: content.type === "tool_use" ? "tool_use" : "end_turn",
    stop_sequence: null, usage: { input_tokens: 10, cache_read_input_tokens: 100, cache_creation_input_tokens: 50, output_tokens: 10 },
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
    usage: { ...message.usage, output_tokens: 0 },
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
          .match(/CLAUDE_BRIDGE_FIXTURE:(allow|deny|interrupt|image|resume|opus|haiku|custom|policy)/);
        if (match) { mode = match[1]; promptIndex = index; break; }
      }
      assert(mode, "Model request did not contain the controlled prompt");
      requests.push({ mode, input });
      const hasResult = messages.slice(promptIndex + 1)
        .some(message => contentBlocks(message).some(block => block.type === "tool_result"));
      const content = ["resume", "opus", "haiku", "custom"].includes(mode) || hasResult
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
        ANTHROPIC_MODEL: "m-claude", ANTHROPIC_DEFAULT_OPUS_MODEL: "m-claude",
        CLAUDE_CODE_EFFORT_LEVEL: "high",
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
        threadId, input, model: "claude-sonnet-4-6", effort: "high", approvalPolicy: "on-request",
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
    assert(requests.filter(request => request.mode === "allow").every(request => request.input.output_config?.effort === "high"), "Known-model effort must reach the real API request");

    const beforeRestart = await peer.rpc("thread/read", { threadId: threadIds.get("allow"), includeTurns: true });
    assert(JSON.stringify(beforeRestart).includes("CLAUDE_BRIDGE_ALLOW_OK"));
    assert.equal(beforeRestart.tokenUsage.last.inputTokens, 160, "Real CLI cached input must count toward context");
    assert.equal(beforeRestart.tokenUsage.last.totalTokens, 170, "Context must use a single request, not the tool loop total");
    assert.equal(beforeRestart.tokenUsage.total.totalTokens, 340, "Both real tool-loop requests contribute to cumulative usage");
    assert(beforeRestart.tokenUsage.modelContextWindow > 0, "CLI should report the actual recognized model window");
    const firstExit = await peer.close();
    assert.equal(firstExit.code, 0, "Bridge must exit gracefully on input EOF");
    peer = new BridgePeer(port);
    peer.approvalAction = "accept";
    await peer.rpc("initialize");
    const listed = await peer.rpc("thread/list", { limit: 20 });
    assert(listed.data.some(thread => thread.id === threadIds.get("allow")), "Restart lost persisted thread");
    const resumed = await peer.rpc("thread/resume", { threadId: threadIds.get("allow") });
    assert(JSON.stringify(resumed).includes("CLAUDE_BRIDGE_ALLOW_OK"), "Resume lost completed assistant history");
    assert.deepEqual(resumed.tokenUsage, beforeRestart.tokenUsage, "Restart lost model context usage");
    const resumedStart = peer.messages.length;
    const nextTurn = await peer.rpc("turn/start", {
      threadId: threadIds.get("allow"), model: "claude-sonnet-4-6",
      input: [{ type: "text", text: "CLAUDE_BRIDGE_FIXTURE:resume" }], approvalPolicy: "on-request",
    });
    const completion = await peer.wait("turn/completed", params => params.turn.id === nextTurn.turn.id, resumedStart);
    assert.equal(completion.params.turn.status, "completed");
    const resumedRequest = requests.find(request => request.mode === "resume");
    assert(resumedRequest && resumedRequest.input.messages.some(message => message.role === "assistant" && contentBlocks(message).some(block => block.text === "CLAUDE_BRIDGE_ALLOW_OK")), "CLI resume must preserve model context, not just UI history");

    const opus = await peer.rpc("thread/start", { cwd: workspace, model: "claude-opus-5-5" });
    const opusStart = peer.messages.length;
    const opusTurn = await peer.rpc("turn/start", {
      threadId: opus.thread.id, model: "claude-opus-5-5", effort: "medium",
      input: [{ type: "text", text: "CLAUDE_BRIDGE_FIXTURE:opus" }], approvalPolicy: "on-request",
    });
    const opusCompletion = await peer.wait("turn/completed", params => params.turn.id === opusTurn.turn.id, opusStart);
    assert.equal(opusCompletion.params.turn.status, "completed");
    const opusRequest = requests.find(request => request.mode === "opus");
    assert.equal(opusRequest?.input.model, "claude-opus-5-5", "Explicit Opus 5.5 must override the native m-claude alias");
    const effortOnWire = opusRequest.input.output_config?.effort;
    assert.equal(effortOnWire, "medium", "Opus 5.5 effort must reach the real API request");
    for (const [mode, model] of [["haiku", "claude-haiku-4-5"], ["custom", "custom-fixture-model"]]) {
      const created = await peer.rpc("thread/start", { cwd: workspace, model });
      const after = peer.messages.length;
      const started = await peer.rpc("turn/start", {
        threadId: created.thread.id, model,
        input: [{ type: "text", text: `CLAUDE_BRIDGE_FIXTURE:${mode}` }], approvalPolicy: "on-request",
      });
      const completed = await peer.wait("turn/completed", params => params.turn.id === started.turn.id, after);
      assert.equal(completed.params.turn.status, "completed");
      const request = requests.find(value => value.mode === mode);
      assert.equal(request?.input.model, model);
      assert.equal(request.input.output_config?.effort, undefined, `${model} must not inherit native high effort`);
    }
    const settingsFile = path.join(nativeConfig, "settings.json");
    const policySettings = JSON.stringify({
      effortLevel: "high", env: { CLAUDE_CODE_EFFORT_LEVEL: "high" },
      permissions: { deny: ["Write"] },
    });
    fs.writeFileSync(settingsFile, policySettings);
    const policy = await peer.rpc("thread/start", { cwd: workspace, model: "custom-fixture-model" });
    const policyStart = peer.messages.length;
    peer.approvalAction = "accept";
    const policyTurn = await peer.rpc("turn/start", {
      threadId: policy.thread.id, model: "custom-fixture-model",
      input: [{ type: "text", text: "CLAUDE_BRIDGE_FIXTURE:policy" }], approvalPolicy: "on-request",
    });
    const policyComplete = await peer.wait("turn/completed", params => params.turn.id === policyTurn.turn.id, policyStart);
    assert.equal(policyComplete.params.turn.status, "completed");
    assert(!peer.messages.slice(policyStart).some(message => message.method === "item/permissions/requestApproval"), "Native deny policy must precede the App permission prompt");
    assert(!fs.existsSync(path.join(workspace, "policy.txt")), "Clearing effort must not disable native permissions");
    assert.equal(fs.readFileSync(settingsFile, "utf8"), policySettings, "Per-turn effort must not rewrite the user's settings");
    const finalExit = await peer.close();
    assert.equal(finalExit.code, 0);
    console.log("Claude Code real CLI integration: allow, deny, interrupt, image, streaming, persistence, context usage, model and effort forwarding, native policy preservation, and resumed model context passed (local mock API)");
  } finally {
    await peer.close();
    apiServer.closeAllConnections();
    await new Promise(resolve => apiServer.close(resolve));
    fs.rmSync(temporaryRoot, { recursive: true, force: true });
  }
}

main().catch(error => { console.error(error.stack || error); process.exitCode = 1; });

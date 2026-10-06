"use strict";

// Explicit opt-in: this test makes at most two paid requests to the configured API.
const assert = require("node:assert/strict");
const { spawn } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const readline = require("node:readline");

if (process.argv.slice(2).join(" ") !== "--live") {
  console.error("Live Claude test requires --live (two paid API turns maximum).");
  process.exit(2);
}

const root = path.resolve(__dirname, "..");
const bridgePath = path.join(root, "flutter_app/assets/claude-code-bridge.cjs");
const nativeConfig = "/root/.claude/settings.json";
const claudeBin = process.env.CLAUDE_CODE_TEST_BIN || "/usr/local/bin/claude";
const temp = fs.mkdtempSync(path.join(os.tmpdir(), "claude-bridge-live-"));
const workspace = path.join(temp, "workspace");
const configDir = path.join(temp, "claude-config");
const wrapper = path.join(temp, "claude-safe.cjs");
let child;
let exit;

function clean() {
  if (child && child.exitCode == null) {
    try { process.kill(-child.pid, "SIGKILL"); } catch (_) {}
  }
  fs.rmSync(temp, { recursive: true, force: true });
}

class Peer {
  constructor() {
    this.pending = new Map();
    this.waiters = new Set();
    this.messages = [];
    this.nextId = 1;
    child = spawn(process.execPath, [bridgePath, "--directory", workspace], {
      cwd: workspace,
      detached: true,
      env: {
        HOME: temp, USER: "claude-live-test", PATH: process.env.PATH || "/usr/local/bin:/usr/bin:/bin",
        CLAUDE_BIN: wrapper, CLAUDE_CONFIG_DIR: configDir,
        CODEX_REMOTE_CLAUDE_STATE: path.join(temp, "bridge-state.json"),
        CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: "1", DISABLE_TELEMETRY: "1", DISABLE_AUTOUPDATER: "1",
      },
      stdio: ["pipe", "pipe", "pipe"],
    });
    exit = new Promise(resolve => child.once("close", (code, signal) => resolve({ code, signal })));
    child.stdin.on("error", () => {});
    child.stderr.resume(); // Never expose CLI diagnostics: they may contain credentials or the private API URL.
    readline.createInterface({ input: child.stdout, crlfDelay: Infinity }).on("line", line => {
      let message;
      try { message = JSON.parse(line); } catch (_) { return; }
      this.messages.push(message);
      if (message.id != null && !message.method) {
        const pending = this.pending.get(message.id);
        if (pending) {
          this.pending.delete(message.id);
          message.error ? pending.reject(new Error("Bridge RPC failed")) : pending.resolve(message.result);
        }
      }
      if (message.method === "item/permissions/requestApproval") {
        this.send({ id: message.id, result: { permissions: {}, scope: "turn" } });
      }
      for (const waiter of [...this.waiters]) {
        if (waiter.match(message)) { this.waiters.delete(waiter); waiter.resolve(message); }
      }
    });
  }
  send(message) { child.stdin.write(JSON.stringify(message) + "\n"); }
  rpc(method, params = {}, timeoutMs = 5000) {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this.pending.delete(id); reject(new Error(`RPC timeout: ${method}`)); }, timeoutMs);
      this.pending.set(id, {
        resolve: value => { clearTimeout(timer); resolve(value); },
        reject: error => { clearTimeout(timer); reject(error); },
      });
      this.send({ id, method, params });
    });
  }
  wait(method, predicate, after, timeoutMs = 90000) {
    const match = message => message.method === method && predicate(message.params || {});
    const existing = this.messages.slice(after).find(match);
    if (existing) return Promise.resolve(existing);
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this.waiters.delete(waiter); reject(new Error(`${method} timed out`)); }, timeoutMs);
      const waiter = {
        match,
        resolve: value => { clearTimeout(timer); resolve(value); },
        reject: error => { clearTimeout(timer); reject(error); },
      };
      this.waiters.add(waiter);
    });
  }
}

async function main() {
  fs.mkdirSync(workspace, { mode: 0o700 });
  fs.mkdirSync(configDir, { mode: 0o700 });
  const original = JSON.parse(fs.readFileSync(nativeConfig, "utf8"));
  const env = {};
  for (const name of ["ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY",
    "ANTHROPIC_MODEL", "ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL", "CLAUDE_CODE_MAX_CONTEXT_TOKENS"]) {
    if (typeof original.env?.[name] === "string") env[name] = original.env[name];
  }
  assert(env.ANTHROPIC_BASE_URL && (env.ANTHROPIC_AUTH_TOKEN || env.ANTHROPIC_API_KEY),
    "Live test needs a configured API URL and key");
  fs.writeFileSync(path.join(configDir, "settings.json"), JSON.stringify({ env, hooks: {} }), { mode: 0o600 });
  fs.writeFileSync(wrapper, [
    "#!/usr/bin/env node", "'use strict';",
    "const { spawn } = require('node:child_process');",
    `const child = spawn(${JSON.stringify(claudeBin)}, [...process.argv.slice(2), '--tools', '', '--strict-mcp-config', '--disable-slash-commands', '--max-budget-usd', '0.5'], { stdio: 'inherit' });`,
    "for (const signal of ['SIGTERM', 'SIGINT']) process.on(signal, () => child.kill(signal));",
    "child.on('exit', (code, signal) => { if (signal) process.kill(process.pid, signal); else process.exit(code ?? 1); });",
    "child.on('error', () => process.exit(127));", "",
  ].join("\n"), { mode: 0o700 });

  let peer = new Peer();
  await peer.rpc("initialize");
  const created = await peer.rpc("thread/start", { cwd: workspace, model: "claude-opus-5-5" });
  const threadId = created.thread.id;
  const timings = [];
  let firstTotalInputTokens = 0;
  for (let round = 1; round <= 2; round++) {
    const startedAt = Date.now();
    const start = peer.messages.length;
    const started = await peer.rpc("turn/start", {
      threadId, model: "claude-opus-5-5", effort: "medium", approvalPolicy: "on-request",
      input: [{ type: "text", text: round === 1
        ? "Live bridge check, first turn. Reply only OK1. Do not use tools."
        : "Live bridge check, resumed second turn. Reply only OK2. Do not use tools." }],
    });
    const done = await peer.wait("turn/completed",
      params => params.threadId === threadId && params.turn.id === started.turn.id, start);
    timings.push(Date.now() - startedAt);
    assert.equal(done.params.turn.status, "completed", `Turn ${round} did not complete`);
    const snapshot = await peer.rpc("thread/read", { threadId, includeTurns: true });
    assert.equal(snapshot.model, "claude-opus-5-5");
    assert.equal(snapshot.reasoningEffort, "medium");
    assert(snapshot.tokenUsage?.last?.inputTokens > 0, `Turn ${round} missing live input usage`);
    assert(snapshot.tokenUsage?.total?.inputTokens > 0, `Turn ${round} missing cumulative usage`);
    if (round === 2) assert(snapshot.tokenUsage.total.inputTokens > firstTotalInputTokens,
      "Second turn did not increase cumulative input usage");
    console.log(JSON.stringify({ round, status: "completed", model: snapshot.model,
      effort: snapshot.reasoningEffort, inputTokens: snapshot.tokenUsage.last.inputTokens,
      contextWindowTokens: snapshot.tokenUsage.modelContextWindow || null, elapsedMs: timings.at(-1) }));
    if (round === 1) {
      const priorUsage = snapshot.tokenUsage;
      firstTotalInputTokens = priorUsage.total.inputTokens;
      child.stdin.end();
      const ended = await Promise.race([exit, new Promise(resolve => setTimeout(() => resolve(null), 3000))]);
      assert.equal(ended?.code, 0, "Bridge did not exit cleanly before resume");
      peer = new Peer();
      await peer.rpc("initialize");
      const resumed = await peer.rpc("thread/resume", { threadId });
      assert.deepEqual(resumed.tokenUsage, priorUsage, "Process restart or resume lost usage");
    }
  }
  assert(timings.every(ms => ms <= 90000), "Live turn exceeded 90 seconds");
  child.stdin.end();
  const ended = await Promise.race([exit, new Promise(resolve => setTimeout(() => resolve(null), 3000))]);
  assert.equal(ended?.code, 0, "Bridge did not exit cleanly");
  console.log("Live Claude bridge: two Opus 5.5 turns, medium effort, usage and resume passed");
}

main().catch(error => {
  // Keep all CLI and gateway diagnostics private, even on failure.
  const reason = error.message?.includes("timed out") ? "timeout" : "configuration, bridge, or CLI assertion";
  console.error(`Live Claude bridge failed: ${reason}`);
  process.exitCode = 1;
}).finally(clean);

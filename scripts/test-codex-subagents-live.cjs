"use strict";

// Explicitly opted-in live provider test. Credentials never enter arguments,
// stdout, committed fixtures or the Android test APK.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { spawn } = require("node:child_process");
const readline = require("node:readline");

assert(process.argv.includes("--live"), "Live model usage requires --live");
const binary = process.env.CODEX_SUBAGENT_TEST_BIN;
const source = process.env.CODEX_SUBAGENT_CONFIG_DIR;
assert(binary && source, "Set CODEX_SUBAGENT_TEST_BIN and CODEX_SUBAGENT_CONFIG_DIR");
const cache = path.resolve(__dirname, "../.workflow-cache");
fs.mkdirSync(cache, { recursive: true });
const temporary = fs.mkdtempSync(path.join(cache, "subagent-live-private-"));
fs.chmodSync(temporary, 0o700);
const workspace = path.join(temporary, "workspace");
fs.mkdirSync(workspace);
const original = fs.readFileSync(path.join(source, "config.toml"), "utf8");
const auth = fs.readFileSync(path.join(source, "auth.json"), "utf8");
const secrets = [JSON.parse(auth).OPENAI_API_KEY].filter(Boolean);
let section = "";
const config = [];
for (const line of original.split("\n")) {
  if (/^\s*\[/.test(line)) section = line.trim();
  if (section.startsWith("[model_providers.") ||
      (!section && /^(model|model_provider|openai_base_url|preferred_auth_method)\s*=/.test(line))) {
    config.push(line);
    const value = line.match(/(?:base_url|api_key|experimental_bearer_token)\s*=\s*"([^"]+)"/);
    if (value) secrets.push(value[1]);
  }
}
fs.writeFileSync(path.join(temporary, "config.toml"), config.join("\n"), { mode: 0o600 });
fs.writeFileSync(path.join(temporary, "auth.json"), auth, { mode: 0o600 });
const messages = [];
const pending = new Map();
const created = new Set();
const results = [];
const tokenUsage = new Map();
let sequence = 0;
let child;
let stopped = false;
let rootId;
let interruptPromise;
function redact(text) {
  for (const secret of secrets) text = text.split(secret).join("<redacted>");
  return text.replace(/https?:\/\/[^\s"\\]+/g, "<endpoint>")
    .replaceAll(temporary, "<test-home>");
}
function send(value) { child.stdin.write(`${JSON.stringify(value)}\n`); }
function rpc(method, params) {
  const id = ++sequence;
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { pending.delete(id); reject(new Error(`RPC timeout: ${method}`)); }, 20000);
    pending.set(id, value => {
      clearTimeout(timer);
      if (value.error) reject(new Error(`RPC ${method}: ${redact(JSON.stringify(value.error))}`));
      else resolve(value.result);
    });
    send({ id, method, params });
  });
}
async function waitFor(predicate, timeout = 90000, start = 0) {
  const end = Date.now() + timeout;
  while (Date.now() < end) {
    const match = messages.slice(start).find(predicate);
    if (match) return match;
    if (child.exitCode !== null) throw new Error("Test app-server exited");
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  throw new Error("Live scenario timed out");
}
async function turn(threadId, text, interruptChild = false) {
  const from = messages.length;
  const result = await rpc("turn/start", { threadId,
    input: [{ type: "text", text }], effort: "low" });
  if (interruptChild) {
    await waitFor(x => x.method === "turn/completed" && x.params.threadId !== threadId &&
      x.params.turn.status === "interrupted", 90000, from);
    await interruptPromise;
    assert(!messages.slice(from).some(x => x.method === "turn/completed" &&
      x.params.threadId === threadId), "Stopping a child also stopped the parent");
    // Parent wait tools need not return on child interruption. End this test's
    // parent turn explicitly so no model call is left waiting for minutes.
    await rpc("turn/interrupt", { threadId, turnId: result.turn.id });
    await waitFor(x => x.method === "turn/completed" && x.params.threadId === threadId &&
      x.params.turn.id === result.turn.id, 20000, from);
    return messages.slice(from);
  }
  const complete = await waitFor(x => x.method === "turn/completed" &&
    x.params.threadId === threadId && x.params.turn.id === result.turn.id, 240000, from);
  assert.equal(complete.params.turn.status, "completed", "Live model turn failed");
  return messages.slice(from);
}
function collabs(events) {
  return events.filter(x => x.method === "item/completed" &&
    /collab|subagent/i.test(x.params?.item?.type || ""));
}
async function stop() {
  if (stopped) return;
  stopped = true;
  if (child && child.exitCode === null) {
    child.kill("SIGTERM");
    await new Promise(resolve => {
      const timer = setTimeout(() => child.kill("SIGKILL"), 3000);
      child.once("exit", () => { clearTimeout(timer); resolve(); });
    });
  }
  // Preserve only bounded, redacted protocol evidence from these synthetic tasks.
  const evidence = messages.filter(x => x.method && (
    /^(thread\/started|turn\/(started|completed)|thread\/status\/changed)$/.test(x.method) ||
    /collab|subagent/i.test(x.method) || /collab|subagent/i.test(x.params?.item?.type || "")
  ));
  const report = redact(JSON.stringify({ results, usage: [...tokenUsage.values()], events: evidence }, null, 2));
  fs.writeFileSync(path.join(cache, `subagent-live-${Date.now()}.json`), report, { mode: 0o600 });
  fs.writeFileSync(path.join(cache, "subagent-live-evidence.json"), report, { mode: 0o600 });
  fs.rmSync(temporary, { recursive: true, force: true });
}
async function main() {
  const overrides = {
    model_reasoning_effort: "low", suppress_unstable_features_warning: true,
    "features.multi_agent": true, "features.shell_tool": false,
    "agents.max_threads": 4, "agents.max_depth": 2,
    "agents.default_subagent_reasoning_effort": "low",
  };
  const args = Object.entries(overrides).flatMap(([k, v]) => ["-c", `${k}=${JSON.stringify(v)}`]);
  args.push("app-server", "--listen", "stdio://");
  function launch() {
  child = spawn(binary, args, { cwd: workspace,
    env: { PATH: process.env.PATH, HOME: temporary, CODEX_HOME: temporary, RUST_LOG: "off" },
    stdio: ["pipe", "pipe", "pipe"] });
  child.stderr.resume();
  readline.createInterface({ input: child.stdout }).on("line", line => {
    let x; try { x = JSON.parse(line); } catch { return; }
    if (!x.method && pending.has(x.id)) {
      pending.get(x.id)(x); pending.delete(x.id);
    } else {
      if (messages.length < 10000) messages.push(x);
      if (x.method === "thread/started") created.add(x.params.thread.id);
      if (x.method === "turn/started") created.add(x.params.threadId);
      if (x.method === "thread/tokenUsage/updated") tokenUsage.set(x.params.threadId, x.params.tokenUsage?.total);
      if (process.argv.includes("--interrupt") && rootId && !interruptPromise &&
          x.method === "turn/started" && x.params.threadId !== rootId) {
        interruptPromise = rpc("turn/interrupt", { threadId: x.params.threadId, turnId: x.params.turn.id });
        interruptPromise.catch(() => {});
      }
      if (x.method === "item/completed" && /subagent|collab/i.test(x.params?.item?.type || "")) {
        const item = x.params.item;
        if (item.agentThreadId) created.add(item.agentThreadId);
        for (const id of item.receiverThreadIds || []) created.add(id);
        console.log(`Collaboration event: ${item.type} ${item.kind || item.tool} ${item.status || ""}`);
      }
      if (x.method === "turn/completed") console.log(`Turn finished: ${x.params.turn.status}`);
      if (x.id !== undefined && x.method) {
        // Test tasks require no commands, file edits, external tools or approval.
        send({ id: x.id, error: { code: -32601, message: "Unsupported in bounded test" } });
      }
    }
  });
  }
  async function initialize() {
    await rpc("initialize", { clientInfo: { name: "subagent_live_test", version: "1" }, capabilities: { experimentalApi: true } });
    send({ method: "initialized", params: {} });
  }
  launch();
  for (const signal of ["SIGTERM", "SIGINT"]) process.on(signal, () => void stop());
  const limit = setTimeout(() => { console.error("Live test deadline reached"); process.exitCode = 1; void stop(); }, 8 * 60000);
  try {
    await initialize();
    const root = await rpc("thread/start", { cwd: workspace, approvalPolicy: "never", sandbox: "read-only",
      developerInstructions: "This is an authorized bounded subagent integration test. Use collaboration tools as requested. No files, shell commands, web, skills, or external tools. Create at most three children total, nesting at most two levels. Keep messages and final answers under 30 words. Do not request user input. Child agents must use the same model and low reasoning effort." });
    rootId = root.thread.id;
    const interrupt = process.argv.includes("--interrupt");
    console.log(`Live provider connected; testing ${interrupt ? "child interruption" : "parallel and nested collaborators"}.`);
    const first = await turn(rootId, interrupt
      ? "Create exactly one subagent named alpha. Ask it to calculate the first 40 prime numbers mentally and then answer CHILD_ALPHA_OK. Wait for alpha. The test client will deliberately interrupt it: do not retry or spawn another agent if interrupted. Finish ROOT_INTERRUPT_OK once it has stopped. Use collaboration tools."
      : "Create two subagents in parallel named alpha and beta. Alpha must answer CHILD_ALPHA_OK immediately. Beta must create one child named gamma who answers GRANDCHILD_GAMMA_OK, wait for it, then answer CHILD_BETA_OK. Wait for both alpha and beta. Finish with ROOT_PARALLEL_OK. Use real collaboration tool calls, not text descriptions.", interrupt);
    const calls = collabs(first);
    assert(created.size >= (interrupt ? 2 : 4), "Expected collaborator threads missing");
    assert(calls.length > 0, "No collaboration protocol events");
    if (interrupt) {
      await interruptPromise;
      assert(first.some(x => x.method === "turn/completed" && x.params.threadId !== rootId &&
        x.params.turn.status === "interrupted"), "Child interruption was not confirmed");
    }
    results.push({ scenario: interrupt ? "interrupt_child_parent_survives" : "parallel_nested_wait", passed: true, threads: created.size,
      tools: calls.map(x => x.params.item.tool || x.params.item.kind) });
    console.log(`PASS ${results.at(-1).scenario} (${created.size} threads)`);
    const second = await turn(rootId, "Continue the existing alpha subagent with a follow-up task: answer CHILD_ALPHA_AGAIN_OK. Do not create a new agent. Wait for alpha to finish, then answer ROOT_FOLLOWUP_OK.");
    assert(collabs(second).some(x => x.params.item.kind === "interacted" ||
      /send|resume|follow/i.test(x.params.item.tool || "")), "Follow-up produced no interaction event");
    assert(second.some(x => x.method === "turn/completed" && x.params.threadId !== rootId &&
      x.params.turn.status === "completed"), "Follow-up child did not complete");
    results.push({ scenario: "followup_existing_child", passed: true });
    console.log("PASS follow-up of existing child");
    // Recreate the transport/process, retaining only this test's private history.
    const old = child;
    old.kill("SIGTERM");
    await new Promise(resolve => old.once("exit", resolve));
    launch();
    await initialize();
    const resumed = await rpc("thread/resume", { threadId: rootId });
    assert.equal(resumed.thread.id, rootId);
    const items = (resumed.thread.turns || []).flatMap(t => t.items || []);
    assert(items.some(i => /collab|subagent/i.test(i.type)), "Resume lost collaborator history");
    results.push({ scenario: "restart_transport_resume_parent_history", passed: true });
    console.log("PASS parent history after app-server restart");
  } finally { clearTimeout(limit); await stop(); }
}
main().catch(async error => { console.error(redact(error.message)); process.exitCode = 1; await stop(); });

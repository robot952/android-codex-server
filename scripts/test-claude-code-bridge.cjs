"use strict";

const assert = require("node:assert/strict");
const cp = require("node:child_process");
const crypto = require("node:crypto");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const readline = require("node:readline");
const bridgePath = path.resolve(__dirname, "../flutter_app/assets/claude-code-bridge.cjs");
const { ThreadStore, prepareInput, bounded, modelCatalog, usageBreakdown } = require(bridgePath);
const timeoutMs = 5000;

// The fake runs as a CLI subprocess and waits for the SDK control handshake.
// It never emits a canned reply before the bridge has installed its listeners.
function fakeClaudeMain() {
  const assert = require("node:assert/strict");
  const fs = require("node:fs");
  const readline = require("node:readline");
  const args = process.argv.slice(2);
  const valueOf = flag => args[args.indexOf(flag) + 1];
  const session = valueOf(args.includes("--resume") ? "--resume" : "--session-id");
  const send = value => process.stdout.write(JSON.stringify(value) + "\n");
  const audit = value => fs.appendFileSync(process.env.CLAUDE_TEST_AUDIT, JSON.stringify(value) + "\n");
  const input = readline.createInterface({ input: process.stdin });
  let initialized = false;
  let scenario;
  let request;
  let holdExit = false;
  audit({ type: "spawn", pid: process.pid, args, cwd: process.cwd(), effortEnv: process.env.CLAUDE_CODE_EFFORT_LEVEL });
  assert.equal(valueOf("--input-format"), "stream-json");
  assert.equal(valueOf("--output-format"), "stream-json");
  assert.equal(valueOf("--permission-mode"), "default");
  assert.equal(valueOf("--permission-prompt-tool"), "stdio");
  assert.ok(args.includes("--include-partial-messages"));
  assert.ok(!args.includes("--dangerously-skip-permissions"));
  const result = text => send({ type: "result", is_error: false, result: text });
  input.on("line", line => {
    const message = JSON.parse(line);
    audit({ type: "input", message });
    if (message.type === "control_request") {
      if (message.request.subtype === "initialize") {
        assert.equal(initialized, false);
        initialized = true;
        if (valueOf("--model") === "fixture-late-initialize") {
          audit({ type: "initialize-held" });
          process.once("SIGTERM", () => {
            send({ type: "control_response", response: { subtype: "success", request_id: message.request_id, response: {} } });
            // Give the bridge a chance to process this intentionally late reply.
            setTimeout(() => process.exit(0), 100);
          });
          return;
        }
        send({ type: "control_response", response: { subtype: "success", request_id: message.request_id, response: {} } });
      } else if (message.request.subtype === "interrupt") {
        result("LATE_RESULT_AFTER_INTERRUPT");
      }
      return;
    }
    if (message.type === "control_response") {
      assert.equal(message.response.request_id, "fixture-control");
      if (scenario === "unknown-control") {
        assert.equal(message.response.subtype, "error");
        result("UNSUPPORTED_CONTROL_REJECTED");
        return;
      }
      const answer = message.response.response;
      if (scenario === "question") {
        result(answer.behavior === "allow" ? JSON.stringify(answer.updatedInput.answers) : "QUESTION_DENIED");
      } else {
        if (answer.behavior === "allow") assert.deepEqual(answer.updatedInput, request.input);
        send({ type: "user", message: { content: [{ type: "tool_result", tool_use_id: "fixture-tool", content: answer.behavior === "allow" ? "command output" : "not executed", is_error: answer.behavior !== "allow" }] } });
        result(answer.behavior === "allow" ? "TOOL_ALLOWED" : "TOOL_DENIED");
      }
      return;
    }
    assert.equal(initialized, true, "prompt arrived before control initialize");
    assert.equal(message.type, "user");
    assert.equal(message.message.role, "user");
    scenario = message.message.content.find(block => block.type === "text")?.text.replace(/^CASE:/, "") || "image";
    send({ type: "system", subtype: "init", session_id: session });
    if (scenario === "usage" || scenario === "usage-unknown") {
      const model = scenario === "usage" ? "claude-opus-5-5" : "custom-unknown";
      const first = { type: "assistant", message: { id: "usage-first", model, usage: { input_tokens: 100, cache_read_input_tokens: 200, cache_creation_input_tokens: 50, output_tokens: 30 }, content: [{ type: "text", text: "first" }] } };
      send(first); send(first);
      send({ type: "assistant", parent_tool_use_id: "child-agent", message: { id: "child-usage", model: "other-model", usage: { input_tokens: 9000, output_tokens: 999 }, content: [] } });
      send({ type: "stream_event", event: { type: "message_start", message: { id: "usage-latest", model, usage: { input_tokens: 150, cache_read_input_tokens: 250, cache_creation_input_tokens: 75, output_tokens: 0 } } } });
      send({ type: "stream_event", event: { type: "message_delta", usage: { output_tokens: 40 } } });
      send({ type: "assistant", message: { id: "usage-latest", model, usage: { input_tokens: 150, cache_read_input_tokens: 250, cache_creation_input_tokens: 75, output_tokens: 40 }, content: [{ type: "text", text: "latest" }] } });
      send(first); // A repeated earlier snapshot must not roll the context back.
      send({ type: "result", is_error: false, usage: { input_tokens: 999999, output_tokens: 99999 }, modelUsage: {
        "other-model": { contextWindow: 9999 },
        ...(scenario === "usage" ? { [model]: { contextWindow: 1000000, inputTokens: 999999 } } : {}),
      } });
    } else if (scenario === "stream") {
      send({ type: "stream_event", event: { type: "message_start", message: { id: "message-one" } } });
      send({ type: "stream_event", event: { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } } });
      const delta = Buffer.from(JSON.stringify({ type: "stream_event", event: { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: "你好 Claude" } } }) + "\n");
      const split = delta.indexOf(Buffer.from("你")) + 1;
      process.stdout.write(delta.subarray(0, split));
      process.stdout.write(delta.subarray(split));
      const snapshot = { type: "assistant", message: { id: "message-one", content: [{ type: "text", text: "你好 Claude" }] } };
      send(snapshot); send(snapshot);
      send({ type: "assistant", parent_tool_use_id: "nested-agent", message: { id: "nested", content: [{ type: "text", text: "NESTED_TEXT_MUST_NOT_LEAK" }] } });
      send({ type: "assistant", message: { id: "message-two", content: [{ type: "text", text: "Only snapshot" }] } });
      send({ type: "assistant", message: { id: "message-two", content: [{ type: "text", text: "Only snapshot" }] } });
      result("你好 Claude\nOnly snapshot");
    } else if (scenario === "stream-no-id") {
      // Claude-compatible gateways may omit the message ID on message_start
      // but include one on the final assistant snapshot.
      send({ type: "stream_event", event: { type: "message_start", message: {} } });
      send({ type: "stream_event", event: { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: "无 ID 仍只显示一次" } } });
      send({ type: "assistant", message: { id: "message-no-id", content: [{ type: "text", text: "无 ID 仍只显示一次" }] } });
      result("无 ID 仍只显示一次");
    } else if (scenario === "semantic-duplicate") {
      // Some gateways identify message_start but omit the ID on the first
      // assistant snapshot, then assign a different ID to a repeated snapshot.
      // Tool IDs can drift the same way, which used to create duplicate text
      // and two identical Bash cards in the app.
      const text = "我先看一下当前目录和这台机器的基础信息。";
      const input = { command: "pwd" };
      send({ type: "stream_event", event: { type: "message_start", message: { id: "stream-message" } } });
      send({ type: "stream_event", event: { type: "content_block_delta", index: 0, delta: { type: "text_delta", text } } });
      send({ type: "assistant", message: { content: [
        { type: "text", text }, { type: "tool_use", id: "tool-one", name: "Bash", input },
      ] } });
      // A reconnect can emit another message_start before the same response's
      // final snapshot. Fingerprints must survive this transport reset.
      send({ type: "stream_event", event: { type: "message_start", message: { id: "stream-retry" } } });
      send({ type: "assistant", message: { id: "snapshot-two", content: [
        { type: "text", text }, { type: "tool_use", id: "tool-two", name: "Bash", input: { command: "pwd" } },
      ] } });
      // The result follows the second snapshot and carries its drifted ID.
      // The bridge must resolve it to the first visible card.
      send({ type: "user", message: { content: [{ type: "tool_result", tool_use_id: "tool-two", content: "/home/yan", is_error: false }] } });
      result("SEMANTIC_DUPLICATE_DONE");
    } else if (scenario === "permission" || scenario === "question" || scenario === "cancel-approval") {
      request = scenario === "question"
        ? { subtype: "can_use_tool", tool_name: "AskUserQuestion", tool_use_id: "fixture-tool", input: { questions: [
          { header: "颜色", question: "Which color?", options: [{ label: "Blue", description: "Cool" }, { label: "Red", description: "Warm" }] },
          { header: "环境", question: "Which environment?", options: [{ label: "Local", description: "Local fixture" }] },
        ] } }
        : { subtype: "can_use_tool", tool_name: "Bash", tool_use_id: "fixture-tool", input: { command: "printf fixture", description: "Fixture command" } };
      send({ type: "assistant", message: { id: "tool-message", content: [{ type: "tool_use", id: "fixture-tool", name: request.tool_name, input: request.input }] } });
      send({ type: "control_request", request_id: "fixture-control", request });
      if (scenario === "cancel-approval") send({ type: "control_cancel_request", request_id: "fixture-control" });
    } else if (scenario === "unknown-control") {
      send({ type: "control_request", request_id: "fixture-control", request: { subtype: "unsupported-fixture" } });
    } else if (scenario === "hang") {
      send({ type: "stream_event", event: { type: "content_block_delta", delta: { type: "text_delta", text: "WAITING" } } });
    } else if (scenario === "slow-exit") {
      holdExit = true;
      result("DELAYED_EXIT_RESULT");
      audit({ type: "result-sent" });
      const gate = setInterval(() => {
        if (fs.existsSync(process.env.CLAUDE_TEST_RELEASE)) {
          clearInterval(gate);
          process.exit(0);
        }
      }, 10);
    } else if (scenario === "unicode-limit") {
      assert.equal(message.message.content[1].text.length, 500000);
      for (const id of ["large-one", "large-two"]) {
        send({ type: "assistant", message: { id, content: [{ type: "text", text: "汉".repeat(131072) }] } });
      }
      result("LARGE_RESULT_ALREADY_STREAMED");
    } else if (scenario === "error") {
      send({ type: "result", is_error: true, errors: ["fixture failure"] });
    } else if (scenario === "malformed") {
      process.stdout.write("{invalid-json}\n");
    } else if (scenario === "early-exit") {
      process.stderr.write("DO_NOT_EXPOSE_RAW_CLI_STDERR\n");
      process.exit(9);
    } else if (scenario === "image") {
      assert.ok(message.message.content.some(block => block.type === "image"));
      result("IMAGE_RECEIVED");
    } else {
      result("FALLBACK_RESULT");
    }
  });
  input.on("close", () => { if (!holdExit) process.exit(0); });
}

class Peer {
  constructor(root, fake, state = path.join(root, "state")) {
    this.state = state;
    this.messages = [];
    this.waiters = new Set();
    this.nextId = 1;
    this.child = cp.spawn(process.execPath, [bridgePath, "--directory", root], {
      cwd: root,
      // Isolate HOME and credentials; no real model service is involved.
      env: { PATH: process.env.PATH, HOME: root, TMPDIR: root, LANG: "C.UTF-8", CLAUDE_BIN: fake, CODEX_REMOTE_CLAUDE_STATE: state, CLAUDE_TEST_AUDIT: path.join(root, "audit.jsonl"), CLAUDE_TEST_RELEASE: path.join(root, "release-cli") },
      stdio: ["pipe", "pipe", "pipe"],
    });
    this.stderr = "";
    this.child.stderr.on("data", data => { this.stderr += data.toString(); });
    this.output = readline.createInterface({ input: this.child.stdout });
    this.output.on("line", line => {
      this.messages.push(JSON.parse(line));
      for (const waiter of [...this.waiters]) waiter.check();
    });
    this.closed = new Promise(resolve => this.child.once("close", (code, signal) => {
      this.exit = { code, signal };
      for (const waiter of [...this.waiters]) waiter.check();
      resolve(this.exit);
    }));
  }
  mark() { return this.messages.length; }
  send(value) { this.child.stdin.write(JSON.stringify(value) + "\n"); }
  wait(predicate, after = 0) {
    return new Promise((resolve, reject) => {
      const waiter = { check: () => {
        const found = this.messages.slice(after).find(predicate);
        if (found) return finish(null, found);
        if (this.exit) finish(new Error("bridge exited before expected response: " + JSON.stringify(this.exit)));
      } };
      const finish = (error, value) => {
        clearTimeout(timer); this.waiters.delete(waiter);
        error ? reject(error) : resolve(value);
      };
      const timer = setTimeout(() => finish(new Error("timed out waiting for bridge response")), timeoutMs);
      this.waiters.add(waiter);
      waiter.check();
    });
  }
  request(method, params = {}) {
    const id = this.nextId++;
    // Register before writing, and retain events to avoid fast-response races.
    const response = this.wait(message => message.id === id && !message.method);
    this.send({ id, method, params });
    return response;
  }
  async ok(method, params = {}) {
    const value = await this.request(method, params);
    assert.equal(value.error, undefined, method + ": " + JSON.stringify(value.error));
    return value.result;
  }
  async initialize() {
    const result = await this.ok("initialize");
    assert.equal(result.serverInfo.name, "claude-code-bridge");
    this.send({ method: "initialized", params: {} });
    return this;
  }
  async thread(cwd) { return (await this.ok("thread/start", cwd ? { cwd } : {})).thread.id; }
  async turn(threadId, scenario, options = {}) {
    const after = this.mark();
    const result = await this.ok("turn/start", { threadId, input: [{ type: "text", text: "CASE:" + scenario }], ...options });
    return { id: result.turn.id, after, threadId };
  }
  async complete(turn, expected = "completed") {
    const event = await this.wait(message => message.method === "turn/completed" && message.params.turn.id === turn.id, turn.after);
    assert.equal(event.params.turn.status, expected);
    return event;
  }
  async history(threadId) { return (await this.ok("thread/resume", { threadId })).initialTurnsPage.data; }
  async close(signal) {
    if (!this.exit) {
      if (signal) this.child.kill(signal);
      else this.child.stdin.end();
    }
    const timer = setTimeout(() => this.child.kill("SIGKILL"), timeoutMs);
    await this.closed;
    clearTimeout(timer);
    this.output.close();
  }
}

async function until(predicate) {
  const deadline = Date.now() + timeoutMs;
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error("timed out waiting for fixture cleanup");
    await new Promise(resolve => setTimeout(resolve, 10));
  }
}
const cases = [];
function test(name, body) { cases.push({ name, body }); }
const assistantTexts = turn => turn.items.filter(item => item.type === "agentMessage").map(item => item.text);
const approvalFor = turn => message => message.method === "item/permissions/requestApproval" && message.params.turnId === turn.id;
const questionFor = turn => message => message.method === "item/tool/requestUserInput" && message.params.turnId === turn.id;
const auditFor = root => fs.readFileSync(path.join(root, "audit.jsonl"), "utf8").trim().split("\n").map(JSON.parse);

test("initialize, ordered handshake, Unicode streaming and duplicate snapshots", async ({ peer, root }) => {
  const catalog = await peer.ok("model/list");
  assert.equal(catalog.data.find(model => model.isDefault).model, "default");
  assert.ok(catalog.data.some(model => model.model === "claude-opus-5-5"));
  const id = await peer.thread();
  const turn = await peer.turn(id, "stream", { model: "fixture-model" });
  await peer.complete(turn);
  const history = await peer.history(id);
  assert.equal(history.length, 1);
  assert.deepEqual(assistantTexts(history[0]), ["你好 Claude", "Only snapshot"]);
  assert.equal(peer.messages.filter(message => message.method === "turn/completed" && message.params.turn.id === turn.id).length, 1);
  const deltas = peer.messages.filter(message => message.method === "item/agentMessage/delta" && message.params.turnId === turn.id);
  assert.equal(deltas.map(message => message.params.delta).join("|"), "你好 Claude|Only snapshot");
  const audit = auditFor(root);
  assert.equal(audit[1].message.request.subtype, "initialize");
  assert.equal(audit[2].message.type, "user");
  assert.equal(audit[0].args[audit[0].args.indexOf("--model") + 1], "fixture-model");
  assert.equal(audit[0].cwd, root);
  const next = await peer.turn(id, "fallback");
  await peer.complete(next);
  const starts = auditFor(root).filter(value => value.type === "spawn");
  assert.equal(starts[1].args[starts[1].args.indexOf("--resume") + 1], id);
  assert.ok(!starts[1].args.includes("--session-id"));
  const listed = await peer.ok("thread/list");
  assert.equal(listed.data[0].id, id);
  assert.equal(listed.data[0].source, "claude-code");
  assert.equal(listed.data[0].modelProvider, "anthropic");
});

test("streamed text reconciles when message_start omits its ID", async ({ peer }) => {
  const id = await peer.thread();
  const turn = await peer.turn(id, "stream-no-id");
  await peer.complete(turn);
  assert.deepEqual(assistantTexts((await peer.history(id))[0]), ["无 ID 仍只显示一次"]);
  const deltas = peer.messages.filter(message => message.method === "item/agentMessage/delta" && message.params.turnId === turn.id);
  assert.deepEqual(deltas.map(message => message.params.delta), ["无 ID 仍只显示一次"]);
});

test("semantic per-index dedup reconciles mismatched message and tool IDs", async ({ peer }) => {
  const id = await peer.thread();
  const turn = await peer.turn(id, "semantic-duplicate");
  await peer.complete(turn);
  const latest = (await peer.history(id))[0];
  assert.deepEqual(assistantTexts(latest), ["我先看一下当前目录和这台机器的基础信息。"]);
  const tools = latest.items.filter(item => item.type === "mcpToolCall");
  assert.equal(tools.length, 1);
  assert.equal(tools[0].id, "tool-one");
  assert.equal(tools[0].status, "completed");
  assert.equal(tools[0].result, "/home/yan");
  const deltas = peer.messages.filter(message => message.method === "item/agentMessage/delta" && message.params.turnId === turn.id);
  assert.deepEqual(deltas.map(message => message.params.delta), ["我先看一下当前目录和这台机器的基础信息。"]);
});

test("thread list title remains the first prompt while preview follows the latest prompt", async ({ peer }) => {
  const id = await peer.thread();
  const first = await peer.turn(id, "first stable title");
  await peer.complete(first);
  let listed = await peer.ok("thread/list");
  let row = listed.data.find(thread => thread.id === id);
  assert.equal(row.name, "CASE:first stable title");
  assert.equal(row.preview, "CASE:first stable title");

  const second = await peer.turn(id, "second mutable preview");
  await peer.complete(second);
  listed = await peer.ok("thread/list");
  row = listed.data.find(thread => thread.id === id);
  assert.equal(row.name, "CASE:first stable title");
  assert.equal(row.preview, "CASE:second mutable preview");
});

test("legacy thread list title is inferred from its first saved user turn", async ({ peer }) => {
  const id = await peer.thread();
  const first = await peer.turn(id, "legacy stable title");
  await peer.complete(first);

  // Simulate a record written before persistent thread names were introduced.
  const store = new ThreadStore(peer.state);
  const record = store.get(id);
  delete record.name;
  record.preview = "CASE:later mutable preview";
  store.save(record);

  const listed = await peer.ok("thread/list");
  const row = listed.data.find(thread => thread.id === id);
  assert.equal(row.name, "CASE:legacy stable title");
  assert.equal(row.preview, "CASE:later mutable preview");
});

test("explicit Opus 5.5, supported efforts and server-default selection reach CLI", async ({ peer, root }) => {
  const id = await peer.thread();
  for (const effort of ["low", "medium", "high", "xhigh", "max"]) {
    await peer.complete(await peer.turn(id, "fallback", { model: "claude-opus-5-5", effort }));
    const spawn = auditFor(root).filter(value => value.type === "spawn").at(-1);
    assert.equal(spawn.args[spawn.args.indexOf("--model") + 1], "claude-opus-5-5");
    assert.equal(spawn.args[spawn.args.indexOf("--effort") + 1], effort);
    const snapshot = await peer.ok("thread/read", { threadId: id });
    assert.equal(snapshot.model, "claude-opus-5-5");
    assert.equal(snapshot.reasoningEffort, effort);
  }
  await peer.complete(await peer.turn(id, "fallback", { model: "default" }));
  const spawn = auditFor(root).filter(value => value.type === "spawn").at(-1);
  assert.ok(!spawn.args.includes("--model"), "default must defer to native settings");
  assert.ok(!spawn.args.includes("--effort"), "omitted effort must not retain an earlier per-turn override");
  for (const options of [{ effort: "ultra" }, { model: "--dangerous" }, { model: "invalid\nmodel" }, { model: "x".repeat(201) }]) {
    assert.ok((await peer.request("turn/start", { threadId: id, input: [{ type: "text", text: "should not run" }], ...options })).error);
  }
  assert.equal(auditFor(root).filter(value => value.type === "spawn").length, 6);
  const custom = modelCatalog({ model: "m-claude", reasoningEffort: "high" }).data[0];
  assert.equal(custom.model, "m-claude");
  assert.equal(custom.isDefault, true);
  assert.deepEqual(custom.supportedReasoningEfforts, []);
  assert.equal(custom.contextWindowTokens, undefined, "custom aliases cannot imply context capacity");
});

test("unsupported explicit model does not inherit global effort", async ({ peer, root }) => {
  const configDir = path.join(root, ".claude");
  fs.mkdirSync(configDir, { recursive: true });
  fs.writeFileSync(path.join(configDir, "settings.json"), JSON.stringify({
    effortLevel: "high", env: { CLAUDE_CODE_EFFORT_LEVEL: "high", ANTHROPIC_MODEL: "claude-opus-5-5" },
  }));
  const id = await peer.thread();
  for (const model of ["claude-haiku-4-5", "custom-model-id"]) {
    await peer.complete(await peer.turn(id, "fallback", { model }));
    const spawn = auditFor(root).filter(value => value.type === "spawn").at(-1);
    assert.equal(spawn.args[spawn.args.indexOf("--model") + 1], model);
    assert.ok(!spawn.args.includes("--effort"), `${model} must not inherit CLI effort`);
    assert.equal(spawn.effortEnv, "auto", `${model} must clear inherited effort`);
    assert.ok(!spawn.args.includes("--setting-sources"), "native permissions and hooks must remain enabled");
    assert.deepEqual(JSON.parse(spawn.args[spawn.args.indexOf("--settings") + 1]), {
      env: { CLAUDE_CODE_EFFORT_LEVEL: "auto" },
    });
    assert.equal((await peer.ok("thread/read", { threadId: id })).reasoningEffort, null);
  }
  await peer.complete(await peer.turn(id, "fallback", { model: "claude-opus-5-5" }));
  const opus = auditFor(root).filter(value => value.type === "spawn").at(-1);
  assert.equal(opus.args[opus.args.indexOf("--effort") + 1], "high", "Opus retains the configured default");
  assert.equal(opus.effortEnv, "high");
});

test("current context includes cache tokens, deduplicates usage and survives restart", async ({ peer, root, fake, peers }) => {
  const id = await peer.thread();
  const turn = await peer.turn(id, "usage", { model: "claude-opus-5-5" });
  await peer.complete(turn);
  const snapshot = await peer.ok("thread/resume", { threadId: id });
  assert.deepEqual(snapshot.tokenUsage.last, { inputTokens: 475, cachedInputTokens: 250, outputTokens: 40, reasoningOutputTokens: 0, totalTokens: 515 });
  assert.deepEqual(snapshot.tokenUsage.total, { inputTokens: 825, cachedInputTokens: 450, outputTokens: 70, reasoningOutputTokens: 0, totalTokens: 895 });
  assert.equal(snapshot.tokenUsage.modelContextWindow, 1000000);
  const usageEvent = peer.messages.filter(message => message.method === "thread/tokenUsage/updated" && message.params.threadId === id).at(-1);
  assert.deepEqual(usageEvent.params.tokenUsage, snapshot.tokenUsage);
  await peer.close();
  const restarted = new Peer(root, fake, peer.state);
  peers.push(restarted);
  await restarted.initialize();
  assert.deepEqual((await restarted.ok("thread/resume", { threadId: id })).tokenUsage, snapshot.tokenUsage);
  await restarted.complete(await restarted.turn(id, "usage-unknown", { model: "custom-unknown" }));
  const switched = await restarted.ok("thread/read", { threadId: id });
  assert.equal(switched.tokenUsage.modelContextWindow, 0, "a new unknown model must not inherit old model capacity");
  assert.equal(switched.tokenUsage.last.totalTokens, 515, "context is the latest request, not cumulative usage");
  assert.equal(switched.tokenUsage.total.totalTokens, 1790);
  assert.equal(usageBreakdown({ output_tokens: 7 }), null, "output alone cannot establish context input size");
  assert.equal(usageBreakdown({ input_tokens: -1, output_tokens: 7 }), null);
});

test("tool approval explicitly allows, denies and ignores an unrelated response", async ({ peer }) => {
  const id = await peer.thread();
  for (const accepted of [true, false]) {
    const turn = await peer.turn(id, "permission");
    const approval = await peer.wait(approvalFor(turn), turn.after);
    assert.equal(approval.params.threadId, id);
    assert.equal(approval.params.permissions.claudeTool.name, "Bash");
    peer.send({ id: "not-this-request", result: { permissions: approval.params.permissions } });
    assert.equal((await peer.ok("thread/read", { threadId: id })).thread.status, "active");
    peer.send({ id: approval.id, result: accepted ? { permissions: approval.params.permissions } : {} });
    await peer.wait(message => message.method === "serverRequest/resolved" && message.params.requestId === approval.id, turn.after);
    await peer.complete(turn);
    const latest = (await peer.history(id))[0];
    assert.deepEqual(assistantTexts(latest), [accepted ? "TOOL_ALLOWED" : "TOOL_DENIED"]);
    const tool = latest.items.find(item => item.id === "fixture-tool");
    assert.equal(tool.type, "mcpToolCall");
    assert.equal(tool.status, accepted ? "completed" : "failed");
    assert.equal(tool.result, accepted ? "command output" : "not executed");
  }
});

test("completion waits for CLI exit and the next turn starts immediately", async ({ peer, root }) => {
  const id = await peer.thread();
  const turn = await peer.turn(id, "slow-exit");
  await until(() => fs.existsSync(path.join(root, "audit.jsonl")) && auditFor(root).some(value => value.type === "result-sent"));
  // RPC response establishes an ordering barrier after the result was emitted.
  await peer.ok("initialize");
  assert.ok(!peer.messages.slice(turn.after).some(message => message.method === "turn/completed" && message.params.turn.id === turn.id));
  assert.ok(fs.existsSync(path.join(peer.state, id, "writer.lock")));
  fs.writeFileSync(path.join(root, "release-cli"), "release");
  await peer.complete(turn);
  assert.equal(fs.existsSync(path.join(peer.state, id, "writer.lock")), false);
  const next = await peer.turn(id, "fallback");
  await peer.complete(next);
});

test("large Unicode turns stay readable and match persisted output", async ({ peer, root }) => {
  const id = await peer.thread();
  const input = [{ type: "text", text: "CASE:unicode-limit" }, { type: "text", text: "文".repeat(500000) }];
  const turn = await peer.turn(id, "unicode-limit", { input });
  await peer.complete(turn);
  const resumed = (await peer.history(id))[0];
  const file = path.join(peer.state, id, turn.id + ".json");
  assert.ok(fs.statSync(file).size <= 2 * 1024 * 1024, "persisted UTF-8 JSON exceeded its read limit");
  assert.deepEqual(JSON.parse(fs.readFileSync(file, "utf8")), resumed);
  const shown = new Map();
  for (const message of peer.messages.slice(turn.after)) {
    if (message.method === "item/agentMessage/delta" && message.params.turnId === turn.id) {
      const { itemId, delta } = message.params;
      shown.set(itemId, (shown.get(itemId) || "") + delta);
    }
  }
  assert.deepEqual([...shown.values()], assistantTexts(resumed));
  assert.ok(assistantTexts(resumed).join("").includes("截断"), "truncated output must be explicit");
  assert.equal(resumed.items[0].content[1].text.length, 500000);
  assert.ok(auditFor(root).some(value => value.message?.type === "user"));
});

test("full access requires both flags and never bypasses AskUserQuestion", async ({ peer }) => {
  const id = await peer.thread();
  const fullAccess = { approvalPolicy: "never", sandboxPolicy: { type: "dangerFullAccess" } };
  const turn = await peer.turn(id, "permission", fullAccess);
  await peer.complete(turn);
  assert.ok(!peer.messages.slice(turn.after).some(approvalFor(turn)));
  assert.deepEqual(assistantTexts((await peer.history(id))[0]), ["TOOL_ALLOWED"]);
  for (const options of [{ approvalPolicy: "never" }, { sandboxPolicy: { type: "dangerFullAccess" } }]) {
    const restricted = await peer.turn(id, "permission", options);
    const approval = await peer.wait(approvalFor(restricted), restricted.after);
    peer.send({ id: approval.id, result: {} });
    await peer.complete(restricted);
  }
  const questionTurn = await peer.turn(id, "question", fullAccess);
  const question = await peer.wait(questionFor(questionTurn), questionTurn.after);
  assert.deepEqual(question.params.questions.map(item => item.id), ["0", "1"]);
  assert.equal(question.params.questions[0].options[0].description, "Cool");
  peer.send({ id: question.id, result: { answers: { "0": { answers: ["Blue"] }, "1": { answers: ["Local", "Other"] } } } });
  await peer.complete(questionTurn);
  assert.deepEqual(JSON.parse(assistantTexts((await peer.history(id))[0])[0]), { "Which color?": "Blue", "Which environment?": "Local, Other" });
  const skipped = await peer.turn(id, "question");
  const pending = await peer.wait(questionFor(skipped), skipped.after);
  peer.send({ id: pending.id, result: { answers: { "0": { answers: ["Blue"] } } } });
  await peer.complete(skipped);
  assert.deepEqual(assistantTexts((await peer.history(id))[0]), ["QUESTION_DENIED"]);
});

test("interrupt rejects stale turn ids, resolves approval and permits a new turn", async ({ peer }) => {
  const id = await peer.thread();
  const turn = await peer.turn(id, "permission");
  const approval = await peer.wait(approvalFor(turn), turn.after);
  assert.ok((await peer.request("turn/interrupt", { threadId: id, turnId: crypto.randomUUID() })).error);
  assert.equal((await peer.ok("thread/read", { threadId: id })).thread.status, "active");
  await peer.ok("turn/interrupt", { threadId: id, turnId: turn.id });
  await peer.complete(turn, "interrupted");
  assert.ok(peer.messages.some(message => message.method === "serverRequest/resolved" && message.params.requestId === approval.id));
  peer.send({ id: approval.id, result: { permissions: approval.params.permissions } });
  const latest = (await peer.history(id))[0];
  assert.equal(latest.status, "interrupted");
  assert.ok(!JSON.stringify(latest).includes("LATE_RESULT_AFTER_INTERRUPT"));
  assert.equal(peer.messages.filter(message => message.method === "turn/completed" && message.params.turn.id === turn.id).length, 1);
  const next = await peer.turn(id, "fallback");
  await peer.complete(next);
});

test("CLI cancellation resolves only its pending approval", async ({ peer, root }) => {
  const id = await peer.thread();
  const turn = await peer.turn(id, "cancel-approval");
  const approval = await peer.wait(approvalFor(turn), turn.after);
  await peer.wait(message => message.method === "serverRequest/resolved" && message.params.requestId === approval.id, turn.after);
  peer.send({ id: approval.id, result: { permissions: approval.params.permissions } });
  await peer.ok("initialize");
  assert.ok(!auditFor(root).some(value => value.message?.type === "control_response"));
  await peer.ok("turn/interrupt", { threadId: id, turnId: turn.id });
  await peer.complete(turn, "interrupted");
});

test("interruption before initialize never sends a late user prompt", async ({ peer, root }) => {
  const id = await peer.thread();
  const turn = await peer.turn(id, "hang", { model: "fixture-late-initialize" });
  await until(() => fs.existsSync(path.join(root, "audit.jsonl")) && auditFor(root).some(value => value.type === "initialize-held"));
  await peer.ok("turn/interrupt", { threadId: id, turnId: turn.id });
  await peer.complete(turn, "interrupted");
  assert.ok(!auditFor(root).some(value => value.message?.type === "user"));
  assert.equal((await peer.history(id))[0].status, "interrupted");
});

test("image payload uses base64 while history stores only its remote path", async ({ peer, root }) => {
  const image = path.join(root, "fixture.png");
  const bytes = Buffer.from("89504e470d0a1a0a", "hex");
  fs.writeFileSync(image, bytes);
  const id = await peer.thread();
  const turn = await peer.turn(id, "image", { input: [{ type: "localImage", path: image }] });
  await peer.complete(turn);
  const content = auditFor(root).find(value => value.message?.type === "user").message.message.content;
  assert.deepEqual(content, [{ type: "image", source: { type: "base64", media_type: "image/png", data: bytes.toString("base64") } }]);
  const latest = (await peer.history(id))[0];
  assert.deepEqual(latest.items[0].content, [{ type: "localImage", path: image }]);
  assert.ok(!JSON.stringify(latest).includes(bytes.toString("base64")));
  assert.equal(fs.statSync(path.join(peer.state, id, "thread.json")).mode & 0o777, 0o600);
});

test("history pagination, compact views, list search and workspace isolation", async ({ peer, root }) => {
  const store = new ThreadStore(peer.state);
  const record = store.create(root, null);
  record.name = "Searchable fixture";
  for (let index = 0; index < 6; index++) {
    const id = crypto.randomUUID();
    record.turnIds.push(id);
    store.saveTurn(record, { id, status: "completed", items: [{ id: "answer-" + index, type: "agentMessage", text: "line-" + index + ":" + "x".repeat(5000) }] });
  }
  store.save(record);
  const first = await peer.ok("thread/resume", { threadId: record.id, initialTurnsPage: { limit: 2, sortDirection: "desc" } });
  assert.deepEqual(first.initialTurnsPage.data.map(turn => turn.id), record.turnIds.slice(-2).reverse());
  const second = await peer.ok("thread/turns/list", { threadId: record.id, limit: 2, cursor: first.initialTurnsPage.nextCursor });
  assert.deepEqual(second.data.map(turn => turn.id), record.turnIds.slice(2, 4).reverse());
  const last = await peer.ok("thread/turns/list", { threadId: record.id, limit: 2, cursor: second.nextCursor });
  assert.deepEqual(last.data.map(turn => turn.id), record.turnIds.slice(0, 2).reverse());
  assert.equal(last.nextCursor, null);
  const asc = await peer.ok("thread/turns/list", { threadId: record.id, limit: 2, sortDirection: "asc", cursor: record.turnIds[1] });
  assert.deepEqual(asc.data.map(turn => turn.id), record.turnIds.slice(2, 4));
  const summary = await peer.ok("thread/turns/list", { threadId: record.id, limit: 1, itemsView: "summary" });
  assert.ok(summary.data[0].items[0].text.length < 4100);
  assert.match(summary.data[0].items[0].text, /已截断/);
  const unloaded = await peer.ok("thread/turns/list", { threadId: record.id, itemsView: "notLoaded" });
  assert.ok(unloaded.data.every(turn => turn.items.length === 0 && turn.itemsView === "notLoaded"));
  assert.equal((await peer.ok("thread/read", { threadId: record.id, includeTurns: false })).initialTurnsPage, undefined);
  assert.ok((await peer.request("thread/turns/list", { threadId: record.id, cursor: "missing" })).error);
  const otherDirectory = path.join(root, "other-workspace");
  fs.mkdirSync(otherDirectory);
  await peer.thread(otherDirectory);
  const secondId = await peer.thread();
  await peer.ok("thread/name/set", { threadId: secondId, name: "Second fixture" });
  const listed = await peer.ok("thread/list", { limit: 1 });
  assert.equal(listed.data.length, 1);
  assert.ok(listed.nextCursor);
  const remainder = await peer.ok("thread/list", { limit: 1, cursor: listed.nextCursor });
  assert.equal(remainder.data.length, 1);
  assert.equal(remainder.nextCursor, null);
  assert.notEqual(remainder.data[0].id, listed.data[0].id);
  assert.deepEqual((await peer.ok("thread/list", { searchTerm: "SEARCHABLE" })).data.map(thread => thread.id), [record.id]);
  assert.deepEqual((await peer.ok("thread/list", { archived: true })).data, []);
  assert.ok((await peer.request("thread/list", { cursor: "missing" })).error);
});

test("bad history records are isolated and symlink reads are rejected", async ({ peer }) => {
  const good = await peer.thread();
  const broken = await peer.thread();
  const file = path.join(peer.state, broken, "thread.json");
  fs.writeFileSync(file, "{corrupt");
  assert.deepEqual((await peer.ok("thread/list")).data.map(thread => thread.id), [good]);
  assert.ok((await peer.request("thread/resume", { threadId: broken })).error);
  fs.unlinkSync(file);
  fs.symlinkSync(path.join(peer.state, good, "thread.json"), file);
  assert.ok((await peer.request("thread/resume", { threadId: broken })).error);
  const store = new ThreadStore(peer.state);
  const record = store.get(good);
  record.turnIds = [crypto.randomUUID()];
  store.save(record);
  fs.writeFileSync(path.join(peer.state, good, record.turnIds[0] + ".json"), "{bad-turn");
  assert.ok((await peer.request("thread/resume", { threadId: good })).error);
  assert.equal((await peer.ok("initialize")).serverInfo.name, "claude-code-bridge");
});

test("two connections cannot start or rename a live writer", async ({ peer, root, fake, peers }) => {
  const id = await peer.thread();
  const turn = await peer.turn(id, "hang");
  await peer.wait(message => message.method === "item/agentMessage/delta", turn.after);
  const other = new Peer(root, fake, peer.state);
  peers.push(other);
  await other.initialize();
  assert.equal((await other.ok("thread/read", { threadId: id })).thread.status, "active");
  assert.ok((await other.request("turn/start", { threadId: id, input: [{ type: "text", text: "CASE:fallback" }] })).error);
  assert.ok((await other.request("thread/name/set", { threadId: id, name: "Wrong writer" })).error);
  await peer.ok("turn/interrupt", { threadId: id, turnId: turn.id });
  await peer.complete(turn, "interrupted");
  const recovered = await other.turn(id, "fallback");
  await other.complete(recovered);
});

test("bridge crash leaves readable interrupted history and recovers a dead lock", async ({ peer, root, fake, peers }) => {
  const id = await peer.thread();
  const turn = await peer.turn(id, "hang");
  await peer.wait(message => message.method === "item/agentMessage/delta", turn.after);
  await until(() => JSON.parse(fs.readFileSync(path.join(peer.state, id, "thread.json"), "utf8")).claudeSessionId === id);
  await peer.close("SIGKILL");
  assert.ok(fs.existsSync(path.join(peer.state, id, "writer.lock")));
  const restarted = new Peer(root, fake, peer.state);
  peers.push(restarted);
  await restarted.initialize();
  const snapshot = await restarted.ok("thread/resume", { threadId: id });
  assert.equal(snapshot.thread.status, "idle");
  assert.equal(snapshot.initialTurnsPage.data[0].status, "interrupted");
  assert.deepEqual(assistantTexts(snapshot.initialTurnsPage.data[0]), ["WAITING"]);
  const next = await restarted.turn(id, "fallback");
  await restarted.complete(next);
  assert.equal((await restarted.history(id)).length, 2);
});

test("CLI failure, malformed output, early exit and unknown control are bounded", async ({ peer }) => {
  for (const scenario of ["error", "malformed", "early-exit"]) {
    const id = await peer.thread();
    const turn = await peer.turn(id, scenario);
    const event = await peer.complete(turn, "failed");
    assert.ok(event.params.turn.error.message.length < 4100);
    assert.ok(!JSON.stringify(peer.messages).includes("DO_NOT_EXPOSE_RAW_CLI_STDERR"));
  }
  const id = await peer.thread();
  const turn = await peer.turn(id, "unknown-control");
  await peer.complete(turn);
  assert.deepEqual(assistantTexts((await peer.history(id))[0]), ["UNSUPPORTED_CONTROL_REJECTED"]);
});

test("invalid requests and attachment limits cannot start a CLI", async ({ peer, root }) => {
  const id = await peer.thread();
  for (const input of [[], null, [null], [{ type: "text", text: "  " }], [{ type: "unknown" }], Array.from({ length: 33 }, () => ({ type: "text", text: "x" }))]) {
    assert.ok((await peer.request("turn/start", { threadId: id, input })).error);
  }
  assert.ok((await peer.request("thread/resume", { threadId: "../../outside" })).error);
  assert.ok((await peer.request("thread/start", { cwd: "relative/path" })).error);
  assert.equal((await peer.request("unsupported/method", { threadId: id })).error.code, -32601);
  assert.equal(fs.existsSync(path.join(root, "audit.jsonl")), false);
  const image = path.join(root, "large.png");
  fs.writeFileSync(image, Buffer.alloc(5 * 1024 * 1024 + 1));
  assert.throws(() => prepareInput([{ type: "localImage", path: image }]), /5 MB/);
  fs.truncateSync(image, 4 * 1024 * 1024);
  assert.throws(() => prepareInput([{ type: "localImage", path: image }, { type: "localImage", path: image }]), /6 MB/);
  const link = path.join(root, "link.png");
  fs.symlinkSync(image, link);
  assert.throws(() => prepareInput([{ type: "localImage", path: link }]));
  assert.throws(() => prepareInput([{ type: "localImage", path: "relative.png" }]), /路径/);
  assert.throws(() => prepareInput([{ type: "localImage", path: path.join(root, "image.svg") }]), /格式/);
  assert.throws(() => prepareInput([{ type: "text", text: "x".repeat(512 * 1024 + 1) }]), /文本附件/);
  assert.equal(bounded("abc", 2), "ab\n[内容过长，已截断]");
  assert.equal(bounded(null), "");
});

test("malformed client JSON receives a parse error and shuts down safely", async ({ peer }) => {
  const error = peer.wait(message => message.id === null && message.error?.code === -32700);
  peer.child.stdin.write("{bad-input}\n");
  await error;
  await peer.close();
  assert.equal(peer.exit.code, 0);
});

async function main() {
  let passed = 0;
  for (const entry of cases) {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), "claude-code-protocol-"));
    const fake = path.join(root, "fake-claude.cjs");
    fs.writeFileSync(fake, "#!/usr/bin/env node\n(" + fakeClaudeMain.toString() + ")();\n", { mode: 0o700 });
    const peer = new Peer(root, fake);
    const peers = [peer];
    try {
      await peer.initialize();
      await entry.body({ peer, root, fake, peers });
      process.stdout.write("ok " + (++passed) + " - " + entry.name + "\n");
    } catch (error) {
      error.message = entry.name + ": " + error.message;
      throw error;
    } finally {
      await Promise.all(peers.map(peer => peer.close()));
      fs.rmSync(root, { recursive: true, force: true });
    }
  }
  process.stdout.write("Claude Code bridge protocol tests passed (" + passed + " scenarios)\n");
}
main().catch(error => {
  process.stderr.write((error.stack || error.message || String(error)) + "\n");
  process.exitCode = 1;
});

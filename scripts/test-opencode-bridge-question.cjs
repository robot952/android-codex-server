"use strict";

const assert = require("node:assert/strict");
const childProcess = require("node:child_process");
const fs = require("node:fs");
const http = require("node:http");
const os = require("node:os");
const path = require("node:path");
const readline = require("node:readline");

const repository = path.resolve(__dirname, "..");
const bridgePath = path.join(repository, "app/src/main/assets/opencode-bridge.cjs");
const temporaryRoot = fs.mkdtempSync(path.join(os.tmpdir(), "opencode-bridge-question-"));
const fakeBinary = path.join(temporaryRoot, "fake-opencode.cjs");
const replyPath = path.join(temporaryRoot, "question-reply.json");
const fakeSource = `
"use strict";
const fs = require("node:fs");
const http = require("node:http");
const portIndex = process.argv.indexOf("--port");
const port = Number(process.argv[portIndex + 1]);
const replyPath = process.env.QUESTION_REPLY_PATH;
let eventResponse = null;
let questionSent = false;
let sessionBusy = false;
let sessionMessages = [];
function emit(type, properties) {
  if (!eventResponse || eventResponse.destroyed) return;
  eventResponse.write("data: " + JSON.stringify({
    payload: { id: "event-" + type + "-" + Date.now(), type, properties },
  }) + "\\n\\n");
}
function body(request) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    request.on("data", chunk => chunks.push(chunk));
    request.on("end", () => {
      try { resolve(JSON.parse(Buffer.concat(chunks).toString("utf8") || "{}")); }
      catch (error) { reject(error); }
    });
    request.on("error", reject);
  });
}
function json(response, value, status) {
  response.writeHead(status || 200, { "content-type": "application/json" });
  response.end(JSON.stringify(value));
}
const server = http.createServer(async (request, response) => {
  const url = new URL(request.url, "http://127.0.0.1");
  if (request.method === "GET" && url.pathname === "/global/health") {
    json(response, { healthy: true, version: "1.18.11" });
    return;
  }
  if (request.method === "GET" && url.pathname === "/event") {
    response.writeHead(200, {
      "content-type": "text/event-stream",
      "cache-control": "no-cache",
      connection: "keep-alive",
    });
    response.write(": ready\\n\\n");
    eventResponse = response;
    return;
  }
  if (request.method === "GET" && url.pathname === "/global/config") {
    json(response, {
      model: "custom-api/test-model",
      provider: { "custom-api": { models: { "test-model": { name: "Test" } } } },
    });
    return;
  }
  if (request.method === "POST" && url.pathname.endsWith("/prompt_async")) {
    if (!questionSent) {
      questionSent = true;
      sessionBusy = true;
      const userInfo = {
        id: "user-message-1",
        sessionID: "session-1",
        role: "user",
        time: { created: 1000 },
      };
      const userPart = {
        id: "user-part-1",
        messageID: "user-message-1",
        sessionID: "session-1",
        type: "text",
        text: "show an OpenCode question",
      };
      const assistantInfo = {
        id: "assistant-message-1",
        sessionID: "session-1",
        parentID: "user-message-1",
        role: "assistant",
      };
      const questionPart = {
        id: "call-1",
        messageID: "assistant-message-1",
        sessionID: "session-1",
        type: "tool",
        tool: "question",
        state: { status: "running" },
      };
      sessionMessages = [
        { info: userInfo, parts: [userPart] },
        { info: assistantInfo, parts: [questionPart] },
      ];
      setTimeout(() => {
        emit("message.updated", { info: userInfo });
        emit("message.part.updated", { part: userPart });
        emit("message.updated", { info: assistantInfo });
        emit("message.part.updated", { part: questionPart });
        emit("question.asked", {
          id: "question-1",
          sessionID: "session-1",
          questions: [{
            header: "模式",
            question: "选择运行模式",
            options: [
              { label: "快速", description: "少量检查" },
              { label: "完整", description: "完整检查" },
            ],
          }],
          tool: { messageID: "assistant-message-1", callID: "call-1" },
        });
      }, 40);
    }
    await new Promise(resolve => setTimeout(resolve, 1500));
    response.writeHead(204);
    response.end();
    return;
  }
  if (request.method === "POST" && url.pathname === "/question/question-1/reply") {
    const value = await body(request);
    fs.writeFileSync(replyPath, JSON.stringify({ path: url.pathname, body: value }));
    json(response, true);
    const questionPart = sessionMessages[1].parts[0];
    questionPart.state = { status: "completed", output: "快速" };
    const answerPart = {
      id: "answer-1",
      messageID: "assistant-message-1",
      sessionID: "session-1",
      type: "text",
      text: "selected quick mode",
    };
    sessionMessages[1].parts.push(answerPart);
    sessionBusy = false;
    setTimeout(() => {
      // OpenCode can republish the original user part after a question reply. Its item and the
      // resumed snapshot must still belong to the same synthetic turn returned by turn/start.
      emit("message.part.updated", { part: sessionMessages[0].parts[0] });
      emit("message.part.updated", { part: questionPart });
      emit("message.part.updated", { part: answerPart });
      emit("question.replied", { requestID: "question-1", sessionID: "session-1" });
      emit("session.idle", { sessionID: "session-1" });
    }, 20);
    return;
  }
  if (request.method === "POST" && url.pathname === "/question/question-1/reject") {
    fs.writeFileSync(replyPath, JSON.stringify({ path: url.pathname, body: {} }));
    json(response, true);
    return;
  }
  if (request.method === "GET" && url.pathname === "/session") {
    json(response, [{
      id: "session-1",
      title: "Question test",
      directory: process.cwd(),
      time: { created: 1000, updated: 1000 },
    }]);
    return;
  }
  if (request.method === "GET" && url.pathname === "/session/status") {
    json(response, sessionBusy ? { "session-1": { type: "busy" } } : {});
    return;
  }
  if (request.method === "GET" && url.pathname === "/session/session-1") {
    json(response, {
      id: "session-1",
      title: "Question test",
      directory: process.cwd(),
      time: { created: 1000, updated: 1000 },
    });
    return;
  }
  if (request.method === "GET" && url.pathname === "/session/session-1/message") {
    json(response, sessionMessages);
    return;
  }
  if (request.method === "GET" && url.pathname === "/session/session-1/message/user-message-1") {
    json(response, sessionMessages[0]);
    return;
  }
  json(response, {});
});
server.listen(port, "127.0.0.1");
`;

fs.writeFileSync(fakeBinary, "#!/usr/bin/env node\n" + fakeSource, { mode: 0o755 });

const messages = [];
const pending = new Map();
let nextID = 1;
let bridgeProcess;

function waitFor(predicate, timeoutMs) {
  const started = Date.now();
  return new Promise((resolve, reject) => {
    function poll() {
      const match = messages.find(predicate);
      if (match) return resolve(match);
      if (Date.now() - started >= timeoutMs) {
        return reject(new Error("Timed out waiting for bridge message"));
      }
      setTimeout(poll, 20);
    }
    poll();
  });
}

function sendRpc(method, params) {
  const id = nextID++;
  return new Promise((resolve, reject) => {
    pending.set(id, { resolve, reject });
    bridgeProcess.stdin.write(JSON.stringify({ id, method, params: params || {} }) + "\n");
  });
}

async function main() {
  try {
    bridgeProcess = childProcess.spawn(process.execPath, [bridgePath, "--directory", repository], {
      cwd: repository,
      env: Object.assign({}, process.env, {
        HOME: path.join(temporaryRoot, "home"),
        XDG_CONFIG_HOME: path.join(temporaryRoot, "config"),
        XDG_DATA_HOME: path.join(temporaryRoot, "data"),
        XDG_CACHE_HOME: path.join(temporaryRoot, "cache"),
        OPENCODE_BIN: fakeBinary,
        QUESTION_REPLY_PATH: replyPath,
      }),
      stdio: ["pipe", "pipe", "pipe"],
    });
    bridgeProcess.on("error", error => {
      for (const callback of pending.values()) callback.reject(error);
      pending.clear();
    });
    readline.createInterface({ input: bridgeProcess.stdout, crlfDelay: Infinity })
      .on("line", line => {
        let message;
        try { message = JSON.parse(line); } catch (_) { return; }
        messages.push(message);
        if (Object.prototype.hasOwnProperty.call(message, "id") && !message.method) {
          const callback = pending.get(Number(message.id));
          if (!callback) return;
          pending.delete(Number(message.id));
          if (message.error) callback.reject(new Error(message.error.message || "RPC failed"));
          else callback.resolve(message.result);
        }
      });

    await sendRpc("initialize");
    const startedAt = Date.now();
    const turn = await sendRpc("turn/start", {
      threadId: "session-1",
      model: "custom-api/test-model",
      input: [{ type: "text", text: "slow endpoint should not block" }],
    });
    assert.equal(turn.turn.status, "inProgress");
    assert(Date.now() - startedAt < 700, "turn/start waited for prompt_async");

    const prompt = await waitFor(message => message.method === "item/tool/requestUserInput", 5_000);
    assert.equal(prompt.params.threadId, "session-1");
    assert.equal(prompt.params.turnId, turn.turn.id);
    assert.equal(prompt.params.questions[0].id, "opencode-question-0");
    assert.deepEqual(prompt.params.questions[0].options.map(option => option.label), ["快速", "完整"]);

    const resumed = await sendRpc("thread/resume", { threadId: "session-1" });
    const resumedTurn = resumed.thread.turns[resumed.thread.turns.length - 1];
    assert.equal(resumedTurn.status, "inProgress");
    assert.equal(
      resumedTurn.id,
      turn.turn.id,
      "resuming while a question is open must preserve the active turn identity",
    );

    bridgeProcess.stdin.write(JSON.stringify({
      id: prompt.id,
      result: { answers: { "opencode-question-0": { answers: ["快速"] } } },
    }) + "\n");
    const deadline = Date.now() + 5_000;
    while (!fs.existsSync(replyPath) && Date.now() < deadline) {
      await new Promise(resolve => setTimeout(resolve, 20));
    }
    assert(fs.existsSync(replyPath), "OpenCode question reply was not sent");
    const reply = JSON.parse(fs.readFileSync(replyPath, "utf8"));
    assert.equal(reply.path, "/question/question-1/reply");
    assert.deepEqual(reply.body, { answers: [["快速"]] });
    const completion = await waitFor(message => message.method === "turn/completed", 5_000);
    assert.equal(completion.params.turn.id, turn.turn.id);
    const repeatedUserItems = messages.filter(message =>
      message.method === "item/completed" &&
      message.params && message.params.item && message.params.item.id === "user-message-1",
    );
    assert(repeatedUserItems.length >= 2, "the fake server did not republish the user message");
    assert(
      repeatedUserItems.every(message => message.params.turnId === turn.turn.id),
      "republished user messages must keep the active turn identity",
    );
    process.stdout.write("OpenCode bridge question tests passed\n");
  } finally {
    for (const callback of pending.values()) callback.reject(new Error("Test shutting down"));
    pending.clear();
    if (bridgeProcess && !bridgeProcess.killed) bridgeProcess.kill("SIGTERM");
    try { fs.rmSync(temporaryRoot, { recursive: true, force: true }); } catch (_) { }
  }
}

main().catch(error => {
  process.stderr.write((error.stack || error.message || String(error)) + "\n");
  process.exitCode = 1;
});

"use strict";

const assert = require("node:assert/strict");
const path = require("node:path");
const bridge = require(path.resolve(__dirname, "../app/src/main/assets/opencode-bridge.cjs"));

assert.equal(bridge.isSessionActive({ type: "busy" }), true);
assert.equal(bridge.isSessionActive({ type: "retry" }), true);
assert.equal(bridge.isSessionActive({ type: "idle" }), false);

assert.deepEqual(bridge.parseModel("openai/gpt-5"), {
  providerID: "openai",
  modelID: "gpt-5",
});
assert.equal(bridge.parseModel("missing-provider"), null);
assert.equal(bridge.normalizeOpenCodeModel("gpt-new", "codex-remote"), "codex-remote/gpt-new");
assert.equal(
  bridge.normalizeOpenCodeModel("existing/model", "codex-remote"),
  "existing/model",
);
assert.deepEqual(
  bridge.modelConfigDefinition({
    modelId: "codex-remote/gpt-new",
    displayName: "GPT New",
    contextWindowTokens: 200000,
    maxOutputTokens: 32000,
  }, "codex-remote"),
  {
    modelID: "gpt-new",
    definition: { name: "GPT New", limit: { context: 200000, output: 32000 } },
  },
);
assert.equal(bridge.healthVersion({ healthy: true, version: " 1.18.11 " }), "1.18.11");
assert.equal(bridge.healthVersion({ healthy: true }), "opencode");

assert.deepEqual(bridge.proxyEnvironment("http://127.0.0.1:7890"), {
  HTTP_PROXY: "http://127.0.0.1:7890",
  HTTPS_PROXY: "http://127.0.0.1:7890",
  ALL_PROXY: "http://127.0.0.1:7890",
  http_proxy: "http://127.0.0.1:7890",
  https_proxy: "http://127.0.0.1:7890",
  all_proxy: "http://127.0.0.1:7890",
});
assert.throws(function () { bridge.normalizeProxyUrl("file:///tmp/proxy"); });

const mappedSettings = bridge.mapGlobalSettings({
  model: "custom/gpt-new",
  provider: {
    custom: { options: { baseURL: "https://api.example.com/v1" } },
  },
}, {
  connected: ["custom"],
  all: [{ id: "custom", key: "test-key", options: {} }],
}, "http://127.0.0.1:7890");
assert.deepEqual(mappedSettings, {
  baseUrl: "https://api.example.com/v1",
  model: "custom/gpt-new",
  reasoningEffort: "",
  modelProvider: "custom",
  hasStoredAuthentication: true,
  apiKey: "test-key",
  proxyUrl: "http://127.0.0.1:7890",
});

const models = bridge.mapModels({
  connected: ["openai"],
  default: { openai: "gpt-5" },
  all: [
    {
      id: "openai",
      name: "OpenAI",
      models: {
        "gpt-5": { id: "gpt-5", name: "GPT-5", limit: { context: 400000, output: 128000 } },
      },
    },
    { id: "disabled", name: "Disabled", models: { unused: { id: "unused" } } },
  ],
});
assert.equal(models.length, 1);
assert.deepEqual(models[0], {
  id: "openai/gpt-5",
  model: "openai/gpt-5",
  displayName: "GPT-5",
  description: "OpenAI",
  isDefault: true,
  defaultReasoningEffort: "",
  supportedReasoningEfforts: [],
  contextWindowTokens: 400000,
  maxOutputTokens: 128000,
});

const v1Permission = {
  id: "perm/1",
  sessionID: "session/1",
  permission: "bash",
  patterns: ["git status"],
  metadata: { description: "运行 git status" },
  tool: { messageID: "message-1", callID: "call-1" },
};
assert.equal(bridge.permissionApiVersion("permission.asked"), "v1");
assert.equal(bridge.permissionApiVersion("permission.v2.asked"), "v2");
assert.equal(bridge.permissionApiVersion("permission.replied"), null);
assert.deepEqual(bridge.permissionReplyTarget(v1Permission, "once", "v1"), {
  route: "/session/session%2F1/permissions/perm%2F1",
  body: { response: "once" },
});
assert.deepEqual(bridge.permissionPrompt(v1Permission, "turn-1"), {
  threadId: "session/1",
  turnId: "turn-1",
  itemId: "call-1",
  reason: "运行 git status",
  cwd: process.cwd(),
  permissions: { bash: true },
});

const v2Permission = {
  id: "perm-2",
  sessionID: "session-2",
  action: "external_directory",
  resources: ["/srv/project"],
};
assert.deepEqual(bridge.permissionReplyTarget(v2Permission, "reject", "v2"), {
  route: "/permission/perm-2/reply",
  body: { reply: "reject" },
});

const question = {
  id: "question/1",
  sessionID: "session/1",
  questions: [{
    header: "模式",
    question: "选择运行模式",
    options: [
      { label: "快速", description: "少量检查" },
      { label: "完整", description: "完整检查" },
    ],
  }],
  tool: { messageID: "message-2", callID: "call-2" },
};
assert.equal(bridge.questionApiVersion("question.asked"), "v1");
assert.equal(bridge.questionApiVersion("question.v2.asked"), "v2");
assert.equal(bridge.questionApiVersion("question.replied"), null);
assert.deepEqual(bridge.questionPrompt(question, "turn-2"), {
  threadId: "session/1",
  turnId: "turn-2",
  itemId: "call-2",
  title: "模式",
  detail: "选择运行模式",
  cwd: process.cwd(),
  questions: [{
    id: "opencode-question-0",
    header: "模式",
    question: "选择运行模式",
    options: [
      { label: "快速", description: "少量检查" },
      { label: "完整", description: "完整检查" },
    ],
    isSecret: false,
  }],
});
assert.deepEqual(bridge.questionReplyTarget(question, [["快速"]], "v1"), {
  route: "/question/question%2F1/reply",
  body: { answers: [["快速"]] },
});
assert.deepEqual(bridge.questionReplyTarget(question, [["完整"]], "v2"), {
  route: "/api/session/session%2F1/question/question%2F1/reply",
  body: { answers: [["完整"]] },
});
assert.equal(
  bridge.questionRejectTarget(question, "v2"),
  "/api/session/session%2F1/question/question%2F1/reject",
);
assert.deepEqual(
  bridge.questionAnswersFromResponse(
    { questions: [{ id: "opencode-question-0" }] },
    { answers: { "opencode-question-0": { answers: ["快速"] } } },
  ),
  [["快速"]],
);

const turns = bridge.groupMessages([
  {
    info: { id: "user-1", role: "user", time: { created: 1000 } },
    parts: [{ id: "part-u", type: "text", text: "hello" }],
  },
  {
    info: { id: "assistant-1", parentID: "user-1", role: "assistant" },
    parts: [
      { id: "reason-1", type: "reasoning", text: "thinking" },
      { id: "answer-1", type: "text", text: "done" },
    ],
  },
], false);
assert.equal(turns.length, 1);
assert.equal(turns[0].items[0].type, "userMessage");
assert.equal(turns[0].items[1].type, "reasoning");
assert.equal(turns[0].items[2].type, "agentMessage");

process.stdout.write("OpenCode bridge tests passed\n");

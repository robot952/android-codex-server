"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
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
assert.equal(bridge.normalizeOpenCodeModel("gpt-new", "custom-api"), "custom-api/gpt-new");
assert.equal(
  bridge.normalizeOpenCodeModel("existing/model", "custom-api"),
  "existing/model",
);
assert.equal(
  bridge.normalizeOpenCodeModel("codex-remote/gpt-5.6-sol", "custom-api"),
  "custom-api/gpt-5.6-sol",
);
assert.deepEqual(
  bridge.modelConfigDefinition({
    modelId: "custom-api/gpt-new",
    displayName: "GPT New",
    contextWindowTokens: 200000,
    maxOutputTokens: 32000,
  }, "custom-api"),
  {
    modelID: "gpt-new",
    definition: {
      name: "GPT New",
      provider: { npm: "@ai-sdk/openai-compatible" },
      limit: { context: 200000, output: 32000 },
    },
  },
);
assert.deepEqual(
  bridge.modelConfigDefinition({
    modelId: "custom-api/gpt-5.6-sol",
    displayName: "GPT 5.6 Sol",
  }, "custom-api"),
  {
    modelID: "gpt-5.6-sol",
    definition: {
      name: "GPT 5.6 Sol",
      provider: { npm: "@ai-sdk/openai-compatible" },
      reasoning: true,
      variants: {
        minimal: { reasoningEffort: "minimal" },
        low: { reasoningEffort: "low" },
        medium: { reasoningEffort: "medium" },
        high: { reasoningEffort: "high" },
        xhigh: { reasoningEffort: "xhigh" },
      },
    },
  },
);
const syncPlan = bridge.buildModelSyncPatch({
  model: "custom-api/legacy",
  provider: {
    "custom-api": {
      name: "Keep this name",
      npm: "keep-this-package",
      options: { baseURL: "https://api.example.com/v1", timeout: 30 },
      headers: { "x-test": "preserve" },
      models: {
        legacy: { name: "Legacy" },
        untouched: { name: "Untouched" },
      },
    },
  },
  features: { preserve: true },
}, {
  models: [{
    modelId: "custom-api/new-model",
    displayName: "New model",
    contextWindowTokens: 128000,
    maxOutputTokens: 16000,
  }],
  removeModelIds: ["custom-api/legacy"],
});
assert.deepEqual(syncPlan.patch.provider["custom-api"].options, {
  baseURL: "https://api.example.com/v1",
  timeout: 30,
});
assert.deepEqual(syncPlan.patch.provider["custom-api"].headers, { "x-test": "preserve" });
assert.deepEqual(syncPlan.patch.provider["custom-api"].models, {
  "new-model": {
    name: "New model",
    provider: { npm: "@ai-sdk/openai-compatible" },
    limit: { context: 128000, output: 16000 },
  },
});
assert.equal(syncPlan.patch.model, "custom-api/untouched");
assert.deepEqual(syncPlan.removedModelIds, ["custom-api/legacy"]);

const removalOnlyPlan = bridge.buildModelSyncPatch({
  provider: {
    "custom-api": { models: { removable: { name: "Remove me" } } },
  },
}, {
  models: [],
  removeModelIds: ["custom-api/removable"],
});
assert.equal(removalOnlyPlan.patch, null);
assert.deepEqual(removalOnlyPlan.removedModelIds, ["custom-api/removable"]);

const responsesPlan = bridge.buildModelSyncPatch({
  provider: {
    "custom-api": {
      npm: "@ai-sdk/openai-compatible",
      models: {
        switching: {
          name: "Switching",
          provider: { npm: "@ai-sdk/openai-compatible" },
        },
      },
    },
  },
}, {
  models: [{
    modelId: "custom-api/switching",
    displayName: "Switching",
    apiProtocol: "responses",
  }],
  removeModelIds: [],
});
assert.equal(
  responsesPlan.patch.provider["custom-api"].models.switching.provider.npm,
  "@ai-sdk/openai",
);
const chatCompletionsPlan = bridge.buildModelSyncPatch({
  provider: {
    "custom-api": {
      npm: "@ai-sdk/openai-compatible",
      models: responsesPlan.patch.provider["custom-api"].models,
    },
  },
}, {
  models: [{
    modelId: "custom-api/switching",
    displayName: "Switching",
    apiProtocol: "chat_completions",
  }],
  removeModelIds: [],
});
assert.equal(
  chatCompletionsPlan.patch.provider["custom-api"].models.switching.provider.npm,
  "@ai-sdk/openai-compatible",
);
assert.throws(function () {
  bridge.normalizeModelApiProtocol("unsupported");
});

const migration = bridge.buildManagedProviderMigration({
  model: "codex-remote/gpt-5.6-sol",
  agent: {
    build: { model: "codex-remote/gpt-5.6-sol", variant: "high", temperature: 0.2 },
  },
  provider: {
    "codex-remote": {
      name: "Codex Remote",
      npm: "@ai-sdk/openai-compatible",
      options: { baseURL: "https://api.example.com/v1", timeout: 30 },
      models: { "gpt-5.6-sol": { name: "GPT 5.6 Sol" } },
    },
    "custom-api": {
      headers: { "x-existing": "keep" },
      models: { untouched: { name: "Untouched" } },
    },
  },
});
assert.equal(migration.patch.model, "custom-api/gpt-5.6-sol");
assert.equal(migration.patch.agent.build.model, "custom-api/gpt-5.6-sol");
assert.equal(migration.patch.provider["custom-api"].name, "Custom API");
assert.equal(migration.patch.provider["custom-api"].options.timeout, 30);
assert.equal(migration.patch.provider["custom-api"].headers["x-existing"], "keep");
assert.equal(
  migration.patch.provider["custom-api"].models["gpt-5.6-sol"].variants.high.reasoningEffort,
  "high",
);
assert.equal(migration.patch.provider["custom-api"].models.untouched.name, "Untouched");

const parserLookupPaths = [path.dirname(process.execPath)];
if (process.env.OPENCODE_BIN) parserLookupPaths.push(path.dirname(path.resolve(process.env.OPENCODE_BIN)));
let jsoncParserPath = "";
for (const lookupPath of parserLookupPaths) {
  try {
    jsoncParserPath = require.resolve("jsonc-parser", { paths: [lookupPath] });
    break;
  } catch (error) { /* try the next runtime */ }
}
if (jsoncParserPath) {
  const previousParser = process.env.OPENCODE_JSONC_PARSER;
  const parserDirectory = path.dirname(jsoncParserPath);
  process.env.OPENCODE_JSONC_PARSER = parserDirectory;
  const legacyJsonc = [
    "{",
    "  // Preserve this comment.",
    "  \"provider\": {",
    "    \"codex-remote\": { \"models\": { \"old\": { \"name\": \"Old\" } } },",
    "    \"custom-api\": { \"models\": {} },",
    "  },",
    "  \"agent\": { \"build\": { \"variant\": \"high\", \"temperature\": 0.2 } },",
    "}",
    "",
  ].join("\n");
  const removedLegacy = bridge.migrateManagedProviderConfigText(legacyJsonc);
  assert.equal(removedLegacy.changed, true);
  assert(!Object.prototype.hasOwnProperty.call(removedLegacy.config.provider, "codex-remote"));
  assert(removedLegacy.text.includes("Preserve this comment"));
  const removedVariant = bridge.removeConfigValueFromText(
    removedLegacy.text,
    ["agent", "build", "variant"],
  );
  assert.equal(removedVariant.changed, true);
  assert.equal(removedVariant.config.agent.build.variant, undefined);
  assert.equal(removedVariant.config.agent.build.temperature, 0.2);
  if (previousParser === undefined) delete process.env.OPENCODE_JSONC_PARSER;
  else process.env.OPENCODE_JSONC_PARSER = previousParser;
}

const newProviderPlan = bridge.buildModelSyncPatch({}, {
  models: [{ modelId: "new-provider/model" }],
  removeModelIds: [],
});
assert.equal(newProviderPlan.patch.provider["new-provider"].models.model.name, "model");
assert.equal(newProviderPlan.patch.provider["new-provider"].models.model.provider, undefined);
assert.equal(newProviderPlan.patch.provider["new-provider"].npm, "@ai-sdk/openai-compatible");
assert.equal(
  bridge.buildModelSyncPatch(newProviderPlan.patch, { models: [], removeModelIds: [] }).patch,
  null,
);
assert.equal(bridge.healthVersion({ healthy: true, version: " 1.18.11 " }), "1.18.11");
assert.equal(bridge.healthVersion({ healthy: true }), "opencode");

assert.deepEqual(bridge.compactionModel([
  {
    info: {
      role: "assistant",
      providerID: "codex-remote",
      modelID: "older-model",
    },
  },
  {
    info: {
      role: "assistant",
      providerID: "anthropic",
      modelID: "claude-sonnet-4-5",
    },
  },
], {
  model: "custom-api/default-model",
}), {
  providerID: "anthropic",
  modelID: "claude-sonnet-4-5",
});
assert.deepEqual(bridge.compactionModel([], {
  model: "custom-api/default-model",
  agent: { build: { model: "codex-remote/build-model" } },
}), {
  providerID: "custom-api",
  modelID: "build-model",
});
assert.equal(bridge.compactionModel([], {}), null);

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

const previousDataHome = process.env.XDG_DATA_HOME;
const authTestRoot = fs.mkdtempSync(path.join(os.tmpdir(), "opencode-auth-read-"));
try {
  process.env.XDG_DATA_HOME = authTestRoot;
  const authDirectory = path.join(authTestRoot, "opencode");
  fs.mkdirSync(authDirectory, { recursive: true });
  fs.writeFileSync(path.join(authDirectory, "auth.json"), JSON.stringify({
    custom: { type: "api", key: "stored-test-key" },
    oauth: { type: "oauth", access: "not-an-api-key" },
  }));
  assert.equal(bridge.readStoredApiKey("custom"), "stored-test-key");
  assert.equal(bridge.readStoredApiKey("oauth"), "");
  assert.equal(bridge.mapGlobalSettings({
    model: "custom/gpt-new",
    provider: { custom: { options: { baseURL: "https://api.example.com/v1" } } },
  }, {
    connected: ["custom"],
    all: [{ id: "custom", options: {} }],
  }, "").apiKey, "stored-test-key");
} finally {
  if (previousDataHome === undefined) delete process.env.XDG_DATA_HOME;
  else process.env.XDG_DATA_HOME = previousDataHome;
  fs.rmSync(authTestRoot, { recursive: true, force: true });
}

const models = bridge.mapModels({
  connected: ["openai"],
  default: { openai: "gpt-5" },
  all: [
    {
      id: "openai",
      name: "OpenAI",
      models: {
        "gpt-5": {
          id: "gpt-5",
          name: "GPT-5",
          limit: { context: 400000, output: 128000 },
          variants: { low: { reasoningEffort: "low" }, high: { reasoningEffort: "high" } },
        },
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
  supportedReasoningEfforts: ["low", "high"],
  contextWindowTokens: 400000,
  maxOutputTokens: 128000,
});

const managedModels = bridge.mapModels({
  connected: ["custom-api"],
  default: { "custom-api": "gpt-managed" },
  all: [{
    id: "custom-api",
    name: "Custom API",
    npm: "@ai-sdk/openai-compatible",
    models: {
      "gpt-managed": {
        id: "gpt-managed",
        name: "GPT Managed",
      },
    },
  }],
}, {
  provider: {
    "custom-api": {
      models: {
        "gpt-managed": { provider: { npm: "@ai-sdk/openai" } },
      },
    },
  },
});
assert.equal(managedModels[0].isCustom, true);
assert.equal(managedModels[0].apiProtocol, "responses");

assert.deepEqual(
  bridge.mapMessageTokenUsage({
    role: "assistant",
    providerID: "openai",
    modelID: "gpt-5",
    tokens: {
      input: 11,
      output: 5,
      reasoning: 2,
      cache: { read: 7, write: 3 },
    },
  }, 400000),
  {
    last: {
      cachedInputTokens: 7,
      inputTokens: 11,
      outputTokens: 5,
      reasoningOutputTokens: 2,
      totalTokens: 28,
    },
    total: {
      cachedInputTokens: 7,
      inputTokens: 11,
      outputTokens: 5,
      reasoningOutputTokens: 2,
      totalTokens: 28,
    },
    modelContextWindow: 400000,
  },
);
assert.equal(
  bridge.mapMessageTokenUsage({ tokens: { input: 11, output: 1, reasoning: 0, cache: { read: 0, write: 0 } } }, 0),
  null,
);

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

const resumedActiveTurns = bridge.groupMessages([
  {
    info: {
      id: "user-active",
      sessionID: "session-active",
      role: "user",
      time: { created: 2000 },
    },
    parts: [{ id: "part-user-active", type: "text", text: "ask a question" }],
  },
  {
    info: {
      id: "assistant-active",
      sessionID: "session-active",
      parentID: "user-active",
      role: "assistant",
    },
    parts: [{ id: "part-question-active", type: "tool", tool: "question", state: {} }],
  },
], true, "opencode-turn-active");
assert.equal(resumedActiveTurns.length, 1);
assert.equal(
  resumedActiveTurns[0].id,
  "opencode-turn-active",
  "resuming an active session must preserve the turn/start identity",
);
assert.equal(resumedActiveTurns[0].status, "inProgress");

assert.deepEqual(bridge.normalizeInitialTurnsPageRequest(), {
  limit: 4,
  itemsView: "full",
  sortDirection: "desc",
});
assert.deepEqual(
  bridge.normalizeInitialTurnsPageRequest({
    limit: 0,
    itemsView: "unsupported",
    sortDirection: "sideways",
  }),
  { limit: 4, itemsView: "full", sortDirection: "desc" },
);
assert.deepEqual(
  bridge.normalizeInitialTurnsPageRequest({
    limit: "2",
    itemsView: "summary",
    sortDirection: "asc",
  }),
  { limit: 2, itemsView: "summary", sortDirection: "asc" },
);
assert.equal(bridge.normalizeInitialTurnsPageRequest({ limit: 1000 }).limit, 100);
assert.equal(bridge.normalizeInitialTurnsPageRequest({ limit: 1.5 }).limit, 4);

const heavyText = "x".repeat(4000);
const pageTurns = [
  {
    id: "turn-oldest",
    status: "completed",
    startedAt: 1000,
    items: [{ id: "old-user", type: "userMessage", content: [] }],
  },
  {
    id: "turn-middle",
    status: "completed",
    startedAt: 2000,
    items: [{ id: "middle-agent", type: "agentMessage", text: "middle" }],
  },
  {
    id: "turn-newest",
    status: "inProgress",
    startedAt: 3000,
    items: [
      {
        id: "new-user",
        type: "userMessage",
        content: [
          { type: "text", text: heavyText },
          { type: "localImage", path: "/tmp/large-image.png" },
        ],
      },
      {
        id: "new-reasoning",
        type: "reasoning",
        content: [{ text: heavyText }],
      },
      {
        id: "new-command",
        type: "commandExecution",
        command: "build",
        aggregatedOutput: heavyText,
      },
      {
        id: "new-agent",
        type: "agentMessage",
        text: heavyText,
        phase: "final_answer",
      },
      { id: "new-compaction", type: "contextCompaction" },
    ],
  },
];

const fullTurnPage = bridge.buildInitialTurnsPage(pageTurns, {
  limit: 1,
  sortDirection: "desc",
  itemsView: "full",
}, "thread-page");
assert.ok(fullTurnPage.nextCursor);
assert.deepEqual(fullTurnPage.data, [pageTurns[2]]);
assert.deepEqual(
  bridge.buildInitialTurnsPage(pageTurns, {
    limit: 2,
    sortDirection: "desc",
    itemsView: "full",
  }, "thread-page").data.map(turn => turn.id),
  ["turn-newest", "turn-middle"],
);
assert.deepEqual(
  bridge.buildInitialTurnsPage(pageTurns, {
    limit: 2,
    sortDirection: "asc",
    itemsView: "full",
  }, "thread-page").data.map(turn => turn.id),
  ["turn-oldest", "turn-middle"],
);
assert.deepEqual(
  bridge.buildInitialTurnsPage(pageTurns, undefined, "thread-page").data.map(turn => turn.id),
  ["turn-newest", "turn-middle", "turn-oldest"],
);

const summaryTurnPage = bridge.buildInitialTurnsPage(pageTurns, {
  limit: 1,
  sortDirection: "desc",
  itemsView: "summary",
}, "thread-page");
assert.equal(summaryTurnPage.data[0].id, "turn-newest");
assert.equal(summaryTurnPage.data[0].status, "inProgress");
assert.deepEqual(
  summaryTurnPage.data[0].items.map(item => item.type),
  ["userMessage", "agentMessage", "contextCompaction"],
);
assert.equal(summaryTurnPage.data[0].items[0].content.length, 1);
assert.equal(summaryTurnPage.data[0].items[0].content[0].text.length, 512);
assert.equal(summaryTurnPage.data[0].items[1].text.length, 512);

const unloadedTurnPage = bridge.buildInitialTurnsPage(pageTurns, {
  limit: 1,
  sortDirection: "desc",
  itemsView: "notLoaded",
}, "thread-page");
assert.deepEqual(unloadedTurnPage.data, [{
  id: "turn-newest",
  status: "inProgress",
  startedAt: 3000,
  items: [],
}]);
assert.ok(JSON.stringify(fullTurnPage).length > JSON.stringify(summaryTurnPage).length);
assert.ok(JSON.stringify(summaryTurnPage).length > JSON.stringify(unloadedTurnPage).length);
assert.equal(pageTurns[2].items.length, 5, "page projection must not mutate hydrated turns");

const firstCursorPage = bridge.buildTurnsPage(pageTurns, {
  limit: 1,
  sortDirection: "desc",
  itemsView: "notLoaded",
}, "thread-page");
assert.ok(firstCursorPage.nextCursor);
assert.deepEqual(
  bridge.buildTurnsPage(pageTurns, {
    limit: 1,
    sortDirection: "desc",
    itemsView: "notLoaded",
  }, "thread-page", firstCursorPage.nextCursor).data.map(turn => turn.id),
  ["turn-middle"],
);
assert.throws(
  () => bridge.buildTurnsPage(pageTurns, {
    limit: 1,
    sortDirection: "desc",
    itemsView: "notLoaded",
  }, "another-thread", firstCursorPage.nextCursor),
  error => error && error.code === -32602,
);

const hydratedResumeThread = {
  id: "thread-resume",
  status: "active",
  turns: pageTurns,
  tokenUsage: { totalTokens: 42 },
};
const resumeResponse = bridge.buildThreadResumeResponse(hydratedResumeThread, {
  limit: 1,
  sortDirection: "desc",
  itemsView: "notLoaded",
});
assert.equal(Object.hasOwn(resumeResponse.thread, "turns"), false);
assert.equal(resumeResponse.thread.tokenUsage.totalTokens, 42);
assert.equal(resumeResponse.initialTurnsPage.data[0].id, "turn-newest");
assert.equal(hydratedResumeThread.turns, pageTurns, "resume response must not mutate its input");

const activeTurnForMutation = { id: "turn-current" };
assert.deepEqual(
  bridge.validateActiveTurn(
    { threadId: "thread-active", expectedTurnId: "turn-current" },
    activeTurnForMutation,
    "expectedTurnId",
  ),
  { sessionID: "thread-active", turn: activeTurnForMutation },
);
assert.deepEqual(
  bridge.validateActiveTurn(
    { threadId: "thread-active", turnId: "turn-current" },
    activeTurnForMutation,
    "turnId",
  ),
  { sessionID: "thread-active", turn: activeTurnForMutation },
);

function assertStaleTurn(params, active, expectedField) {
  assert.throws(
    () => bridge.validateActiveTurn(params, active, expectedField),
    error => error &&
      error.code === bridge.staleTurnErrorCode &&
      error.message.includes("no longer active"),
  );
}

assertStaleTurn(
  { threadId: "thread-active", expectedTurnId: "turn-old" },
  activeTurnForMutation,
  "expectedTurnId",
);
assertStaleTurn(
  { threadId: "thread-active", turnId: "turn-old" },
  activeTurnForMutation,
  "turnId",
);
assertStaleTurn(
  { threadId: "thread-active", expectedTurnId: "turn-current" },
  null,
  "expectedTurnId",
);
assertStaleTurn(
  { threadId: "thread-active", turnId: "turn-current" },
  activeTurnForMutation,
  "expectedTurnId",
);
assertStaleTurn(
  { threadId: 123, expectedTurnId: "turn-current" },
  activeTurnForMutation,
  "expectedTurnId",
);

process.stdout.write("OpenCode bridge tests passed\n");

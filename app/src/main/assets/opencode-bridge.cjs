"use strict";

const childProcess = require("node:child_process");
const crypto = require("node:crypto");
const fs = require("node:fs");
const net = require("node:net");
const os = require("node:os");
const path = require("node:path");
const readline = require("node:readline");

const directoryArgument = process.argv.indexOf("--directory");
const directory = directoryArgument >= 0 && process.argv[directoryArgument + 1]
  ? path.resolve(process.argv[directoryArgument + 1])
  : process.cwd();
const openCodeBin = process.env.OPENCODE_BIN;
const serverUsername = "codex-remote";
const serverPassword = crypto.randomBytes(32).toString("hex");
const serverAuthorization = "Basic " + Buffer.from(
  serverUsername + ":" + serverPassword,
).toString("base64");
const managedProviderID = "custom-api";
const legacyManagedProviderID = "codex-remote";
const managedProviderName = "Custom API";
const managedProviderPackage = "@ai-sdk/openai-compatible";
const managedReasoningEfforts = ["minimal", "low", "medium", "high", "xhigh"];
const bridgeStartedAt = Date.now();

let baseUrl = "";
let serverProcess = null;
let shuttingDown = false;
let sseStarted = false;
let openCodeVersion = "opencode";
const activeTurns = new Map();
const messageInfo = new Map();
const messageToTurn = new Map();
const pendingPermissions = new Map();
const pendingQuestions = new Map();
const modelContextWindows = new Map();
const publishedTokenUsage = new Map();
let modelCatalogRefresh = null;
let jsoncParserModule = null;

function send(value) {
  process.stdout.write(JSON.stringify(value) + "\n");
}

function notify(method, params) {
  send({ method: method, params: params || {} });
}

function reservePort() {
  return new Promise(function (resolve, reject) {
    const server = net.createServer();
    server.unref();
    server.on("error", reject);
    server.listen(0, "127.0.0.1", function () {
      const address = server.address();
      const port = address && typeof address === "object" ? address.port : 0;
      server.close(function () {
        if (port) resolve(port);
        else reject(new Error("Unable to reserve a local port"));
      });
    });
  });
}

async function request(route, options) {
  const opts = options || {};
  const url = new URL(baseUrl + route);
  if (directory) url.searchParams.set("directory", directory);
  const headers = Object.assign({ authorization: serverAuthorization }, opts.headers || {});
  let body;
  if (Object.prototype.hasOwnProperty.call(opts, "body")) {
    headers["content-type"] = "application/json";
    body = JSON.stringify(opts.body);
  }
  const response = await fetch(url, {
    method: opts.method || "GET",
    headers: headers,
    body: body,
    signal: opts.timeoutMs ? AbortSignal.timeout(opts.timeoutMs) : undefined,
  });
  const text = await response.text();
  if (!response.ok) {
    throw new Error((opts.method || "GET") + " " + url.pathname + " failed (" +
      response.status + "): " + text.slice(0, 500));
  }
  if (!text.trim()) return null;
  try {
    return JSON.parse(text);
  } catch (error) {
    return text;
  }
}

async function waitForServer() {
  let lastError = null;
  for (let attempt = 0; attempt < 100; attempt += 1) {
    try {
      return await request("/global/health", { timeoutMs: 750 });
    } catch (error) {
      lastError = error;
      await new Promise(function (resolve) { setTimeout(resolve, 100); });
    }
  }
  throw lastError || new Error("OpenCode server did not become ready");
}

function healthVersion(health) {
  const value = health && typeof health.version === "string" ? health.version.trim() : "";
  return value || "opencode";
}

function statusType(value) {
  if (!value) return "idle";
  if (typeof value === "string") return value;
  return value.type || "idle";
}

function isSessionActive(value) {
  const type = statusType(value);
  return type === "busy" || type === "retry";
}

function mapSession(session, status) {
  const time = session.time || {};
  return {
    id: session.id || "",
    name: session.title || "",
    preview: session.title || "",
    cwd: session.directory || directory,
    source: "opencode",
    status: isSessionActive(status) ? "active" : "idle",
    createdAt: Number(time.created || 0),
    updatedAt: Number(time.updated || time.created || 0),
    cliVersion: openCodeVersion,
  };
}

function mapUserMessage(info, parts) {
  const content = [];
  for (const part of parts || []) {
    if (part.type === "text" && part.text) {
      content.push({ type: "text", text: part.text });
    } else if (part.type === "file" && part.url) {
      if (String(part.mime || "").startsWith("image/")) {
        content.push({ type: "localImage", path: String(part.url).replace(/^file:\/\//, "") });
      } else {
        content.push({
          type: "text",
          text: "附件 " + (part.filename || path.basename(part.url)) + ": " +
            String(part.url).replace(/^file:\/\//, ""),
        });
      }
    }
  }
  return {
    id: info.id || "user-message",
    type: "userMessage",
    content: content,
  };
}

function nonNegativeTokenCount(value) {
  const number = Number(value);
  return Number.isFinite(number) && number >= 0 ? Math.floor(number) : 0;
}

/**
 * Converts OpenCode's AssistantMessage.tokens shape to the neutral token breakdown used by the
 * Android client. OpenCode counts cache reads/writes as part of the context window as well.
 */
function mapMessageTokenUsage(info, contextWindowTokens) {
  const tokens = objectValue(info && info.tokens);
  if (!Object.keys(tokens).length) return null;
  const cache = objectValue(tokens.cache);
  const cachedInputTokens = nonNegativeTokenCount(
    cache.read ?? tokens.cachedInputTokens ?? tokens.cacheRead,
  );
  const inputTokens = nonNegativeTokenCount(tokens.input ?? tokens.inputTokens ?? tokens.prompt_tokens);
  const outputTokens = nonNegativeTokenCount(tokens.output ?? tokens.outputTokens ?? tokens.completion_tokens);
  const reasoningOutputTokens = nonNegativeTokenCount(tokens.reasoning ?? tokens.reasoningOutputTokens);
  const cacheWriteTokens = nonNegativeTokenCount(cache.write ?? tokens.cacheWrite);
  const totalTokens = cachedInputTokens + inputTokens + outputTokens +
    reasoningOutputTokens + cacheWriteTokens;
  const contextWindow = nonNegativeTokenCount(contextWindowTokens);
  if (totalTokens <= 0 || contextWindow <= 0) return null;
  const last = {
    cachedInputTokens: cachedInputTokens,
    inputTokens: inputTokens,
    outputTokens: outputTokens,
    reasoningOutputTokens: reasoningOutputTokens,
    totalTokens: totalTokens,
  };
  return {
    // The Android reducer uses `last` for the context ring. `total` is kept equal to the latest
    // OpenCode sample because the bridge only receives the latest assistant message here; the UI
    // deliberately does not use the cumulative thread total for the ring.
    last: last,
    total: last,
    modelContextWindow: contextWindow,
  };
}

function modelReferenceFromInfo(info, sessionID) {
  const providerID = String(info && info.providerID || "").trim();
  const modelID = String(info && info.modelID || "").trim();
  if (providerID && modelID) return providerID + "/" + modelID;
  const active = activeTurns.get(sessionID);
  return active && active.modelReference || "";
}

function modelContextWindowForInfo(info, sessionID) {
  const reference = modelReferenceFromInfo(info, sessionID);
  if (!reference) return 0;
  return modelContextWindows.get(reference) || 0;
}

function publishTokenUsage(sessionID, tokenUsage) {
  if (!sessionID || !tokenUsage) return;
  const signature = JSON.stringify(tokenUsage);
  if (publishedTokenUsage.get(sessionID) === signature) return;
  publishedTokenUsage.set(sessionID, signature);
  notify("thread/tokenUsage/updated", {
    threadId: sessionID,
    tokenUsage: tokenUsage,
  });
}

function tokenUsageForInfo(info, sessionID) {
  return mapMessageTokenUsage(info, modelContextWindowForInfo(info, sessionID));
}

async function refreshModelContextWindows() {
  if (modelCatalogRefresh) return modelCatalogRefresh;
  modelCatalogRefresh = request("/provider")
    .then(function (providers) {
      mapModels(providers || {});
    })
    .catch(function () {
      // Model limits are optional in OpenCode provider metadata. A missing limit is represented
      // as an unavailable context ring rather than failing an otherwise usable turn.
    })
    .finally(function () {
      modelCatalogRefresh = null;
    });
  return modelCatalogRefresh;
}

async function tokenUsageForMessages(messages) {
  const latest = (messages || []).slice().reverse().find(function (message) {
    const info = message && message.info;
    return info && info.role === "assistant" && Object.keys(objectValue(info.tokens)).length;
  });
  if (!latest) return null;
  const sessionID = latest.info.sessionID || "";
  let usage = tokenUsageForInfo(latest.info, sessionID);
  if (!usage) {
    await refreshModelContextWindows();
    usage = tokenUsageForInfo(latest.info, sessionID);
  }
  return usage;
}

async function publishTokenUsageForInfo(info, sessionID) {
  let usage = tokenUsageForInfo(info, sessionID);
  if (!usage) {
    await refreshModelContextWindows();
    usage = tokenUsageForInfo(info, sessionID);
  }
  publishTokenUsage(sessionID, usage);
}

function toolStatus(state) {
  const status = state && state.status;
  if (status === "completed") return "completed";
  if (status === "error") return "failed";
  return "inProgress";
}

function toolOutput(state) {
  if (!state) return "";
  if (typeof state.output === "string") return state.output;
  if (typeof state.error === "string") return state.error;
  return "";
}

function mapPart(part, role) {
  if (!part) return null;
  const id = part.id || (part.messageID + "-" + part.type);
  if (role === "user") return null;
  if (part.type === "text") {
    return { id: id, type: "agentMessage", text: part.text || "", phase: "final_answer" };
  }
  if (part.type === "reasoning") {
    return {
      id: id,
      type: "reasoning",
      summary: [],
      content: [{ text: part.text || "" }],
    };
  }
  if (part.type === "tool") {
    const state = part.state || {};
    const input = state.input || {};
    if (part.tool === "bash" || part.tool === "shell") {
      return {
        id: id,
        type: "commandExecution",
        command: input.command || input.cmd || "",
        cwd: input.cwd || directory,
        status: toolStatus(state),
        aggregatedOutput: toolOutput(state),
      };
    }
    if (part.tool === "edit" || part.tool === "write" || part.tool === "patch") {
      const file = input.filePath || input.path || input.file || "";
      const diff = state.metadata && typeof state.metadata.diff === "string"
        ? state.metadata.diff
        : "";
      if (file) {
        return {
          id: id,
          type: "fileChange",
          status: toolStatus(state),
          changes: [{ path: file, kind: part.tool, diff: diff }],
        };
      }
    }
    return {
      id: id,
      type: "dynamicToolCall",
      tool: part.tool || "OpenCode tool",
      status: toolStatus(state),
      result: toolOutput(state),
    };
  }
  if (part.type === "patch") {
    return {
      id: id,
      type: "fileChange",
      status: "completed",
      changes: (part.files || []).map(function (file) {
        return { path: file, kind: "patch", diff: "" };
      }),
    };
  }
  if (part.type === "compaction") {
    return { id: id, type: "contextCompaction" };
  }
  if (part.type === "subtask") {
    return {
      id: id,
      type: "dynamicToolCall",
      tool: part.agent || "subtask",
      status: "completed",
      result: part.description || part.prompt || "",
    };
  }
  return null;
}

function groupMessages(messages, busy) {
  const turns = [];
  let current = null;
  for (const message of messages || []) {
    const info = message.info || {};
    const parts = message.parts || [];
    messageInfo.set(info.id, info);
    if (info.role === "user") {
      current = {
        id: info.id || "turn-" + turns.length,
        status: "completed",
        startedAt: Number(info.time && info.time.created || 0),
        items: [mapUserMessage(info, parts)],
      };
      turns.push(current);
      messageToTurn.set(info.id, current.id);
    } else if (info.role === "assistant") {
      if (!current) {
        current = {
          id: info.parentID || info.id || "turn-" + turns.length,
          status: "completed",
          startedAt: Number(info.time && info.time.created || 0),
          items: [],
        };
        turns.push(current);
      }
      messageToTurn.set(info.id, current.id);
      for (const part of parts) {
        const item = mapPart(part, "assistant");
        if (item) current.items.push(item);
      }
    }
  }
  if (busy && turns.length) turns[turns.length - 1].status = "inProgress";
  return turns;
}

async function statusMap() {
  try {
    return await request("/session/status") || {};
  } catch (error) {
    return {};
  }
}

async function sessionMessages(sessionID, limit) {
  const suffix = limit ? "?limit=" + encodeURIComponent(String(limit)) : "";
  return await request("/session/" + encodeURIComponent(sessionID) + "/message" + suffix) || [];
}

async function hydrateSession(session, statuses) {
  const status = statuses && statuses[session.id];
  const busy = isSessionActive(status);
  const messages = await sessionMessages(session.id, 200);
  const thread = mapSession(session, status);
  thread.turns = groupMessages(messages, busy);
  const tokenUsage = await tokenUsageForMessages(messages);
  if (tokenUsage) thread.tokenUsage = tokenUsage;
  if (busy && thread.turns.length && !activeTurns.has(session.id)) {
    const latest = thread.turns[thread.turns.length - 1];
    activeTurns.set(session.id, {
      id: latest.id,
      startedAt: latest.startedAt,
      approvalPolicy: "untrusted",
      modelReference: "",
    });
  }
  return thread;
}

function parseModel(value) {
  if (!value || typeof value !== "string") return null;
  const split = value.indexOf("/");
  if (split <= 0 || split >= value.length - 1) return null;
  return { providerID: value.slice(0, split), modelID: value.slice(split + 1) };
}

function normalizeManagedModelReference(value) {
  const parsed = parseModel(value);
  if (!parsed || parsed.providerID !== legacyManagedProviderID) return String(value || "");
  return managedProviderID + "/" + parsed.modelID;
}

function normalizeReasoningEffort(value) {
  const effort = String(value || "").trim().toLowerCase();
  if (!effort) return "";
  if (!managedReasoningEfforts.includes(effort)) {
    throw new Error("思考强度只能为极低、低、中、高或极高");
  }
  return effort;
}

function reasoningVariants() {
  const variants = {};
  for (const effort of managedReasoningEfforts) {
    variants[effort] = { reasoningEffort: effort };
  }
  return variants;
}

function isReasoningModelID(value) {
  const modelID = String(value || "").trim().toLowerCase();
  return /(^|\/)gpt-5(?:[._-]|$)/.test(modelID) ||
    /(^|\/)o(?:1|3|4)(?:[._-]|$)/.test(modelID);
}

function withReasoningMetadata(definition, modelID) {
  const current = Object.assign({}, objectValue(definition));
  if (!isReasoningModelID(modelID)) return current;
  current.reasoning = true;
  current.variants = Object.assign(reasoningVariants(), objectValue(current.variants));
  return current;
}

function openCodeConfigDirectory() {
  if (process.env.OPENCODE_CONFIG_DIR) {
    return path.resolve(process.env.OPENCODE_CONFIG_DIR);
  }
  const configHome = process.env.XDG_CONFIG_HOME
    ? path.resolve(process.env.XDG_CONFIG_HOME)
    : path.join(os.homedir(), ".config");
  return path.join(configHome, "opencode");
}

function jsoncParser() {
  if (jsoncParserModule) return jsoncParserModule;
  const lookupPaths = [];
  if (process.env.OPENCODE_JSONC_PARSER) {
    lookupPaths.push(path.resolve(process.env.OPENCODE_JSONC_PARSER));
  }
  if (openCodeBin) {
    lookupPaths.push(path.dirname(path.resolve(openCodeBin)));
    try {
      lookupPaths.push(path.dirname(fs.realpathSync(openCodeBin)));
    } catch (error) {
      // The executable may be replaced while an installation is being probed.
    }
  }
  for (const lookupPath of lookupPaths) {
    try {
      const resolved = require.resolve("jsonc-parser", { paths: [lookupPath] });
      jsoncParserModule = require(resolved);
      return jsoncParserModule;
    } catch (error) {
      // Try the next installation location.
    }
  }
  throw new Error("OpenCode 配置编辑依赖未安装，请重新安装 OpenCode 运行时");
}

function openCodeConfigFiles() {
  if (process.env.OPENCODE_CONFIG) {
    return [path.resolve(process.env.OPENCODE_CONFIG)];
  }
  const directoryPath = openCodeConfigDirectory();
  return [
    path.join(directoryPath, "opencode.jsonc"),
    path.join(directoryPath, "opencode.json"),
  ];
}

function openCodeDataDirectory() {
  if (process.env.XDG_DATA_HOME) return path.resolve(process.env.XDG_DATA_HOME, "opencode");
  return path.join(os.homedir(), ".local", "share", "opencode");
}

function openCodeAuthPath() {
  return path.join(openCodeDataDirectory(), "auth.json");
}

function parseJsoncDocument(text, filePath) {
  const errors = [];
  const value = jsoncParser().parse(text, errors, { allowTrailingComma: true });
  if (errors.length || !value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("OpenCode 配置文件格式错误: " + filePath);
  }
  return value;
}

function mergedManagedProvider(legacyProvider, currentProvider) {
  const legacy = objectValue(legacyProvider);
  const current = objectValue(currentProvider);
  const merged = Object.assign({}, legacy, current);
  const legacyName = String(legacy.name || "").trim();
  merged.name = String(current.name || (
    !legacyName || legacyName === "Codex Remote" ? managedProviderName : legacyName
  ));
  merged.npm = String(current.npm || legacy.npm || managedProviderPackage);
  if (Object.keys(objectValue(legacy.options)).length || Object.keys(objectValue(current.options)).length) {
    merged.options = Object.assign({}, objectValue(legacy.options), objectValue(current.options));
  }
  const models = Object.assign({}, objectValue(legacy.models), objectValue(current.models));
  for (const modelKey of Object.keys(models)) {
    const model = objectValue(models[modelKey]);
    models[modelKey] = withReasoningMetadata(model, model.id || modelKey);
  }
  merged.models = models;
  return merged;
}

function buildManagedProviderMigration(config) {
  const currentConfig = objectValue(config);
  const providers = objectValue(currentConfig.provider);
  if (!hasOwn(providers, legacyManagedProviderID)) return null;
  const patch = { provider: {} };
  patch.provider[managedProviderID] = mergedManagedProvider(
    providers[legacyManagedProviderID],
    providers[managedProviderID],
  );
  for (const key of ["model", "small_model"]) {
    const migrated = normalizeManagedModelReference(currentConfig[key]);
    if (migrated && migrated !== currentConfig[key]) patch[key] = migrated;
  }
  const agentPatch = {};
  for (const [agentID, agentValue] of Object.entries(objectValue(currentConfig.agent))) {
    const agent = objectValue(agentValue);
    const model = normalizeManagedModelReference(agent.model);
    if (model && model !== agent.model) agentPatch[agentID] = { model: model };
  }
  if (Object.keys(agentPatch).length) patch.agent = agentPatch;
  return { patch: patch };
}

function replaceJsoncNodeText(text, node, value) {
  return text.slice(0, node.offset) + JSON.stringify(value) + text.slice(node.offset + node.length);
}

function modifyJsoncValue(text, configPath, value) {
  const parser = jsoncParser();
  const edits = parser.modify(
    text,
    configPath,
    value,
    { formattingOptions: { insertSpaces: true, tabSize: 2 } },
  );
  return parser.applyEdits(text, edits);
}

function migrateManagedProviderConfigText(text, filePath) {
  const source = filePath || "opencode.jsonc";
  let current = text;
  let config = parseJsoncDocument(current, source);
  if (!hasOwn(objectValue(config.provider), legacyManagedProviderID)) {
    return { text: current, changed: false, config: config };
  }
  const parser = jsoncParser();
  const providers = objectValue(config.provider);
  if (!hasOwn(providers, managedProviderID)) {
    const tree = parser.parseTree(current);
    const providerNode = tree && parser.findNodeAtLocation(tree, ["provider"]);
    const legacyProperty = providerNode && (providerNode.children || []).find(function (property) {
      return property.children && property.children[0] &&
        property.children[0].value === legacyManagedProviderID;
    });
    if (!legacyProperty || !legacyProperty.children || !legacyProperty.children[0]) {
      throw new Error("OpenCode 旧模型 Provider 结构无法识别: " + source);
    }
    current = replaceJsoncNodeText(current, legacyProperty.children[0], managedProviderID);
  } else {
    current = modifyJsoncValue(
      current,
      ["provider", managedProviderID],
      mergedManagedProvider(providers[legacyManagedProviderID], providers[managedProviderID]),
    );
    current = modifyJsoncValue(current, ["provider", legacyManagedProviderID], undefined);
  }
  config = parseJsoncDocument(current, source);
  const provider = objectValue(objectValue(config.provider)[managedProviderID]);
  const providerName = String(provider.name || "").trim();
  if (!providerName || providerName === "Codex Remote") {
    current = modifyJsoncValue(current, ["provider", managedProviderID, "name"], managedProviderName);
    config = parseJsoncDocument(current, source);
  }
  for (const key of ["model", "small_model"]) {
    const migrated = normalizeManagedModelReference(config[key]);
    if (migrated && migrated !== config[key]) {
      current = modifyJsoncValue(current, [key], migrated);
      config = parseJsoncDocument(current, source);
    }
  }
  for (const [agentID, agentValue] of Object.entries(objectValue(config.agent))) {
    const model = normalizeManagedModelReference(objectValue(agentValue).model);
    if (model && model !== agentValue.model) {
      current = modifyJsoncValue(current, ["agent", agentID, "model"], model);
      config = parseJsoncDocument(current, source);
    }
  }
  const models = objectValue(objectValue(objectValue(config.provider)[managedProviderID]).models);
  for (const [modelKey, modelValue] of Object.entries(models)) {
    const model = objectValue(modelValue);
    if (!isReasoningModelID(model.id || modelKey)) continue;
    if (model.reasoning !== true) {
      current = modifyJsoncValue(
        current,
        ["provider", managedProviderID, "models", modelKey, "reasoning"],
        true,
      );
      config = parseJsoncDocument(current, source);
    }
    const configuredVariants = objectValue(
      objectValue(objectValue(objectValue(config.provider)[managedProviderID]).models)[modelKey]
        ?.variants,
    );
    for (const effort of managedReasoningEfforts) {
      if (hasOwn(configuredVariants, effort)) continue;
      current = modifyJsoncValue(
        current,
        ["provider", managedProviderID, "models", modelKey, "variants", effort],
        { reasoningEffort: effort },
      );
      config = parseJsoncDocument(current, source);
    }
  }
  return { text: current, changed: current !== text, config: config };
}

function migrateManagedProviderConfigFiles() {
  let changed = false;
  let existingFile = false;
  for (const filePath of openCodeConfigFiles()) {
    if (!fs.existsSync(filePath)) continue;
    existingFile = true;
    const original = fs.readFileSync(filePath, "utf8");
    const result = migrateManagedProviderConfigText(original, filePath);
    if (!result.changed) continue;
    atomicWriteConfig(filePath, result.text);
    const written = parseJsoncDocument(fs.readFileSync(filePath, "utf8"), filePath);
    if (hasOwn(objectValue(written.provider), legacyManagedProviderID)) {
      throw new Error("OpenCode 旧模型 Provider 迁移失败");
    }
    changed = true;
  }
  if (!existingFile) throw new Error("找不到 OpenCode 全局配置文件，无法迁移模型 Provider");
  return changed;
}

function migrateManagedProviderAuth() {
  const authPath = openCodeAuthPath();
  let text;
  try {
    text = fs.readFileSync(authPath, "utf8");
  } catch (error) {
    if (error && error.code === "ENOENT") return false;
    throw error;
  }
  let auth;
  try {
    auth = JSON.parse(text);
  } catch (error) {
    throw new Error("OpenCode 认证文件格式错误: " + authPath);
  }
  if (!hasOwn(objectValue(auth), legacyManagedProviderID)) return false;
  const next = Object.assign({}, auth);
  if (!hasOwn(next, managedProviderID)) next[managedProviderID] = next[legacyManagedProviderID];
  delete next[legacyManagedProviderID];
  const directoryPath = path.dirname(authPath);
  fs.mkdirSync(directoryPath, { recursive: true, mode: 0o700 });
  atomicWriteConfig(authPath, JSON.stringify(next, null, 2) + "\n");
  fs.chmodSync(authPath, 0o600);
  return true;
}

function migrateLegacyManagedProviderBeforeStart() {
  let hasLegacyConfig = false;
  for (const filePath of openCodeConfigFiles()) {
    if (!fs.existsSync(filePath)) continue;
    const config = parseJsoncDocument(fs.readFileSync(filePath, "utf8"), filePath);
    if (hasOwn(objectValue(config.provider), legacyManagedProviderID)) {
      hasLegacyConfig = true;
      break;
    }
  }
  const configChanged = hasLegacyConfig ? migrateManagedProviderConfigFiles() : false;
  const authChanged = migrateManagedProviderAuth();
  return configChanged || authChanged;
}

function removeConfigValueFromText(text, configPath) {
  const config = parseJsoncDocument(text, "opencode.jsonc");
  const parser = jsoncParser();
  const tree = parser.parseTree(text);
  if (!tree || !parser.findNodeAtLocation(tree, configPath)) {
    return { text: text, changed: false, config: config };
  }
  const edits = parser.modify(
    text,
    configPath,
    undefined,
    { formattingOptions: { insertSpaces: true, tabSize: 2 } },
  );
  const updated = parser.applyEdits(text, edits);
  return {
    text: updated,
    changed: updated !== text,
    config: parseJsoncDocument(updated, "opencode.jsonc"),
  };
}

function removeConfigValueFromFiles(configPath) {
  let changed = false;
  for (const filePath of openCodeConfigFiles()) {
    if (!fs.existsSync(filePath)) continue;
    const original = fs.readFileSync(filePath, "utf8");
    const result = removeConfigValueFromText(original, configPath);
    if (!result.changed) continue;
    atomicWriteConfig(filePath, result.text);
    parseJsoncDocument(fs.readFileSync(filePath, "utf8"), filePath);
    changed = true;
  }
  return changed;
}

function modelKeysInConfig(config, providerID, modelID) {
  const provider = objectValue(config && config.provider && config.provider[providerID]);
  const models = objectValue(provider.models);
  return Object.keys(models).filter(function (key) {
    const value = objectValue(models[key]);
    return key === modelID || value.id === modelID;
  });
}

function normalizeConfigModelIds(modelIds) {
  return Array.from(new Set((Array.isArray(modelIds) ? modelIds : []).map(function (value) {
    return normalizeSyncModel(value).fullModel;
  })));
}

/**
 * Removes model properties from JSONC while leaving comments and unrelated fields intact.
 * The jsonc-parser edit operation is used instead of regex/string replacement so quoted keys,
 * trailing commas, and comments are handled according to OpenCode's own config syntax.
 */
function removeModelsFromConfigText(text, modelIds, removeDefaultModel) {
  const parser = jsoncParser();
  let current = text;
  let config = parseJsoncDocument(current, "opencode.jsonc");
  const removed = [];
  const normalizedIds = normalizeConfigModelIds(modelIds);
  for (const fullModel of normalizedIds) {
    const parsed = parseModel(fullModel);
    if (!parsed) continue;
    const keys = modelKeysInConfig(config, parsed.providerID, parsed.modelID);
    const provider = objectValue(config && config.provider && config.provider[parsed.providerID]);
    const configuredModelKeys = Object.keys(objectValue(provider.models));
    if (keys.length && keys.length === configuredModelKeys.length) {
      const edits = parser.modify(
        current,
        ["provider", parsed.providerID, "models"],
        {},
        { formattingOptions: { insertSpaces: true, tabSize: 2 } },
      );
      current = parser.applyEdits(current, edits);
      removed.push(fullModel);
      config = parseJsoncDocument(current, "opencode.jsonc");
      continue;
    }
    for (const modelKey of keys) {
      const edits = parser.modify(
        current,
        ["provider", parsed.providerID, "models", modelKey],
        undefined,
        { formattingOptions: { insertSpaces: true, tabSize: 2 } },
      );
      current = parser.applyEdits(current, edits);
      removed.push(fullModel);
      config = parseJsoncDocument(current, "opencode.jsonc");
    }
  }
  if (removeDefaultModel && typeof config.model === "string") {
    const edits = parser.modify(
      current,
      ["model"],
      undefined,
      { formattingOptions: { insertSpaces: true, tabSize: 2 } },
    );
    if (edits.length) {
      current = parser.applyEdits(current, edits);
      config = parseJsoncDocument(current, "opencode.jsonc");
    }
  }
  return { text: current, removedModelIds: Array.from(new Set(removed)), config: config };
}

function atomicWriteConfig(filePath, text) {
  const directoryPath = path.dirname(filePath);
  const temporaryPath = path.join(
    directoryPath,
    "." + path.basename(filePath) + "." + process.pid + "." +
      crypto.randomBytes(6).toString("hex") + ".tmp",
  );
  let mode = 0o600;
  try {
    mode = fs.statSync(filePath).mode & 0o777;
  } catch (error) {
    // Keep the restrictive default for a newly-created config file.
  }
  try {
    fs.writeFileSync(temporaryPath, text, { encoding: "utf8", mode: mode });
    fs.renameSync(temporaryPath, filePath);
    try { fs.chmodSync(filePath, mode); } catch (error) { /* best effort */ }
  } finally {
    try { fs.unlinkSync(temporaryPath); } catch (error) {
      if (!error || error.code !== "ENOENT") throw error;
    }
  }
}

function removeModelsFromConfigFile(modelIds, removeDefaultModel) {
  const normalizedIds = normalizeConfigModelIds(modelIds);
  if (!normalizedIds.length && !removeDefaultModel) {
    return { changed: false, removedModelIds: [] };
  }
  let changed = false;
  const removed = [];
  let existingFile = false;
  for (const filePath of openCodeConfigFiles()) {
    if (!fs.existsSync(filePath)) continue;
    existingFile = true;
    const original = fs.readFileSync(filePath, "utf8");
    const result = removeModelsFromConfigText(original, normalizedIds, removeDefaultModel);
    if (result.text === original) continue;
    atomicWriteConfig(filePath, result.text);
    // Re-read and parse after the rename so a partial/corrupt write is never reported as success.
    parseJsoncDocument(fs.readFileSync(filePath, "utf8"), filePath);
    changed = true;
    result.removedModelIds.forEach(function (id) { removed.push(id); });
  }
  if (!existingFile && normalizedIds.length) {
    throw new Error("找不到 OpenCode 全局配置文件，无法删除模型");
  }
  return { changed: changed, removedModelIds: Array.from(new Set(removed)) };
}

function proxySettingsPath() {
  return path.join(openCodeConfigDirectory(), "codex-remote-proxy");
}

function normalizeProxyUrl(value) {
  const proxy = String(value || "").trim();
  if (!proxy) return "";
  if (proxy.length > 2048 || /\s/.test(proxy) || /[^\x20-\x7e]/.test(proxy)) {
    throw new Error("代理地址不能包含空格、换行或控制字符");
  }
  const scheme = proxy.slice(0, proxy.indexOf("://")).toLowerCase();
  if (!["http", "https", "socks5", "socks5h"].includes(scheme)) {
    throw new Error("代理地址必须以 http://、https://、socks5:// 或 socks5h:// 开头");
  }
  const authority = proxy.slice(scheme.length + 3).split("/")[0];
  if (!authority) throw new Error("代理地址缺少主机");
  return proxy;
}

function readProxyUrl() {
  try {
    return normalizeProxyUrl(fs.readFileSync(proxySettingsPath(), "utf8"));
  } catch (error) {
    if (error && error.code === "ENOENT") return "";
    return "";
  }
}

function writeProxyUrl(value) {
  const proxy = normalizeProxyUrl(value);
  const target = proxySettingsPath();
  if (!proxy) {
    try { fs.unlinkSync(target); } catch (error) {
      if (!error || error.code !== "ENOENT") throw error;
    }
    return "";
  }
  fs.mkdirSync(path.dirname(target), { recursive: true, mode: 0o700 });
  const temporary = target + "." + process.pid + ".tmp";
  try {
    fs.writeFileSync(temporary, proxy + "\n", { encoding: "utf8", mode: 0o600 });
    fs.renameSync(temporary, target);
    fs.chmodSync(target, 0o600);
  } finally {
    try { fs.unlinkSync(temporary); } catch (error) {
      if (!error || error.code !== "ENOENT") throw error;
    }
  }
  return proxy;
}

function proxyEnvironment(value) {
  const proxy = normalizeProxyUrl(value);
  if (!proxy) return {};
  return {
    HTTP_PROXY: proxy,
    HTTPS_PROXY: proxy,
    ALL_PROXY: proxy,
    http_proxy: proxy,
    https_proxy: proxy,
    all_proxy: proxy,
  };
}

function normalizeOpenCodeModel(value, providerID) {
  const model = String(value || "").trim();
  if (!model) return "";
  if (model.length > 200 || /\s/.test(model) || /[^A-Za-z0-9._\-/:@+]/.test(model)) {
    throw new Error("模型 ID 格式错误");
  }
  return parseModel(model)
    ? normalizeManagedModelReference(model)
    : String(providerID || managedProviderID) + "/" + model;
}

function modelConfigDefinition(value, providerID) {
  const fullModel = normalizeOpenCodeModel(value && (value.modelId || value.id), providerID);
  const parsed = parseModel(fullModel);
  if (!parsed || parsed.providerID !== providerID) return null;
  const context = Math.max(0, Math.floor(Number(value && value.contextWindowTokens || 0)));
  const output = Math.max(0, Math.floor(Number(value && value.maxOutputTokens || 0)));
  const definition = {
    name: String(value && value.displayName || parsed.modelID).trim() || parsed.modelID,
  };
  if (context > 0 || output > 0) {
    definition.limit = { context: context, output: output };
  }
  return { modelID: parsed.modelID, definition: withReasoningMetadata(definition, parsed.modelID) };
}

function configuredModels(models, providerID, defaultModel) {
  const result = {};
  for (const value of models || []) {
    const configured = modelConfigDefinition(value, providerID);
    if (configured) result[configured.modelID] = configured.definition;
  }
  const parsedDefault = parseModel(normalizeOpenCodeModel(defaultModel, providerID));
  if (parsedDefault && parsedDefault.providerID === providerID && !result[parsedDefault.modelID]) {
    result[parsedDefault.modelID] = withReasoningMetadata(
      { name: parsedDefault.modelID },
      parsedDefault.modelID,
    );
  }
  return result;
}

function objectValue(value) {
  return value && typeof value === "object" && !Array.isArray(value) ? value : {};
}

function hasOwn(value, key) {
  return Object.prototype.hasOwnProperty.call(value, key);
}

function normalizeSyncModel(value) {
  const fullModel = normalizeOpenCodeModel(value, managedProviderID);
  const parsed = parseModel(fullModel);
  if (!parsed) throw new Error("OpenCode 模型 ID 必须包含 provider/model");
  return { fullModel: fullModel, providerID: parsed.providerID, modelID: parsed.modelID };
}

function modelDefinitionsByProvider(models) {
  const result = new Map();
  for (const value of Array.isArray(models) ? models : []) {
    const normalized = normalizeSyncModel(value && (value.modelId || value.id));
    const configured = modelConfigDefinition(
      Object.assign({}, value || {}, { modelId: normalized.fullModel }),
      normalized.providerID,
    );
    if (!configured) throw new Error("OpenCode 模型 ID 必须包含 provider/model");
    if (!result.has(normalized.providerID)) result.set(normalized.providerID, new Map());
    result.get(normalized.providerID).set(configured.modelID, configured.definition);
  }
  return result;
}

function modelIdsByProvider(modelIds) {
  const result = new Map();
  for (const value of Array.isArray(modelIds) ? modelIds : []) {
    const normalized = normalizeSyncModel(value);
    if (!result.has(normalized.providerID)) result.set(normalized.providerID, new Set());
    result.get(normalized.providerID).add(normalized.modelID);
  }
  return result;
}

function modelMapsEqual(left, right) {
  const leftKeys = Object.keys(left || {});
  const rightKeys = Object.keys(right || {});
  if (leftKeys.length !== rightKeys.length) return false;
  for (const key of leftKeys) {
    if (!hasOwn(right, key) || JSON.stringify(left[key]) !== JSON.stringify(right[key])) return false;
  }
  return true;
}

function deleteModelFromMap(models, modelID) {
  const deletedKeys = [];
  for (const key of Object.keys(models)) {
    const value = objectValue(models[key]);
    if (key === modelID || value.id === modelID) {
      delete models[key];
      deletedKeys.push(key);
    }
  }
  return deletedKeys;
}

function buildModelSyncPatch(config, params) {
  const currentConfig = objectValue(config);
  const providers = objectValue(currentConfig.provider);
  const definitions = modelDefinitionsByProvider(params && params.models);
  const removals = modelIdsByProvider(params && params.removeModelIds);
  const providerIDs = new Set([...definitions.keys(), ...removals.keys()]);
  const nextModelsByProvider = new Map();
  for (const providerID of Object.keys(providers)) {
    nextModelsByProvider.set(providerID, Object.assign({}, objectValue(providers[providerID].models)));
  }
  const patch = { provider: {} };
  let changed = false;
  const addedModelIds = [];
  const removedModelIds = [];

  for (const providerID of providerIDs) {
    const hasProvider = hasOwn(providers, providerID) && objectValue(providers[providerID]);
    const existingProvider = hasProvider ? objectValue(providers[providerID]) : {};
    const existingModels = Object.assign({}, objectValue(existingProvider.models));
    const nextModels = Object.assign({}, existingModels);
    const modelPatch = {};
    const providerDefinitions = definitions.get(providerID) || new Map();
    const providerRemovals = removals.get(providerID) || new Set();
    for (const modelID of providerRemovals) {
      // An update wins over a removal if both are present in one request.
      if (providerDefinitions.has(modelID)) continue;
      const deletedKeys = deleteModelFromMap(nextModels, modelID);
      if (deletedKeys.length) {
        removedModelIds.push(providerID + "/" + modelID);
      }
    }
    for (const [modelID, definition] of providerDefinitions.entries()) {
      const wasPresent = hasOwn(nextModels, modelID);
      if (!wasPresent || JSON.stringify(nextModels[modelID]) !== JSON.stringify(definition)) {
        nextModels[modelID] = definition;
        modelPatch[modelID] = definition;
        addedModelIds.push(providerID + "/" + modelID);
      }
    }
    nextModelsByProvider.set(providerID, nextModels);
    if (!modelMapsEqual(existingModels, nextModels)) {
      const providerPatch = Object.assign({}, existingProvider);
      if (!hasProvider) {
        providerPatch.name = managedProviderName;
        providerPatch.npm = managedProviderPackage;
      }
      // OpenCode's config PATCH is recursive. Removed keys are edited in JSONC below because
      // 1.18.x validates nested values and rejects the usual JSON Merge Patch null marker.
      if (Object.keys(modelPatch).length || !hasProvider) {
        providerPatch.models = hasProvider ? modelPatch : nextModels;
        patch.provider[providerID] = providerPatch;
        changed = true;
      }
    }
  }

  const configuredDefault = String(currentConfig.model || "").trim();
  const defaultProviderID = parseModel(configuredDefault)?.providerID || settingsProvider(currentConfig);
  const defaultParsed = configuredDefault
    ? parseModel(normalizeOpenCodeModel(configuredDefault, defaultProviderID))
    : null;
  const defaultRemovals = removals.get(defaultParsed && defaultParsed.providerID);
  const defaultWasRemoved = Boolean(
    defaultParsed && defaultRemovals && defaultRemovals.has(defaultParsed.modelID) &&
      !(definitions.get(defaultParsed.providerID) || new Map()).has(defaultParsed.modelID),
  );
  if (defaultWasRemoved) {
    const preferredProvider = defaultParsed.providerID;
    const candidateProviders = [preferredProvider, ...Array.from(nextModelsByProvider.keys())]
      .filter((value, index, all) => value && all.indexOf(value) === index);
    let fallback = "";
    for (const providerID of candidateProviders) {
      const models = nextModelsByProvider.get(providerID) || {};
      const modelID = Object.keys(models)[0];
      if (modelID) {
        fallback = providerID + "/" + modelID;
        break;
      }
    }
    patch.model = fallback;
    const agents = objectValue(currentConfig.agent);
    for (const [agentID, agentValue] of Object.entries(agents)) {
      const agent = objectValue(agentValue);
      if (normalizeManagedModelReference(agent.model) === configuredDefault) {
        if (!patch.agent) patch.agent = {};
        patch.agent[agentID] = fallback
          ? Object.assign({}, agent, { model: fallback })
          : Object.assign({}, agent);
        if (!fallback) delete patch.agent[agentID].model;
      }
    }
    changed = true;
  }
  const hasPatch = Object.keys(patch.provider).length > 0 || hasOwn(patch, "model") ||
    Object.keys(objectValue(patch.agent)).length > 0;
  return changed || removedModelIds.length > 0
    ? {
      patch: hasPatch ? patch : null,
      addedModelIds: addedModelIds,
      removedModelIds: removedModelIds,
      defaultModel: hasOwn(patch, "model") ? patch.model : configuredDefault,
    }
    : { patch: null, addedModelIds: [], removedModelIds: [], defaultModel: configuredDefault };
}

function settingsProvider(config) {
  const providers = config && config.provider || {};
  const selected = parseModel(config && config.model);
  if (selected && providers[selected.providerID]) return selected.providerID;
  if (providers[managedProviderID]) return managedProviderID;
  if (providers[legacyManagedProviderID]) return legacyManagedProviderID;
  return selected ? selected.providerID : managedProviderID;
}

function settingsReasoningEffort(config) {
  const buildAgent = objectValue(objectValue(config && config.agent).build);
  try {
    return normalizeReasoningEffort(buildAgent.variant);
  } catch (error) {
    return "";
  }
}

function mapGlobalSettings(config, providers, proxyUrl) {
  const providerID = settingsProvider(config || {});
  const configured = config && config.provider && config.provider[providerID] || {};
  const runtime = (providers && providers.all || []).find(function (item) {
    return item && item.id === providerID;
  }) || {};
  const configuredBaseUrl = configured.options && configured.options.baseURL;
  const runtimeBaseUrl = runtime.options && runtime.options.baseURL;
  const key = typeof runtime.key === "string" ? runtime.key : "";
  return {
    baseUrl: String(configuredBaseUrl || runtimeBaseUrl || ""),
    model: normalizeManagedModelReference(config && config.model),
    reasoningEffort: settingsReasoningEffort(config),
    modelProvider: providerID === legacyManagedProviderID ? managedProviderID : providerID,
    hasStoredAuthentication: Boolean(key) || (providers && providers.connected || []).includes(providerID),
    apiKey: key,
    proxyUrl: String(proxyUrl || ""),
  };
}

async function readGlobalSettings() {
  const config = await request("/global/config") || {};
  const providers = await request("/provider") || {};
  return mapGlobalSettings(config, providers, readProxyUrl());
}

async function writeGlobalSettings(params) {
  const config = await request("/global/config") || {};
  const currentProvider = settingsProvider(config);
  const configuredProvider = config.provider && config.provider[currentProvider];
  const preserve = params.preserveCurrentProvider === true && Boolean(configuredProvider);
  const providerID = preserve ? currentProvider : managedProviderID;
  const baseURL = String(params.baseUrl || "").trim().replace(/\/+$/, "");
  if (baseURL && !/^https?:\/\/[^\s]+$/i.test(baseURL)) {
    throw new Error("模型 URL 必须是有效的 http:// 或 https:// 地址");
  }
  const apiKey = String(params.apiKey || "").trim();
  if (apiKey && (apiKey.length > 4096 || /\s/.test(apiKey) || /[^\x20-\x7e]/.test(apiKey))) {
    throw new Error("API 密钥不能包含空格、换行或控制字符");
  }
  const proxyUrl = normalizeProxyUrl(params.proxyUrl);
  const defaultModel = normalizeOpenCodeModel(params.defaultModel, providerID);
  const writesReasoningEffort = hasOwn(params, "defaultReasoningEffort");
  const defaultReasoningEffort = writesReasoningEffort
    ? normalizeReasoningEffort(params.defaultReasoningEffort)
    : settingsReasoningEffort(config);
  const provider = Object.assign({}, configuredProvider || {});
  const models = Object.assign({}, objectValue(provider.models));
  for (const [modelID, definition] of Object.entries(
    configuredModels(params.customModels, providerID, defaultModel),
  )) {
    models[modelID] = definition;
  }
  provider.models = models;
  if (!configuredProvider || providerID === managedProviderID) {
    provider.name = configuredProvider && configuredProvider.name || managedProviderName;
    provider.npm = configuredProvider && configuredProvider.npm || managedProviderPackage;
  }
  if (Object.prototype.hasOwnProperty.call(params, "baseUrl")) {
    provider.options = Object.assign({}, objectValue(provider.options), { baseURL: baseURL });
  }
  const patch = { provider: {} };
  patch.provider[providerID] = provider;
  if (Object.prototype.hasOwnProperty.call(params, "defaultModel")) {
    patch.model = defaultModel;
  }
  const writesBuildAgent = hasOwn(params, "defaultModel") || writesReasoningEffort;
  if (writesBuildAgent) {
    const buildAgent = Object.assign({}, objectValue(objectValue(config.agent).build));
    if (hasOwn(params, "defaultModel")) {
      if (defaultModel) buildAgent.model = defaultModel;
      else delete buildAgent.model;
    }
    if (writesReasoningEffort && defaultReasoningEffort) {
      buildAgent.variant = defaultReasoningEffort;
    }
    patch.agent = { build: buildAgent };
  }
  await request("/global/config", { method: "PATCH", body: patch });
  if (apiKey) {
    await request("/auth/" + encodeURIComponent(providerID), {
      method: "PUT",
      body: { type: "api", key: apiKey },
    });
  }
  writeProxyUrl(proxyUrl);
  if (hasOwn(params, "defaultModel") && !defaultModel) {
    removeConfigValueFromFiles(["agent", "build", "model"]);
  }
  if (writesReasoningEffort && !defaultReasoningEffort &&
      removeConfigValueFromFiles(["agent", "build", "variant"])) {
    try { await request("/global/dispose", { method: "POST", body: {} }); } catch (error) { /* best effort */ }
    for (let attempt = 0; attempt < 12; attempt += 1) {
      const refreshed = await request("/global/config") || {};
      if (!settingsReasoningEffort(refreshed)) break;
      await new Promise(function (resolve) { setTimeout(resolve, 100); });
    }
  }
  return readGlobalSettings();
}

async function ensureCustomModel(params) {
  const fullModel = normalizeOpenCodeModel(params.modelId, managedProviderID);
  const result = await syncCustomModels({ models: [Object.assign({}, params, { modelId: fullModel })] });
  return {
    configured: result.configured === true,
    model: fullModel,
  };
}

async function syncCustomModels(params) {
  const models = Array.isArray(params && params.models) ? params.models : [];
  const removeModelIds = Array.isArray(params && params.removeModelIds)
    ? params.removeModelIds
    : [];
  if (!models.length && !removeModelIds.length) {
    return { configured: false, addedModelIds: [], removedModelIds: [] };
  }
  const config = await request("/global/config") || {};
  const plan = buildModelSyncPatch(config, { models: models, removeModelIds: removeModelIds });
  const removeDefaultModel = plan.defaultModel === "" && String(config.model || "").trim() !== "";
  if (plan.patch) {
    // Apply additions/edits and a valid default-model fallback through OpenCode first. The
    // subsequent JSONC deletion then cannot be overwritten by a recursive PATCH merge.
    await request("/global/config", { method: "PATCH", body: plan.patch });
  }
  let fileResult = { changed: false, removedModelIds: [] };
  let runtimeRefreshed = true;
  if (plan.removedModelIds.length || removeDefaultModel) {
    fileResult = removeModelsFromConfigFile(plan.removedModelIds, removeDefaultModel);
    runtimeRefreshed = await refreshAfterConfigFileEdit(plan.removedModelIds, removeDefaultModel);
  }
  if (!plan.patch && !fileResult.changed) {
    return {
      configured: false,
      addedModelIds: plan.addedModelIds,
      removedModelIds: plan.removedModelIds,
      defaultModel: plan.defaultModel,
      runtimeRefreshed: runtimeRefreshed,
    };
  }
  return {
    configured: Boolean(plan.patch || fileResult.changed),
    addedModelIds: plan.addedModelIds,
    removedModelIds: plan.removedModelIds.length
      ? plan.removedModelIds
      : fileResult.removedModelIds,
    defaultModel: plan.defaultModel,
    runtimeRefreshed: runtimeRefreshed,
  };
}

function configuredModelPresent(config, fullModel) {
  const parsed = parseModel(fullModel);
  if (!parsed) return false;
  const provider = objectValue(config && config.provider && config.provider[parsed.providerID]);
  const models = objectValue(provider.models);
  return Object.keys(models).some(function (key) {
    const value = objectValue(models[key]);
    return key === parsed.modelID || value.id === parsed.modelID;
  });
}

function providerCatalogModelPresent(providers, fullModel) {
  const parsed = parseModel(fullModel);
  if (!parsed) return false;
  const provider = (providers && providers.all || []).find(function (item) {
    return item && item.id === parsed.providerID;
  });
  const models = objectValue(provider && provider.models);
  return Object.keys(models).some(function (key) {
    const value = objectValue(models[key]);
    return key === parsed.modelID || value.id === parsed.modelID;
  });
}

async function refreshAfterConfigFileEdit(modelIds, removeDefaultModel) {
  const normalizedIds = normalizeConfigModelIds(modelIds);
  if (!normalizedIds.length && !removeDefaultModel) return true;
  async function isApplied() {
    const current = await request("/global/config") || {};
    if (removeDefaultModel && String(current.model || "").trim()) return false;
    if (normalizedIds.some(function (id) { return configuredModelPresent(current, id); })) return false;
    const providers = await request("/provider") || {};
    return normalizedIds.every(function (id) { return !providerCatalogModelPresent(providers, id); });
  }
  // Force OpenCode to drop its provider cache after the external JSONC edit. The endpoint
  // disposes the global instance, not the HTTP server, so subsequent requests rebuild it.
  try { await request("/global/dispose", { method: "POST", body: {} }); } catch (error) { /* best effort */ }
  for (let attempt = 0; attempt < 12; attempt += 1) {
    if (await isApplied()) return true;
    await new Promise(function (resolve) { setTimeout(resolve, 100); });
  }
  // Config watchers normally reload within a few milliseconds. Dispose once more for servers
  // that raced the first request with their file watcher.
  try { await request("/global/dispose", { method: "POST", body: {} }); } catch (error) { /* best effort */ }
  for (let attempt = 0; attempt < 12; attempt += 1) {
    if (await isApplied()) return true;
    await new Promise(function (resolve) { setTimeout(resolve, 100); });
  }
  // Some long-running OpenCode servers retain a provider snapshot even after global disposal.
  // The atomically-written JSONC is authoritative and will be loaded on the next connection.
  return false;
}

function mapModels(providers) {
  const connected = new Set(providers.connected || []);
  const data = [];
  const contextWindows = new Map();
  for (const provider of providers.all || []) {
    for (const modelKey of Object.keys(provider.models || {})) {
      const model = provider.models[modelKey] || {};
      const modelID = model.id || modelKey;
      const id = provider.id + "/" + modelID;
      const contextWindow = nonNegativeTokenCount(model.limit && model.limit.context);
      if (contextWindow > 0) contextWindows.set(id, contextWindow);
      if (connected.size && !connected.has(provider.id)) continue;
      const variants = objectValue(model.variants);
      const efforts = managedReasoningEfforts.filter(function (effort) {
        return hasOwn(variants, effort);
      });
      data.push({
        id: id,
        model: id,
        displayName: model.name || modelID,
        description: provider.name || provider.id,
        isDefault: providers.default && providers.default[provider.id] === modelID,
        defaultReasoningEffort: "",
        supportedReasoningEfforts: efforts,
        contextWindowTokens: contextWindow,
        maxOutputTokens: nonNegativeTokenCount(model.limit && model.limit.output),
      });
    }
  }
  modelContextWindows.clear();
  contextWindows.forEach(function (value, key) { modelContextWindows.set(key, value); });
  return data;
}

function inputParts(input) {
  const parts = [];
  for (const item of input || []) {
    if (item.type === "text" && item.text) {
      parts.push({ type: "text", text: item.text });
    } else if (item.type === "localImage" && item.path) {
      parts.push({
        type: "file",
        mime: "image/*",
        filename: path.basename(item.path),
        url: "file://" + item.path,
      });
    }
  }
  return parts;
}

async function sendPrompt(sessionID, params) {
  const body = { parts: inputParts(params.input) };
  const model = parseModel(normalizeManagedModelReference(params.model));
  if (model) {
    body.model = model;
    const active = activeTurns.get(sessionID);
    if (active) active.modelReference = model.providerID + "/" + model.modelID;
  }
  const variant = normalizeReasoningEffort(params.effort);
  if (variant) body.variant = variant;
  await request("/session/" + encodeURIComponent(sessionID) + "/prompt_async", {
    method: "POST",
    body: body,
  });
}

function rpcMethodError(method) {
  const error = new Error("Unsupported OpenCode capability: " + method);
  error.code = -32601;
  return error;
}

async function handleRequest(method, params) {
  params = params || {};
  if (method === "initialize") {
    if (!sseStarted) {
      sseStarted = true;
      startEventStream();
    }
    return { userAgent: openCodeVersion };
  }
  if (method === "initialized") return null;
  if (method === "model/list") {
    const providers = await request("/provider") || {};
    return { data: mapModels(providers) };
  }
  if (method === "agent/settings/read") {
    return readGlobalSettings();
  }
  if (method === "agent/settings/write") {
    return writeGlobalSettings(params);
  }
  if (method === "agent/models/sync") {
    return syncCustomModels(params);
  }
  if (method === "agent/model/ensure") {
    return ensureCustomModel(params);
  }
  if (method === "thread/list") {
    const values = await Promise.all([request("/session"), statusMap()]);
    const sessions = values[0] || [];
    const statuses = values[1];
    const search = String(params.searchTerm || "").toLowerCase();
    const data = sessions.map(function (session) {
      return mapSession(session, statuses[session.id]);
    }).filter(function (thread) {
      return !search || thread.name.toLowerCase().includes(search) ||
        thread.cwd.toLowerCase().includes(search);
    });
    data.sort(function (left, right) { return right.updatedAt - left.updatedAt; });
    return { data: data.slice(0, Number(params.limit || 100)) };
  }
  if (method === "thread/start") {
    const session = await request("/session", { method: "POST", body: {} });
    const thread = mapSession(session, null);
    thread.turns = [];
    return { thread: thread };
  }
  if (method === "thread/resume" || method === "thread/read") {
    const sessionID = params.threadId;
    const session = await request("/session/" + encodeURIComponent(sessionID));
    const statuses = await statusMap();
    return { thread: await hydrateSession(session, statuses) };
  }
  if (method === "thread/turns/list") {
    return { data: [], nextCursor: null };
  }
  if (method === "turn/start") {
    const turnID = "opencode-turn-" + Date.now().toString(36) + "-" +
      Math.random().toString(36).slice(2, 8);
    activeTurns.set(params.threadId, {
      id: turnID,
      startedAt: Date.now(),
      approvalPolicy: params.approvalPolicy || "untrusted",
      modelReference: "",
    });
    notify("turn/started", {
      threadId: params.threadId,
      turn: { id: turnID, status: "inProgress", startedAt: Date.now(), items: [] },
    });
    startPrompt(params.threadId, params, turnID);
    return { turn: { id: turnID, status: "inProgress" } };
  }
  if (method === "turn/steer") {
    startPrompt(params.threadId, params, activeTurns.get(params.threadId)?.id || "");
    return {};
  }
  if (method === "turn/interrupt") {
    await request("/session/" + encodeURIComponent(params.threadId) + "/abort", {
      method: "POST",
      body: {},
    });
    return {};
  }
  if (method === "thread/archive") {
    await request("/session/" + encodeURIComponent(params.threadId), { method: "DELETE" });
    return {};
  }
  if (method === "thread/name/set") {
    await request("/session/" + encodeURIComponent(params.threadId), {
      method: "PATCH",
      body: { title: params.name || "" },
    });
    notify("thread/name/updated", { threadId: params.threadId, name: params.name || "" });
    return {};
  }
  if (method === "thread/goal/get") return { goal: null };
  if (method === "thread/compact/start" || method === "thread/rollback" ||
      method === "thread/goal/set" || method === "thread/goal/clear" ||
      method === "review/start") {
    throw rpcMethodError(method);
  }
  throw rpcMethodError(method);
}

async function emitCurrentTurn(sessionID, turn) {
  try {
    const messages = await sessionMessages(sessionID, 200);
    const tokenUsage = await tokenUsageForMessages(messages);
    publishTokenUsage(sessionID, tokenUsage);
    const turns = groupMessages(messages, true);
    const current = turns.length ? turns[turns.length - 1] : null;
    if (!current) return;
    for (const item of current.items || []) {
      notify("item/completed", { threadId: sessionID, turnId: turn.id, item: item });
    }
  } catch (error) {
    notify("warning", { threadId: sessionID, message: error.message || String(error) });
  }
}

async function completeSession(sessionID, error) {
  const turn = activeTurns.get(sessionID);
  if (!turn) return;
  await emitCurrentTurn(sessionID, turn);
  activeTurns.delete(sessionID);
  notify("turn/completed", {
    threadId: sessionID,
    turn: {
      id: turn.id,
      status: error ? "failed" : "completed",
      error: error ? { message: error } : undefined,
    },
  });
}

async function replyPermission(permission, reply, apiVersion) {
  const target = permissionReplyTarget(permission, reply, apiVersion);
  await request(target.route, {
    method: "POST",
    body: target.body,
  });
}

function permissionReplyTarget(permission, reply, apiVersion) {
  if (apiVersion === "v2") {
    return {
      route: "/permission/" + encodeURIComponent(permission.id) + "/reply",
      body: { reply: reply },
    };
  }
  return {
    route: "/session/" + encodeURIComponent(permission.sessionID) + "/permissions/" +
      encodeURIComponent(permission.id),
    body: { response: reply },
  };
}

function permissionPrompt(permission, turnID) {
  const permissionName = permission.permission || permission.action || permission.type || "permission";
  const source = permission.tool || permission.source || {};
  const resources = permission.patterns || permission.resources || [];
  return {
    threadId: permission.sessionID,
    turnId: turnID || "",
    itemId: source.callID || source.messageID || permission.id,
    reason: permission.title || permission.metadata && permission.metadata.description ||
      resources.join(", ") || permissionName,
    cwd: directory,
    permissions: { [permissionName]: true },
  };
}

function permissionApiVersion(eventType) {
  if (eventType === "permission.asked" || eventType === "permission.updated") return "v1";
  if (eventType === "permission.v2.asked") return "v2";
  return null;
}

function questionApiVersion(eventType) {
  if (eventType === "question.asked") return "v1";
  if (eventType === "question.v2.asked") return "v2";
  return null;
}

function questionOptions(value) {
  return Array.isArray(value) ? value.map(function (option) {
    if (typeof option === "string") return { label: option, description: "" };
    if (!option || typeof option !== "object") return null;
    const label = String(option.label || "").trim();
    if (!label) return null;
    return { label: label, description: String(option.description || "").trim() };
  }).filter(Boolean) : [];
}

function normalizedQuestions(questions) {
  return (Array.isArray(questions) ? questions : []).map(function (question, index) {
    const value = question && typeof question === "object" ? question : {};
    return {
      id: "opencode-question-" + String(index),
      header: String(value.header || "").trim(),
      question: String(value.question || "").trim(),
      options: questionOptions(value.options),
      isSecret: false,
    };
  }).filter(function (question) {
    return question.question || question.options.length || question.header;
  });
}

function questionPrompt(question, turnID) {
  const questions = normalizedQuestions(question.questions);
  const first = questions[0] || {};
  const tool = question.tool || {};
  return {
    threadId: question.sessionID,
    turnId: turnID || "",
    itemId: tool.callID || question.id,
    title: first.header || "OpenCode 需要信息",
    detail: first.question || "OpenCode 正在等待你的选择",
    cwd: directory,
    questions: questions,
  };
}

function questionReplyTarget(question, answers, apiVersion) {
  const encodedRequest = encodeURIComponent(question.id);
  if (apiVersion === "v2") {
    return {
      route: "/api/session/" + encodeURIComponent(question.sessionID) +
        "/question/" + encodedRequest + "/reply",
      body: { answers: answers },
    };
  }
  return {
    route: "/question/" + encodedRequest + "/reply",
    body: { answers: answers },
  };
}

function questionRejectTarget(question, apiVersion) {
  const encodedRequest = encodeURIComponent(question.id);
  if (apiVersion === "v2") {
    return "/api/session/" + encodeURIComponent(question.sessionID) +
      "/question/" + encodedRequest + "/reject";
  }
  return "/question/" + encodedRequest + "/reject";
}

function questionAnswersFromResponse(pending, result) {
  const values = result && result.answers && typeof result.answers === "object"
    ? result.answers
    : {};
  return pending.questions.map(function (question) {
    const answer = values[question.id];
    const selected = answer && Array.isArray(answer.answers)
      ? answer.answers
      : typeof answer === "string" ? [answer] : [];
    return selected.map(function (value) { return String(value); }).filter(Boolean);
  });
}

async function replyQuestion(question, answers, apiVersion) {
  const target = questionReplyTarget(question, answers, apiVersion);
  await request(target.route, { method: "POST", body: target.body });
}

async function rejectQuestion(question, apiVersion) {
  await request(questionRejectTarget(question, apiVersion), { method: "POST", body: {} });
}

function startPrompt(sessionID, params, turnID) {
  Promise.resolve(sendPrompt(sessionID, params)).catch(async function (error) {
    const active = activeTurns.get(sessionID);
    if (!active || !turnID || active.id !== turnID) {
      notify("warning", { message: error.message || String(error) });
      return;
    }
    await completeSession(sessionID, error.message || String(error));
  });
}

async function handlePermission(permission, apiVersion) {
  const sessionID = permission.sessionID;
  const turn = activeTurns.get(sessionID);
  const policy = turn && turn.approvalPolicy || "untrusted";
  if (policy === "never") {
    await replyPermission(permission, "always", apiVersion);
    return;
  }
  const requestID = "opencode-permission-" + permission.id;
  pendingPermissions.set(requestID, { permission: permission, apiVersion: apiVersion });
  send({
    id: requestID,
    method: "item/permissions/requestApproval",
    params: permissionPrompt(permission, turn && turn.id),
  });
}

async function handleQuestion(question, apiVersion) {
  const normalized = normalizedQuestions(question.questions);
  if (!normalized.length) {
    await rejectQuestion(question, apiVersion);
    return;
  }
  const turn = activeTurns.get(question.sessionID);
  const requestID = "opencode-question-" + apiVersion + "-" + question.id;
  pendingQuestions.set(requestID, {
    question: question,
    apiVersion: apiVersion,
    questions: normalized,
  });
  send({
    id: requestID,
    method: "item/tool/requestUserInput",
    params: Object.assign({}, questionPrompt(question, turn && turn.id), {
      questions: normalized,
    }),
  });
}

async function handleApprovalResponse(message) {
  const requestID = String(message.id);
  const question = pendingQuestions.get(requestID);
  if (question) {
    pendingQuestions.delete(requestID);
    const answers = questionAnswersFromResponse(question, message.result || {});
    const hasAnswer = answers.some(function (answer) { return answer.length > 0; });
    try {
      if (hasAnswer) await replyQuestion(question.question, answers, question.apiVersion);
      else await rejectQuestion(question.question, question.apiVersion);
    } catch (error) {
      pendingQuestions.set(requestID, question);
      throw error;
    }
    return true;
  }
  const pending = pendingPermissions.get(requestID);
  if (!pending) return false;
  pendingPermissions.delete(requestID);
  const permissions = message.result && message.result.permissions;
  const accepted = permissions && typeof permissions === "object" &&
    Object.keys(permissions).length > 0;
  await replyPermission(pending.permission, accepted ? "once" : "reject", pending.apiVersion);
  return true;
}

async function handleEvent(rawEvent) {
  const event = rawEvent && rawEvent.payload ? rawEvent.payload : rawEvent;
  if (!event || !event.type) return;
  const properties = event.properties || event.data || {};
  if (event.type === "message.updated") {
    const info = properties.info || {};
    messageInfo.set(info.id, info);
    if (info.role === "user") messageToTurn.set(info.id, info.id);
    if (info.role === "assistant") {
      messageToTurn.set(info.id, info.parentID || info.id);
      Promise.resolve(publishTokenUsageForInfo(info, info.sessionID || "")).catch(function (error) {
        notify("warning", { threadId: info.sessionID || "", message: error.message || String(error) });
      });
    }
    return;
  }
  if (event.type === "message.part.updated") {
    const part = properties.part || {};
    const info = messageInfo.get(part.messageID) || {};
    const sessionID = part.sessionID || info.sessionID;
    if (!sessionID) return;
    const turn = activeTurns.get(sessionID);
    const turnID = turn && turn.id || messageToTurn.get(part.messageID) || part.messageID;
    if (info.role === "user") {
      Promise.resolve(request("/session/" + encodeURIComponent(sessionID) +
        "/message/" + encodeURIComponent(part.messageID))).then(function (message) {
        notify("item/completed", {
          threadId: sessionID,
          turnId: turnID,
          item: mapUserMessage(message.info || info, message.parts || [part]),
        });
      }).catch(function () {
        notify("item/completed", {
          threadId: sessionID,
          turnId: turnID,
          item: mapUserMessage(info, [part]),
        });
      });
    } else {
      const item = mapPart(part, "assistant");
      if (item) {
        notify("item/completed", { threadId: sessionID, turnId: turnID, item: item });
      }
    }
    return;
  }
  if (event.type === "session.status") {
    const sessionID = properties.sessionID;
    if (sessionID && isSessionActive(properties.status) && !activeTurns.has(sessionID)) {
      const turnID = "opencode-turn-" + Date.now().toString(36);
      activeTurns.set(sessionID, {
        id: turnID,
        startedAt: Date.now(),
        approvalPolicy: "untrusted",
        modelReference: "",
      });
      notify("turn/started", {
        threadId: sessionID,
        turn: { id: turnID, status: "inProgress", startedAt: Date.now(), items: [] },
      });
    }
    if (sessionID && statusType(properties.status) === "idle") {
      await completeSession(sessionID, null);
    }
    return;
  }
  if (event.type === "session.idle") {
    await completeSession(properties.sessionID, null);
    return;
  }
  if (event.type === "session.error") {
    const error = properties.error;
    const message = error && error.data && error.data.message ||
      error && error.message || "OpenCode session failed";
    if (properties.sessionID) await completeSession(properties.sessionID, message);
    else notify("error", { message: message });
    return;
  }
  const questionVersion = questionApiVersion(event.type);
  if (questionVersion) {
    await handleQuestion(properties, questionVersion);
    return;
  }
  if (event.type === "question.replied" || event.type === "question.rejected" ||
      event.type === "question.v2.replied" || event.type === "question.v2.rejected") {
    for (const [requestID, pending] of pendingQuestions.entries()) {
      if (pending.question.id === properties.requestID &&
          pending.question.sessionID === properties.sessionID) {
        pendingQuestions.delete(requestID);
      }
    }
    return;
  }
  const permissionVersion = permissionApiVersion(event.type);
  if (permissionVersion) {
    await handlePermission(properties, permissionVersion);
    return;
  }
  if (event.type === "session.diff") {
    const chunks = [];
    for (const diff of properties.diff || []) {
      chunks.push("--- a/" + diff.file + "\n+++ b/" + diff.file + "\n" +
        (diff.before || "") + "\n" + (diff.after || ""));
    }
    notify("turn/diff/updated", {
      threadId: properties.sessionID || "",
      diff: chunks.join("\n"),
    });
  }
}

async function startEventStream() {
  while (!shuttingDown) {
    try {
      const url = new URL(baseUrl + "/event");
      if (directory) url.searchParams.set("directory", directory);
      const response = await fetch(url, {
        headers: { accept: "text/event-stream", authorization: serverAuthorization },
      });
      if (!response.ok || !response.body) {
        throw new Error("OpenCode event stream failed (" + response.status + ")");
      }
      const decoder = new TextDecoder();
      let buffer = "";
      for await (const chunk of response.body) {
        if (shuttingDown) return;
        buffer += decoder.decode(chunk, { stream: true }).replace(/\r\n/g, "\n");
        let boundary = buffer.indexOf("\n\n");
        while (boundary >= 0) {
          const block = buffer.slice(0, boundary);
          buffer = buffer.slice(boundary + 2);
          const data = block.split("\n").filter(function (line) {
            return line.startsWith("data:");
          }).map(function (line) {
            return line.slice(5).trimStart();
          }).join("\n");
          if (data) {
            try {
              Promise.resolve(handleEvent(JSON.parse(data))).catch(function (error) {
                notify("warning", { message: error.message || String(error) });
              });
            } catch (error) {
              notify("warning", { message: error.message || String(error) });
            }
          }
          boundary = buffer.indexOf("\n\n");
        }
      }
    } catch (error) {
      if (!shuttingDown) {
        process.stderr.write("OpenCode event stream: " + (error.message || String(error)) + "\n");
        await new Promise(function (resolve) { setTimeout(resolve, 1000); });
      }
    }
  }
}

async function processLine(line) {
  let message;
  try {
    message = JSON.parse(line);
  } catch (error) {
    return;
  }
  if (!message.method && Object.prototype.hasOwnProperty.call(message, "id")) {
    await handleApprovalResponse(message);
    return;
  }
  if (!message.method) return;
  if (!Object.prototype.hasOwnProperty.call(message, "id")) {
    if (message.method === "initialized") return;
    try {
      await handleRequest(message.method, message.params || {});
    } catch (error) {
      notify("warning", { message: error.message || String(error) });
    }
    return;
  }
  try {
    const result = await handleRequest(message.method, message.params || {});
    send({ id: message.id, result: result === null ? {} : result });
  } catch (error) {
    send({
      id: message.id,
      error: {
        code: Number(error.code || -32000),
        message: error.message || String(error),
      },
    });
  }
}

function isConcurrentReadLine(line) {
  try {
    const message = JSON.parse(line);
    return Object.prototype.hasOwnProperty.call(message, "id") &&
      (message.method === "model/list" || message.method === "thread/list");
  } catch (error) {
    return false;
  }
}

async function shutdown(exitCode) {
  if (shuttingDown) return;
  shuttingDown = true;
  if (serverProcess && !serverProcess.killed) serverProcess.kill("SIGTERM");
  setTimeout(function () {
    if (serverProcess && !serverProcess.killed) serverProcess.kill("SIGKILL");
    process.exit(exitCode);
  }, 1000).unref();
}

async function main() {
  if (!openCodeBin) {
    throw new Error("OPENCODE_BIN is not configured");
  }
  migrateLegacyManagedProviderBeforeStart();
  const port = await reservePort();
  baseUrl = "http://127.0.0.1:" + port;
  serverProcess = childProcess.spawn(openCodeBin, [
    "serve",
    "--hostname", "127.0.0.1",
    "--port", String(port),
  ], {
    cwd: directory,
    env: Object.assign({}, process.env, proxyEnvironment(readProxyUrl()), {
      OPENCODE_SERVER_USERNAME: serverUsername,
      OPENCODE_SERVER_PASSWORD: serverPassword,
    }),
    stdio: ["ignore", "pipe", "pipe"],
  });
  serverProcess.stdout.on("data", function (chunk) { process.stderr.write(chunk); });
  serverProcess.stderr.on("data", function (chunk) { process.stderr.write(chunk); });
  serverProcess.on("exit", function (code, signal) {
    if (!shuttingDown) {
      process.stderr.write("OpenCode server stopped: " + String(code || signal || "unknown") + "\n");
      process.exit(code || 1);
    }
  });
  const input = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
  const ready = waitForServer().then(function (health) {
    openCodeVersion = healthVersion(health);
    process.stderr.write(
      "__CODEX_REMOTE_TIMING agent=OpenCode stage=server_ready elapsed_ms=" +
        String(Date.now() - bridgeStartedAt) + "\n",
    );
  });
  let serialChain = ready;
  const concurrentReads = new Set();
  function reportLineError(error) {
    process.stderr.write((error.stack || error.message || String(error)) + "\n");
  }
  input.on("line", function (line) {
    if (isConcurrentReadLine(line)) {
      const task = serialChain.then(function () { return processLine(line); }).catch(reportLineError);
      concurrentReads.add(task);
      task.finally(function () { concurrentReads.delete(task); });
      return;
    }
    serialChain = serialChain.then(async function () {
      if (concurrentReads.size) {
        await Promise.allSettled(Array.from(concurrentReads));
      }
      return processLine(line);
    }).catch(reportLineError);
  });
  input.on("close", function () { shutdown(0); });
  await ready;
}

process.on("SIGINT", function () { shutdown(130); });
process.on("SIGTERM", function () { shutdown(143); });
process.on("SIGHUP", function () { shutdown(129); });

if (require.main === module) {
  main().catch(function (error) {
    process.stderr.write((error.stack || error.message || String(error)) + "\n");
    shutdown(1);
  });
}

module.exports = {
  groupMessages: groupMessages,
  healthVersion: healthVersion,
  isSessionActive: isSessionActive,
  mapGlobalSettings: mapGlobalSettings,
  mapMessageTokenUsage: mapMessageTokenUsage,
  mapModels: mapModels,
  mapPart: mapPart,
  mapSession: mapSession,
  buildModelSyncPatch: buildModelSyncPatch,
  buildManagedProviderMigration: buildManagedProviderMigration,
  isReasoningModelID: isReasoningModelID,
  modelConfigDefinition: modelConfigDefinition,
  modelDefinitionsByProvider: modelDefinitionsByProvider,
  normalizeOpenCodeModel: normalizeOpenCodeModel,
  normalizeManagedModelReference: normalizeManagedModelReference,
  normalizeProxyUrl: normalizeProxyUrl,
  normalizeReasoningEffort: normalizeReasoningEffort,
  parseModel: parseModel,
  permissionApiVersion: permissionApiVersion,
  permissionPrompt: permissionPrompt,
  permissionReplyTarget: permissionReplyTarget,
  questionApiVersion: questionApiVersion,
  questionAnswersFromResponse: questionAnswersFromResponse,
  questionPrompt: questionPrompt,
  questionRejectTarget: questionRejectTarget,
  questionReplyTarget: questionReplyTarget,
  proxyEnvironment: proxyEnvironment,
  removeModelsFromConfigText: removeModelsFromConfigText,
  migrateManagedProviderConfigText: migrateManagedProviderConfigText,
  removeConfigValueFromText: removeConfigValueFromText,
  reasoningVariants: reasoningVariants,
  settingsProvider: settingsProvider,
  statusType: statusType,
};

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
const managedProviderID = "codex-remote";
const managedProviderName = "Codex Remote";
const managedProviderPackage = "@ai-sdk/openai-compatible";

let baseUrl = "";
let serverProcess = null;
let shuttingDown = false;
let sseStarted = false;
let openCodeVersion = "opencode";
const activeTurns = new Map();
const messageInfo = new Map();
const messageToTurn = new Map();
const pendingPermissions = new Map();

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
  if (busy && thread.turns.length && !activeTurns.has(session.id)) {
    const latest = thread.turns[thread.turns.length - 1];
    activeTurns.set(session.id, {
      id: latest.id,
      startedAt: latest.startedAt,
      approvalPolicy: "untrusted",
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

function openCodeConfigDirectory() {
  if (process.env.OPENCODE_CONFIG_DIR) {
    return path.resolve(process.env.OPENCODE_CONFIG_DIR);
  }
  const configHome = process.env.XDG_CONFIG_HOME
    ? path.resolve(process.env.XDG_CONFIG_HOME)
    : path.join(os.homedir(), ".config");
  return path.join(configHome, "opencode");
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
  return parseModel(model) ? model : String(providerID || managedProviderID) + "/" + model;
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
  return { modelID: parsed.modelID, definition: definition };
}

function configuredModels(models, providerID, defaultModel) {
  const result = {};
  for (const value of models || []) {
    const configured = modelConfigDefinition(value, providerID);
    if (configured) result[configured.modelID] = configured.definition;
  }
  const parsedDefault = parseModel(normalizeOpenCodeModel(defaultModel, providerID));
  if (parsedDefault && parsedDefault.providerID === providerID && !result[parsedDefault.modelID]) {
    result[parsedDefault.modelID] = { name: parsedDefault.modelID };
  }
  return result;
}

function settingsProvider(config) {
  const providers = config && config.provider || {};
  const selected = parseModel(config && config.model);
  if (selected && providers[selected.providerID]) return selected.providerID;
  if (providers[managedProviderID]) return managedProviderID;
  return selected ? selected.providerID : managedProviderID;
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
    model: String(config && config.model || ""),
    reasoningEffort: "",
    modelProvider: providerID,
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
  const provider = {
    models: configuredModels(params.customModels, providerID, defaultModel),
  };
  if (!configuredProvider || providerID === managedProviderID) {
    provider.name = configuredProvider && configuredProvider.name || managedProviderName;
    provider.npm = configuredProvider && configuredProvider.npm || managedProviderPackage;
  }
  if (Object.prototype.hasOwnProperty.call(params, "baseUrl")) {
    provider.options = { baseURL: baseURL };
  }
  const patch = { provider: {} };
  patch.provider[providerID] = provider;
  if (Object.prototype.hasOwnProperty.call(params, "defaultModel")) {
    patch.model = defaultModel;
  }
  await request("/global/config", { method: "PATCH", body: patch });
  if (apiKey) {
    await request("/auth/" + encodeURIComponent(providerID), {
      method: "PUT",
      body: { type: "api", key: apiKey },
    });
  }
  writeProxyUrl(proxyUrl);
  return readGlobalSettings();
}

async function ensureCustomModel(params) {
  const fullModel = normalizeOpenCodeModel(params.modelId, managedProviderID);
  const parsed = parseModel(fullModel);
  if (!parsed) throw new Error("OpenCode 模型 ID 必须包含 provider/model");
  const providers = await request("/provider") || {};
  const runtimeProvider = (providers.all || []).find(function (item) {
    return item && item.id === parsed.providerID;
  });
  if (runtimeProvider && runtimeProvider.models && runtimeProvider.models[parsed.modelID]) {
    return { configured: false, model: fullModel };
  }
  const config = await request("/global/config") || {};
  const configuredProvider = config.provider && config.provider[parsed.providerID];
  if (!configuredProvider) {
    throw new Error("请先在 OpenCode 设置中配置模型 URL 和 API 密钥");
  }
  const model = modelConfigDefinition(Object.assign({}, params, { modelId: fullModel }), parsed.providerID);
  const providerPatch = { models: {} };
  providerPatch.models[model.modelID] = model.definition;
  const patch = { provider: {} };
  patch.provider[parsed.providerID] = providerPatch;
  await request("/global/config", { method: "PATCH", body: patch });
  return { configured: true, model: fullModel };
}

function mapModels(providers) {
  const connected = new Set(providers.connected || []);
  const data = [];
  for (const provider of providers.all || []) {
    if (connected.size && !connected.has(provider.id)) continue;
    for (const modelKey of Object.keys(provider.models || {})) {
      const model = provider.models[modelKey] || {};
      const modelID = model.id || modelKey;
      const id = provider.id + "/" + modelID;
      data.push({
        id: id,
        model: id,
        displayName: model.name || modelID,
        description: provider.name || provider.id,
        isDefault: providers.default && providers.default[provider.id] === modelID,
        defaultReasoningEffort: "",
        supportedReasoningEfforts: [],
        contextWindowTokens: Number(model.limit && model.limit.context || 0),
        maxOutputTokens: Number(model.limit && model.limit.output || 0),
      });
    }
  }
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
  const model = parseModel(params.model);
  if (model) body.model = model;
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
  if (method === "agent/model/ensure") {
    return ensureCustomModel(params);
  }
  if (method === "thread/list") {
    const sessions = await request("/session") || [];
    const statuses = await statusMap();
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
    });
    notify("turn/started", {
      threadId: params.threadId,
      turn: { id: turnID, status: "inProgress", startedAt: Date.now(), items: [] },
    });
    try {
      await sendPrompt(params.threadId, params);
    } catch (error) {
      activeTurns.delete(params.threadId);
      notify("turn/completed", {
        threadId: params.threadId,
        turn: {
          id: turnID,
          status: "failed",
          error: { message: error.message || String(error) },
        },
      });
      throw error;
    }
    return { turn: { id: turnID, status: "inProgress" } };
  }
  if (method === "turn/steer") {
    await sendPrompt(params.threadId, params);
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

async function handleApprovalResponse(message) {
  const requestID = String(message.id);
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
  const properties = event.properties || {};
  if (event.type === "message.updated") {
    const info = properties.info || {};
    messageInfo.set(info.id, info);
    if (info.role === "user") messageToTurn.set(info.id, info.id);
    if (info.role === "assistant") messageToTurn.set(info.id, info.parentID || info.id);
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
      try {
        const message = await request("/session/" + encodeURIComponent(sessionID) +
          "/message/" + encodeURIComponent(part.messageID));
        notify("item/completed", {
          threadId: sessionID,
          turnId: turnID,
          item: mapUserMessage(message.info || info, message.parts || [part]),
        });
      } catch (error) {
        notify("item/completed", {
          threadId: sessionID,
          turnId: turnID,
          item: mapUserMessage(info, [part]),
        });
      }
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
              await handleEvent(JSON.parse(data));
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
  });
  let chain = ready;
  input.on("line", function (line) {
    chain = chain.then(function () { return processLine(line); }).catch(function (error) {
      process.stderr.write((error.stack || error.message || String(error)) + "\n");
    });
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
  mapModels: mapModels,
  mapPart: mapPart,
  mapSession: mapSession,
  modelConfigDefinition: modelConfigDefinition,
  normalizeOpenCodeModel: normalizeOpenCodeModel,
  normalizeProxyUrl: normalizeProxyUrl,
  parseModel: parseModel,
  permissionApiVersion: permissionApiVersion,
  permissionPrompt: permissionPrompt,
  permissionReplyTarget: permissionReplyTarget,
  proxyEnvironment: proxyEnvironment,
  settingsProvider: settingsProvider,
  statusType: statusType,
};

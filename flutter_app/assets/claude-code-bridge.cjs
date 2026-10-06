#!/usr/bin/env node
"use strict";

// Claude's documented SDK stream/control protocol, adapted to the App's JSONL
// contract. No SDK dependency, credentials, or shell command interpolation.
const cp = require("node:child_process");
const crypto = require("node:crypto");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { StringDecoder } = require("node:string_decoder");
const settings = globalThis.__claudeRemoteSettings || require("./claude-code-settings.cjs");

const MAX_LINE = 8 * 1024 * 1024;
const MAX_TEXT = 128 * 1024;
const MAX_TURN = 2 * 1024 * 1024;
const OUTPUT_RESERVE = 65536;
const TRUNCATED = "\n[内容过长，已截断]";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const uuid = () => crypto.randomUUID();
const bounded = (value, limit = MAX_TEXT) => {
  const text = value == null ? "" : String(value);
  return text.length <= limit ? text : text.slice(0, limit) + "\n[内容过长，已截断]";
};
const clone = value => JSON.parse(JSON.stringify(value));
const integer = (value, fallback, max) => Number.isSafeInteger(value) && value > 0 ? Math.min(value, max) : fallback;
const jsonBytes = value => Buffer.byteLength(JSON.stringify(value), "utf8");
const textBytes = value => jsonBytes(String(value)) - 2;
const EFFORTS = ["low", "medium", "high", "xhigh", "max"];
const ZERO_USAGE = { inputTokens: 0, cachedInputTokens: 0, outputTokens: 0, reasoningOutputTokens: 0, totalTokens: 0 };
const tokenCount = value => Number.isSafeInteger(value) && value >= 0 ? value : 0;

function modelCatalog(configuration = settings.readSettings()) {
  const configured = configuration.model || "default";
  const known = [
    ["claude-opus-5-5", "Claude Opus 5.5", EFFORTS, "medium"],
    ["claude-opus-4-6", "Claude Opus 4.6", EFFORTS.filter(value => value !== "xhigh"), "high"],
    ["claude-sonnet-4-6", "Claude Sonnet 4.6", EFFORTS.filter(value => value !== "xhigh"), "high"],
    ["claude-haiku-4-5", "Claude Haiku 4.5", [], ""],
  ];
  const options = known.map(([model, displayName, efforts, defaultEffort]) => ({
    id: model, model, displayName, description: "", isDefault: model === configured,
    supportedReasoningEfforts: efforts.map(reasoningEffort => ({ reasoningEffort, description: reasoningEffort })),
    defaultReasoningEffort: defaultEffort,
  }));
  const current = options.find(option => option.model === configured);
  if (current && current.supportedReasoningEfforts.some(option => option.reasoningEffort === configuration.reasoningEffort)) {
    current.defaultReasoningEffort = configuration.reasoningEffort;
  }
  if (!current) options.unshift({
    id: configured, model: configured, displayName: configured === "default" ? "服务器默认" : `服务器默认 · ${configured}`,
    description: "使用服务器配置的模型", isDefault: true, supportedReasoningEfforts: [], defaultReasoningEffort: "",
  });
  return { data: options };
}

function usageBreakdown(value) {
  if (!value || !["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"].some(key => Number.isSafeInteger(value[key]) && value[key] >= 0)) return null;
  const cachedInputTokens = tokenCount(value.cache_read_input_tokens);
  const inputTokens = tokenCount(value.input_tokens) + cachedInputTokens + tokenCount(value.cache_creation_input_tokens);
  const outputTokens = tokenCount(value.output_tokens);
  return { inputTokens, cachedInputTokens, outputTokens, reasoningOutputTokens: 0, totalTokens: inputTokens + outputTokens };
}

function modelArgument(value) {
  if (value == null || value === "" || value === "default") return null;
  if (typeof value !== "string" || value.length > 200 || /[\s\x00-\x1f\x7f]/.test(value) || value.startsWith("-")) throw new Error("Claude Code 模型名称无效");
  return value;
}

function textPrefix(value, maxBytes) {
  let low = 0, high = value.length;
  while (low < high) {
    const middle = Math.ceil((low + high) / 2);
    if (textBytes(value.slice(0, middle)) <= maxBytes) low = middle;
    else high = middle - 1;
  }
  // Do not cut an astral Unicode character into an unpaired surrogate.
  if (low > 0 && /[\uD800-\uDBFF]/.test(value[low - 1])) low--;
  return value.slice(0, low);
}

function boundedJsonText(value, maxBytes) {
  const text = String(value == null ? "" : value);
  if (textBytes(text) <= maxBytes) return text;
  const suffix = textBytes(TRUNCATED) <= maxBytes ? TRUNCATED : "";
  return textPrefix(text, Math.max(0, maxBytes - textBytes(suffix))) + suffix;
}

function jsonLines(stream, onLine, onError) {
  const decoder = new StringDecoder("utf8");
  let buffer = "";
  let failed = false;
  const append = chunk => {
    if (failed) return;
    buffer += chunk;
    let index;
    while ((index = buffer.indexOf("\n")) >= 0) {
      if (index > MAX_LINE || Buffer.byteLength(buffer.slice(0, index), "utf8") > MAX_LINE) {
        failed = true; buffer = ""; onError(new Error("Claude Code 消息超过大小限制")); return;
      }
      const line = buffer.slice(0, index).trim();
      buffer = buffer.slice(index + 1);
      if (line) {
        try { onLine(JSON.parse(line)); } catch (error) { onError(error); }
      }
    }
    if (Buffer.byteLength(buffer, "utf8") > MAX_LINE) { failed = true; buffer = ""; onError(new Error("Claude Code 消息超过大小限制")); }
  };
  stream.on("data", chunk => append(decoder.write(chunk)));
  stream.on("end", () => { append(decoder.end()); if (buffer.trim()) append("\n"); });
}

function atomicJson(file, value) {
  const temp = file + "." + uuid() + ".tmp";
  try {
    fs.writeFileSync(temp, JSON.stringify(value), { mode: 0o600, flag: "wx" });
    fs.renameSync(temp, file);
  } finally { try { fs.unlinkSync(temp); } catch (_) {} }
}

class ThreadStore {
  constructor(root) {
    this.root = root;
    fs.mkdirSync(root, { recursive: true, mode: 0o700 });
  }
  directory(id) {
    if (!UUID.test(id || "")) throw new Error("Claude Code 会话编号无效");
    const directory = path.join(this.root, id);
    try {
      if (!fs.lstatSync(directory).isDirectory()) throw new Error("Claude Code 会话目录无效");
    } catch (error) { if (error.code !== "ENOENT") throw error; }
    return directory;
  }
  read(file, max) {
    const fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
    try {
      const stat = fs.fstatSync(fd);
      if (!stat.isFile() || stat.size > max) throw new Error("Claude Code 历史文件无效或过大");
      return JSON.parse(fs.readFileSync(fd, "utf8"));
    } finally { fs.closeSync(fd); }
  }
  get(id) {
    const thread = this.read(path.join(this.directory(id), "thread.json"), 1024 * 1024);
    if (thread.id !== id || !Array.isArray(thread.turnIds) || thread.turnIds.length > 10000 ||
        !thread.turnIds.every(turn => UUID.test(turn)) || !path.isAbsolute(thread.cwd || "")) {
      throw new Error("Claude Code 会话记录损坏");
    }
    return thread;
  }
  save(thread) {
    if (jsonBytes(thread) > 1024 * 1024) throw new Error("Claude Code 会话记录过大");
    atomicJson(path.join(this.directory(thread.id), "thread.json"), thread);
  }
  saveTurn(thread, turn) {
    if (!UUID.test(turn.id || "") || jsonBytes(turn) > MAX_TURN) throw new Error("Claude Code 回合记录过大或无效");
    atomicJson(path.join(this.directory(thread.id), turn.id + ".json"), turn);
  }
  readTurn(thread, id) {
    if (!UUID.test(id || "")) throw new Error("Claude Code 回合编号无效");
    return this.read(path.join(this.directory(thread.id), id + ".json"), MAX_TURN);
  }
  inferName(thread) {
    if (String(thread.name || "").trim() || !thread.turnIds.length) return "";
    try {
      const turn = this.readTurn(thread, thread.turnIds[0]);
      const user = Array.isArray(turn.items)
        ? turn.items.find(item => item && item.type === "userMessage")
        : null;
      const text = Array.isArray(user?.content)
        ? user.content.filter(item => item?.type === "text").map(item => item.text).join("\n")
        : "";
      return initialThreadName(text);
    } catch (_) {
      // A partially written or legacy turn should not make the whole list fail.
      return "";
    }
  }
  create(cwd, model) {
    if (!path.isAbsolute(cwd) || !fs.statSync(cwd).isDirectory()) throw new Error("工作目录不存在");
    const thread = { id: uuid(), cwd, model: modelArgument(model), createdAt: Date.now(), updatedAt: Date.now(), turnIds: [], status: "idle" };
    fs.mkdirSync(this.directory(thread.id), { mode: 0o700 });
    this.save(thread);
    return thread;
  }
  list() {
    const all = [];
    const directory = fs.opendirSync(this.root);
    try {
      let entry;
      let scanned = 0;
      while ((entry = directory.readSync()) && scanned++ < 10000) {
        if (!entry.isDirectory() || !UUID.test(entry.name)) continue;
        try {
          const thread = this.get(entry.name);
          // Older records predate the persistent name field. Infer their title
          // from the first user turn for a stable list without writing during a
          // refresh (which could race an active writer and clobber newer data).
          if (!String(thread.name || "").trim()) thread.name = this.inferName(thread);
          all.push(thread);
        } catch (_) { /* Isolate corrupt records. */ }
      }
    } finally { directory.closeSync(); }
    return all;
  }
  lock(id) {
    const file = path.join(this.directory(id), "writer.lock");
    const token = uuid();
    for (let attempt = 0; attempt < 2; attempt++) {
      try {
        fs.writeFileSync(file, JSON.stringify({ pid: process.pid, token }), { flag: "wx", mode: 0o600 });
        return () => {
          try { if (this.read(file, 1024).token === token) fs.unlinkSync(file); } catch (_) {}
        };
      } catch (error) {
        if (error.code !== "EEXIST") throw error;
        let owner;
        try { owner = this.read(file, 1024); } catch (_) { throw new Error("会话正在由另一个连接使用"); }
        if (!Number.isSafeInteger(owner.pid) || owner.pid < 1) throw new Error("会话锁无效");
        try { process.kill(owner.pid, 0); throw new Error("会话正在由另一个连接使用"); }
        catch (error) { if (error.code !== "ESRCH") throw error; }
        // Only recover a dead owner, never terminate another client.
        if (this.read(file, 1024).token === owner.token) fs.unlinkSync(file);
      }
    }
    throw new Error("会话正在由另一个连接使用");
  }
  hasWriter(id) {
    try {
      const owner = this.read(path.join(this.directory(id), "writer.lock"), 1024);
      if (!Number.isSafeInteger(owner.pid) || owner.pid < 1) return false;
      process.kill(owner.pid, 0); return true;
    } catch (error) { return error.code === "EPERM"; }
  }
}

function threadView(thread, active = false) {
  return {
    // `preview` is intentionally updated on every turn. It is not a stable
    // title fallback: using it here made unnamed conversations appear to
    // rename themselves after each new prompt.
    id: thread.id, name: String(thread.name || "").trim() || "Claude Code",
    preview: thread.preview || "", cwd: thread.cwd, model: thread.model,
    source: "claude-code", modelProvider: "anthropic",
    status: active ? "active" : "idle", activeTurnId: active ? thread.activeTurnId : null,
    createdAt: thread.createdAt, updatedAt: thread.updatedAt,
  };
}

function prepareInput(input) {
  if (!Array.isArray(input) || input.length === 0 || input.length > 32) throw new Error("消息内容无效");
  const content = [];
  const display = [];
  let bytes = 0;
  for (const item of input) {
    if (item.type === "text") {
      const text = String(item.text || "");
      bytes += Buffer.byteLength(text);
      content.push({ type: "text", text }); display.push({ type: "text", text });
    } else if (item.type === "localImage") {
      if (!path.isAbsolute(item.path || "")) throw new Error("图片路径无效");
      const mime = { ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".gif": "image/gif", ".webp": "image/webp" }[path.extname(item.path).toLowerCase()];
      if (!mime) throw new Error("Claude Code 不支持此图片格式");
      const fd = fs.openSync(item.path, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
      let data;
      try {
        const stat = fs.fstatSync(fd);
        if (!stat.isFile() || stat.size > 5 * 1024 * 1024) throw new Error("Claude Code 图片不能超过 5 MB");
        data = fs.readFileSync(fd);
      } finally { fs.closeSync(fd); }
      bytes += data.length;
      content.push({ type: "image", source: { type: "base64", media_type: mime, data: data.toString("base64") } });
      display.push({ type: "localImage", path: item.path });
    } else { throw new Error("Claude Code 不支持此消息内容类型"); }
    if (bytes > 6 * 1024 * 1024) throw new Error("消息和图片合计不能超过 6 MB");
  }
  if (!content.some(item => item.type === "image" || item.text.trim())) throw new Error("消息不能为空");
  // Keep the user-facing text cap stable in characters while also applying the
  // same UTF-8 JSON byte budget used by persisted turns.
  const displayTextChars = display.reduce((total, item) => total + (item.type === "text" ? item.text.length : 0), 0);
  if (displayTextChars > MAX_TEXT * 4 || jsonBytes(display) > MAX_TURN - OUTPUT_RESERVE) throw new Error("文本附件过大");
  return { content, display };
}

function initialThreadName(value) {
  const line = String(value || "").split(/\r?\n/, 1)[0].trim();
  if (!line) return "图片附件";
  // Keep titles compact while preserving a complete Unicode code point.
  if (line.length <= 160) return line;
  const clipped = line.slice(0, 160);
  return /[\uD800-\uDBFF]$/.test(clipped) ? clipped.slice(0, -1) : clipped;
}

class ClaudeBridge {
  constructor({ directory = process.cwd(), claudeBin = process.env.CLAUDE_BIN || "claude", store, send }) {
    this.directory = path.resolve(directory);
    this.claudeBin = claudeBin;
    this.store = store;
    this.send = send;
    this.active = new Map();
    this.approvals = new Map();
    this.stopping = false;
  }
  response(id, result) { if (id !== undefined) this.send({ id, result }); }
  error(id, error, code = -32000) { if (id !== undefined) this.send({ id, error: { code, message: bounded(error.message || error, 4000) } }); }
  notify(method, params) { this.send({ method, params }); }
  view(thread) { return threadView(thread, this.store.hasWriter(thread.id) && !!thread.activeTurnId); }
  page(thread, params = {}) {
    const desc = params.sortDirection !== "asc";
    let end = desc ? thread.turnIds.length : 0;
    if (params.cursor) {
      const at = thread.turnIds.indexOf(params.cursor);
      if (at < 0) throw new Error("历史游标已失效，请重新打开会话");
      end = desc ? at : at + 1;
    }
    const limit = integer(params.limit, 4, 20);
    const ids = desc ? thread.turnIds.slice(Math.max(0, end - limit), end).reverse() : thread.turnIds.slice(end, end + limit);
    const data = ids.map(id => {
      const running = this.active.get(thread.id);
      const turn = clone(running?.turn.id === id ? running.turn : this.store.readTurn(thread, id));
      if (turn.status === "inProgress" && !this.store.hasWriter(thread.id)) turn.status = "interrupted";
      if (params.itemsView === "notLoaded") { turn.items = []; turn.itemsView = "notLoaded"; }
      else if (params.itemsView === "summary") {
        turn.items = turn.items.map(item => ({ ...item, text: bounded(item.text, 4000), result: bounded(item.result, 4000) }));
        turn.itemsView = "summary";
      }
      return turn;
    });
    const hasMore = desc ? end > ids.length : end + ids.length < thread.turnIds.length;
    return { data, nextCursor: hasMore ? ids.at(-1) : null };
  }
  snapshot(thread, params = {}) {
    const result = { thread: this.view(thread), tokenUsage: thread.tokenUsage || null, model: thread.model, reasoningEffort: thread.effort || null };
    if (params.includeTurns !== false) result.initialTurnsPage = this.page(thread, params.initialTurnsPage || {});
    return result;
  }
  persist(run) {
    clearTimeout(run.saveTimer); run.saveTimer = null;
    this.store.saveTurn(run.thread, run.turn);
    this.store.save(run.thread);
  }
  changed(run) {
    if (!run.saveTimer) run.saveTimer = setTimeout(() => {
      try { this.persist(run); } catch (_) { this.fail(run, "无法保存 Claude Code 会话历史"); }
    }, 250);
  }
  usage(run, messageId, value, model) {
    const breakdown = usageBreakdown(value);
    if (!breakdown) return;
    const isLatest = !run.usageByMessage.has(messageId) || run.lastUsageId === messageId;
    if (isLatest && model) {
      if (run.usageModel && run.usageModel !== model) run.contextWindow = 0;
      run.usageModel = model;
    }
    run.usageByMessage.set(messageId, breakdown);
    if (isLatest) { run.lastUsage = breakdown; run.lastUsageId = messageId; }
    this.publishUsage(run);
  }
  publishUsage(run) {
    if (!run.lastUsage) return;
    const total = { ...run.baseUsage };
    for (const value of run.usageByMessage.values()) for (const key of Object.keys(ZERO_USAGE)) total[key] += value[key];
    run.thread.tokenUsage = { last: run.lastUsage, total, modelContextWindow: run.contextWindow || 0 };
    run.thread.usageModel = run.usageModel;
    this.notify("thread/tokenUsage/updated", { threadId: run.thread.id, turnId: run.turn.id, tokenUsage: clone(run.thread.tokenUsage) });
    this.changed(run);
  }
  item(run, id, type, fields = {}) {
    let item = run.turn.items.find(value => value.id === id);
    if (!item) {
      if (run.turn.items.length >= 256) throw new Error("本轮工具和消息数量超过限制");
      item = { id, type, ...fields };
      if (jsonBytes(run.turn) + jsonBytes(item) + 1 > MAX_TURN - OUTPUT_RESERVE) throw new Error("本轮输出超过历史保存上限");
      run.turn.items.push(item);
      this.notify("item/started", { threadId: run.thread.id, turnId: run.turn.id, item: clone(item) });
    }
    return item;
  }
  appendText(run, id, text) {
    const item = this.item(run, id, "agentMessage", { text: "" });
    run.truncated ||= new Set();
    if (run.truncated.has(id)) return;
    const incoming = String(text || "");
    const remaining = Math.max(0, Math.min(MAX_TEXT - textBytes(item.text), MAX_TURN - OUTPUT_RESERVE - jsonBytes(run.turn)) - textBytes(TRUNCATED));
    const clipped = textBytes(incoming) > remaining;
    const delta = clipped ? textPrefix(incoming, remaining) + TRUNCATED : incoming;
    if (!delta) return;
    if (clipped) run.truncated.add(id);
    item.text += delta;
    this.notify("item/agentMessage/delta", { threadId: run.thread.id, turnId: run.turn.id, itemId: id, delta });
    this.changed(run);
  }
  control(run, value) {
    if (!run.child.stdin.destroyed && run.child.stdin.writable) run.child.stdin.write(JSON.stringify(value) + "\n");
  }
  permissionResponse(run, requestId, value) {
    this.control(run, { type: "control_response", response: { subtype: "success", request_id: requestId, response: value } });
  }
  permission(run, message) {
    const request = message.request || {};
    if (request.subtype !== "can_use_tool") {
      this.control(run, { type: "control_response", response: { subtype: "error", request_id: message.request_id, error: "Unsupported control request" } });
      return;
    }
    if (run.turn.status !== "inProgress") return this.permissionResponse(run, message.request_id, { behavior: "deny", message: "任务已经结束" });
    const input = request.input || {};
    const isQuestion = request.tool_name === "AskUserQuestion";
    if (run.fullAccess && !isQuestion) return this.permissionResponse(run, message.request_id, { behavior: "allow", updatedInput: input });
    if (this.approvals.size >= 64) return this.permissionResponse(run, message.request_id, { behavior: "deny", message: "待审批请求过多" });
    const id = "claude-permission-" + uuid();
    const pending = { run, request, requestId: message.request_id, isQuestion };
    pending.timer = setTimeout(() => this.resolveApproval(id, {}), 10 * 60 * 1000);
    this.approvals.set(id, pending);
    const params = { threadId: run.thread.id, turnId: run.turn.id, itemId: request.tool_use_id || "", reason: bounded("Claude Code 请求使用 " + request.tool_name + "\n" + JSON.stringify(input), 16000) };
    if (isQuestion) {
      pending.questions = Array.isArray(input.questions) ? input.questions.slice(0, 16) : [];
      params.questions = pending.questions.map((question, index) => ({ id: String(index), header: bounded(question.header, 100), question: bounded(question.question, 4000), isOther: true, options: (question.options || []).slice(0, 24) }));
    } else { params.permissions = { claudeTool: { name: request.tool_name, input } }; }
    this.send({ id, method: isQuestion ? "item/tool/requestUserInput" : "item/permissions/requestApproval", params });
  }
  resolveApproval(id, result) {
    const pending = this.approvals.get(id);
    if (!pending) return;
    this.approvals.delete(id); clearTimeout(pending.timer);
    const { run, request, requestId, isQuestion } = pending;
    let answer = { behavior: "deny", message: "用户拒绝或取消了此次工具请求" };
    if (run.turn.status === "inProgress") {
      if (isQuestion && pending.questions.length && pending.questions.every((_, i) => result.answers?.[i]?.answers?.length)) {
        const answers = {};
        for (const [index, question] of pending.questions.entries()) answers[question.question] = result.answers[index].answers.join(", ");
        answer = { behavior: "allow", updatedInput: { ...request.input, answers } };
      } else if (!isQuestion && result.permissions?.claudeTool?.name === request.tool_name) {
        answer = { behavior: "allow", updatedInput: request.input };
      }
    }
    this.permissionResponse(run, requestId, answer);
    this.notify("serverRequest/resolved", { threadId: run.thread.id, requestId: id });
  }
  finish(run, status, error) {
    if (run.turn.status !== "inProgress") return;
    run.turn.status = status; run.turn.completedAt = Date.now();
    clearTimeout(run.initTimer);
    run.thread.updatedAt = Date.now();
    if (error) run.turn.error = { message: bounded(error, 4000) };
    for (const [id, approval] of this.approvals) if (approval.run === run) this.resolveApproval(id, {});
    for (const item of run.turn.items) {
      if (item.status === "inProgress") {
        item.status = status === "completed" ? "completed" : "failed";
        this.notify("item/completed", { threadId: run.thread.id, turnId: run.turn.id, item: clone(item) });
      }
    }
    try { this.persist(run); } catch (_) { run.turn.status = "failed"; run.turn.error = { message: "无法保存 Claude Code 会话历史" }; }
    // The CLI may still own its native session until close. Keep the visible
    // turn active until that writer is gone; completion must permit a new turn.
  }
  terminate(run) {
    if (run.killTimer) return;
    run.child.kill("SIGTERM");
    run.killTimer = setTimeout(() => run.child.kill("SIGKILL"), 2000);
  }
  fail(run, error) { this.finish(run, "failed", error); this.terminate(run); }
  message(run, value) {
    if (value.type === "control_request") return this.permission(run, value);
    if (value.type === "control_cancel_request") {
      for (const [id, pending] of this.approvals) {
        if (pending.run === run && pending.requestId === value.request_id) {
          this.approvals.delete(id); clearTimeout(pending.timer);
          this.notify("serverRequest/resolved", { threadId: run.thread.id, requestId: id });
        }
      }
      return;
    }
    if (run.turn.status !== "inProgress") return;
    if (value.type === "control_response" && value.response?.request_id === run.initializeId) {
      if (run.initialized) return;
      if (value.response.subtype !== "success") return this.fail(run, "Claude Code 初始化失败");
      run.initialized = true;
      clearTimeout(run.initTimer);
      this.control(run, { type: "user", session_id: run.thread.id, message: { role: "user", content: run.content }, parent_tool_use_id: null });
      run.content = null;
      return;
    }
    if (value.type === "system" && value.subtype === "init") {
      run.thread.claudeSessionId = value.session_id;
      run.actualModel = value.model || run.thread.model;
      this.changed(run);
    }
    if (value.parent_tool_use_id) return; // Nested Agent tools stay inside their own tool card.
    if (value.type === "stream_event") {
      const event = value.event || {};
      if (event.type === "message_start") {
        // Some Claude-compatible gateways omit message_start.message.id while
        // the later assistant event still contains one. A random fallback
        // makes the streamed text and final snapshot look like two messages.
        // Keep a deterministic per-message key and reconcile final blocks to
        // the item IDs emitted while streaming.
        run.messageSequence += 1;
        const streamMessageId = event.message?.id;
        run.streamMessageIdProvided = typeof streamMessageId === "string" && streamMessageId.length > 0;
        run.messageId = run.streamMessageIdProvided ? streamMessageId : `stream-${run.turn.id}-${run.messageSequence}`;
        run.streamMessageKey = run.messageId;
        run.streamedByIndex.clear();
        run.messageUsage = { ...event.message?.usage };
        run.messageModel = event.message?.model || run.actualModel;
        this.usage(run, run.messageId, run.messageUsage, run.messageModel);
      }
      if (event.type === "message_delta" && event.usage && run.messageId) {
        run.messageUsage = { ...run.messageUsage, ...event.usage };
        this.usage(run, run.messageId, run.messageUsage, run.messageModel);
      }
      const index = Number.isSafeInteger(event.index) && event.index >= 0 ? event.index : 0;
      const id = "assistant-" + (run.streamMessageKey || run.messageId || run.turn.id) + "-" + index;
      if (event.type === "content_block_delta" && event.delta?.type === "text_delta") {
        run.streamedByIndex.set(index, id);
        run.streamed.add(id); this.appendText(run, id, event.delta.text);
      }
    } else if (value.type === "assistant" && Array.isArray(value.message?.content)) {
      const finalMessageId = value.message.id;
      const finalMessageIdProvided = typeof finalMessageId === "string" && finalMessageId.length > 0;
      const messageId = finalMessageIdProvided ? finalMessageId : run.messageId || run.turn.id;
      // A later assistant snapshot can arrive without another message_start.
      // Never let an old stream index swallow that independent response.
      const canReuseStreamItems = !run.streamMessageIdProvided
        || (finalMessageIdProvided && finalMessageId === run.messageId);
      this.usage(run, messageId, value.message.usage, value.message.model || run.actualModel);
      value.message.content.forEach((block, index) => {
        // Prefer the item already used by stream deltas when the message
        // identity is compatible; mismatched IDs represent a new response.
        const streamedId = canReuseStreamItems ? run.streamedByIndex.get(index) : null;
        const id = streamedId || "assistant-" + (canReuseStreamItems ? (run.streamMessageKey || messageId) : messageId) + "-" + index;
        if (block.type === "text") {
          if (!run.streamed.has(id) && !run.completedMessages.has(id)) this.appendText(run, id, block.text);
          run.completedMessages.add(id);
        } else if (block.type === "tool_use") {
          this.item(run, block.id, "mcpToolCall", { server: "Claude Code", tool: bounded(block.name, 100), arguments: boundedJsonText(JSON.stringify(block.input || {}), 16000), status: "inProgress" });
          this.changed(run);
        }
      });
    } else if (value.type === "user" && Array.isArray(value.message?.content)) {
      for (const block of value.message.content) if (block.type === "tool_result") {
        const item = run.turn.items.find(item => item.id === block.tool_use_id);
        if (item) {
          delete item.result;
          item.result = boundedJsonText(typeof block.content === "string" ? block.content : JSON.stringify(block.content || ""), Math.max(0, Math.min(MAX_TEXT, MAX_TURN - OUTPUT_RESERVE - jsonBytes(run.turn) - 32)));
          item.status = block.is_error ? "failed" : "completed";
          this.notify("item/completed", { threadId: run.thread.id, turnId: run.turn.id, item: clone(item) });
          this.changed(run);
        }
      }
    } else if (value.type === "result") {
      // Result input/output totals accumulate every tool loop (and subagents).
      // Only the latest assistant request measures the current context occupancy.
      const modelUsage = value.modelUsage?.[run.usageModel || run.actualModel];
      const reportedWindow = tokenCount(modelUsage?.contextWindow);
      if (reportedWindow) {
        run.contextWindow = reportedWindow;
        this.publishUsage(run);
      }
      if (value.result && !run.turn.items.some(item => item.type === "agentMessage")) this.appendText(run, "assistant-" + run.turn.id, value.result);
      this.finish(run, value.is_error ? "failed" : "completed", value.is_error ? (value.errors || [value.result || "Claude Code 执行失败"]).join("\n") : null);
      run.child.stdin.end();
      run.exitTimer = setTimeout(() => this.terminate(run), 2000);
    }
  }
  start(thread, prepared, params, requestId) {
    if (params.sandboxPolicy?.type === "readOnly") throw new Error("Claude Code 暂不支持应用内只读沙箱，请使用 Claude Code 权限审批模式");
    if (this.active.has(thread.id)) throw new Error("Claude Code 会话仍在处理中");
    if (this.active.size >= 8) throw new Error("同时运行的 Claude Code 会话过多");
    const unlock = this.store.lock(thread.id);
    let run;
    try {
      thread = this.store.get(thread.id);
      if (!String(thread.name || "").trim()) thread.name = this.store.inferName(thread);
      if (thread.turnIds.length >= 10000) throw new Error("会话回合数量已达上限，请新建会话");
      const turn = { id: uuid(), status: "inProgress", startedAt: Date.now(), items: [{ id: uuid(), type: "userMessage", content: prepared.display }] };
      if (jsonBytes(turn) > MAX_TURN - OUTPUT_RESERVE) throw new Error("文本附件过大");
      const args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--include-partial-messages", "--permission-mode", "default", "--permission-prompt-tool", "stdio"];
      if (thread.claudeSessionId) args.push("--resume", thread.claudeSessionId);
      else args.push("--session-id", thread.id);
      const configuration = settings.readSettings();
      const model = modelArgument(params.model ?? thread.model ?? configuration.model);
      const unsupportedEffort = model && !modelCatalog(configuration).data.find(option => option.model === model)?.supportedReasoningEfforts.length;
      if (unsupportedEffort && params.effort) throw new Error("所选 Claude Code 模型不支持思考强度");
      const effort = unsupportedEffort ? null : params.effort ?? configuration.reasoningEffort;
      if (effort && !EFFORTS.includes(effort)) throw new Error("Claude Code 不支持此思考强度");
      if (model) args.push("--model", model);
      if (effort) args.push("--effort", effort);
      const environment = settings.launchEnvironment();
      if (unsupportedEffort) {
        // Claude's auto sentinel clears this session's effort,
        // including persisted effortLevel and settings.env overrides. Retain
        // all native settings sources (especially permissions and hooks).
        environment.CLAUDE_CODE_EFFORT_LEVEL = "auto";
        args.push("--settings", '{"env":{"CLAUDE_CODE_EFFORT_LEVEL":"auto"}}');
      } else if (params.effort) {
        environment.CLAUDE_CODE_EFFORT_LEVEL = effort;
        args.push("--settings", JSON.stringify({ effortLevel: effort, env: { CLAUDE_CODE_EFFORT_LEVEL: effort } }));
      }
      const previousUsage = thread.tokenUsage;
      const previousModel = thread.usageModel;
      if (model !== thread.model) thread.tokenUsage = null;
      thread.model = model;
      thread.effort = effort || null;
      thread.turnIds.push(turn.id); thread.activeTurnId = turn.id; thread.updatedAt = Date.now(); thread.status = "active";
      const previewText = prepared.display.filter(item => item.type === "text").map(item => item.text).join("\n");
      thread.preview = bounded(previewText, 1000) || "图片附件";
      // A conversation title is assigned once, from its first prompt. Keep
      // the mutable preview separate so list refreshes cannot rename it.
      if (!String(thread.name || "").trim()) thread.name = initialThreadName(previewText);
      this.store.saveTurn(thread, turn); this.store.save(thread);
      const child = cp.spawn(this.claudeBin, args, { cwd: thread.cwd, env: environment, stdio: ["pipe", "pipe", "pipe"] });
      run = { thread, turn, child, unlock, content: prepared.content, streamed: new Set(), streamedByIndex: new Map(), messageSequence: 0, streamMessageKey: null, streamMessageIdProvided: false, completedMessages: new Set(), truncated: new Set(), fullAccess: params.approvalPolicy === "never" && params.sandboxPolicy?.type === "dangerFullAccess", initializeId: uuid(), usageByMessage: new Map(), baseUsage: { ...ZERO_USAGE, ...previousUsage?.total }, usageModel: previousModel, contextWindow: model === previousModel ? tokenCount(previousUsage?.modelContextWindow) : 0 };
      this.active.set(thread.id, run);
      this.response(requestId, { turn: { id: turn.id, status: "inProgress" } });
      this.notify("turn/started", { threadId: thread.id, turn: { id: turn.id, status: "inProgress" } });
      this.notify("item/completed", { threadId: thread.id, turnId: turn.id, item: turn.items[0] });
      jsonLines(child.stdout, value => this.message(run, value), error => this.fail(run, error.message));
      child.stderr.on("data", () => {}); // Never forward raw credential-bearing CLI diagnostics.
      child.stdin.on("error", () => this.fail(run, "Claude Code 输入通道已关闭"));
      child.on("error", () => this.fail(run, "无法启动 Claude Code，请检查服务器上的安装与登录"));
      child.on("close", code => {
        clearTimeout(run.initTimer); clearTimeout(run.saveTimer); clearTimeout(run.killTimer); clearTimeout(run.exitTimer);
        if (run.turn.status === "inProgress") this.finish(run, "failed", `Claude Code 未完成响应便退出 (${code ?? "signal"})，请检查登录与服务配置`);
        if (this.active.get(thread.id) === run) this.active.delete(thread.id);
        run.thread.activeTurnId = null; run.thread.status = "idle";
        try { this.persist(run); } catch (_) { run.turn.status = "failed"; run.turn.error = { message: "无法保存 Claude Code 会话历史" }; }
        unlock();
        this.notify("turn/completed", { threadId: run.thread.id, turn: { id: run.turn.id, status: run.turn.status, error: run.turn.error || null } });
        this.notify("thread/status/changed", { threadId: run.thread.id, status: "idle" });
      });
      run.initTimer = setTimeout(() => this.fail(run, "Claude Code 初始化超时，请检查 CLI 版本"), 30000);
      this.control(run, { type: "control_request", request_id: run.initializeId, request: { subtype: "initialize", hooks: {} } });
    } catch (error) { if (!run) unlock(); throw error; }
  }
  async handle(message) {
    if (!message || typeof message !== "object") return;
    const { id, method, params = {} } = message;
    if (!method) return this.resolveApproval(id, message.result || {});
    if (method === "initialized") return;
    if (this.stopping) return this.error(id, "连接正在关闭");
    try {
      if (method === "initialize") return this.response(id, { serverInfo: { name: "claude-code-bridge", version: "1" } });
      if (method === "model/list") return this.response(id, modelCatalog());
      if (method === "agent/settings/read") return this.response(id, settings.readSettings());
      if (method === "agent/settings/write") return this.response(id, await settings.writeSettings(params));
      if (method === "agent/settings/test") return this.response(id, await settings.testSettings(params));
      if (method === "agent/models/list") return this.response(id, await settings.listApiModels(params));
      if (method === "thread/list") {
        const search = String(params.searchTerm || "").toLowerCase();
        const threads = params.archived ? [] : this.store.list().filter(thread => thread.cwd === this.directory && (!search || [thread.name, thread.preview].some(value => String(value || "").toLowerCase().includes(search)))).sort((a, b) => b.updatedAt - a.updatedAt || a.id.localeCompare(b.id));
        const offset = params.cursor ? threads.findIndex(thread => thread.id === params.cursor) + 1 : 0;
        if (params.cursor && offset === 0) throw new Error("会话列表游标已失效");
        const limit = integer(params.limit, 100, 100);
        const data = threads.slice(offset, offset + limit).map(thread => this.view(thread));
        return this.response(id, { data, nextCursor: offset + data.length < threads.length ? data.at(-1).id : null });
      }
      if (method === "thread/start") return this.response(id, this.snapshot(this.store.create(params.cwd || this.directory, params.model)));
      const thread = this.store.get(String(params.threadId || ""));
      if (method === "thread/read" || method === "thread/resume") return this.response(id, this.snapshot(thread, params));
      if (method === "thread/turns/list") return this.response(id, this.page(thread, params));
      if (method === "turn/start") return this.start(thread, prepareInput(params.input), params, id);
      if (method === "turn/interrupt") {
        const run = this.active.get(thread.id);
        if (!run || run.turn.id !== params.turnId) throw new Error("待停止的回合已失效或由另一个连接运行");
        this.finish(run, "interrupted");
        this.control(run, { type: "control_request", request_id: uuid(), request: { subtype: "interrupt" } });
        this.terminate(run);
        return this.response(id, {});
      }
      if (method === "thread/name/set") {
        const unlock = this.store.lock(thread.id);
        try { const current = this.store.get(thread.id); current.name = bounded(params.name, 160).trim(); if (!current.name) throw new Error("会话名称不能为空"); this.store.save(current); }
        finally { unlock(); }
        return this.response(id, {});
      }
      this.error(id, "Claude Code 暂不支持此操作", -32601);
    } catch (error) { this.error(id, error); }
  }
  stop() {
    if (this.stopping) return;
    this.stopping = true;
    for (const run of this.active.values()) { this.finish(run, "interrupted", "连接已关闭"); this.terminate(run); }
  }
}

function main() {
  const at = process.argv.indexOf("--directory");
  const directory = at < 0 ? process.cwd() : process.argv[at + 1];
  const store = new ThreadStore(process.env.CODEX_REMOTE_CLAUDE_STATE || path.join(os.homedir(), ".local", "share", "codex-remote", "claude-history"));
  let outputOpen = true;
  const bridge = new ClaudeBridge({ directory, store, send: value => { if (outputOpen) process.stdout.write(JSON.stringify(value) + "\n"); } });
  const stop = () => { bridge.stop(); process.stdin.pause(); };
  process.stdout.on("error", () => { outputOpen = false; stop(); });
  jsonLines(process.stdin, message => bridge.handle(message), () => { bridge.error(null, "无效或过大的 JSON 消息", -32700); stop(); });
  process.stdin.on("end", stop);
  process.on("SIGTERM", stop); process.on("SIGINT", stop);
}

if (require.main === module) main();
module.exports = { ClaudeBridge, ThreadStore, prepareInput, bounded, threadView, initialThreadName, modelCatalog, usageBreakdown };

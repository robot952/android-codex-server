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
// Claude-compatible gateways sometimes give a streamed message and its final
// assistant snapshot different IDs. IDs alone therefore cannot identify a
// repeated content block. Keep the semantic key deterministic even when tool
// input object keys arrive in a different order.
function stableJson(value) {
  if (Array.isArray(value)) return "[" + value.map(item => stableJson(item)).join(",") + "]";
  if (value && typeof value === "object") {
    return "{" + Object.keys(value).sort().map(key => JSON.stringify(key) + ":" + stableJson(value[key])).join(",") + "}";
  }
  const encoded = JSON.stringify(value);
  return encoded === undefined ? "null" : encoded;
}
function assistantBlockFingerprint(block) {
  if (!block || typeof block !== "object") return "";
  let value;
  if (block.type === "text") value = "text\u0000" + String(block.text || "");
  else if (block.type === "tool_use") value = "tool\u0000" + String(block.name || "") + "\u0000" + stableJson(block.input || {});
  else return "";
  return crypto.createHash("sha256").update(value).digest("hex");
}
// A reconnect can replay text deltas after a new message_start. Reconcile the
// replay against the text already emitted for that content index, preserving
// only an unseen cumulative suffix. Exact chunks are tracked separately so a
// legitimate short continuation that happens to match the existing tail is
// never swallowed. This is intentionally used only while a retry is pending;
// ordinary consecutive chunks may legitimately repeat words.
function streamDeltaSuffix(existing, incoming, seen) {
  const previous = String(existing || "");
  const next = String(incoming || "");
  if (!next || seen?.has(next)) return "";
  if (next.startsWith(previous)) return next.slice(previous.length);
  return next;
}
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

// Every native tool is projected onto the App's shared timeline contract so
// Claude Code cards read exactly like Codex cards: shell work becomes a
// command card, file writes become a diff card, and the remaining tools keep a
// Chinese label instead of the raw English wire name.
const TOOL_TITLES = {
  Read: "读取文件", Glob: "查找文件", Grep: "搜索内容",
  WebSearch: "网页搜索", WebFetch: "抓取网页", TodoWrite: "更新任务清单",
  TaskCreate: "创建任务", TaskUpdate: "更新任务", TaskList: "查看任务", TaskGet: "查看任务",
  AskUserQuestion: "询问用户", EnterPlanMode: "进入计划模式", ExitPlanMode: "退出计划模式",
  EnterWorktree: "进入工作树", ExitWorktree: "退出工作树", KillShell: "停止后台任务",
  KillBash: "停止后台任务", BashOutput: "查看命令输出", NotebookRead: "读取笔记本",
  Skill: "调用技能", SlashCommand: "执行命令", ListMcpResources: "列出资源",
  ReadMcpResource: "读取资源", Computer: "操作界面", CodebaseSearch: "搜索代码",
  ExitSpecMode: "退出规格模式", EnterSpecMode: "进入规格模式",
};
// Blueprint names that Claude has renamed across releases.
const TOOL_ALIASES = { Bash: "command", Shell: "command", Terminal: "command", Task: "agent", Agent: "agent", SendMessage: "agentMessage" };
const AGENT_TOOLS = new Set(["Task", "Agent"]);
// Sending a message to an agent that already exists is not a new delegation,
// so it becomes an addressable transcript row instead of a tool card.
const AGENT_MESSAGE_TOOLS = new Set(["SendMessage"]);

function toolKind(name) {
  const raw = String(name || "");
  const colon = raw.indexOf(":");
  // `mcp__server__tool`, `Server:tool` and `mcp_server_tool` all reach one name.
  if (raw.startsWith("mcp__")) return { kind: "mcp", server: raw.split("__")[1] || "MCP", tool: raw.split("__").slice(2).join("__") || raw };
  if (colon > 0) return { kind: "mcp", server: raw.slice(0, colon), tool: raw.slice(colon + 1) };
  const alias = TOOL_ALIASES[raw];
  if (alias === "command") return { kind: "command" };
  if (alias === "agent") return { kind: "agent" };
  if (alias === "agentMessage") return { kind: "agentMessage" };
  if (raw === "Edit" || raw === "MultiEdit" || raw === "Write" || raw === "NotebookEdit") return { kind: "file" };
  if (raw === "WebSearch") return { kind: "search" };
  return { kind: "tool", title: TOOL_TITLES[raw] || raw || "工具调用" };
}

function readString(value, key) {
  const found = value?.[key];
  return typeof found === "string" ? found : "";
}

// A local line diff is enough to keep +N/-N and the per-file rows meaningful;
// the App never re-applies these hunks.
function lineDiff(before, after, context = 2) {
  const left = String(before ?? "").split("\n");
  const target = String(after ?? "").split("\n");
  const right = target;
  let head = 0;

  while (head < left.length && head < right.length && left[head] === right[head]) head += 1;
  let tail = 0;
  while (tail < left.length - head && tail < right.length - head && left[left.length - 1 - tail] === right[right.length - 1 - tail]) tail += 1;
  const removed = left.slice(head, left.length - tail);
  const added = right.slice(head, right.length - tail);
  if (!removed.length && !added.length) return "";
  const from = Math.max(0, head - context);
  const to = Math.min(left.length, left.length - tail + context);
  const lines = [];
  for (const line of left.slice(from, head)) lines.push(" " + line);
  for (const line of removed) lines.push("-" + line);
  for (const line of added) lines.push("+" + line);
  const last = Math.min(right.length, right.length - tail + context);
  for (const line of right.slice(right.length - tail, last)) lines.push(" " + line);
  return lines.join("\n");
}

// Claude tools carry one file per call. Emitting the App's `changes` array lets
// the transcript show the edited paths instead of an opaque tool row.
function fileChanges(name, input) {
  const path = readString(input, "file_path") || readString(input, "notebook_path") || readString(input, "path");
  if (!path) return null;
  if (name === "MultiEdit" && Array.isArray(input.edits)) {
    const diff = input.edits.map(edit => lineDiff(edit.old_string, edit.new_string)).filter(Boolean).join("\n");
    return { path, kind: "update", diff };
  }
  if (name === "Edit") return { path, kind: "update", diff: lineDiff(input.old_string, input.new_string) };
  if (name === "NotebookEdit") return { path, kind: "update", diff: lineDiff(input.old_source, input.new_source) };
  const content = readString(input, "content");
  return { path, kind: "add", diff: content ? content.split("\n").map(line => "+" + line).join("\n") : "" };
}

function toolResultText(block) {
  const content = block?.content;
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content.map(part => typeof part === "string" ? part : readString(part, "text")).filter(Boolean).join("\n");
  }
  return "";
}

// The spawn result ends with the address that later SendMessage calls use
// (`agentId: a1b2c3d4e5f6`). Those calls may name that address instead of the
// teammate, so it has to be read back off the result text.
function resultAgentId(text) {
  const match = /agent_?id\s*[:=]\s*([A-Za-z0-9_.:-]{4,80})/i.exec(String(text || ""));
  return match ? match[1] : "";
}

// `Explore` alone cannot tell three delegated searches apart, so the label the
// App shows comes from the description the parent wrote. The subagent type
// stays the address: a SendMessage names teammates by it.
function agentLabel(subagentType, description) {
  const type = String(subagentType || "").split(":")[0].trim() || "Agent";
  const text = String(description || "").split(/\r?\n/, 1)[0].trim();
  return { type, name: agentDisplayName(text, type), summary: text ? bounded(text, 400) : "" };
}

// The App reads a collaborator's name from the last segment of its path, so a
// separator inside a description would hide everything that precedes it.
function agentDisplayName(description, fallback) {
  const name = description.replace(/[\\/]+/g, " ").replace(/\s+/g, " ").trim() || fallback;
  return name.length <= 60 ? name : name.slice(0, 60).trim();
}

// Two delegations can carry the same type and description. Rows named alike
// would leave the parent transcript unable to tell the two apart.
function uniqueAgentName(run, wanted) {
  const taken = new Set();
  for (const sibling of (run.children || new Map()).values()) taken.add(sibling.name);
  if (!taken.has(wanted)) return wanted;
  for (let index = 2; ; index += 1) {
    const candidate = `${wanted} ${index}`;
    if (!taken.has(candidate)) return candidate;
  }
}

// One delegated conversation. Its blocks arrive on the parent's transport with
// `parent_tool_use_id` set, and they are kept out of the parent's own usage
// totals so the context ring still measures the parent only.
class ChildAgent {
  constructor({ run, store }, input) {
    const label = agentLabel(input.subagent_type, input.description);
    this.parent = run;
    this.name = uniqueAgentName(run, label.name);
    // The address a SendMessage uses, which the description never replaces.
    this.type = label.type;
    this.summary = label.summary;
    this.agentPath = this.name;
    // The spawn result exposes an `agentId` (a…-…) that later SendMessage
    // calls may address instead of the display name.
    this.agentId = "";
    this.status = "running";
    this.turn = { id: uuid(), status: "inProgress", startedAt: Date.now(), items: [] };
    this.thread = store.createChild(run.thread, { name: this.name, model: run.thread.model, agentPath: this.agentPath });
    // The App opens the delegated page by this id, so it has to be the id the
    // thread is actually persisted under.
    this.id = this.thread.id;
    this.streamed = new Set();
    this.completedMessages = new Set();
    this.lastAssistantBlocks = [];
    this.runText = new Map();
    // Registering the turn is what makes the child page load its history at all.
    this.thread.turnIds.push(this.turn.id);
    this.thread.activeTurnId = this.turn.id;
    this.thread.status = "active";
    this.preview = this.summary;
    store.saveTurn(this.thread, this.turn);
    store.save(this.thread);
  }
  item(type, id, fields) {
    let item = this.turn.items.find(value => value.id === id);
    if (item) return item;
    item = { id, type, ...fields };
    this.thread.updatedAt = Date.now();
    this.turn.items.push(item);
    return item;
  }
  text(id, value) {
    const item = this.item("agentMessage", id, { text: "" });
    const incoming = String(value || "");
    if (!incoming || this.streamed.has(id)) return "";
    this.streamed.add(id);
    item.text += incoming;
    return item.text;
  }
  settle(status) {
    if (this.status !== "running") return;
    this.status = status;
    this.turn.status = status === "completed" ? "completed" : status;
    this.turn.completedAt = Date.now();
    this.thread.updatedAt = Date.now();
    this.thread.status = "idle";
    delete this.thread.activeTurnId;
    for (const item of this.turn.items) if (item.status === "inProgress") item.status = this.turn.status === "completed" ? "completed" : "failed";
  }
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
  // A delegated sub-agent gets its own openable conversation. The App only
  // treats it as a collaborator when the record declares its parent and the
  // subagent thread source.
  createChild(parent, { name, model, agentPath }) {
    const thread = this.create(parent.cwd, model);
    thread.parentThreadId = parent.id;
    thread.threadSource = "subagent";
    thread.agentPath = agentPath;
    thread.name = name;
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
  const view = {
    // `preview` is intentionally updated on every turn. It is not a stable
    // title fallback: using it here made unnamed conversations appear to
    // rename themselves after each new prompt.
    id: thread.id, name: String(thread.name || "").trim() || "Claude Code",
    preview: thread.preview || "", cwd: thread.cwd, model: thread.model,
    source: "claude-code", modelProvider: "anthropic",
    status: active ? "active" : "idle", activeTurnId: active ? thread.activeTurnId : null,
    createdAt: thread.createdAt, updatedAt: thread.updatedAt,
  };
  // A delegated conversation is only recognised as a collaborator when its
  // parent and subagent origin travel with the record; otherwise reopening
  // the child page loses the parent link the App navigates back to.
  if (thread.parentThreadId) view.parentThreadId = thread.parentThreadId;
  if (thread.threadSource) view.threadSource = thread.threadSource;
  if (thread.agentPath) view.agentPath = thread.agentPath;
  return view;
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
    // A delegated conversation is written by its parent's run, so it has no
    // writer lock of its own. Opening one mid-run must still read as running.
    this.childThreads = new Map();
    this.stopping = false;
  }
  response(id, result) { if (id !== undefined) this.send({ id, result }); }
  error(id, error, code = -32000) { if (id !== undefined) this.send({ id, error: { code, message: bounded(error.message || error, 4000) } }); }
  notify(method, params) { this.send({ method, params }); }
  view(thread) { return threadView(thread, (!!thread.activeTurnId) && (this.childThreads.has(thread.id) || this.store.hasWriter(thread.id))); }
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
      if (turn.status === "inProgress" && !this.childThreads.has(thread.id) && !this.store.hasWriter(thread.id)) turn.status = "interrupted";
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
    this.closeChildren(run, status === "completed" ? "completed" : "failed");
    try { this.persist(run); } catch (_) { run.turn.status = "failed"; run.turn.error = { message: "无法保存 Claude Code 会话历史" }; }
    // A compaction pass holds the request until its turn reaches this point.
    if (run.settlePass) { const settle = run.settlePass; run.settlePass = null; settle(); }
    // The CLI may still own its native session until close. Keep the visible
    // turn active until that writer is gone; completion must permit a new turn.
  }
  // The CLI compacts the conversation itself and then reports the boundary.
  // The App only needs the one notice card plus corrected occupancy.
  compacted(run, metadata) {
    const post = tokenCount(metadata.post_tokens);
    if (post) {
      const previous = run.usageByMessage.get(run.compactionId) || { ...ZERO_USAGE };
      run.usageByMessage.set(run.compactionId, { ...previous, inputTokens: post, totalTokens: post + previous.outputTokens });
      run.lastUsage = run.usageByMessage.get(run.compactionId);
      run.lastUsageId = run.compactionId;
      this.publishUsage(run);
    }
    const item = this.item(run, run.compactionId, "contextCompaction", {});
    item.status = "completed";
    this.notify("item/completed", { threadId: run.thread.id, turnId: run.turn.id, item: clone(item) });
    run.compactionDone = true;
    this.changed(run);
  }
  // A delegation whose closing tool result never arrived still has to reach a
  // terminal state, otherwise its card would spin forever.
  closeChildren(run, status) {
    for (const child of this.children(run).values()) {
      if (child.status !== "running") continue;
      child.settle(status);
      if (this.childThreads.get(child.id) === child) this.childThreads.delete(child.id);
      try { this.store.saveTurn(child.thread, child.turn); this.store.save(child.thread); } catch (_) {}
      const kind = status === "completed" ? "completed" : "interrupted";
      this.activity(run, child, kind, status === "completed" ? "completed" : "interrupted");
    }
  }
  terminate(run) {
    if (run.killTimer) return;
    // A superseded transport may still flush buffered events while the
    // replacement run is already publishing; it must not touch shared state.
    run.exiting = true;
    run.child.kill("SIGTERM");
    run.killTimer = setTimeout(() => run.child.kill("SIGKILL"), 2000);
  }
  // Claude Code has no compaction control request. It ships `/compact` as a
  // local command that works non-interactively, so active compaction is one
  // extra headless pass over the same native session: the pass summarises the
  // transcript, the CLI persists the new session state, and the App gets a
  // single notice card plus the corrected context occupancy.
  async compact(thread, params, requestId) {
    if (this.active.has(thread.id)) throw new Error("Claude Code 会话仍在处理中");
    const current = this.store.get(thread.id);
    if (!current.claudeSessionId) throw new Error("当前会话尚未在服务器上建立 Claude Code 原生会话，请先发送一条消息");
    if (this.active.size >= 8) throw new Error("同时运行的 Claude Code 会话过多");
    const compactionId = uuid();
    // The notice turn is registered and written by start(), together with its
    // own turn file. Registering it here would leave a turn id in the history
    // whose file start() never wrote whenever start() rejects the pass, and the
    // App cannot page past a missing turn file.
    const turn = { id: uuid(), status: "inProgress", startedAt: Date.now(), items: [{ id: compactionId, type: "contextCompaction", status: "inProgress" }] };
    // `/compact` is a local command: it reads the resumed session, summarises
    // it, and persists the rewritten session. Its own turn carries only the
    // notice card, so the user sees the compression and nothing else.
    const prepared = { display: [], content: [{ type: "text", text: "/compact" }] };
    let resolveBoundary;
    let rejectBoundary;
    const boundary = new Promise((resolve, reject) => { resolveBoundary = resolve; rejectBoundary = reject; });
    // The boundary only has the new occupancy; the turn stays active until the
    // CLI exits and releases its writer, so the request has to outlive it or
    // the App would page a turn that is still marked in progress.
    let settlePass;
    const settled = new Promise(resolve => { settlePass = resolve; });
    const run = this.start(thread, prepared, { model: current.model, effort: current.effort }, requestId, { turn, compactionId, compact: true });
    run.settlePass = settlePass;
    run.boundaryResolve = () => {
      run.boundaryDone = true;
      resolveBoundary();
      // `/compact` rewrites the session on the server before it reports the
      // boundary, so the pass is already done: the CLI only still has to exit,
      // and one that lingers is stopped shortly after rather than holding the
      // request open.
      run.exitTimer = setTimeout(() => this.completePass(run), 2000);
    };
    run.boundaryReject = error => rejectBoundary(error);
    // The App budgets 180s for this request; the pass gives up sooner so the
    // user reads a reason instead of a bare timeout.
    run.boundaryTimer = setTimeout(() => this.fail(run, "Claude Code 压缩超时，请稍后重试"), 120000);
    let failure = null;
    try { await boundary; } catch (error) { failure = error; }
    clearTimeout(run.boundaryTimer);
    if (!run.boundaryDone) {
      if (!failure) failure = "Claude Code 未能压缩当前会话上下文";
      this.finish(run, "failed", failure);
      this.terminate(run);
      throw new Error(failure);
    }
    await settled;
    if (run.turn.status !== "completed") throw new Error(run.turn.error?.message || "Claude Code 未能完成压缩");
    return {};
  }
  fail(run, error) { this.finish(run, "failed", error); this.terminate(run); }
  // A compaction pass that saw its boundary has already done its work; the CLI
  // only still has to go away.
  completePass(run) { this.finish(run, "completed"); this.terminate(run); }
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
    // Compaction reports how much of the window survived, so the App's usage
    // ring can be corrected without waiting for the next model response.
    if (value.type === "system" && value.subtype === "compact_boundary") {
      this.compacted(run, value.compact_metadata || {});
      if (run.boundaryResolve) run.boundaryResolve();
      return;
    }
    // A dedicated compaction run only produces the boundary and its summary
    // message; nothing from it may be appended to the conversation. The CLI
    // still has to be told the pass is over, or a pass that reported no
    // boundary would leave its request waiting on a process that never exits.
    if (run.compactOnly) {
      if (value.type === "result") run.child.stdin.end();
      return;
    }
    // A delegated sub-agent shares the parent's transport but not its turn.
    // Its blocks belong to the child conversation that owns this tool call.
    const child = value.parent_tool_use_id ? this.children(run).get(value.parent_tool_use_id) : null;
    if (value.parent_tool_use_id && !child) return;
    if (run.exiting) return; // A superseded transport must not touch the newer one.
    if (child) {
      // A child's answer is not deduplicated against the parent's stream state,
      // so it only needs the block snapshots. Its tool results arrive as `user`
      // messages on the same transport and must reach the same child.
      if ((value.type === "assistant" || value.type === "user") && Array.isArray(value.message?.content)) this.childAnswer(child, value);
      return;
    }
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
        // Existing indexes belong to the previous transport generation. Keep
        // their canonical items and reconcile the next deltas as replays.
        for (const index of run.streamedByIndex.keys()) run.streamReplayByIndex.set(index, true);
        // Keep streamed indexes, semantic fingerprints and tool aliases across
        // repeated message_start snapshots. Gateways can restart a stream for
        // the same assistant response before its tool_result arrives; resetting
        // here would recreate text/tool cards under fresh transport IDs.
        run.messageUsage = { ...event.message?.usage };
        run.messageModel = event.message?.model || run.actualModel;
        this.usage(run, run.messageId, run.messageUsage, run.messageModel);
      }
      if (event.type === "message_delta" && event.usage && run.messageId) {
        run.messageUsage = { ...run.messageUsage, ...event.usage };
        this.usage(run, run.messageId, run.messageUsage, run.messageModel);
      }
      const index = Number.isSafeInteger(event.index) && event.index >= 0 ? event.index : 0;
      if (event.type === "content_block_delta" && event.delta?.type === "text_delta") {
        // Keep the first item ID for this content index. A retried
        // message_start must not create a second visible assistant card.
        const id = run.streamedByIndex.get(index) || ("assistant-" + (run.streamMessageKey || run.messageId || run.turn.id) + "-" + index);
        run.streamedByIndex.set(index, id);
        const incoming = String(event.delta.text || "");
        const seen = run.streamDeltaHistoryByIndex.get(index) || new Set();
        run.streamDeltaHistoryByIndex.set(index, seen);
        let delta = incoming;
        if (run.streamReplayByIndex.get(index)) {
          const item = run.turn.items.find(value => value.id === id && value.type === "agentMessage");
          const reconciled = streamDeltaSuffix(item?.text || "", incoming, seen);
          // Keep replay mode while a chunk overlaps already emitted text;
          // leave it once an unrelated continuation arrives.
          if (reconciled === incoming && !seen.has(incoming)) run.streamReplayByIndex.delete(index);
          delta = reconciled;
        }
        if (incoming) seen.add(incoming);
        if (delta) {
          run.streamed.add(id);
          this.appendText(run, id, delta);
        }
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
      const nextAssistantBlocks = [];
      // The CLI snapshots each content block of one message separately, and a
      // replayed snapshot may drop or reorder a leading thinking block. The
      // text then arrives under a different index than the deltas used, so an
      // index lookup alone would show the same answer twice. Match the text
      // against what this message already emitted before trusting the index.
      const messageKey = canReuseStreamItems ? (run.streamMessageKey || messageId) : messageId;
      const messagePrefix = "assistant-" + messageKey + "-";
      const emittedRunText = (block, index) => {
        const indexed = run.turn.items.find(
          item => item.id === run.streamedByIndex.get(index) && item.type === "agentMessage");
        if (block.type !== "text") return indexed || null;
        const finalText = String(block.text || "");
        const matches = item => item.type === "agentMessage" &&
          (item.text === finalText || (finalText && finalText.startsWith(item.text)));
        if (indexed && matches(indexed)) return indexed;
        for (let at = run.turn.items.length - 1; at >= 0; at -= 1) {
          const item = run.turn.items[at];
          if (item.id.startsWith(messagePrefix) && matches(item)) return item;
        }
        return null;
      };
      value.message.content.forEach((block, index) => {
        // Prefer the item already used by stream deltas when the message
        // identity is compatible; mismatched IDs represent a new response.
        const streamedId = canReuseStreamItems ? run.streamedByIndex.get(index) : null;
        const streamItem = emittedRunText(block, index);
        const finalText = block.type === "text" ? String(block.text || "") : "";
        // Reconcile a final snapshot with the item emitted by content_block
        // deltas even when the snapshot ID is missing or changed. If the
        // snapshot contains more text, emit only the unseen suffix.
        const streamPrefix = !!(streamItem && finalText && finalText.startsWith(streamItem.text));
        const id = streamItem
          ? streamItem.id
          : streamedId || "assistant-" + messageKey + "-" + index;
        const fingerprint = assistantBlockFingerprint(block);
        const previous = run.lastAssistantBlocks[index];
        const duplicateBlock = !!(fingerprint && previous?.fingerprint === fingerprint);
        if (block.type === "text") {
          if (streamPrefix) {
            const suffix = finalText.slice(streamItem.text.length);
            if (suffix) this.appendText(run, id, suffix);
          } else if (!duplicateBlock && !run.streamed.has(id) && !run.completedMessages.has(id)) {
            this.appendText(run, id, block.text);
          }
          run.completedMessages.add(id);
        } else if (block.type === "tool_use") {
          // Tool IDs are also unstable across assistant snapshots. Keep the
          // first card and let its later tool_result update that card.
          if (!duplicateBlock) {
            // A SendMessage naming an agent the bridge never saw start is not a
            // collaborator this app can open, so it stays an ordinary card.
            const plan = this.toolPlan(block);
            if (plan) this.item(run, block.id, plan.type, { ...plan.fields, status: "inProgress" });
            else if (toolKind(block.name).kind === "agentMessage") {
              if (!this.relay(run, block)) this.item(run, block.id, "mcpToolCall", { title: "发送消息", status: "inProgress" });
            } else this.delegate(run, block);
            this.changed(run);
          } else if (previous?.id && block.id && previous.id !== block.id) {
            // A repeated snapshot may assign a new tool_use ID. Remember the
            // canonical first card so a result carrying the new ID still
            // completes the visible card instead of creating a second one.
            run.toolAliases.set(block.id, previous.id);
          }
        }
        if (fingerprint) {
          // For tool blocks the item ID is block.id, while text uses the
          // generated/stream item ID. Keeping the canonical ID here makes the
          // alias above point at the actual persisted tool card.
          nextAssistantBlocks[index] = { fingerprint, id: block.type === "tool_use" ? block.id : id };
        }
      });
      run.lastAssistantBlocks = nextAssistantBlocks;
    } else if (value.type === "user" && Array.isArray(value.message?.content)) {
      for (const block of value.message.content) if (block.type === "tool_result") {
        const canonicalToolId = run.toolAliases.get(block.tool_use_id) || block.tool_use_id;
        const child = this.children(run).get(canonicalToolId);
        if (child) {
          // The delegation is over; its closing report is not shown on the
          // parent page, only the child's terminal status.
          const alias = resultAgentId(toolResultText(block));
          if (alias) { child.agentId = alias; this.bindChildName(run, child, alias); }
          child.settle(block.is_error ? "failed" : "completed");
          if (this.childThreads.get(child.id) === child) this.childThreads.delete(child.id);
          try { this.store.saveTurn(child.thread, child.turn); this.store.save(child.thread); } catch (_) {}
          this.activity(run, child, block.is_error ? "interrupted" : "completed", block.is_error ? "interrupted" : "completed");
          continue;
        }
        const item = run.turn.items.find(item => item.id === canonicalToolId);
        if (item) {
          if (item.type === "fileChange" || item.type === "commandExecution") {
            // These cards read `output`/`changes` and would show a stray `result`.
            if (item.type === "commandExecution") {
              const output = toolResultText(block);
              item.output = boundedJsonText(output, Math.max(0, Math.min(MAX_TEXT, MAX_TURN - OUTPUT_RESERVE - jsonBytes(run.turn) - 32)));
            }
          } else {
            delete item.result;
            item.result = boundedJsonText(typeof block.content === "string" ? block.content : JSON.stringify(block.content || ""), Math.max(0, Math.min(MAX_TEXT, MAX_TURN - OUTPUT_RESERVE - jsonBytes(run.turn) - 32)));
          }
          item.status = block.is_error ? "failed" : "completed";
          this.notify("item/completed", { threadId: run.thread.id, turnId: run.turn.id, item: clone(item) });
          this.changed(run);
        }
      }
      // A tool result starts the next assistant response. The same text or
      // command after that result is a legitimate new block, not a snapshot.
      run.lastAssistantBlocks = [];
      run.streamedByIndex.clear();
      run.streamReplayByIndex.clear();
      run.streamDeltaHistoryByIndex.clear();
      run.toolAliases.clear();
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
  children(run) {
    run.children ??= new Map();
    return run.children;
  }
  // A SendMessage names its target, which is either a teammate name or the
  // `agentId` returned by the spawn. Both are pinned to the child here so the
  // row can be attributed without the App knowing anything about the address.
  childNames(run) {
    run.childNames ??= new Map();
    return run.childNames;
  }
  bindChildName(run, child, alias) {
    const key = String(alias || "").trim().toLowerCase();
    if (key) this.childNames(run).set(key, child);
  }
  // The parent transcript keeps one row per delegation: the child starts, then
  // reports back. Blocks from inside the child never reach the parent page.
  delegate(run, block) {
    const children = this.children(run);
    if (children.has(block.id)) return;
    if (children.size >= 16) return;
    const child = new ChildAgent({ run, store: this.store }, block.input || {});
    children.set(block.id, child);
    if (!this.childThreads.has(child.id)) this.childThreads.set(child.id, child);
    // The parent addresses a teammate by the type it spawned — the only address
    // the CLI exposes while the delegation runs — or by the `agentId` in the
    // closing report. The display label is deliberately not an address: two
    // delegations can share one, and it would shadow a real teammate.
    for (const alias of [child.type, child.agentId]) this.bindChildName(run, child, alias);
    this.activity(run, child, "started", "inProgress");
    this.changed(run);
  }
  // "已向 X 发送消息" — the same row Codex renders when the parent writes to a
  // collaborator it already started. The row is keyed by the tool_use id so it
  // keeps its place in the transcript and stays openable.
  relay(run, block) {
    const input = block.input || {};
    const target = String(input.to ?? "").trim();
    const child = this.childNames(run).get(target.toLowerCase());
    if (!child) return false;
    const summary = readString(input, "summary").trim() || readString(input, "message").split(/\r?\n/, 1)[0].trim();
    const item = this.item(run, block.id, "subAgentActivity", {
      kind: "sendInput",
      agentPath: child.agentPath,
      agentThreadId: child.id,
      message: bounded(summary, 400),
      status: "inProgress",
    });
    this.notify("item/completed", { threadId: run.thread.id, turnId: run.turn.id, item: clone(item) });
    this.changed(run);
    return true;
  }
  // One row per lifecycle change, so the parent page reads as
  // "开始工作 → 已完成" for each delegated conversation.
  activity(run, child, kind, status) {
    const item = this.item(run, `agent:${child.id}:${kind}`, "subAgentActivity", {
      kind,
      agentPath: child.agentPath,
      agentThreadId: child.id,
      message: child.summary,
      status,
    });
    item.status = status;
    this.notify("item/completed", { threadId: run.thread.id, turnId: run.turn.id, item: clone(item) });
    this.changed(run);
  }
  childAnswer(child, value) {
    const { parent: run, turn } = child;
    if (turn.status !== "inProgress") return;
    const messageId = typeof value.message?.id === "string" && value.message.id
      ? value.message.id
      : `${turn.id}-${turn.items.length}`;
    for (const [index, block] of value.message.content.entries()) {
      const id = "child-" + messageId + "-" + index;
      if (block.type === "text") {
        const text = String(block.text || "");
        // The child's transcript shows the finished block, not deltas, so a
        // repeated snapshot is resolved against the text already stored.
        const stored = turn.items.find(entry => entry.id === id && entry.type === "agentMessage");
        if (stored) { if (text.startsWith(stored.text)) stored.text = text; }
        else if (text) child.text(id, text);
      } else if (block.type === "tool_use") {
        this.noteToolUse(child, block);
      } else if (block.type === "tool_result") {
        this.childToolResult(child, block);
      }
    }
    // A child's tokens are deliberately kept out of the parent's totals: the
    // context ring must keep measuring the conversation the user is reading.
    this.changed(run);
  }
  // A child's edits and commands are stored on the child conversation so the
  // delegated page shows the same kind of cards as the parent.
  noteToolUse(child, block) {
    const plan = this.toolPlan(block);
    if (plan) child.item(plan.type, block.id, { ...plan.fields, status: "inProgress" });
  }
  childToolResult(child, block) {
    const item = child.turn.items.find(entry => entry.id === block.tool_use_id);
    if (!item) return;
    if (item.type === "commandExecution") item.output = bounded(toolResultText(block), 64 * 1024);
    else if (item.type === "mcpToolCall") item.result = boundedJsonText(toolResultText(block) || JSON.stringify(block.content || ""), 16000);
    item.status = block.is_error ? "failed" : "completed";
  }
  // Maps a native tool call onto the App's shared card contract. Returns null
  // for delegations, which the parent and child handle differently.
  toolPlan(block) {
    const input = block.input || {};
    const kind = toolKind(block.name);
    // Delegation and messaging are decided by the caller, which knows whether
    // the named collaborator exists in this run.
    if (kind.kind === "agent" || kind.kind === "agentMessage") return null;
    if (kind.kind === "command") {
      return { type: "commandExecution", fields: { command: bounded(readString(input, "command"), 4000), cwd: readString(input, "cwd") } };
    }
    if (kind.kind === "file") {
      const change = fileChanges(block.name, input);
      return change ? { type: "fileChange", fields: { changes: [change] } } : null;
    }
    if (kind.kind === "search") {
      return { type: "webSearch", fields: { query: bounded(readString(input, "query"), 4000), status: "inProgress" } };
    }
    const title = kind.kind === "mcp" ? `${kind.server} · ${kind.tool}` : kind.title;
    return {
      type: "mcpToolCall",
      fields: {
        server: kind.kind === "mcp" ? kind.server : "Claude Code",
        tool: bounded(title, 200),
        arguments: boundedJsonText(JSON.stringify(input), 16000),
      },
    };
  }
  start(thread, prepared, params, requestId, options = {}) {
    if (!options.compact && params.sandboxPolicy?.type === "readOnly") throw new Error("Claude Code 暂不支持应用内只读沙箱，请使用 Claude Code 权限审批模式");
    if (this.active.has(thread.id)) throw new Error("Claude Code 会话仍在处理中");
    if (this.active.size >= 8) throw new Error("同时运行的 Claude Code 会话过多");
    const unlock = this.store.lock(thread.id);
    let run;
    try {
      thread = this.store.get(thread.id);
      if (!String(thread.name || "").trim()) thread.name = this.store.inferName(thread);
      if (thread.turnIds.length >= 10000) throw new Error("会话回合数量已达上限，请新建会话");
      const turn = options.turn || { id: uuid(), status: "inProgress", startedAt: Date.now(), items: [{ id: uuid(), type: "userMessage", content: prepared.display }] };
      if (jsonBytes(turn) > MAX_TURN - OUTPUT_RESERVE) throw new Error("文本附件过大");
      const args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--include-partial-messages", "--permission-mode", "default", "--permission-prompt-tool", "stdio"];
      if (thread.claudeSessionId) args.push("--resume", thread.claudeSessionId);
      else args.push("--session-id", thread.id);
      const configuration = settings.readSettings();
      const model = modelArgument(params.model ?? thread.model ?? configuration.model);
      // The native catalog only knows the models this bridge ships with, but a
      // user-defined or proxied alias can accept the same flag. The vocabulary
      // is the only check; whether a model honors --effort is the CLI's call.
      const effort = params.effort ?? configuration.reasoningEffort;
      if (effort && !EFFORTS.includes(effort)) throw new Error("Claude Code 不支持此思考强度");
      if (model) args.push("--model", model);
      if (effort) args.push("--effort", effort);
      const environment = settings.launchEnvironment();
      // Claude Code resolves a sub-agent's model from per-agent frontmatter
      // (Explore and friends default to a small model). This variable is read
      // first, ahead of any frontmatter, so it is the only reliable pin. An
      // empty choice means 跟随主模型; the literal "inherit" is the CLI's own
      // spelling for that and resolves to the main loop's model. A blank server
      // value counts as unset so a cleared setting cannot pin a stale model.
      // `launchEnvironment()` already folds in settings.json, whose env holds
      // the settings-page default. That default is only a fallback: a choice
      // made for this conversation must be able to override it, so the per-turn
      // value is read first and never compared against the inherited env.
      const chosenSubagentModel = modelArgument(params.subagentModel ?? thread.subagentModel);
      const inheritedSubagentModel = environment.CLAUDE_CODE_SUBAGENT_MODEL;
      environment.CLAUDE_CODE_SUBAGENT_MODEL = chosenSubagentModel ||
        (inheritedSubagentModel == null || inheritedSubagentModel === ""
          ? modelArgument(configuration.subagentModel) || model || "inherit"
          : inheritedSubagentModel);
      if (effort) {
        environment.CLAUDE_CODE_EFFORT_LEVEL = effort;
        args.push("--settings", JSON.stringify({ effortLevel: effort, env: { CLAUDE_CODE_EFFORT_LEVEL: effort } }));
      }
      const previousUsage = thread.tokenUsage;
      const previousModel = thread.usageModel;
      if (model !== thread.model) thread.tokenUsage = null;
      thread.model = model;
      thread.effort = effort || null;
      if (!thread.turnIds.includes(turn.id)) thread.turnIds.push(turn.id);
      thread.activeTurnId = turn.id; thread.updatedAt = Date.now(); thread.status = "active";
      if (!options.compact) {
        const previewText = prepared.display.filter(item => item.type === "text").map(item => item.text).join("\n");
        thread.preview = bounded(previewText, 1000) || "图片附件";
        // A conversation title is assigned once, from its first prompt. Keep
        // the mutable preview separate so list refreshes cannot rename it.
        if (!String(thread.name || "").trim()) thread.name = initialThreadName(previewText);
      }
      this.store.saveTurn(thread, turn); this.store.save(thread);
      const child = cp.spawn(this.claudeBin, args, { cwd: thread.cwd, env: environment, stdio: ["pipe", "pipe", "pipe"] });
    run = { thread, turn, child, unlock, content: prepared.content, streamed: new Set(), streamedByIndex: new Map(), streamReplayByIndex: new Map(), streamDeltaHistoryByIndex: new Map(), messageSequence: 0, streamMessageKey: null, streamMessageIdProvided: false, completedMessages: new Set(), lastAssistantBlocks: [], toolAliases: new Map(), truncated: new Set(), children: new Map(), exiting: false, compactionId: options.compactionId || uuid(), compactionDone: false, compactOnly: !!options.compact, boundaryDone: false, boundaryTimer: null, boundaryResolve: null, boundaryReject: null, settlePass: null, fullAccess: params.approvalPolicy === "never" && params.sandboxPolicy?.type === "dangerFullAccess", initializeId: uuid(), usageByMessage: new Map(), baseUsage: { ...ZERO_USAGE, ...previousUsage?.total }, usageModel: previousModel, contextWindow: model === previousModel ? tokenCount(previousUsage?.modelContextWindow) : 0 };
      this.active.set(thread.id, run);
      // A compaction pass answers its own request once the boundary is in, so it
      // must not resolve the request with a turn the caller never sees.
      if (!options.compact) this.response(requestId, { turn: { id: turn.id, status: "inProgress" } });
      this.notify("turn/started", { threadId: thread.id, turn: { id: turn.id, status: "inProgress" } });
      this.notify("item/completed", { threadId: thread.id, turnId: turn.id, item: turn.items[0] });
      jsonLines(child.stdout, value => this.message(run, value), error => this.fail(run, error.message));
      child.stderr.on("data", () => {}); // Never forward raw credential-bearing CLI diagnostics.
      child.stdin.on("error", () => this.fail(run, "Claude Code 输入通道已关闭"));
      child.on("error", () => this.fail(run, "无法启动 Claude Code，请检查服务器上的安装与登录"));
      child.on("close", code => {
        clearTimeout(run.initTimer); clearTimeout(run.saveTimer); clearTimeout(run.killTimer); clearTimeout(run.exitTimer); clearTimeout(run.boundaryTimer);
        // A compaction pass that exits without reporting a boundary must still
        // release its awaiting request instead of leaving it to time out, and
        // one that did report its boundary has already done its work: the exit
        // only ends the pass, it does not decide whether it succeeded.
        if (run.boundaryReject && !run.boundaryDone) run.boundaryReject(`Claude Code 未完成压缩便退出 (${code ?? "signal"})，请检查登录与服务配置`);
        else if (run.turn.status === "inProgress") this.finish(run, run.compactOnly ? "completed" : "failed", run.compactOnly ? null : `Claude Code 未完成响应便退出 (${code ?? "signal"})，请检查登录与服务配置`);
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
    // The caller has to be able to hand a compaction pass its own boundary hooks.
    return run;
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
        // Delegated conversations belong to their parent page, not to the
        // conversation list the user browses.
        const threads = params.archived ? [] : this.store.list().filter(thread => thread.cwd === this.directory && !thread.parentThreadId && (!search || [thread.name, thread.preview].some(value => String(value || "").toLowerCase().includes(search)))).sort((a, b) => b.updatedAt - a.updatedAt || a.id.localeCompare(b.id));
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
      if (method === "thread/compact/start") return this.response(id, await this.compact(thread, params, id));
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
    this.childThreads.clear();
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

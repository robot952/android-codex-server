// This IIFE is prepended to the installed, single-file Claude bridge. It is also
// a CommonJS module so the exact production implementation can be tested alone.
globalThis.__claudeRemoteSettings = (() => {
  "use strict";
  const fs = require("node:fs");
  const path = require("node:path");
  const os = require("node:os");
  const crypto = require("node:crypto");
  const cp = require("node:child_process");
  const MAX_CONFIG = 1024 * 1024;
  const MAX_RESPONSE = 2 * 1024 * 1024;
  const PROXY_KEYS = ["HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY", "https_proxy", "http_proxy", "all_proxy"];
  const own = (value, key) => Object.prototype.hasOwnProperty.call(value, key);
  const object = value => value && typeof value === "object" && !Array.isArray(value);
  function text(value, maximum = 4096) {
    if (value == null) return "";
    if (typeof value !== "string" || value.length > maximum || /[\x00-\x1f\x7f]/.test(value)) {
      throw new Error("Claude Code 配置字段格式无效");
    }
    return value.trim();
  }
  function location() {
    const directory = text(process.env.CLAUDE_CONFIG_DIR) || path.join(os.homedir(), ".claude");
    return { directory: path.resolve(directory), file: path.resolve(directory, "settings.json") };
  }
  function load() {
    const { directory, file } = location();
    let raw = null;
    try {
      const stat = fs.lstatSync(file);
      if (!stat.isFile() || stat.isSymbolicLink() || stat.size > MAX_CONFIG) {
        throw new Error("Claude Code 配置文件类型或大小无效");
      }
      raw = fs.readFileSync(file, "utf8");
    } catch (error) {
      if (error.code !== "ENOENT") throw new Error("无法安全读取 Claude Code 配置文件");
    }
    let data = {};
    if (raw != null) {
      try { data = JSON.parse(raw); } catch (_) { throw new Error("Claude Code settings.json 不是有效 JSON，请先修复文件"); }
      if (!object(data) || (data.env != null && !object(data.env))) {
        throw new Error("Claude Code settings.json 结构无效，请先修复文件");
      }
    }
    return { directory, file, raw, data };
  }
  function environment(data) {
    const result = { ...process.env };
    for (const [key, value] of Object.entries(data.env || {})) {
      if (typeof value === "string" && !key.includes("\0") && !value.includes("\0")) result[key] = value;
    }
    return result;
  }
  function launchEnvironment() { return environment(load().data); }
  function proxyFrom(env) {
    for (const key of PROXY_KEYS) if (own(env, key)) return text(env[key]);
    return "";
  }
  function readSettings() {
    const { data, directory } = load();
    const env = environment(data);
    const apiKey = text(env.ANTHROPIC_AUTH_TOKEN || env.ANTHROPIC_API_KEY, 16384);
    const model = text(env.ANTHROPIC_MODEL || data.model);
    const reasoningEffort = text(env.CLAUDE_CODE_EFFORT_LEVEL || data.effortLevel, 32);
    const contextLimit = env.CLAUDE_CODE_MAX_CONTEXT_TOKENS;
    const contextWindowTokens = typeof contextLimit === "string" && /^[1-9]\d{0,8}$/.test(contextLimit) &&
      Number(contextLimit) <= 100000000 ? Number(contextLimit) : 0;
    return {
      baseUrl: text(env.ANTHROPIC_BASE_URL) || "https://api.anthropic.com",
      model, reasoningEffort, contextWindowTokens, modelProvider: "anthropic", apiKey,
      proxyUrl: proxyFrom(env),
      hasStoredAuthentication: !!apiKey || !!data.apiKeyHelper || fs.existsSync(path.join(directory, ".credentials.json")),
    };
  }
  function url(value, kind) {
    const input = text(value);
    if (!input) return "";
    let parsed;
    try { parsed = new URL(input); } catch (_) { throw new Error(`${kind}需要完整的 HTTP/HTTPS 地址`); }
    if (!["http:", "https:"].includes(parsed.protocol) || !parsed.hostname || parsed.search || parsed.hash ||
        (kind !== "代理" && (parsed.username || parsed.password))) {
      throw new Error(`${kind}地址格式无效`);
    }
    return input.replace(/\/+$/, "");
  }
  function model(value) {
    const result = text(value, 256);
    if (result && !/^[A-Za-z0-9][A-Za-z0-9._:/\[\]-]*$/.test(result)) throw new Error("模型 ID 格式无效");
    return result;
  }
  function effort(value) {
    const result = text(value, 32).toLowerCase();
    if (result && !["low", "medium", "high", "xhigh", "max"].includes(result)) throw new Error("Claude Code 思考强度无效");
    return result;
  }
  function processStartTicks(pid) {
    try {
      const stat = fs.readFileSync(`/proc/${pid}/stat`, "utf8");
      const fields = stat.slice(stat.lastIndexOf(")") + 1).trim().split(/\s+/);
      return /^\d+$/.test(fields[19] || "") ? fields[19] : null;
    } catch (error) {
      if (error.code === "ENOENT" || error.code === "ESRCH") return null;
      throw error;
    }
  }
  function lockIdentity() {
    const bootId = fs.readFileSync("/proc/sys/kernel/random/boot_id", "utf8").trim();
    const startTicks = processStartTicks(process.pid);
    if (!/^[0-9a-f-]{36}$/.test(bootId) || !startTicks) throw new Error("无法确认配置写入进程身份");
    return { pid: process.pid, bootId, startTicks };
  }
  function staleLockOwner(owner) {
    if (!object(owner) || !Number.isSafeInteger(owner.pid) || owner.pid <= 0 ||
        !/^[0-9a-f-]{36}$/.test(owner.bootId || "") || !/^\d+$/.test(owner.startTicks || "")) return null;
    if (owner.bootId !== fs.readFileSync("/proc/sys/kernel/random/boot_id", "utf8").trim()) return true;
    const currentStart = processStartTicks(owner.pid);
    return currentStart == null || currentStart !== owner.startTicks;
  }
  function clearStaleLock(lock) {
    let stat;
    try { stat = fs.lstatSync(lock); } catch (error) { if (error.code === "ENOENT") return true; throw error; }
    if (!stat.isDirectory() || stat.isSymbolicLink()) return false;
    const entries = fs.readdirSync(lock);
    if (entries.length === 0) {
      // An empty lock has no owner identity. Only a previous-boot directory is provably stale.
      const uptime = Number(fs.readFileSync("/proc/uptime", "utf8").split(" ")[0]);
      const bootTime = Date.now() - uptime * 1000;
      if (!Number.isFinite(bootTime) || Math.max(stat.mtimeMs, stat.ctimeMs) >= bootTime - 5000) {
        throw new Error("Claude Code 无身份的配置锁无法确认写入者；确认没有其他客户端写入后，删除配置目录中的 .codex-remote-settings.lock");
      }
    } else {
      if (entries.length !== 1 || !/^owner-[0-9a-f-]{36}$/.test(entries[0])) return false;
      const ownerFile = path.join(lock, entries[0]);
      let owner;
      try {
        const ownerStat = fs.lstatSync(ownerFile);
        if (!ownerStat.isFile() || ownerStat.isSymbolicLink() || ownerStat.size > 512) return false;
        owner = JSON.parse(fs.readFileSync(ownerFile, "utf8"));
      } catch (error) { if (error.code === "ENOENT") return true; return false; }
      if (staleLockOwner(owner) !== true) return false;
      // The owner filename is unique. A competing reaper cannot unlink a new owner's file.
      try { fs.unlinkSync(ownerFile); } catch (error) { if (error.code !== "ENOENT") throw error; }
    }
    try { fs.rmdirSync(lock); } catch (error) {
      if (error.code !== "ENOENT" && error.code !== "ENOTEMPTY" && error.code !== "EEXIST") throw error;
    }
    return true;
  }
  function acquireSettingsLock(directory) {
    const lock = path.join(directory, ".codex-remote-settings.lock");
    const nonce = crypto.randomUUID();
    const candidate = path.join(directory, `.codex-remote-lock-${nonce}.tmp`);
    const ownerName = `owner-${nonce}`;
    try {
      fs.mkdirSync(candidate, { mode: 0o700 });
      fs.writeFileSync(path.join(candidate, ownerName), JSON.stringify(lockIdentity()), { flag: "wx", mode: 0o600 });
      for (let attempt = 0; attempt < 4; attempt++) {
        if (fs.existsSync(lock) && !clearStaleLock(lock)) break;
        try {
          fs.renameSync(candidate, lock);
          return { lock, ownerName };
        } catch (error) {
          if (error.code !== "EEXIST" && error.code !== "ENOTEMPTY") throw error;
        }
      }
      throw new Error("Claude Code 配置正在写入，请稍后重试");
    } finally {
      try { fs.rmSync(candidate, { recursive: true, force: true }); } catch (_) {}
    }
  }
  function releaseSettingsLock(held) {
    if (!held) return;
    try { fs.unlinkSync(path.join(held.lock, held.ownerName)); } catch (_) {}
    try { fs.rmdirSync(held.lock); } catch (_) {}
  }
  function writeSettings(params = {}) {
    // Validate before creating directories or touching the native file.
    const baseUrl = url(params.baseUrl, "API") || "https://api.anthropic.com";
    const proxyUrl = url(params.proxyUrl, "代理");
    const apiKey = text(params.apiKey, 16384);
    const defaultModel = model(params.defaultModel);
    const defaultEffort = effort(params.defaultReasoningEffort);
    const initial = load();
    try {
      if (fs.existsSync(initial.directory) && fs.lstatSync(initial.directory).isSymbolicLink()) throw new Error();
      fs.mkdirSync(initial.directory, { recursive: true, mode: 0o700 });
    } catch (_) { throw new Error("无法安全访问 Claude Code 配置目录"); }
    let heldLock;
    let temporary;
    try {
      heldLock = acquireSettingsLock(initial.directory);
      const current = load();
      const data = current.data;
      const env = { ...(data.env || {}) };
      const effective = environment(data);
      env.ANTHROPIC_BASE_URL = baseUrl;
      if (apiKey) {
        // Preserve the server's auth-header convention. Blank means unchanged;
        // neither OAuth files nor Claude's login session are ever modified.
        if (effective.ANTHROPIC_AUTH_TOKEN) {
          env.ANTHROPIC_AUTH_TOKEN = apiKey;
        } else {
          env.ANTHROPIC_API_KEY = apiKey;
        }
      }
      env.ANTHROPIC_MODEL = defaultModel;
      if (defaultModel) data.model = defaultModel; else delete data.model;
      env.CLAUDE_CODE_EFFORT_LEVEL = defaultEffort;
      if (defaultEffort) data.effortLevel = defaultEffort; else delete data.effortLevel;
      // Explicit empty overrides inherited proxies for App-launched CLI too.
      for (const key of PROXY_KEYS) env[key] = proxyUrl;
      data.env = env;
      const encoded = JSON.stringify(data, null, 2) + "\n";
      if (Buffer.byteLength(encoded) > MAX_CONFIG) throw new Error("Claude Code 配置超过大小限制");
      temporary = path.join(current.directory, `.settings-${crypto.randomUUID()}.tmp`);
      const fd = fs.openSync(temporary, fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_WRONLY, 0o600);
      try { fs.writeFileSync(fd, encoded); fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
      if (load().raw !== current.raw) throw new Error("Claude Code 配置已被其他程序修改，请重新读取后保存");
      fs.renameSync(temporary, current.file);
      temporary = undefined;
      return { modelProvider: "anthropic" };
    } catch (error) {
      if (error.code) throw new Error("写入 Claude Code 配置失败，原配置已保留");
      throw error;
    } finally {
      if (temporary) { try { fs.unlinkSync(temporary); } catch (_) {} }
      releaseSettingsLock(heldLock);
    }
  }
  function requestConfig(params) {
    const { data } = load();
    const env = environment(data);
    const token = text(env.ANTHROPIC_AUTH_TOKEN, 16384);
    const stored = token || text(env.ANTHROPIC_API_KEY, 16384);
    const apiKey = text(params.apiKey, 16384) || stored;
    if (!apiKey) throw new Error("未找到 API Key；CLI 登录状态可继续使用，对 API 测试请填写 Key");
    return {
      baseUrl: url(params.baseUrl == null ? env.ANTHROPIC_BASE_URL : params.baseUrl, "API") || "https://api.anthropic.com",
      proxyUrl: url(params.proxyUrl == null ? proxyFrom(env) : params.proxyUrl, "代理"),
      apiKey, token: !!token,
    };
  }
  function endpoint(baseUrl, route) {
    return `${baseUrl}${/\/v1$/.test(new URL(baseUrl).pathname) ? "" : "/v1"}/${route}`;
  }
  function curlString(value) { return `"${value.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`; }
  async function request(config, route, payload) {
    const args = ["--disable", "--config", "-"];
    const env = { ...process.env };
    for (const key of [...PROXY_KEYS, "NO_PROXY", "no_proxy"]) delete env[key];
    // All URLs, credentials and request bodies travel through stdin, never argv.
    const lines = ["silent", "show-error", "connect-timeout = 10", "max-time = 35", "max-filesize = 2097152",
      `url = ${curlString(endpoint(config.baseUrl, route))}`,
      `header = ${curlString(config.token ? `Authorization: Bearer ${config.apiKey}` : `x-api-key: ${config.apiKey}`)}`,
      'header = "anthropic-version: 2023-06-01"', 'header = "content-type: application/json"',
      'write-out = "\\n%{http_code}"', `proxy = ${curlString(config.proxyUrl)}`];
    if (payload) lines.push(`data = ${curlString(JSON.stringify(payload))}`);
    return await new Promise((resolve, reject) => {
      const child = cp.spawn("curl", args, { env, stdio: ["pipe", "pipe", "pipe"] });
      let bytes = 0, body = "", settled = false;
      const finish = (error, result) => {
        if (settled) return;
        settled = true; clearTimeout(timer);
        error ? reject(error) : resolve(result);
      };
      const timer = setTimeout(() => { child.kill("SIGKILL"); finish(new Error("API 请求超时")); }, 40000);
      child.stdout.setEncoding("utf8");
      child.stdout.on("data", chunk => {
        bytes += Buffer.byteLength(chunk);
        if (bytes > MAX_RESPONSE + 1024) { child.kill("SIGKILL"); finish(new Error("API 响应超过大小限制")); }
        else body += chunk;
      });
      child.stderr.resume(); // Never echo curl diagnostics: they can contain URLs or credentials.
      child.stdin.on("error", () => {});
      child.on("error", () => finish(new Error("无法启动 curl，请在服务器安装 curl")));
      child.on("close", code => {
        if (code !== 0) {
          const messages = { 5: "代理解析失败", 6: "API 域名解析失败", 7: "API 连接失败", 28: "API 请求超时", 35: "API TLS 连接失败", 60: "API TLS 证书校验失败", 63: "API 响应超过大小限制" };
          finish(new Error(messages[code] || "API 请求失败")); return;
        }
        const split = body.lastIndexOf("\n");
        const status = Number(body.slice(split + 1));
        if (status < 200 || status >= 300) {
          finish(new Error(status === 401 || status === 403 ? "API 鉴权失败，请检查 Key 和模型权限" : `API 返回 HTTP ${status}`)); return;
        }
        try { finish(null, JSON.parse(body.slice(0, split))); }
        catch (_) { finish(new Error("API 未返回有效 JSON")); }
      });
      child.stdin.end(lines.join("\n") + "\n");
    });
  }
  async function testSettings(params = {}) {
    try {
      const config = requestConfig(params);
      const selected = model(params.testModel);
      if (!selected) throw new Error("请选择测试模型");
      const result = await request(config, "messages", { model: selected, max_tokens: 32, messages: [{ role: "user", content: "Reply with OK only." }] });
      if (result?.type !== "message" || result.role !== "assistant" || !Array.isArray(result.content) ||
          !result.content.some(item => item?.type === "text" && typeof item.text === "string" && item.text.trim()) ||
          !["end_turn", "max_tokens", "stop_sequence"].includes(result.stop_reason)) {
        throw new Error("API 未返回完整的模型回复");
      }
      return { successful: true, message: "Anthropic Messages API 连接成功" };
    } catch (error) { return { successful: false, message: error.message }; }
  }
  async function listApiModels(params = {}) {
    const result = await request(requestConfig(params), "models");
    const source = result?.data || result?.models;
    if (!Array.isArray(source)) throw new Error("API 未返回有效模型列表，可手动输入模型 ID");
    const seen = new Set();
    const values = [];
    for (const item of source.slice(0, 2000)) {
      if (!object(item)) continue;
      let id;
      try { id = model(item.id || item.modelId); } catch (_) { continue; }
      if (!id || seen.has(id)) continue;
      seen.add(id);
      const positive = value => Number.isSafeInteger(value) && value > 0 && value <= 100000000 ? value : 0;
      values.push({ modelId: id, displayName: typeof item.display_name === "string" ? item.display_name.slice(0, 256) : id,
        contextWindowTokens: positive(item.context_window || item.contextWindowTokens),
        maxOutputTokens: positive(item.max_output_tokens || item.maxOutputTokens) });
    }
    return values;
  }
  return { readSettings, writeSettings, testSettings, listApiModels, launchEnvironment };
})();
if (typeof module !== "undefined") module.exports = globalThis.__claudeRemoteSettings;

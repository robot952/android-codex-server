"use strict";

// Runs on the SSH host, alongside Codex. Never uses the phone's receive clock.
// Native OTLP timestamps identify upstream request boundaries; native JSONL
// timestamps identify the first nonempty model text/reasoning delta. Tool time,
// warm-up requests, replayed history and unknown timings are not substituted.
const COUNT_KEYS = ["inputTokens", "outputTokens", "cachedInputTokens", "reasoningOutputTokens", "totalTokens"];
const DELTAS = new Set(["item/agentMessage/delta", "item/reasoning/textDelta", "item/reasoning/summaryTextDelta"]);
function integer(value) {
  return Number.isSafeInteger(value) && value >= 0 ? value : null;
}
function identifier(value) {
  return typeof value === "string" && value.length > 0 && value.length <= 256 && !/[\s\x00-\x1f]|:\/\/|[?&#]/.test(value) ? value : null;
}
function counts(value) {
  if (!value || typeof value !== "object") return null;
  const result = {};
  for (const key of COUNT_KEYS) {
    const number = integer(value[key]);
    if (number === null) return null;
    result[key] = number;
  }
  return result;
}
function sameCounts(a, b) { return COUNT_KEYS.every(key => a[key] === b[key]); }
function boundedPush(list, value, limit) {
  list.push(value);
  if (list.length > limit) list.splice(0, list.length - limit);
}

class RequestMetricsCollector {
  constructor(emit) {
    this.emit = emit;
    this.threads = new Map();
  }

  thread(id) {
    if (!identifier(id)) return null;
    let state = this.threads.get(id);
    if (!state) state = { events: [], points: [], usages: [] };
    this.threads.delete(id);
    this.threads.set(id, state);
    while (this.threads.size > 128) this.threads.delete(this.threads.keys().next().value);
    return state;
  }

  notification(message) {
    const params = message && message.params;
    const time = integer(message && message.emittedAtMs);
    // Old runtimes without emission timestamps remain usable, but cannot
    // acquire a trustworthy TTFT by timing buffered stdout on reconnect.
    if (!params || !time || !identifier(params.turnId)) return;
    if (message.method !== "thread/tokenUsage/updated" && !DELTAS.has(message.method)) return;
    const state = this.thread(params.threadId);
    if (!state) return;
    if (DELTAS.has(message.method)) {
      if (typeof params.delta !== "string" || !params.delta.trim() || !identifier(params.itemId)) return;
      if (!state.points.some(point => point.turn === params.turnId && point.item === params.itemId)) {
        boundedPush(state.points, { time, turn: params.turnId, item: params.itemId }, 512);
      }
    } else {
      if (params.requestMetrics?.historical || params.requestMetrics?.requestId) return;
      const last = counts(params.tokenUsage?.last);
      const total = counts(params.tokenUsage?.total);
      if (!last || !total) return;
      const key = JSON.stringify([params.turnId, total]);
      if (!state.usages.some(usage => usage.key === key)) {
        boundedPush(state.usages, { key, time, turn: params.turnId, last, total, sent: "" }, 128);
      }
    }
    this.reconcile(params.threadId, state);
  }

  telemetry(payload) {
    const changed = new Set();
    for (const resource of payload?.resourceLogs || []) {
      for (const scope of resource.scopeLogs || []) {
        for (const record of scope.logRecords || []) {
          const attributes = {};
          // Never retain or forward prompts, commands, results, credentials,
          // URLs, identities, or arbitrary OTLP bodies/attributes.
          const allowed = new Set(["event.name", "event.timestamp", "conversation.id", "model", "duration_ms",
            "endpoint", "http.response.status_code", "success", "event.kind", "input_token_count",
            "output_token_count", "cached_token_count", "reasoning_token_count", "tool_token_count"]);
          for (const attribute of record.attributes || []) {
            if (allowed.has(attribute.key)) attributes[attribute.key] = attribute.value?.stringValue ?? attribute.value?.intValue ?? attribute.value?.boolValue;
          }
          const name = attributes["event.name"];
          const time = Date.parse(attributes["event.timestamp"]);
          const threadId = identifier(attributes["conversation.id"]);
          if (!threadId || !integer(time)) continue;
          let event;
          if (name === "codex.api_request" || name === "codex.websocket_request") {
            const duration = integer(Number(attributes.duration_ms));
            const http = name === "codex.api_request";
            const success = http
              ? Number(attributes["http.response.status_code"]) >= 200 && Number(attributes["http.response.status_code"]) < 300 && attributes.endpoint === "/responses"
              : attributes.success === true || attributes.success === "true";
            if (!success || duration === null || duration > 86400000 || duration > time) continue;
            event = { kind: "start", time, start: time - duration, model: identifier(attributes.model) };
          } else if (name === "codex.sse_event" && attributes["event.kind"] === "response.completed") {
            const usage = counts({
              inputTokens: Number(attributes.input_token_count), outputTokens: Number(attributes.output_token_count),
              cachedInputTokens: Number(attributes.cached_token_count), reasoningOutputTokens: Number(attributes.reasoning_token_count),
              totalTokens: Number(attributes.tool_token_count),
            });
            if (!usage) continue;
            event = { kind: "end", time, usage };
          } else continue;
          const state = this.thread(threadId);
          const key = JSON.stringify(event);
          if (!state.events.some(existing => existing.key === key)) boundedPush(state.events, { ...event, key }, 256);
          changed.add(threadId);
        }
      }
    }
    for (const threadId of changed) this.reconcile(threadId, this.threads.get(threadId));
  }

  reconcile(threadId, state) {
    if (!state) return;
    let start;
    const spans = [];
    for (const event of state.events.slice().sort((a, b) => a.time - b.time)) {
      if (event.kind === "start") start = event;
      else if (start) {
        if (event.time >= start.start && event.time - start.start <= 86400000) {
          spans.push({ start: start.start, end: event.time, model: start.model, usage: event.usage });
        }
        start = null;
      }
    }
    const matched = new Set();
    for (const usage of state.usages.slice().sort((a, b) => a.time - b.time)) {
      // A complete response precedes its native usage notification. Select the
      // nearest matching completion, not a prefetch/warm-up with equal counts.
      const span = spans.filter(value => !matched.has(value) && sameCounts(value.usage, usage.last) &&
        usage.time >= value.end && usage.time - value.end <= 2000).at(-1);
      if (!span) continue;
      matched.add(span);
      const first = state.points.filter(point => point.turn === usage.turn && point.time >= span.start && point.time <= usage.time)
        .sort((a, b) => a.time - b.time)[0];
      const firstTokenMillis = first && first.time <= span.end ? first.time - span.start : null;
      const metrics = { source: "server", startedAtMillis: span.start, firstTokenMillis,
        durationMillis: span.end - span.start, model: span.model };
      const signature = JSON.stringify(metrics);
      if (usage.sent === signature) continue;
      usage.sent = signature;
      // A distinct notification must NOT roll back the live context ring or
      // replay an old message. Keep the original cumulative identity to merge.
      this.emit({ method: "thread/requestMetrics/updated", params: { threadId, turnId: usage.turn,
        tokenUsage: { last: usage.last, total: usage.total }, requestMetrics: metrics } });
    }
  }
}

// Inspect complete lines without changing original stdout bytes. Oversized
// lines still pass through; only optional metrics inspection is skipped.
function lineObserver(consume, limit = 8 * 1024 * 1024) {
  let buffer = "";
  let skipping = false;
  return chunk => {
    for (const piece of chunk.split(/(?<=\n)/)) {
      if (!skipping) {
        buffer += piece;
        if (buffer.length > limit) { buffer = ""; skipping = true; }
      }
      if (piece.endsWith("\n")) {
        if (!skipping) { try { consume(JSON.parse(buffer)); } catch (_) { /* Optional metrics must not break JSONL. */ } }
        buffer = ""; skipping = false;
      }
    }
  };
}

function hasExistingTelemetry(env, cwd) {
  const fs = require("node:fs");
  const path = require("node:path");
  if (Object.keys(env).some(key => key.startsWith("OTEL_EXPORTER_"))) return true;
  const files = new Set([path.join(env.CODEX_HOME || path.join(env.HOME || "", ".codex"), "config.toml"),
    "/etc/codex/config.toml"]);
  for (let directory = path.resolve(cwd); ; directory = path.dirname(directory)) {
    files.add(path.join(directory, ".codex/config.toml"));
    if (directory === path.dirname(directory)) break;
  }
  for (const file of files) {
    try {
      if (fs.statSync(file).size > 4 * 1024 * 1024 || /\botel\b/.test(fs.readFileSync(file, "utf8"))) return true;
    } catch (error) {
      if (error.code !== "ENOENT" && error.code !== "ENOTDIR") return true;
    }
  }
  return false;
}

async function runRelay(command) {
  const http = require("node:http");
  const { randomBytes } = require("node:crypto");
  const { spawn } = require("node:child_process");
  const { StringDecoder } = require("node:string_decoder");
  if (typeof command !== "string" || !command.trim()) throw new Error("Missing Codex command");
  const token = randomBytes(24).toString("hex");
  let child;
  const write = value => {
    if (!process.stdout.write(value)) child?.stdout.pause();
  };
  let inLine = false;
  const queued = [];
  const collector = new RequestMetricsCollector(message => {
    const line = JSON.stringify(message) + "\n";
    if (inLine) boundedPush(queued, line, 256);
    else write(line);
  });
  const server = http.createServer(async (req, res) => {
    if (req.method !== "POST" || req.url !== "/v1/logs" || req.headers["x-codex-metrics-token"] !== token) {
      res.writeHead(404).end(); req.resume(); return;
    }
    let size = 0;
    const chunks = [];
    try {
      for await (const chunk of req) {
        size += chunk.length;
        if (size > 4 * 1024 * 1024) { res.writeHead(413).end(); req.resume(); return; }
        chunks.push(chunk);
      }
      collector.telemetry(JSON.parse(Buffer.concat(chunks).toString("utf8")));
      res.writeHead(200, { "content-type": "application/json" }).end("{}");
    } catch (_) { if (!res.headersSent) res.writeHead(400).end(); }
  });
  server.requestTimeout = 5000;
  server.headersTimeout = 5000;
  let telemetryArguments = "";
  try {
    if (hasExistingTelemetry(process.env, process.cwd())) throw new Error("Keep the user's telemetry exporter");
    await new Promise((resolve, reject) => { server.once("error", reject); server.listen(0, "127.0.0.1", resolve); });
    // CLI-only overrides: never edit provider URLs, auth, or config.toml.
    const exporter = `otel.exporter={otlp-http={endpoint="http://127.0.0.1:${server.address().port}/v1/logs",protocol="json",headers={"x-codex-metrics-token"="${token}"}}}`;
    telemetryArguments = `-c '${exporter}' -c otel.log_user_prompt=false `;
  } catch (_) { server.close(); /* Metrics unavailable: launch normal Codex. */ }
  // Keep overrides in the SAME (root) argument scope. Adding -c after the
  // app-server subcommand makes some Codex versions discard earlier -c values.
  const launch = command.replace(/(^|\s)(["']?)app-server\2(?=\s|$)/,
    (_, space, quote) => `${space}${telemetryArguments}${quote}app-server${quote}`);
  const env = { ...process.env };
  if (telemetryArguments) {
    env.OTEL_BLRP_SCHEDULE_DELAY = "1000";
    // The local exporter must never send its payload through an HTTP proxy.
    env.NO_PROXY = [env.NO_PROXY, env.no_proxy, "127.0.0.1", "localhost"].filter(Boolean).join(",");
    env.no_proxy = env.NO_PROXY;
  }
  child = spawn("/bin/sh", ["-c", `exec ${launch}`], {
    stdio: ["pipe", "pipe", "inherit"], env,
  });
  const decoder = new StringDecoder("utf8");
  const observe = lineObserver(message => collector.notification(message));
  child.stdout.on("data", chunk => {
    // Forward before inspection; an enriched notification is always a separate
    // complete JSONL record, even if a native line spans multiple pipe chunks.
    write(chunk);
    inLine = chunk[chunk.length - 1] !== 10;
    observe(decoder.write(chunk));
    if (!inLine) while (queued.length) write(queued.shift());
  });
  process.stdout.on("drain", () => child.stdout.resume());
  process.stdin.pipe(child.stdin);
  child.stdin.on("error", () => {});
  let stopping = false;
  let killTimer;
  const stop = () => {
    if (stopping) return;
    stopping = true;
    child.kill("SIGTERM");
    killTimer = setTimeout(() => child.kill("SIGKILL"), 2000);
    killTimer.unref();
  };
  process.stdin.on("end", stop);
  process.stdout.on("error", stop);
  for (const signal of ["SIGTERM", "SIGINT", "SIGHUP"]) process.on(signal, stop);
  child.on("error", stop);
  child.once("close", code => {
    clearTimeout(killTimer);
    process.stdin.unpipe(child.stdin);
    process.stdin.pause();
    server.closeAllConnections(); server.close();
    process.exitCode = code ?? 1;
  });
}

module.exports = { RequestMetricsCollector, lineObserver, runRelay };
if (require.main === module) runRelay(process.argv[2]).catch(() => { process.exitCode = 1; });

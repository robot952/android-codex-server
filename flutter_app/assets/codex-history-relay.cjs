"use strict";

// Native Codex owns persistence and writer locks. The mobile history endpoints
// below only project read results; they never rewrite the model's history.
function createHistoryRpcBridge({ send, output, proxy, timeoutMs = 3000 }) {
  const prefix = `codex-history-${require("node:crypto").randomBytes(16).toString("hex")}-`;
  const pending = new Map();
  const configReads = new Map();
  let sequence = 0;
  let closed = false;
  let inputEnded = false;
  let inputWork = Promise.resolve();
  let initializeId;
  const countRequests = new Map();

  function countThreads(params) {
    const searchTerm = typeof params.searchTerm === "string" ? params.searchTerm.trim() : "";
    const modelProviders = Array.isArray(params.modelProviders)
      ? params.modelProviders.filter(value => typeof value === "string") : undefined;
    const key = JSON.stringify([searchTerm, modelProviders]);
    if (countRequests.has(key)) return countRequests.get(key);
    const request = (async () => {
      const ids = new Set();
      const cursors = new Set();
      const started = Date.now();
      let cursor;
      for (let pageNumber = 0; pageNumber < 500 && Date.now() - started < 25000; pageNumber++) {
        const page = await internalRequest("thread/list", {
          limit: 200, archived: false, sortKey: "recency_at", sortDirection: "desc",
          useStateDbOnly: true,
          ...(searchTerm ? { searchTerm } : {}),
          ...(modelProviders?.length ? { modelProviders } : {}),
          ...(cursor ? { cursor } : {}),
        });
        if (!Array.isArray(page.data)) throw historyError("Invalid thread count page");
        for (const thread of page.data) {
          if (typeof thread?.id !== "string" || !thread.id) throw historyError("Invalid thread identity");
          ids.add(thread.id);
        }
        cursor = page.nextCursor;
        if (!cursor) return { totalCount: ids.size };
        if (typeof cursor !== "string" || cursors.has(cursor)) throw historyError("Invalid thread count cursor");
        cursors.add(cursor);
      }
      throw historyError("Thread count temporarily unavailable");
    })().finally(() => countRequests.delete(key));
    countRequests.set(key, request);
    return request;
  }

  function internalRequest(method, params, { configured = false, history = false } = {}) {
    if (closed) return Promise.reject(new Error("Compatibility relay closed"));
    return new Promise((resolve, reject) => {
      const id = prefix + (++sequence);
      const timer = setTimeout(() => {
        pending.delete(id);
        reject(new Error("Compatibility configuration unavailable"));
      }, history ? 120000 : timeoutMs);
      timer.unref?.();
      pending.set(id, { resolve, reject, timer, history });
      try {
        const line = Buffer.from(JSON.stringify({ id, method, params }) + "\n");
        if (configured) void handleInput(line).catch(reject);
        else send(line);
      }
      catch (error) {
        pending.delete(id);
        clearTimeout(timer);
        reject(error);
      }
    });
  }

  const cursorPrefix = "mobile-items-v1:";
  const itemLimit = 20;
  const itemBytes = 4096;
  function historyError(message, code = -32602) {
    return Object.assign(new Error(message), { rpcError: { code, message } });
  }
  function decodeCursor(cursor, threadId) {
    if (cursor == null) return undefined;
    try {
      if (typeof cursor !== "string" || !cursor.startsWith(cursorPrefix) || cursor.length > 32768) throw 0;
      const value = JSON.parse(Buffer.from(cursor.slice(cursorPrefix.length), "base64url"));
      if (value.threadId !== threadId || typeof value.cursor !== "string") throw 0;
      return value.cursor;
    } catch (_) { throw historyError("Invalid mobile history cursor"); }
  }
  function projectItem(item) {
    if (!item || typeof item.id !== "string" || item.id.length > 256) {
      throw historyError("Invalid history item identity");
    }
    // Commands are folded on first paint. Other small items retain their
    // original shape, including all collaboration status/identity fields.
    if (item.type !== "commandExecution" && Buffer.byteLength(JSON.stringify(item)) <= itemBytes) return item;
    if (item.type === "commandExecution") return {
      type: item.type, id: item.id, status: item.status,
      codexRemoteDetailsItemId: item.id,
    };
    const titles = {
      userMessage: "用户消息", agentMessage: "回复", reasoning: "思考过程",
      fileChange: `已编辑 ${Array.isArray(item.changes) ? item.changes.length : ""} 个文件`,
      collabAgentToolCall: "子代理活动", plan: "计划",
    };
    return {
      type: "codexRemoteDeferred", id: item.id, status: String(item.status || "").slice(0, 64),
      title: titles[item.type] || "工具详情", codexRemoteDetailsItemId: item.id,
      previewKind: item.type === "agentMessage" || item.type === "userMessage" ? item.type : "tool",
      text: typeof item.text === "string" ? item.text.slice(0, 500) : "",
    };
  }
  async function itemPage(threadId, cursor, latestTurn) {
    let page;
    for (const limit of [itemLimit, 4, 1]) {
      try {
        page = await internalRequest("thread/items/list", {
          threadId, limit, sortDirection: "desc",
          ...(cursor == null ? {} : { cursor: decodeCursor(cursor, threadId) }),
        }, { history: true });
        break;
      } catch (error) {
        if (error.rpcError?.code !== -32096 || limit === 1) throw error;
      }
    }
    if (!Array.isArray(page.data) || page.data.length > itemLimit) throw historyError("Invalid history page");
    const turns = new Map();
    for (const record of page.data) {
      if (typeof record.turnId !== "string" || record.turnId.length > 256) throw historyError("Invalid history turn identity");
      if (!turns.has(record.turnId)) turns.set(record.turnId, {
        ...(latestTurn?.id === record.turnId ? latestTurn : { id: record.turnId, status: "completed" }), items: [],
      });
      turns.get(record.turnId).items.unshift(projectItem(record.item));
    }
    // An active turn can have no items yet. Keep its status without counting it
    // as a visible history record or changing the item continuation cursor.
    if (latestTurn && !turns.has(latestTurn.id)) turns.set(latestTurn.id, { ...latestTurn, items: [] });
    const data = [...turns.values()];
    if (latestTurn && data.at(-1)?.id === latestTurn.id && data.length > 1) data.unshift(data.pop());
    const nextCursor = page.nextCursor == null ? null : cursorPrefix + Buffer.from(JSON.stringify({ threadId, cursor: page.nextCursor })).toString("base64url");
    const result = { data, nextCursor };
    if (Buffer.byteLength(JSON.stringify(result)) > 96 * 1024) throw historyError("History page exceeds mobile budget");
    return result;
  }
  async function mobileHistory(message) {
    const params = message.params || {};
    const threadId = params.threadId;
    if (typeof threadId !== "string" || !threadId || threadId.length > 256) throw historyError("Invalid thread id");
    if (message.method === "codexRemote/history/page") return itemPage(threadId, params.cursor);
    if (message.method === "codexRemote/history/item") {
      const { turnId, itemId } = params;
      if (typeof turnId !== "string" || !turnId || turnId.length > 256 || typeof itemId !== "string" || !itemId || itemId.length > 256) throw historyError("Invalid item identity");
      // Anchor after the predecessor, not its backwardsCursor (which may be
      // inclusive). Verify the item ID before returning any details.
      const previous = await internalRequest("thread/items/list", {
        threadId, turnId, cursor: { type: "item", itemId }, limit: 1, sortDirection: "desc",
      }, { history: true });
      if (!Array.isArray(previous.data)) throw historyError("Invalid item boundary");
      const page = await internalRequest("thread/items/list", {
        threadId, turnId, limit: 1, sortDirection: "asc",
        ...(previous.data.length ? { cursor: { type: "item", itemId: previous.data[0].item.id } } : {}),
      }, { history: true });
      const record = page.data?.[0];
      if (record?.item?.id !== itemId || record.turnId !== turnId) throw historyError("History item changed; reopen the conversation", -32000);
      // Match the existing mobile command-output display limit on the server,
      // before a single large command can exceed the phone's RPC line limit.
      // This is a read projection only; native persisted output is untouched.
      let item = record.item;
      if (item.type === "commandExecution") {
        item = { ...item };
        const marker = "\n[输出过长，仅显示前 512 KiB 字符；完整输出仍保存在服务器]";
        for (const key of ["aggregatedOutput", "output"]) {
          if (typeof item[key] === "string" && item[key].length > 512 * 1024) {
            item[key] = item[key].slice(0, 512 * 1024 - marker.length) + marker;
          }
        }
      }
      const result = { data: [{ id: turnId, items: [item] }] };
      if (Buffer.byteLength(JSON.stringify(result)) > 7 * 1024 * 1024) {
        throw historyError("History item is too large to display on mobile", -32096);
      }
      return result;
    }
    let metadata;
    let latestTurn;
    if (params.readOnly === true) {
      metadata = await internalRequest("thread/read", { threadId, includeTurns: false }, { history: true });
      try {
        const turns = await internalRequest("thread/turns/list", { threadId, limit: 1, sortDirection: "desc", itemsView: "notLoaded" }, { history: true });
        latestTurn = turns.data?.[0];
      } catch (error) {
        if (error.rpcError?.code === -32600 && error.rpcError.message.includes("is unavailable before first user message")) {
          return { thread: metadata.thread, initialTurnsPage: { data: [], nextCursor: null } };
        }
        throw error;
      }
    } else {
      metadata = await internalRequest("thread/resume", {
        threadId, excludeTurns: true, approvalPolicy: params.approvalPolicy,
        ...(params.config ? { config: params.config } : {}),
        initialTurnsPage: { limit: 1, sortDirection: "desc", itemsView: "notLoaded" },
      }, { configured: true, history: true });
      latestTurn = metadata.initialTurnsPage?.data?.[0];
    }
    if (!metadata.thread || metadata.thread.id !== threadId) throw historyError("Invalid thread metadata");
    const initialTurnsPage = await itemPage(threadId, null, latestTurn);
    const result = { ...metadata, thread: { ...metadata.thread, turns: [],
      // Only these turn IDs can affect the inherited-child filter for this page.
      turnIds: metadata.thread.turnIds?.filter(id => initialTurnsPage.data.some(turn => turn.id === id)),
    }, initialTurnsPage };
    if (Buffer.byteLength(JSON.stringify(result)) > 128 * 1024) throw historyError("History metadata exceeds mobile budget");
    return result;
  }

  function readConfig(cwd) {
    const key = typeof cwd === "string" ? cwd : "";
    if (!configReads.has(key)) {
      const read = internalRequest("config/read", {
        includeLayers: false, ...(key ? { cwd: key } : {}),
      }).then((result) => result.config || {}).finally(() => configReads.delete(key));
      configReads.set(key, read);
    }
    return configReads.get(key);
  }

  // RPC override keys use TOML key syntax, including quoted provider/header
  // names containing dots. Never reinterpret an unsupported key then delete it.
  function configKeyPath(key) {
    const path = [];
    let position = 0;
    while (position < key.length) {
      while (/[ \t]/.test(key[position] || "") && position < key.length) position++;
      const quote = key[position];
      let part = "";
      if (quote === '"' || quote === "'") {
        position++;
        let ended = false;
        while (position < key.length) {
          const char = key[position++];
          if (char === quote) { ended = true; break; }
          if (char === "\n" || char === "\r" || char.charCodeAt(0) < 32) return null;
          if (quote === '"' && char === "\\") {
            const escaped = key[position++];
            const escapes = { b: "\b", t: "\t", n: "\n", f: "\f", r: "\r", '"': '"', "\\": "\\" };
            if (Object.hasOwn(escapes, escaped)) part += escapes[escaped];
            else if (escaped === "u" || escaped === "U") {
              const size = escaped === "u" ? 4 : 8;
              const hex = key.slice(position, position + size);
              if (hex.length !== size || !/^[0-9a-f]+$/i.test(hex)) return null;
              const point = parseInt(hex, 16);
              if (point > 0x10ffff || (point >= 0xd800 && point <= 0xdfff)) return null;
              part += String.fromCodePoint(point);
              position += size;
            } else return null;
          } else part += char;
        }
        if (!ended) return null;
      } else {
        const match = /^[A-Za-z0-9_-]+/.exec(key.slice(position));
        if (!match) return null;
        part = match[0];
        position += part.length;
      }
      path.push(part);
      while (/[ \t]/.test(key[position] || "") && position < key.length) position++;
      if (position === key.length) return path;
      if (key[position++] !== "." || position === key.length) return null;
    }
    return null;
  }

  function withConfigValue(base, path, value) {
    if (!path.length) return value;
    if (base != null && (typeof base !== "object" || Array.isArray(base))) return null;
    const [key, ...rest] = path;
    const next = rest.length ? withConfigValue(Object.hasOwn(base || {}, key) ? base[key] : undefined, rest, value) : value;
    if (rest.length && next === null) return null;
    const result = { ...base };
    // defineProperty also preserves literal keys such as __proto__ safely.
    Object.defineProperty(result, key, { value: next, enumerable: true, configurable: true, writable: true });
    return result;
  }

  function mergeConfig(base, overrides) {
    const result = { ...base, ...overrides };
    const mergedKeys = [];
    if (overrides.model_providers && typeof overrides.model_providers === "object" && !Array.isArray(overrides.model_providers)) {
      result.model_providers = { ...base.model_providers };
      for (const [id, provider] of Object.entries(overrides.model_providers)) {
        Object.defineProperty(result.model_providers, id, {
          value: { ...base.model_providers?.[id], ...provider },
          enumerable: true, configurable: true, writable: true,
        });
      }
    }
    for (const [key, value] of Object.entries(overrides)) {
      if (key === "model_providers") continue;
      const path = configKeyPath(key);
      if (!path || path[0] !== "model_providers" || path.length < 2) continue;
      const providers = withConfigValue(result.model_providers, path.slice(1), value);
      if (providers === null) continue;
      result.model_providers = providers;
      mergedKeys.push(key);
    }
    return { config: result, mergedKeys };
  }

  async function handleInput(line) {
    if (closed) return;
    let message;
    try { message = JSON.parse(line.toString("utf8")); }
    catch (_) { send(line); return; }
    if (!message) { send(line); return; }
    if (message.method === "initialize") initializeId = message.id;
    if (message.method === "codexRemote/threads/count") {
      void countThreads(message.params || {}).then(
        result => { if (!closed) output(Buffer.from(JSON.stringify({ id: message.id, result }) + "\n")); },
        () => { if (!closed) output(Buffer.from(JSON.stringify({ id: message.id,
          error: { code: -32000, message: "Thread count unavailable" } }) + "\n")); },
      );
      return;
    }
    if (["codexRemote/history/open", "codexRemote/history/page", "codexRemote/history/item"].includes(message.method)) {
      // Do not block inputWork: interrupt/approval requests must remain usable
      // while a large native history page is being read.
      void mobileHistory(message).then(
        result => { if (!closed) output(Buffer.from(JSON.stringify({ id: message.id, result }) + "\n")); },
        error => { if (!closed) output(Buffer.from(JSON.stringify({ id: message.id,
          error: error.rpcError || { code: -32000, message: "Mobile history unavailable" } }) + "\n")); },
      );
      return;
    }
    if (!proxy) { send(line); return; }
    if (message.method === "initialized") {
      send(line);
      // Start after initialization, never before the native protocol is ready.
      readConfig().catch(() => {});
      return;
    }
    if (!["thread/start", "thread/resume"].includes(message.method)) {
      send(line);
      return;
    }
    try {
      const params = message.params || {};
      let cwd = params.cwd;
      if (!cwd && message.method === "thread/resume" && params.threadId) {
        const metadata = await internalRequest("thread/read", {
          threadId: params.threadId, includeTurns: false,
        });
        cwd = metadata.thread?.cwd;
      }
      const effective = mergeConfig(await readConfig(cwd), params.config || {});
      const overrides = providerConfigOverrides(effective.config, proxy);
      if (Object.keys(overrides).length) {
        const config = { ...params.config, ...overrides };
        // Remove only provider keys superseded by the complete mapped table.
        // Leaving both dotted and table forms makes native precedence ambiguous.
        if (overrides.model_providers) {
          for (const key of effective.mergedKeys) delete config[key];
        }
        if (!closed) send(Buffer.from(JSON.stringify({
          ...message, params: { ...params, config },
        }) + "\n"));
        return;
      }
    } catch (_) {
      // Never include config values, credentials, history, or native errors.
      if (!closed) process.stderr.write("Codex history compatibility configuration unavailable\n");
    }
    if (!closed) send(line);
  }

  function handleOutput(line) {
    let message;
    try { message = JSON.parse(line.toString("utf8")); }
    catch (_) { output(line); return; }
    if (initializeId != null && message?.id === initializeId && message.result) {
      initializeId = undefined;
      output(Buffer.from(JSON.stringify({ ...message, result: { ...message.result,
        codexRemoteHistoryVersion: 1, codexRemoteThreadListVersion: 1 } }) + "\n"));
      return;
    }
    if (message && typeof message.id === "string" && message.id.startsWith(prefix)) {
      const request = pending.get(message.id);
      if (request) {
        pending.delete(message.id);
        clearTimeout(request.timer);
        if (message.error) request.reject(Object.assign(new Error("Native request failed"), { rpcError: message.error }));
        else request.resolve(message.result || {});
      }
      // Also consume timed-out internal responses. config/read can contain keys.
      return;
    }
    output(line);
  }

  function lineReader(onLine, passthrough, limit, overflowFactory) {
    let chunks = [];
    let length = 0;
    let oversized = false;
    let overflow;
    function consume(part, complete) {
      if (oversized) {
        if (overflow) overflow.write(part); else passthrough(part);
        if (complete) { overflow?.end(); overflow = null; oversized = false; }
        return;
      }
      chunks.push(part);
      length += part.length;
      if (length > limit) {
        overflow = overflowFactory?.();
        for (const chunk of chunks) {
          if (overflow) overflow.write(chunk); else passthrough(chunk);
        }
        chunks = [];
        length = 0;
        oversized = !complete;
        if (complete) { overflow?.end(); overflow = null; }
      } else if (complete) {
        const line = Buffer.concat(chunks, length);
        chunks = [];
        length = 0;
        onLine(line);
      }
    }
    return {
      write(value) {
        const chunk = Buffer.isBuffer(value) ? value : Buffer.from(value);
        let offset = 0;
        let newline;
        while ((newline = chunk.indexOf(10, offset)) !== -1) {
          consume(chunk.subarray(offset, newline + 1), true);
          offset = newline + 1;
        }
        if (offset < chunk.length) consume(chunk.subarray(offset), false);
      },
      end() {
        overflow?.end();
        overflow = null;
        oversized = false;
        if (length) onLine(Buffer.concat(chunks, length));
        chunks = [];
        length = 0;
      },
    };
  }

  function oversizedOutput() {
    const fs = require("node:fs");
    let fd;
    let size = 0;
    let failed = false;
    let depth = 0;
    let inString = false;
    let escaped = false;
    let expectKey = false;
    let expectValue = false;
    let key;
    let capture;
    let token = [];
    let tokenTruncated = false;
    let internalId;
    let directory;
    let file;
    try {
      directory = fs.mkdtempSync(require("node:path").join(require("node:os").tmpdir(), "codex-rpc-"));
      fs.chmodSync(directory, 0o700);
      file = require("node:path").join(directory, "output");
      fd = fs.openSync(file, "wx+", 0o600);
      // The temporary payload has no pathname while it is being buffered.
      fs.unlinkSync(file);
      file = null;
      fs.rmdirSync(directory);
      directory = null;
    } catch (_) {
      if (fd != null) fs.closeSync(fd);
      fd = null;
      failed = true;
      process.stderr.write("Codex history compatibility output unavailable\n");
    } finally {
      // Setup can fail after creating either resource. Retry cleanup without
      // allowing filesystem errors or pathnames into the protocol/logs.
      if (file) { try { fs.unlinkSync(file); } catch (_) {} }
      if (directory) { try { fs.rmdirSync(directory); } catch (_) {} }
    }
    function scan(chunk) {
      for (const byte of chunk) {
        if (inString) {
          if (capture) {
            if (token.length < 4096) token.push(byte);
            else tokenTruncated = true;
          }
          if (escaped) { escaped = false; continue; }
          if (byte === 92) { escaped = true; continue; }
          if (byte !== 34) continue;
          inString = false;
          if (capture) {
            let value;
            try { value = JSON.parse(Buffer.from(token).toString("utf8")); } catch (_) {}
            if (capture === "id" && tokenTruncated) {
              // Internal IDs are short, but a late/malformed reply must not
              // bypass filtering by appending an arbitrarily long ID suffix.
              // Trim only an incomplete JSON escape at the bounded prefix.
              const partial = Buffer.from(token).toString("utf8");
              for (let end = partial.length; end >= Math.max(1, partial.length - 12); end--) {
                try { value = JSON.parse(partial.slice(0, end) + '"'); break; } catch (_) {}
              }
            }
            if (capture === "key") { key = value; expectKey = false; }
            else if (typeof value === "string" && value.startsWith(prefix)) internalId = value;
          }
          capture = null;
          token = [];
          tokenTruncated = false;
          continue;
        }
        if (byte === 34) {
          inString = true;
          capture = depth === 1 && expectKey ? "key" : depth === 1 && expectValue && key === "id" ? "id" : null;
          token = capture ? [34] : [];
          tokenTruncated = false;
          expectValue = false;
        } else if (byte === 123 || byte === 91) {
          depth++;
          if (depth === 1 && byte === 123) expectKey = true;
        } else if (byte === 125 || byte === 93) depth--;
        else if (depth === 1 && byte === 44) { expectKey = true; expectValue = false; key = undefined; }
        else if (depth === 1 && byte === 58) { expectKey = false; expectValue = true; }
      }
    }
    return {
      write(chunk) {
        scan(chunk);
        if (failed) return;
        try {
          let offset = 0;
          while (offset < chunk.length) offset += fs.writeSync(fd, chunk, offset, chunk.length - offset);
          size += chunk.length;
        } catch (_) {
          failed = true;
          if (fd != null) { fs.closeSync(fd); fd = null; }
          process.stderr.write("Codex history compatibility output unavailable\n");
        }
      },
      end() {
        try {
          if (internalId) {
            const request = pending.get(internalId);
            if (request) {
              // Large item bodies stay on the server. The phone still receives
              // only the bounded projection; private config replies never take
              // this path. Cap temporary parse memory and retry smaller pages.
              if (request.history && !failed && size <= 64 * 1024 * 1024) {
                pending.delete(internalId);
                clearTimeout(request.timer);
                try {
                  const bytes = Buffer.allocUnsafe(size);
                  let offset = 0;
                  while (offset < size) {
                    const count = fs.readSync(fd, bytes, offset, size - offset, offset);
                    if (!count) throw new Error("Incomplete history spool");
                    offset += count;
                  }
                  const message = JSON.parse(bytes);
                  if (message.id !== internalId) throw 0;
                  if (message.error) request.reject(Object.assign(new Error("Native request failed"), { rpcError: message.error }));
                  else request.resolve(message.result || {});
                } catch (_) { request.reject(historyError("Invalid history response", -32096)); }
                return;
              }
              pending.delete(internalId);
              clearTimeout(request.timer);
              request.reject(request.history ? historyError("History item exceeds relay limit", -32096) : new Error("Compatibility configuration unavailable"));
            }
          } else if (!failed) {
            // Do not release any bytes until the top-level id is known, even
            // when the native serializer places it after a very large result.
            for (let offset = 0; offset < size;) {
              const chunk = Buffer.allocUnsafe(Math.min(64 * 1024, size - offset));
              const count = fs.readSync(fd, chunk, 0, chunk.length, offset);
              if (!count) break;
              output(chunk.subarray(0, count));
              offset += count;
            }
          }
        } finally {
          if (fd != null) { fs.closeSync(fd); fd = null; }
        }
      },
    };
  }

  function enqueue(line, inspect = true) {
    inputWork = inputWork.then(() => {
      if (!closed) return inspect ? handleInput(line) : send(line);
    }).catch(() => {
      if (!closed) process.stderr.write("Codex history compatibility input failed\n");
    });
  }
  const input = lineReader(enqueue, (chunk) => enqueue(chunk, false), 64 * 1024 * 1024);
  const nativeOutput = lineReader(handleOutput, output, 8 * 1024 * 1024, oversizedOutput);
  return {
    writeInput(chunk) { if (!closed && !inputEnded) input.write(chunk); },
    writeOutput(chunk) { nativeOutput.write(chunk); },
    endInput() {
      if (!inputEnded) { inputEnded = true; input.end(); }
      return inputWork;
    },
    close() {
      if (closed) return;
      closed = true;
      for (const request of pending.values()) {
        clearTimeout(request.timer);
        request.reject(new Error("Compatibility relay closed"));
      }
      pending.clear();
      nativeOutput.end();
    },
  };
}

Object.assign(module.exports, { createHistoryRpcBridge });

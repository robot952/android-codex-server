"use strict";

// Interpose only provider configuration RPCs. Native Codex remains responsible
// for persistence and thread ownership; history is repaired at the HTTP boundary.
function createHistoryRpcBridge({ send, output, proxy, timeoutMs = 3000 }) {
  const prefix = `codex-history-${require("node:crypto").randomBytes(16).toString("hex")}-`;
  const pending = new Map();
  const configReads = new Map();
  let sequence = 0;
  let closed = false;
  let inputEnded = false;
  let inputWork = Promise.resolve();

  function internalRequest(method, params) {
    if (closed) return Promise.reject(new Error("Compatibility relay closed"));
    return new Promise((resolve, reject) => {
      const id = prefix + (++sequence);
      const timer = setTimeout(() => {
        pending.delete(id);
        reject(new Error("Compatibility configuration unavailable"));
      }, timeoutMs);
      timer.unref?.();
      pending.set(id, { resolve, reject, timer });
      try { send(Buffer.from(JSON.stringify({ id, method, params }) + "\n")); }
      catch (error) {
        pending.delete(id);
        clearTimeout(timer);
        reject(error);
      }
    });
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
    if (!message || !proxy) { send(line); return; }
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
    if (message && typeof message.id === "string" && message.id.startsWith(prefix)) {
      const request = pending.get(message.id);
      if (request) {
        pending.delete(message.id);
        clearTimeout(request.timer);
        if (message.error) request.reject(new Error("Compatibility configuration unavailable"));
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
              pending.delete(internalId);
              clearTimeout(request.timer);
              request.reject(new Error("Compatibility configuration unavailable"));
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

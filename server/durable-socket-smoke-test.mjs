import { spawn } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import { existsSync } from "node:fs";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

const binary = process.env.CODEX_REMOTE_BIN || `${process.env.HOME}/.local/bin/codex-remote`;
const stateDirectory = await mkdtemp(join(tmpdir(), "codex-remote-durable-"));
const socket = join(stateDirectory, "app-server.sock");
const handshakeLimit = 16 * 1024;
const messageLimit = 8 * 1024 * 1024;
let server;
let serverStderr = "";
let serverError;

const delay = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));

async function waitFor(predicate, description, timeoutMs = 15_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return;
    await delay(50);
  }
  throw new Error(`Timed out waiting for ${description}. ${serverStderr}`);
}

function processGroupAlive(child) {
  if (!child?.pid) return false;
  try {
    process.kill(-child.pid, 0);
    return true;
  } catch (error) {
    if (error.code === "ESRCH") return false;
    throw error;
  }
}

async function stop(child) {
  if (!processGroupAlive(child)) return;
  process.kill(-child.pid, "SIGTERM");
  const deadline = Date.now() + 5_000;
  while (processGroupAlive(child) && Date.now() < deadline) {
    await delay(50);
  }
  if (processGroupAlive(child)) {
    process.kill(-child.pid, "SIGKILL");
    await waitFor(() => !processGroupAlive(child), "detached Codex process group", 5_000);
  }
}

function websocketAccept(key) {
  return createHash("sha1")
    .update(`${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`)
    .digest("base64");
}

function hasHeaderToken(value, token) {
  return value
    ?.split(",")
    .some((candidate) => candidate.trim().toLowerCase() === token) ?? false;
}

function validateHandshake(headerBytes, expectedAccept, label) {
  const lines = headerBytes.toString("latin1").split("\r\n");
  if (!/^HTTP\/1\.[01] 101(?: |$)/.test(lines[0])) {
    throw new Error(`${label} proxy rejected the WebSocket upgrade: ${lines[0] || "empty response"}`);
  }

  const headers = new Map();
  for (const line of lines.slice(1)) {
    if (!line) continue;
    const colon = line.indexOf(":");
    if (colon <= 0) throw new Error(`${label} proxy returned a malformed HTTP header`);
    const name = line.slice(0, colon).trim().toLowerCase();
    const value = line.slice(colon + 1).trim();
    headers.set(name, headers.has(name) ? `${headers.get(name)},${value}` : value);
  }

  if (headers.get("upgrade")?.toLowerCase() !== "websocket") {
    throw new Error(`${label} proxy response did not select WebSocket`);
  }
  if (!hasHeaderToken(headers.get("connection"), "upgrade")) {
    throw new Error(`${label} proxy response omitted Connection: Upgrade`);
  }
  if (headers.get("sec-websocket-accept") !== expectedAccept) {
    throw new Error(`${label} proxy returned an invalid Sec-WebSocket-Accept value`);
  }
}

function encodeClientFrame(opcode, payload) {
  const body = Buffer.isBuffer(payload) ? payload : Buffer.from(payload);
  if (body.length > messageLimit) throw new Error("Refusing to send an oversized WebSocket message");

  const mask = randomBytes(4);
  let header;
  if (body.length < 126) {
    header = Buffer.from([0x80 | opcode, 0x80 | body.length]);
  } else if (body.length <= 0xffff) {
    header = Buffer.alloc(4);
    header[0] = 0x80 | opcode;
    header[1] = 0x80 | 126;
    header.writeUInt16BE(body.length, 2);
  } else {
    header = Buffer.alloc(10);
    header[0] = 0x80 | opcode;
    header[1] = 0x80 | 127;
    header.writeBigUInt64BE(BigInt(body.length), 2);
  }

  const maskedBody = Buffer.allocUnsafe(body.length);
  for (let index = 0; index < body.length; index += 1) {
    maskedBody[index] = body[index] ^ mask[index % mask.length];
  }
  return Buffer.concat([header, mask, maskedBody]);
}

function sendFrame(stream, opcode, payload) {
  if (!stream.writable || stream.destroyed) throw new Error("WebSocket proxy stdin is closed");
  stream.write(encodeClientFrame(opcode, payload));
}

async function validateProxy(label) {
  const proxy = spawn(binary, ["app-server", "proxy", "--sock", socket], {
    stdio: ["pipe", "pipe", "pipe"],
    env: process.env,
    detached: true,
  });
  let stderr = "";

  try {
    await new Promise((resolve, reject) => {
      const key = randomBytes(16).toString("base64");
      const expectedAccept = websocketAccept(key);
      let buffer = Buffer.alloc(0);
      let handshakeComplete = false;
      let fragmentedText;
      let settled = false;
      const timeout = setTimeout(() => {
        fail(new Error(`${label} proxy timed out. ${stderr}${serverStderr}`));
      }, 15_000);

      const finish = (error) => {
        if (settled) return;
        settled = true;
        clearTimeout(timeout);
        if (error) reject(error);
        else resolve();
      };
      const fail = (error) => finish(error);

      const sendClose = () => {
        try {
          sendFrame(proxy.stdin, 0x8, Buffer.from([0x03, 0xe8]));
          proxy.stdin.end();
        } catch {
          // The process cleanup below closes the proxy if it has already stopped.
        }
      };
      const receiveText = (payload) => {
        let message;
        try {
          message = JSON.parse(payload.toString("utf8"));
        } catch (error) {
          fail(new Error(`${label} proxy returned invalid JSON-RPC text: ${error.message}`));
          return;
        }
        if (!message || typeof message !== "object" || Array.isArray(message)) {
          fail(new Error(`${label} proxy returned a non-object JSON-RPC message`));
          return;
        }
        if (message.id !== 1) return;
        if (message.error) {
          fail(new Error(`${label} proxy returned an initialize error: ${JSON.stringify(message.error)}`));
          return;
        }
        if (!("result" in message)) {
          fail(new Error(`${label} proxy returned an initialize response without a result`));
          return;
        }
        sendClose();
        finish();
      };
      const receiveFrame = (fin, opcode, payload) => {
        if (opcode === 0x8) {
          sendClose();
          fail(new Error(`${label} app-server closed the WebSocket before initialize completed`));
          return;
        }
        if (opcode === 0x9) {
          try {
            sendFrame(proxy.stdin, 0xa, payload);
          } catch (error) {
            fail(error);
          }
          return;
        }
        if (opcode === 0xa) return;
        if (opcode === 0x2) {
          fail(new Error(`${label} app-server returned an unsupported binary WebSocket frame`));
          return;
        }
        if (opcode === 0x0) {
          if (!fragmentedText) {
            fail(new Error(`${label} app-server returned an unexpected continuation frame`));
            return;
          }
          fragmentedText.parts.push(payload);
          fragmentedText.length += payload.length;
          if (fragmentedText.length > messageLimit) {
            fail(new Error(`${label} app-server returned an oversized WebSocket message`));
            return;
          }
          if (fin) {
            const complete = Buffer.concat(fragmentedText.parts, fragmentedText.length);
            fragmentedText = undefined;
            receiveText(complete);
          }
          return;
        }
        if (opcode !== 0x1) {
          fail(new Error(`${label} app-server returned an unsupported WebSocket opcode ${opcode}`));
          return;
        }
        if (fragmentedText) {
          fail(new Error(`${label} app-server started a new text message before finishing the previous one`));
          return;
        }
        if (fin) {
          receiveText(payload);
        } else {
          fragmentedText = { parts: [payload], length: payload.length };
        }
      };
      const parseFrames = () => {
        while (!settled && buffer.length >= 2) {
          const first = buffer[0];
          const second = buffer[1];
          const fin = (first & 0x80) !== 0;
          const rsv = first & 0x70;
          const opcode = first & 0x0f;
          const masked = (second & 0x80) !== 0;
          let payloadLength = second & 0x7f;
          let headerLength = 2;

          if (rsv !== 0) {
            fail(new Error(`${label} app-server returned a WebSocket frame with unsupported RSV bits`));
            return;
          }
          if (payloadLength === 126) {
            if (buffer.length < 4) return;
            payloadLength = buffer.readUInt16BE(2);
            headerLength = 4;
          } else if (payloadLength === 127) {
            if (buffer.length < 10) return;
            const extendedLength = buffer.readBigUInt64BE(2);
            if (extendedLength > BigInt(messageLimit)) {
              fail(new Error(`${label} app-server returned an oversized WebSocket message`));
              return;
            }
            payloadLength = Number(extendedLength);
            headerLength = 10;
          }
          if (payloadLength > messageLimit) {
            fail(new Error(`${label} app-server returned an oversized WebSocket message`));
            return;
          }
          if (masked) {
            fail(new Error(`${label} app-server incorrectly masked a server WebSocket frame`));
            return;
          }
          if (opcode >= 0x8 && (!fin || payloadLength > 125)) {
            fail(new Error(`${label} app-server returned an invalid control WebSocket frame`));
            return;
          }
          if (buffer.length < headerLength + payloadLength) return;

          const payload = buffer.subarray(headerLength, headerLength + payloadLength);
          buffer = buffer.subarray(headerLength + payloadLength);
          receiveFrame(fin, opcode, payload);
        }
      };

      proxy.stdout.on("data", (chunk) => {
        if (settled) return;
        buffer = Buffer.concat([buffer, chunk]);
        if (!handshakeComplete) {
          const headerEnd = buffer.indexOf("\r\n\r\n");
          if (headerEnd < 0) {
            if (buffer.length > handshakeLimit) {
              fail(new Error(`${label} proxy exceeded the WebSocket handshake header limit`));
            }
            return;
          }
          const headerLength = headerEnd + 4;
          if (headerLength > handshakeLimit) {
            fail(new Error(`${label} proxy exceeded the WebSocket handshake header limit`));
            return;
          }
          try {
            validateHandshake(buffer.subarray(0, headerLength), expectedAccept, label);
            buffer = buffer.subarray(headerLength);
            handshakeComplete = true;
            sendFrame(proxy.stdin, 0x1, JSON.stringify({
              method: "initialize",
              id: 1,
              params: {
                clientInfo: {
                  name: "codex_remote_android_durable_smoke_test",
                  title: "Codex Remote Android durable socket smoke test",
                  version: "1.0.0",
                },
              },
            }));
          } catch (error) {
            fail(error);
            return;
          }
        }
        parseFrames();
      });
      proxy.stderr.on("data", (chunk) => {
        stderr += chunk.toString();
      });
      proxy.on("error", (error) => fail(error));
      proxy.on("exit", (code, signal) => {
        if (!settled) {
          fail(new Error(`${label} proxy exited early (code=${code}, signal=${signal}). ${stderr}`));
        }
      });

      proxy.stdin.on("error", (error) => {
        if (!settled) fail(error);
      });
      proxy.stdin.write([
        "GET / HTTP/1.1",
        "Host: localhost",
        "Connection: Upgrade",
        "Upgrade: websocket",
        "Sec-WebSocket-Version: 13",
        `Sec-WebSocket-Key: ${key}`,
        "",
        "",
      ].join("\r\n"));
    });
  } finally {
    await stop(proxy);
  }
}

try {
  server = spawn(binary, ["app-server", "--listen", `unix://${socket}`], {
    stdio: ["ignore", "ignore", "pipe"],
    env: process.env,
    detached: true,
  });
  server.stderr.on("data", (chunk) => {
    serverStderr += chunk.toString();
  });
  server.on("error", (error) => {
    serverError = error;
    serverStderr += error.message;
  });
  await waitFor(() => existsSync(socket) || server.exitCode !== null || serverError, "app-server Unix socket");
  if (serverError || server.exitCode !== null || !existsSync(socket)) {
    throw new Error(`app-server did not start (exit=${server.exitCode}). ${serverStderr}`);
  }

  await validateProxy("first");
  if (server.exitCode !== null || !existsSync(socket)) {
    throw new Error(`app-server stopped after the first proxy disconnected. ${serverStderr}`);
  }
  await validateProxy("second");
  if (server.exitCode !== null || !existsSync(socket)) {
    throw new Error(`app-server stopped after the second proxy disconnected. ${serverStderr}`);
  }
  console.log("Durable Unix socket smoke test passed");
} finally {
  await stop(server);
  await rm(stateDirectory, { recursive: true, force: true });
}

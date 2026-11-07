"use strict";

// Synthetic fixtures and loopback servers only; never read user configuration,
// thread stores, credentials, or contact an actual model provider.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const http = require("node:http");
const https = require("node:https");
const net = require("node:net");
const zlib = require("node:zlib");
const { promisify } = require("node:util");
const { execFile } = require("node:child_process");
const execute = promisify(execFile);
const assets = path.resolve(__dirname, "../flutter_app/assets");
const moduleFixture = { exports: {} };
new Function("require", "module", ["codex-history-compat.cjs", "codex-history-proxy.cjs"]
  .map((name) => fs.readFileSync(path.join(assets, name), "utf8")).join("\n"))
  (require, moduleFixture);
const { createHistoryProxy, providerConfigOverrides } = moduleFixture.exports;

let scenarios = 0;
let cleanup = [];
async function scenario(name, run) {
  cleanup = [];
  try {
    await run();
    scenarios++;
    console.log(`PASS ${name}`);
  } finally {
    for (const close of cleanup.reverse()) await close();
  }
}

async function listen(server, hostname = "127.0.0.1") {
  const sockets = new Set();
  server.on("connection", (socket) => {
    sockets.add(socket);
    socket.once("close", () => sockets.delete(socket));
  });
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, hostname, resolve);
  });
  cleanup.push(async () => {
    for (const socket of sockets) socket.destroy();
    await new Promise((resolve) => server.close(resolve));
  });
  return `${server instanceof https.Server ? "https" : "http"}://${hostname.includes(":") ? `[${hostname}]` : hostname}:${server.address().port}`;
}

async function proxy(env = {}) {
  const value = await createHistoryProxy({ env });
  cleanup.push(() => value.close());
  return value;
}

async function bodyOf(request) {
  const chunks = [];
  for await (const chunk of request) chunks.push(chunk);
  return Buffer.concat(chunks);
}

function request(url, { method = "POST", body = Buffer.alloc(0), headers = {} } = {}) {
  return new Promise((resolve, reject) => {
    const outgoing = http.request(url, {
      method, agent: false, headers: { "content-length": body.length, ...headers },
    }, async (response) => {
      try {
        resolve({ status: response.statusCode, headers: response.headers, body: await bodyOf(response) });
      } catch (error) { reject(error); }
    });
    outgoing.setTimeout(5000, () => outgoing.destroy(new Error("Synthetic request timed out")));
    outgoing.once("error", reject);
    outgoing.end(body);
  });
}

function oldHistory() {
  return { model: "synthetic-model", input: [{
    type: "agent_message", sender: "/root/child", id: "synthetic-id", content: [
      { type: "encrypted_content", encrypted_content: `c2a-msg-v1:${Buffer.from("Synthetic 正文 🙂").toString("base64url")}` },
      { type: "encrypted_content", encrypted_content: "c2c:v1:opaque-valid-summary" },
    ],
  }] };
}

async function main() {
  await scenario("repairs plain child replies on responses and compaction without retries or history mutation", async () => {
    const text = "The child received an opaque gAAAA_SYNTHETIC token; the instructions cannot be read.";
    const source = oldHistory();
    source.input[0].content.unshift({ type: "encrypted_content", encrypted_content: text });
    source.input.push({ type: "compaction", encrypted_content: "gAAAA_SYNTHETIC_SUMMARY==" });
    const original = JSON.stringify(source);
    const seen = [];
    const upstream = await listen(http.createServer(async (req, res) => {
      const body = JSON.parse((await bodyOf(req)).toString());
      seen.push({ url: req.url, body });
      const valid = body.input[0].content[0].type === "input_text";
      res.writeHead(valid ? 200 : 400, { "content-type": "application/json" });
      res.end(valid ? '{"ok":true}' : '{"error":"synthetic invalid encrypted content"}');
    }));
    const local = await proxy();
    // Establish the actual regression: the same malformed input is rejected raw.
    const direct = await request(`${upstream}/v1/responses`, {
      body: Buffer.from(original), headers: { "content-type": "application/json" },
    });
    assert.equal(direct.status, 400);
    const base = local.urlFor(`${upstream}/v1`);
    for (const endpoint of ["responses", "responses/compact", "responses/compact/"]) {
      for (const gzip of [false, true]) {
        const response = await request(`${base}/${endpoint}`, {
          body: gzip ? zlib.gzipSync(original) : Buffer.from(original),
          headers: { "content-type": "application/json", ...(gzip ? { "content-encoding": "gzip" } : {}) },
        });
        assert.equal(response.status, 200, `${endpoint} must normalize malformed child history`);
        assert.equal(seen.at(-1).url, `/v1/${endpoint}`);
        const parsed = seen.at(-1).body;
        assert.deepEqual(parsed.input[0].content[0], { type: "input_text", text });
        assert.deepEqual(parsed.input[0].content[2], source.input[0].content[2]);
        assert.deepEqual(parsed.input[1], source.input[1]);
      }
    }
    assert.equal(seen.length, 7, "No automatic retries or duplicate submissions");
    assert.equal(JSON.stringify(source), original);
  });

  await scenario("normalizes exact old messages while preserving headers, metadata and legal encryption", async () => {
    let received;
    const upstream = await listen(http.createServer(async (req, res) => {
      received = { body: await bodyOf(req), headers: req.headers, url: req.url };
      res.end("ok");
    }));
    const local = await proxy();
    const response = await request(`${local.urlFor(`${upstream}/v1`)}/responses`, {
      body: Buffer.from(JSON.stringify(oldHistory())),
      headers: { "content-type": "application/json", authorization: "Bearer synthetic-only", "x-provider": "kept" },
    });
    assert.equal(response.status, 200);
    const parsed = JSON.parse(received.body);
    assert.deepEqual(parsed.input[0].content[0], { type: "input_text", text: "Synthetic 正文 🙂" });
    assert.deepEqual(parsed.input[0].content[1], oldHistory().input[0].content[1]);
    assert.equal(parsed.input[0].type, "agent_message");
    assert.equal(parsed.input[0].sender, "/root/child");
    assert.equal(parsed.input[0].id, "synthetic-id");
    assert.equal(received.headers.authorization, "Bearer synthetic-only");
    assert.equal(received.headers["x-provider"], "kept");
    assert.equal(Number(received.headers["content-length"]), received.body.length);
    assert.equal(received.headers.host, new URL(upstream).host);
  });

  await scenario("keeps duplicate query keys and raw escaping, with base query fallbacks", async () => {
    let received;
    const upstream = await listen(http.createServer((req, res) => { received = req.url; res.end(); }));
    const local = await proxy();
    const base = `${upstream}/prefix/v1?fallback=a%20b&same=base&repeated=a&repeated=b`;
    await request(`${local.urlFor(base)}/responses?key=a&key=b&same=incoming&space=a+b&literal=%2f`, { method: "GET" });
    assert.equal(received, "/prefix/v1/responses?fallback=a%20b&repeated=a&repeated=b&key=a&key=b&same=incoming&space=a+b&literal=%2f");
  });

  await scenario("preserves IPv6 upstream addresses and Host headers", async () => {
    let received;
    const upstream = await listen(http.createServer((req, res) => {
      received = req.headers.host; res.end("ipv6");
    }), "::1");
    const local = await proxy();
    const response = await request(`${local.urlFor(`${upstream}/v1`)}/responses`, { method: "GET" });
    assert.equal(response.status, 200);
    assert.equal(response.body.toString(), "ipv6");
    assert.equal(received, new URL(upstream).host);
  });

  await scenario("passes normal, malformed and non-Responses requests byte-for-byte", async () => {
    const seen = [];
    const upstream = await listen(http.createServer(async (req, res) => {
      seen.push({ body: await bodyOf(req), headers: req.headers }); res.end();
    }));
    const local = await proxy();
    const base = local.urlFor(`${upstream}/v1`);
    const cases = [
      ["responses", Buffer.from(' { "input": [] } \n'), "application/json", {}],
      ["responses", Buffer.from("{invalid"), "application/json", {}],
      ["responses", Buffer.from([0xff, 0xfe]), "application/json", {}],
      ["messages", Buffer.from(JSON.stringify(oldHistory())), "application/json", {}],
      ["responses", Buffer.from(JSON.stringify(oldHistory())), "text/plain", {}],
      ["responses", Buffer.from(JSON.stringify(oldHistory())), "application/json", { "content-encoding": "br" }],
      ["responses", Buffer.from("invalid gzip"), "application/json", { "content-encoding": "gzip" }],
    ];
    for (const [endpoint, body, type, headers] of cases) {
      await request(`${base}/${endpoint}`, { body, headers: { "content-type": type, ...headers } });
      assert.deepEqual(seen.at(-1).body, body);
      assert.equal(seen.at(-1).headers["content-encoding"], headers["content-encoding"]);
    }
  });

  await scenario("handles gzip conversion and preserves untouched gzip bytes", async () => {
    let received;
    const upstream = await listen(http.createServer(async (req, res) => {
      received = { body: await bodyOf(req), headers: req.headers }; res.end();
    }));
    const local = await proxy();
    const url = `${local.urlFor(`${upstream}/v1`)}/responses`;
    await request(url, { body: zlib.gzipSync(JSON.stringify(oldHistory())), headers: {
      "content-type": "application/vendor+json", "content-encoding": "gzip",
    } });
    assert.equal(JSON.parse(received.body).input[0].content[0].type, "input_text");
    assert.equal(received.headers["content-encoding"], undefined);
    assert.equal(Number(received.headers["content-length"]), received.body.length);
    const untouched = zlib.gzipSync(' { "input": [] } ');
    await request(url, { body: untouched, headers: { "content-type": "application/json", "content-encoding": "gzip" } });
    assert.deepEqual(received.body, untouched);
    assert.equal(received.headers["content-encoding"], "gzip");
  });

  await scenario("preserves upstream errors and cookies and removes hop headers in both directions", async () => {
    let received;
    let calls = 0;
    const upstream = await listen(http.createServer((req, res) => {
      calls++;
      received = req.headers;
      res.writeHead(400, { "content-type": "application/json", "x-error-id": "kept", "set-cookie": ["a=1", "b=2"],
        connection: "close, x-response-hop", "x-response-hop": "removed" });
      res.end('{"error":"synthetic rejection"}');
    }));
    const local = await proxy();
    const response = await request(`${local.urlFor(upstream)}/other`, { headers: {
      connection: "close, x-request-hop", "x-request-hop": "removed", "x-request-end": "kept",
    } });
    assert.equal(response.status, 400);
    assert.equal(response.body.toString(), '{"error":"synthetic rejection"}');
    assert.equal(response.headers["x-error-id"], "kept");
    assert.deepEqual(response.headers["set-cookie"], ["a=1", "b=2"]);
    assert.equal(response.headers["x-response-hop"], undefined);
    assert.equal(received["x-request-hop"], undefined);
    assert.equal(received["x-request-end"], "kept");
    assert.equal(calls, 1);
  });

  await scenario("streams SSE after the request has ended without buffering the response", async () => {
    let ended = false;
    const upstream = await listen(http.createServer(async (req, res) => {
      await bodyOf(req);
      res.writeHead(200, { "content-type": "text/event-stream" });
      res.write("data: first\n\n");
      setTimeout(() => { ended = true; res.end("data: second\n\n"); }, 100);
    }));
    const local = await proxy();
    await new Promise((resolve, reject) => {
      const outgoing = http.request(`${local.urlFor(upstream)}/responses`, {
        method: "POST", headers: { "content-type": "application/json" }, agent: false,
      }, (response) => {
        let text = "";
        response.on("data", (chunk) => {
          if (!text) assert.equal(ended, false);
          text += chunk;
        });
        response.once("end", () => {
          try { assert.equal(text, "data: first\n\ndata: second\n\n"); resolve(); } catch (error) { reject(error); }
        });
        response.once("error", reject);
      });
      outgoing.setTimeout(5000, () => outgoing.destroy(new Error("SSE timed out")));
      outgoing.once("error", reject);
      outgoing.end(JSON.stringify(oldHistory()));
    });
  });

  await scenario("client disconnection cancels the upstream SSE request", async () => {
    let markClosed;
    const closed = new Promise((resolve) => { markClosed = resolve; });
    const upstream = await listen(http.createServer((req, res) => {
      res.writeHead(200, { "content-type": "text/event-stream" });
      res.write("data: first\n\n");
      res.once("close", markClosed);
    }));
    const local = await proxy();
    await new Promise((resolve, reject) => {
      http.get(`${local.urlFor(upstream)}/stream`, { agent: false }, (response) => {
        response.once("data", () => { response.destroy(); resolve(); });
      }).once("error", reject);
    });
    let timer;
    try {
      await Promise.race([closed, new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error("Upstream SSE was not cancelled")), 3000);
      })]);
    } finally { clearTimeout(timer); }
  });

  await scenario("provider overrides preserve provider IDs and attributes and are idempotent", async () => {
    const upstream = await listen(http.createServer((_req, res) => res.end("ok")));
    const local = await proxy();
    const configuration = {
      model_provider: "custom.provider-id", openai_base_url: `${upstream}/builtin`,
      model_providers: {
        "custom.provider-id": { name: "Fixture", base_url: `${upstream}/custom`, env_key: "SYNTHETIC_KEY",
          http_headers: { "x-provider": "preserved" }, supports_websockets: true,
          auth: null, env_http_headers: null, request_max_retries: 0, supports_batch_api: false },
        missing: { name: "Unknown URL", auth: null },
        openai: { catalog_url: "https://example.invalid/catalog" },
        signed: { base_url: `${upstream}/signed`, aws: { region: "synthetic", profile: null } },
        authenticated: { base_url: `${upstream}/auth`, auth: { command: "synthetic", args: ["preserved"],
          env: { PRESENT: "", ABSENT: null }, refresh_interval_seconds: null }, env_key: null },
      },
    };
    const before = JSON.stringify(configuration);
    const first = providerConfigOverrides(configuration, local);
    const second = providerConfigOverrides({ ...configuration, ...first }, local);
    assert.deepEqual(second, first);
    assert.equal(JSON.stringify(configuration), before);
    assert.equal(first.model_providers["custom.provider-id"].env_key, "SYNTHETIC_KEY");
    assert.deepEqual(first.model_providers["custom.provider-id"].http_headers, { "x-provider": "preserved" });
    assert.equal(first.model_providers["custom.provider-id"].supports_websockets, false);
    assert.equal(first.model_providers["custom.provider-id"].request_max_retries, 0);
    assert.equal(first.model_providers["custom.provider-id"].supports_batch_api, false);
    assert.ok(!Object.hasOwn(first.model_providers["custom.provider-id"], "auth"));
    assert.ok(!Object.hasOwn(first.model_providers["custom.provider-id"], "env_http_headers"));
    assert.deepEqual(first.model_providers.openai, configuration.model_providers.openai);
    assert.deepEqual(first.model_providers.signed, { base_url: `${upstream}/signed`, aws: { region: "synthetic" } });
    assert.deepEqual(first.model_providers.missing, { name: "Unknown URL" });
    assert.deepEqual(first.model_providers.authenticated.auth, {
      command: "synthetic", args: ["preserved"], env: { PRESENT: "" },
    });
    assert.ok(!Object.hasOwn(first.model_providers.authenticated, "env_key"));
    const mapped = first.model_providers["custom.provider-id"].base_url;
    assert.equal(local.urlFor(mapped), mapped);
    assert.equal((await request(`${mapped}/responses`)).body.toString(), "ok");
    for (const invalid of ["ftp://example.invalid", "http://user:pass@example.invalid", "http://example.invalid/#fragment", "invalid", undefined]) {
      assert.equal(local.urlFor(invalid), null);
    }
    await local.close();
    await local.close();
    assert.equal(local.urlFor(upstream), null);
  });

  await scenario("honors HTTP proxy authorization, absolute request paths and NO_PROXY", async () => {
    let forwarded;
    const gateway = await listen(http.createServer(async (req, res) => {
      forwarded = { url: req.url, headers: req.headers, body: await bodyOf(req) }; res.end("proxied");
    }));
    const local = await proxy({ HTTP_PROXY: gateway.replace("://", "://synthetic:password@") });
    const upstream = "http://fixture.invalid:4321/v1";
    assert.equal((await request(`${local.urlFor(upstream)}/responses`)).body.toString(), "proxied");
    assert.equal(forwarded.url, `${upstream}/responses`);
    assert.equal(forwarded.headers["proxy-authorization"], `Basic ${Buffer.from("synthetic:password").toString("base64")}`);
    const bypass = await proxy({ ALL_PROXY: "socks5://127.0.0.1:9", NO_PROXY: ".invalid:4321" });
    assert.ok(bypass.urlFor(upstream));
    assert.equal(bypass.urlFor("http://fixture.invalid:4322/v1"), null);
    const unsupported = await proxy({ ALL_PROXY: "socks5://127.0.0.1:9" });
    assert.equal(unsupported.urlFor(upstream), null);
  });

  await scenario("rejects unknown routes, websocket upgrades and oversized requests locally", async () => {
    let calls = 0;
    const upstream = await listen(http.createServer((_req, res) => { calls++; res.end(); }));
    const local = await proxy();
    const url = local.urlFor(upstream);
    const unknown = new URL(url); unknown.pathname = "/wrong/unknown/responses";
    assert.equal((await request(unknown)).status, 404);
    assert.equal((await request(`${url}/responses`, { headers: { "content-type": "application/json", "content-length": 64 * 1024 * 1024 + 1 } })).status, 413);
    await new Promise((resolve, reject) => {
      const outgoing = http.request(`${url}/responses`, { headers: { connection: "Upgrade", upgrade: "websocket" }, agent: false }, (res) => {
        try { assert.equal(res.statusCode, 426); res.resume(); resolve(); } catch (error) { reject(error); }
      });
      outgoing.once("error", reject); outgoing.end();
    });
    assert.equal(calls, 0);
  });

  await scenario("uses verified TLS through authenticated HTTP and HTTPS CONNECT proxies", async () => {
    const directory = fs.mkdtempSync(path.join(os.tmpdir(), "codex-history-proxy-test-"));
    try {
      await execute("openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", path.join(directory, "key.pem"),
        "-out", path.join(directory, "cert.pem"), "-days", "1", "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost"]);
      const result = await execute(process.execPath, [__filename, "--tls", directory], {
        env: { ...process.env, NODE_EXTRA_CA_CERTS: path.join(directory, "cert.pem") }, timeout: 20000,
      });
      assert.equal(result.stdout.trim(), "TLS CONNECT fixtures passed");
    } finally { fs.rmSync(directory, { recursive: true, force: true }); }
  });
  console.log(`${scenarios} proxy scenarios passed`);
}

async function tlsFixtures(directory) {
  cleanup = [];
  const credentials = { key: fs.readFileSync(path.join(directory, "key.pem")), cert: fs.readFileSync(path.join(directory, "cert.pem")) };
  try {
    const upstream = await listen(https.createServer(credentials, async (req, res) => {
      const parsed = JSON.parse(await bodyOf(req));
      assert.equal(parsed.input[0].content[0].type, "input_text"); res.end("verified");
    }));
    for (const secureProxy of [false, true]) {
      let calls = 0;
      const gateway = secureProxy ? https.createServer(credentials) : http.createServer();
      gateway.on("connect", (req, socket, head) => {
        calls++;
        assert.equal(req.headers["proxy-authorization"], `Basic ${Buffer.from("synthetic:password").toString("base64")}`);
        const target = net.connect(new URL(upstream).port, "127.0.0.1", () => {
          socket.write("HTTP/1.1 200 Connection Established\r\n\r\n");
          if (head.length) target.write(head);
          socket.pipe(target); target.pipe(socket);
        });
        socket.once("close", () => target.destroy());
        target.once("error", () => socket.destroy());
      });
      const gatewayUrl = (await listen(gateway)).replace("127.0.0.1", "localhost").replace("://", "://synthetic:password@");
      const local = await proxy({ HTTPS_PROXY: gatewayUrl });
      const base = local.urlFor(upstream.replace("127.0.0.1", "localhost") + "/v1");
      const response = await request(`${base}/responses`, { body: Buffer.from(JSON.stringify(oldHistory())), headers: { "content-type": "application/json" } });
      assert.equal(response.status, 200);
      assert.equal(response.body.toString(), "verified");
      assert.equal(calls, 1);
    }
  } finally { for (const close of cleanup.reverse()) await close(); }
  console.log("TLS CONNECT fixtures passed");
}

(process.argv[2] === "--tls" ? tlsFixtures(process.argv[3]) : main()).catch((error) => {
  console.error(error);
  process.exitCode = 1;
});

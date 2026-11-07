"use strict";

// The relay concatenates this asset after codex-history-compat.cjs. Keep the
// normalizer at the outgoing request boundary; never mutate the thread store.
const codexHistoryProxyApi = (() => {
  const http = require("node:http");
  const https = require("node:https");
  const tls = require("node:tls");
  const crypto = require("node:crypto");
  const zlib = require("node:zlib");
  const { promisify } = require("node:util");
  const gunzip = promisify(zlib.gunzip);
  const maxRequestBytes = 64 * 1024 * 1024;
  const hopHeaders = new Set([
    "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
    "te", "trailer", "transfer-encoding", "upgrade", "proxy-connection",
  ]);

  function withoutHopHeaders(headers) {
    const excluded = new Set(hopHeaders);
    for (const token of String(headers.connection || "").split(",")) {
      if (token.trim()) excluded.add(token.trim().toLowerCase());
    }
    return Object.fromEntries(Object.entries(headers).filter(([key]) =>
      !excluded.has(key.toLowerCase())));
  }

  function parseBaseUrl(value) {
    if (typeof value !== "string" || !value.trim()) return null;
    try {
      const url = new URL(value);
      if (!["http:", "https:"].includes(url.protocol) ||
          url.username || url.password || url.hash) return null;
      return url;
    } catch (_) {
      return null;
    }
  }

  function bypassProxy(url, value) {
    const host = url.hostname.replace(/^\[|\]$/g, "").toLowerCase();
    const port = url.port || (url.protocol === "https:" ? "443" : "80");
    return String(value || "").split(/[\s,]+/).some((entry) => {
      if (!entry) return false;
      if (entry === "*") return true;
      let candidate = entry.toLowerCase();
      let candidatePort = null;
      const bracket = candidate.match(/^\[([^\]]+)\](?::(\d+))?$/);
      if (bracket) {
        candidate = bracket[1];
        candidatePort = bracket[2] || null;
      } else {
        const withPort = candidate.match(/^([^:]+):(\d+)$/);
        if (withPort) {
          candidate = withPort[1];
          candidatePort = withPort[2];
        }
      }
      if (candidatePort && candidatePort !== port) return false;
      candidate = candidate.replace(/^\*?\./, "");
      return host === candidate || host.endsWith(`.${candidate}`);
    });
  }

  // A route we cannot reproduce is deliberately left with the native client.
  // In particular, silently bypassing an ALL_PROXY=socks... proxy is unsafe.
  function upstreamProxy(url, env) {
    if (bypassProxy(url, env.no_proxy || env.NO_PROXY)) return null;
    const value = url.protocol === "https:"
      ? env.https_proxy || env.HTTPS_PROXY || env.all_proxy || env.ALL_PROXY
      : env.http_proxy || env.HTTP_PROXY || env.all_proxy || env.ALL_PROXY;
    if (!value) return null;
    try {
      const proxy = new URL(value);
      if (!["http:", "https:"].includes(proxy.protocol)) return false;
      return proxy;
    } catch (_) {
      return false;
    }
  }

  function proxyAuthorization(proxy) {
    if (!proxy.username && !proxy.password) return null;
    try {
      return `Basic ${Buffer.from(`${decodeURIComponent(proxy.username)}:${
        decodeURIComponent(proxy.password)}`).toString("base64")}`;
    } catch (_) {
      return null;
    }
  }

  function tunnelAgent(proxy, pendingRequests, activeSockets) {
    const agent = new https.Agent({ keepAlive: true, maxSockets: 16 });
    agent.createConnection = (options, callback) => {
      const hostname = String(options.hostname || options.host).replace(/^\[|\]$/g, "");
      const authority = `${hostname.includes(":") ? `[${hostname}]` : hostname}:${options.port || 443}`;
      const headers = { host: authority };
      const auth = proxyAuthorization(proxy);
      if (auth) headers["proxy-authorization"] = auth;
      const connect = (proxy.protocol === "https:" ? https : http).request({
        protocol: proxy.protocol,
        hostname: proxy.hostname.replace(/^\[|\]$/g, ""),
        port: proxy.port || undefined,
        method: "CONNECT",
        path: authority,
        headers,
        agent: false,
      });
      pendingRequests.add(connect);
      connect.once("close", () => pendingRequests.delete(connect));
      let settled = false;
      const fail = (error) => {
        if (settled) return;
        settled = true;
        callback(error);
      };
      connect.once("error", fail);
      connect.once("connect", (response, socket, head) => {
        if (response.statusCode !== 200) {
          socket.destroy();
          fail(new Error("Upstream proxy refused the connection"));
          return;
        }
        if (head.length) socket.unshift(head);
        const secure = tls.connect({
          socket,
          servername: options.servername || (require("node:net").isIP(hostname) ? undefined : hostname),
          rejectUnauthorized: options.rejectUnauthorized !== false,
        });
        activeSockets.add(secure);
        secure.once("close", () => activeSockets.delete(secure));
        secure.once("error", fail);
        secure.once("secureConnect", () => {
          if (settled) return;
          settled = true;
          callback(null, secure);
        });
      });
      connect.end();
    };
    return agent;
  }

  function readBody(request, limit) {
    return new Promise((resolve, reject) => {
      const chunks = [];
      let length = 0;
      let failed = false;
      request.on("data", (chunk) => {
        if (failed) return;
        length += chunk.length;
        if (length > limit) {
          failed = true;
          chunks.length = 0;
          const error = new Error("Request exceeds the compatibility proxy limit");
          error.statusCode = 413;
          reject(error);
          return;
        }
        chunks.push(chunk);
      });
      request.once("end", () => { if (!failed) resolve(Buffer.concat(chunks, length)); });
      request.once("error", reject);
      request.once("aborted", () => reject(new Error("Request aborted")));
    });
  }

  async function normalizeBody(body, headers) {
    const encoding = String(headers["content-encoding"] || "identity").trim().toLowerCase();
    if (!["identity", "gzip"].includes(encoding)) return { body, changed: false };
    let decoded;
    try {
      decoded = encoding === "gzip"
        ? await gunzip(body, { maxOutputLength: maxRequestBytes }) : body;
    } catch (error) {
      if (error.code === "ERR_BUFFER_TOO_LARGE") {
        const limitError = new Error("Decoded request exceeds the compatibility proxy limit");
        limitError.statusCode = 413;
        throw limitError;
      }
      return { body, changed: false };
    }
    let parsed;
    try {
      const text = decoded.toString("utf8");
      if (!Buffer.from(text, "utf8").equals(decoded)) return { body, changed: false };
      parsed = JSON.parse(text);
    } catch (_) {
      return { body, changed: false };
    }
    const result = normalizeResponsesHistory(parsed);
    return result.converted > 0
      ? { body: Buffer.from(JSON.stringify(result.value)), changed: true }
      : { body, changed: false };
  }

  async function create(options = {}) {
    const env = { ...(options.env || process.env) };
    const secret = crypto.randomBytes(32).toString("hex");
    const routes = new Map();
    const routeIds = new Map();
    const sockets = new Set();
    const requests = new Set();
    const agents = new Set();
    const directHttpAgent = new http.Agent({ keepAlive: true, maxSockets: 16 });
    const directHttpsAgent = new https.Agent({ keepAlive: true, maxSockets: 16 });
    agents.add(directHttpAgent);
    agents.add(directHttpsAgent);
    let closed = false;

    function fail(response, statusCode = 502) {
      if (response.destroyed) return;
      if (response.headersSent) {
        response.destroy();
      } else {
        // Do not reflect request URLs, response bodies, credentials, or errors.
        response.writeHead(statusCode, { "content-type": "text/plain", connection: "close" });
        response.end(statusCode === 413 ? "Request too large" : "Upstream request failed");
      }
    }

    const server = http.createServer(async (request, response) => {
      let incoming;
      try { incoming = new URL(request.url, "http://127.0.0.1"); }
      catch (_) { fail(response, 400); return; }
      const match = incoming.pathname.match(/^\/([^/]+)\/([^/]+)(\/.*)?$/);
      const route = match && match[1] === secret && routes.get(match[2]);
      if (!route || closed) { fail(response, 404); request.resume(); return; }
      const target = new URL(route.base.href);
      target.pathname = route.base.pathname.replace(/\/$/, "") + (match[3] || "");
      // Keep incoming query bytes and duplicate keys: signatures and provider
      // routers can distinguish ?key=a&key=b or + from %20. A base URL query is
      // only a fallback for keys not already supplied by the native client.
      const baseQuery = route.base.search.slice(1).split("&").filter((part) => {
        if (!part) return false;
        const key = new URLSearchParams(part).keys().next().value;
        return !incoming.searchParams.has(key);
      }).join("&");
      target.search = [baseQuery, incoming.search.slice(1)].filter(Boolean).join("&");
      const headers = withoutHopHeaders(request.headers);
      headers.host = target.host;
      const isJson = /^application\/(?:[\w.+-]+\+)?json(?:\s*;|$)/i.test(
        String(request.headers["content-type"] || ""));
      const shouldNormalize = request.method === "POST" && /\/responses(?:\/compact)?\/?$/.test(target.pathname) && isJson;
      let body = null;
      try {
        const contentLength = Number(request.headers["content-length"]);
        if (Number.isFinite(contentLength) && contentLength > maxRequestBytes) {
          fail(response, 413); request.resume(); return;
        }
        if (shouldNormalize) {
          const normalized = await normalizeBody(await readBody(request, maxRequestBytes), headers);
          body = normalized.body;
          if (normalized.changed) delete headers["content-encoding"];
          headers["content-length"] = String(body.length);
        }
      } catch (error) {
        fail(response, error.statusCode || 502);
        request.resume();
        return;
      }
      if (response.destroyed || request.aborted) return;
      let transport = target.protocol === "https:" ? https : http;
      let requestOptions = {
        protocol: target.protocol,
        hostname: target.hostname.replace(/^\[|\]$/g, ""),
        port: target.port || undefined,
        method: request.method,
        path: target.pathname + target.search,
        headers,
        agent: target.protocol === "https:" ? directHttpsAgent : directHttpAgent,
      };
      if (route.proxy && target.protocol === "http:") {
        transport = route.proxy.protocol === "https:" ? https : http;
        requestOptions = {
          ...requestOptions,
          protocol: route.proxy.protocol,
          hostname: route.proxy.hostname.replace(/^\[|\]$/g, ""),
          port: route.proxy.port || undefined,
          path: target.href,
          agent: route.proxy.protocol === "https:" ? directHttpsAgent : directHttpAgent,
        };
        const auth = proxyAuthorization(route.proxy);
        if (auth) headers["proxy-authorization"] = auth;
      } else if (route.proxy) {
        requestOptions.agent = route.agent;
      }
      let outbound;
      try {
        outbound = transport.request(requestOptions, (upstream) => {
          response.writeHead(upstream.statusCode || 502, withoutHopHeaders(upstream.headers));
          upstream.once("error", () => fail(response));
          upstream.pipe(response);
        });
      } catch (_) { fail(response); return; }
      requests.add(outbound);
      outbound.once("close", () => requests.delete(outbound));
      outbound.once("error", () => fail(response));
      response.once("close", () => outbound.destroy());
      request.once("aborted", () => outbound.destroy());
      if (body) {
        outbound.end(body);
      } else {
        let streamedBytes = 0;
        request.on("data", (chunk) => {
          streamedBytes += chunk.length;
          if (streamedBytes > maxRequestBytes) {
            request.unpipe(outbound);
            fail(response, 413);
            outbound.destroy();
            request.resume();
          }
        });
        request.once("error", () => outbound.destroy());
        request.pipe(outbound);
      }
    });
    server.on("connection", (socket) => {
      sockets.add(socket);
      socket.once("close", () => sockets.delete(socket));
    });
    // Custom providers disable WebSockets in their override. Built-in providers
    // receive 426 once and use Codex's existing HTTPS fallback; never inspect frames.
    server.on("upgrade", (_request, socket) => {
      socket.end("HTTP/1.1 426 Upgrade Required\r\nConnection: close\r\nContent-Length: 0\r\n\r\n");
    });
    await new Promise((resolve, reject) => {
      server.once("error", reject);
      server.listen(0, "127.0.0.1", resolve);
    });
    const address = server.address();
    const origin = `http://127.0.0.1:${address.port}/${secret}`;
    return {
      urlFor(value) {
        if (closed) return null;
        const base = parseBaseUrl(value);
        if (!base) return null;
        // Effective thread configuration may be read and applied repeatedly.
        // Do not wrap our own already registered route into another route.
        const localPrefix = `${origin}/`;
        if (base.href.startsWith(localPrefix)) {
          const id = base.href.slice(localPrefix.length).split(/[/?]/, 1)[0];
          if (routes.has(id)) return base.href;
        }
        const proxy = upstreamProxy(base, env);
        if (proxy === false) return null;
        let id = routeIds.get(base.href);
        if (!id) {
          id = crypto.randomBytes(12).toString("hex");
          const agent = proxy && base.protocol === "https:" ? tunnelAgent(proxy, requests, sockets) : null;
          if (agent) agents.add(agent);
          routes.set(id, { base, proxy, agent });
          routeIds.set(base.href, id);
        }
        return `${origin}/${id}`;
      },
      async close() {
        if (closed) return;
        closed = true;
        for (const request of requests) request.destroy();
        for (const agent of agents) agent.destroy();
        for (const socket of sockets) socket.destroy();
        await new Promise((resolve) => server.close(resolve));
        routes.clear();
        routeIds.clear();
      },
    };
  }

  function overrides(config, proxy) {
    if (!config || typeof config !== "object" || !proxy) return {};
    const result = {};
    const openaiUrl = proxy.urlFor(config.openai_base_url);
    if (openaiUrl) result.openai_base_url = openaiUrl;
    const providers = config.model_providers;
    if (providers && typeof providers === "object" && !Array.isArray(providers)) {
      let changed = false;
      // config/read includes absent optional fields as null. RPC overrides are
      // converted to TOML, which has no null value; forwarding those defaults
      // produces empty strings (for example auth="") rejected by native Codex.
      // Omit only absent values, preserving explicit false, zero, empty strings,
      // auth objects, environment references, and arbitrary provider headers.
      function presentValues(value) {
        if (Array.isArray(value)) {
          return value.filter((item) => item != null).map(presentValues);
        }
        if (value && typeof value === "object") {
          return Object.fromEntries(Object.entries(value)
            .filter(([, item]) => item != null)
            .map(([key, item]) => [key, presentValues(item)]));
        }
        return value;
      }
      const mapped = presentValues(providers);
      for (const [id, provider] of Object.entries(providers)) {
        // Built-in openai accepts only catalog_url in model_providers; AWS SigV4
        // signs Host and cannot be redirected through a loopback base URL.
        if (id === "openai" || !provider || typeof provider !== "object" || provider.aws) continue;
        const url = proxy.urlFor(provider.base_url);
        if (!url) continue;
        mapped[id] = { ...mapped[id], base_url: url, supports_websockets: false };
        changed = true;
      }
      if (changed) result.model_providers = mapped;
    }
    return result;
  }

  return { createHistoryProxy: create, providerConfigOverrides: overrides };
})();

async function createHistoryProxy(options) {
  return codexHistoryProxyApi.createHistoryProxy(options);
}

function providerConfigOverrides(config, proxy) {
  return codexHistoryProxyApi.providerConfigOverrides(config, proxy);
}

Object.assign(module.exports, { createHistoryProxy, providerConfigOverrides });

#!/usr/bin/env node
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const http = require("node:http");
const cp = require("node:child_process");
const crypto = require("node:crypto");
const settings = require("../flutter_app/assets/claude-code-settings.cjs");

async function concurrentWriters(temporary, filename, draft) {
  const release = path.join(temporary, "release-writer");
  const before = fs.readFileSync(filename);
  const children = [0, 1].map(index => {
    const marker = path.join(temporary, `writer-${index}-held`);
    const model = `fixture-model-${index}`;
    const child = cp.spawn(process.execPath, ["-e", `
      const fs = require('node:fs');
      const helper = require(${JSON.stringify(path.resolve(__dirname, "../flutter_app/assets/claude-code-settings.cjs"))});
      const rename = fs.renameSync;
      fs.renameSync = (from, to) => {
        if (to === ${JSON.stringify(filename)}) {
          fs.writeFileSync(${JSON.stringify(marker)}, 'held');
          const deadline = Date.now() + 10000;
          while (!fs.existsSync(${JSON.stringify(release)})) {
            if (Date.now() >= deadline) process.exit(75);
            Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 10);
          }
        }
        return rename(from, to);
      };
      try {
        helper.writeSettings(${JSON.stringify({ ...draft, defaultModel: model })});
      } catch (error) {
        process.exit(/正在写入|无身份的配置锁/.test(error.message) ? 74 : 76);
      }
    `], { env: process.env, stdio: "ignore" });
    const result = { child, marker, model, exited: false };
    result.done = new Promise((resolve, reject) => {
      child.once("error", reject);
      child.once("exit", code => { result.exited = true; resolve(code); });
    });
    return result;
  });
  try {
    const deadline = Date.now() + 5000;
    while (!(children.some(value => fs.existsSync(value.marker)) && children.some(value => value.exited))) {
      assert.ok(Date.now() < deadline, "concurrent writers did not reach the held/rejected state");
      await new Promise(resolve => setTimeout(resolve, 10));
    }
    const holder = children.filter(value => fs.existsSync(value.marker));
    assert.equal(holder.length, 1, "only one real process may hold the settings lock");
    const rejected = children.find(value => value !== holder[0]);
    assert.equal(await rejected.done, 74, "the other writer fails closed while the owner is alive");
    assert.deepEqual(fs.readFileSync(filename), before, "the blocked writer cannot overwrite the native file");
    fs.writeFileSync(release, "release");
    assert.equal(await holder[0].done, 0);
    assert.equal(JSON.parse(fs.readFileSync(filename, "utf8")).model, holder[0].model);
    assert.equal(fs.existsSync(path.join(path.dirname(filename), ".codex-remote-settings.lock")), false);
  } finally {
    for (const value of children) if (!value.exited) value.child.kill("SIGKILL");
    await Promise.allSettled(children.map(value => value.done));
    fs.rmSync(release, { force: true });
    for (const value of children) fs.rmSync(value.marker, { force: true });
  }
}

async function main() {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), "claude-settings-"));
  const saved = { ...process.env };
  const proxyNames = ["HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY", "https_proxy", "http_proxy", "all_proxy", "NO_PROXY", "no_proxy"];
  for (const key of [...Object.keys(process.env).filter(key => /^(CLAUDE_|ANTHROPIC_)/.test(key)), ...proxyNames]) delete process.env[key];
  process.env.CLAUDE_CONFIG_DIR = path.join(temporary, "custom-config");
  fs.mkdirSync(process.env.CLAUDE_CONFIG_DIR);
  const filename = path.join(process.env.CLAUDE_CONFIG_DIR, "settings.json");
  const write = data => fs.writeFileSync(filename, JSON.stringify(data), { mode: 0o600 });
  const read = () => JSON.parse(fs.readFileSync(filename, "utf8"));
  const draft = { baseUrl: "https://example.invalid", apiKey: "", proxyUrl: "", defaultModel: "claude-opus-5-5", defaultReasoningEffort: "high" };
  let server;
  const originalSpawn = cp.spawn;
  try {
    write({ model: "old-root-model", effortLevel: "low", unknown: { keep: [1, 2] }, permissions: { allow: ["Read"] },
      env: { ANTHROPIC_BASE_URL: "https://old.invalid", ANTHROPIC_AUTH_TOKEN: "fake-token", ANTHROPIC_MODEL: "m-claude",
        ANTHROPIC_DEFAULT_OPUS_MODEL: "m-claude", CLAUDE_CODE_MAX_CONTEXT_TOKENS: "65536", OTHER_SETTING: "retained" } });
    assert.equal(settings.readSettings().model, "m-claude");
    assert.equal(settings.readSettings().apiKey, "fake-token");
    assert.equal(settings.readSettings().modelProvider, "anthropic");
    assert.equal(settings.readSettings().contextWindowTokens, 65536);
    settings.writeSettings(draft);
    assert.equal(settings.readSettings().model, "claude-opus-5-5");
    assert.equal(read().env.ANTHROPIC_MODEL, "claude-opus-5-5");
    assert.equal(read().env.ANTHROPIC_AUTH_TOKEN, "fake-token", "blank key preserves native token");
    assert.equal(read().env.ANTHROPIC_API_KEY, undefined);
    assert.equal(read().env.ANTHROPIC_DEFAULT_OPUS_MODEL, "m-claude");
    assert.equal(read().env.CLAUDE_CODE_MAX_CONTEXT_TOKENS, "65536");
    assert.equal(settings.readSettings().contextWindowTokens, 65536);
    assert.deepEqual(read().unknown, { keep: [1, 2] });
    assert.deepEqual(read().permissions, { allow: ["Read"] });
    assert.equal(fs.statSync(filename).mode & 0o777, 0o600);
    assert.equal(settings.launchEnvironment().PATH, saved.PATH);
    assert.equal(settings.launchEnvironment().CLAUDE_CODE_MAX_CONTEXT_TOKENS, "65536");
    const preserved = read();
    for (const invalid of ["0", "-1", "unknown", "100000001", "999999999999999999999"]) {
      write({ ...preserved, env: { ...preserved.env, CLAUDE_CODE_MAX_CONTEXT_TOKENS: invalid } });
      assert.equal(settings.readSettings().contextWindowTokens, 0);
      settings.writeSettings(draft);
      assert.equal(read().env.CLAUDE_CODE_MAX_CONTEXT_TOKENS, invalid);
    }
    write(preserved);

    settings.writeSettings({ ...draft, apiKey: "replacement-token", proxyUrl: "http://proxy.invalid:3128" });
    assert.equal(read().env.ANTHROPIC_AUTH_TOKEN, "replacement-token");
    assert.equal(settings.launchEnvironment().HTTPS_PROXY, "http://proxy.invalid:3128");
    settings.writeSettings({ ...draft, defaultModel: "", defaultReasoningEffort: "" });
    assert.equal(read().model, undefined);
    assert.equal(read().effortLevel, undefined);
    assert.equal(settings.readSettings().model, "");
    assert.equal(settings.readSettings().proxyUrl, "");
    assert.equal(settings.launchEnvironment().HTTPS_PROXY, "");
    write({ env: { ANTHROPIC_API_KEY: "fake-api-key" } });
    settings.writeSettings({ ...draft, apiKey: "new-api-key" });
    assert.equal(read().env.ANTHROPIC_API_KEY, "new-api-key");
    assert.equal(read().env.ANTHROPIC_AUTH_TOKEN, undefined);

    const credentials = path.join(process.env.CLAUDE_CONFIG_DIR, ".credentials.json");
    fs.writeFileSync(credentials, '{"claudeAiOauth":{"accessToken":"fake-oauth"}}', { mode: 0o600 });
    const originalCredentials = fs.readFileSync(credentials);
    write({ theme: "dark" });
    assert.equal(settings.readSettings().hasStoredAuthentication, true);
    assert.equal(settings.readSettings().apiKey, "");
    settings.writeSettings(draft);
    assert.deepEqual(fs.readFileSync(credentials), originalCredentials);
    assert.equal((await settings.testSettings({ ...draft, testModel: "claude-opus-5-5" })).successful, false);
    assert.equal(read().theme, "dark");

    for (const bad of ["{ broken json", "[]", '{"env":[]}']) {
      fs.writeFileSync(filename, bad);
      assert.throws(() => settings.writeSettings(draft), /JSON|结构/);
      assert.equal(fs.readFileSync(filename, "utf8"), bad);
    }
    write({ untouched: true });
    for (const invalid of [{ apiKey: "key\nInjected: yes" }, { baseUrl: "file:///tmp/a" }, { baseUrl: "https://user:secret@example.invalid" },
      { proxyUrl: "socks5://localhost:1234" }, { defaultModel: "--malicious" }, { defaultReasoningEffort: "ultra" }]) {
      assert.throws(() => settings.writeSettings({ ...draft, ...invalid }));
      assert.deepEqual(read(), { untouched: true });
    }
    const linkTarget = path.join(temporary, "target.json");
    fs.renameSync(filename, linkTarget);
    fs.symlinkSync(linkTarget, filename);
    assert.throws(() => settings.writeSettings(draft), /安全读取/);
    assert.deepEqual(JSON.parse(fs.readFileSync(linkTarget)), { untouched: true });
    fs.unlinkSync(filename);
    fs.renameSync(linkTarget, filename);
    const lock = path.join(process.env.CLAUDE_CONFIG_DIR, ".codex-remote-settings.lock");
    fs.mkdirSync(lock);
    assert.throws(() => settings.writeSettings(draft), /无身份的配置锁/);
    assert.deepEqual(read(), { untouched: true });
    const originalStat = fs.lstatSync;
    const previousBootTime = Date.now() - Number(fs.readFileSync("/proc/uptime", "utf8").split(" ")[0]) * 1000 - 60000;
    fs.lstatSync = value => {
      const result = originalStat(value);
      if (value === lock) { result.mtimeMs = previousBootTime; result.ctimeMs = previousBootTime; }
      return result;
    };
    try {
      settings.writeSettings(draft);
      assert.equal(fs.existsSync(lock), false, "a legacy empty lock proven to predate this boot is recovered");
    } finally { fs.lstatSync = originalStat; }
    const bootId = fs.readFileSync("/proc/sys/kernel/random/boot_id", "utf8").trim();
    const selfStat = fs.readFileSync(`/proc/${process.pid}/stat`, "utf8");
    const startTicks = selfStat.slice(selfStat.lastIndexOf(")") + 1).trim().split(/\s+/)[19];
    const owner = { pid: process.pid, bootId, startTicks };
    const createLock = identity => {
      fs.mkdirSync(lock);
      const ownerFile = path.join(lock, `owner-${crypto.randomUUID()}`);
      fs.writeFileSync(ownerFile, JSON.stringify(identity), { mode: 0o600 });
      return ownerFile;
    };
    const liveOwner = createLock(owner);
    assert.throws(() => settings.writeSettings(draft), /正在写入/, "a live owner keeps the lock");
    assert.equal(fs.existsSync(liveOwner), true);
    fs.unlinkSync(liveOwner);
    fs.rmdirSync(lock);
    for (const stale of [{ ...owner, startTicks: String(Number(startTicks) + 1) },
      { ...owner, bootId: "00000000-0000-0000-0000-000000000000" },
      { ...owner, pid: 99999999 }]) {
      createLock(stale);
      settings.writeSettings(draft);
      assert.equal(fs.existsSync(lock), false, "a crashed or reused owner is recovered");
    }
    const crash = cp.spawnSync(process.execPath, ["-e", `
      const fs = require('node:fs');
      const path = require('node:path');
      const helper = require(${JSON.stringify(path.resolve(__dirname, "../flutter_app/assets/claude-code-settings.cjs"))});
      const rename = fs.renameSync;
      fs.renameSync = (from, to) => {
        if (path.basename(to) === 'settings.json') process.exit(73);
        return rename(from, to);
      };
      helper.writeSettings({ baseUrl: 'https://example.invalid', defaultModel: 'claude-opus-5-5' });
    `], { env: process.env, encoding: "utf8" });
    assert.equal(crash.status, 73);
    assert.equal(fs.existsSync(lock), true, "crashed writer leaves its lock for recovery");
    settings.writeSettings(draft);
    assert.equal(fs.existsSync(lock), false, "the next write recovers a real crashed process lock");
    const staleOwner = createLock({ ...owner, startTicks: String(Number(startTicks) + 1) });
    const replacementOwner = path.join(lock, `owner-${crypto.randomUUID()}`);
    const originalUnlink = fs.unlinkSync;
    fs.unlinkSync = filename => {
      if (filename === staleOwner) {
        originalUnlink(filename);
        fs.rmdirSync(lock);
        fs.mkdirSync(lock);
        fs.writeFileSync(replacementOwner, JSON.stringify(owner), { mode: 0o600 });
        return;
      }
      return originalUnlink(filename);
    };
    try {
      assert.throws(() => settings.writeSettings(draft), /正在写入/, "reaping must not remove a new live owner");
      assert.equal(fs.existsSync(replacementOwner), true);
    } finally { fs.unlinkSync = originalUnlink; }
    fs.unlinkSync(replacementOwner);
    fs.rmdirSync(lock);
    assert.equal(read().env.ANTHROPIC_MODEL, "claude-opus-5-5");
    createLock({ ...owner, pid: 99999999 });
    await concurrentWriters(temporary, filename, draft);

    let responseMode = "valid";
    const requests = [];
    server = http.createServer((request, response) => {
      let body = "";
      request.on("data", chunk => body += chunk);
      request.on("end", () => {
        requests.push({ url: request.url, headers: request.headers, body: body ? JSON.parse(body) : null });
        if (responseMode === "unauthorized") { response.writeHead(401); response.end('{"error":"secret-remote-details"}'); return; }
        if (responseMode === "redirect") { response.writeHead(302, { Location: "http://localhost:1/secret" }); response.end(); return; }
        response.setHeader("Content-Type", "application/json");
        if (responseMode === "malformed") { response.end("not json fake-secret"); return; }
        if (request.url === "/v1/models") {
          response.end(JSON.stringify({ data: [{ id: "claude-opus-5-5", display_name: "Opus 5.5", context_window: 1000000 },
            { id: "claude-opus-5-5" }, { id: "invalid model" }, { id: "custom-alias" }] })); return;
        }
        response.end(JSON.stringify(responseMode === "incomplete" ? { type: "message", role: "assistant", content: [] } :
          { type: "message", role: "assistant", stop_reason: "end_turn", content: [{ type: "text", text: "OK" }] }));
      });
    });
    await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
    const baseUrl = `http://127.0.0.1:${server.address().port}`;
    write({ env: { ANTHROPIC_AUTH_TOKEN: "fake-header-token", ANTHROPIC_BASE_URL: baseUrl, ANTHROPIC_MODEL: "m-claude" } });
    const nativeBefore = fs.readFileSync(filename);
    cp.spawn = (command, args, options) => {
      assert.equal(command, "curl");
      assert.deepEqual(args, ["--disable", "--config", "-"]);
      assert.equal(JSON.stringify(args).includes("fake-header-token"), false);
      assert.equal(options.env.HTTPS_PROXY, undefined);
      return originalSpawn(command, args, options);
    };
    process.env.HTTPS_PROXY = "http://must-not-use.invalid:1";
    let result = await settings.testSettings({ baseUrl, apiKey: "", proxyUrl: "", testModel: "claude-opus-5-5" });
    assert.equal(result.successful, true);
    assert.equal(requests.at(-1).url, "/v1/messages");
    assert.equal(requests.at(-1).body.model, "claude-opus-5-5");
    assert.equal(requests.at(-1).headers.authorization, "Bearer fake-header-token");
    assert.equal(requests.at(-1).headers["x-api-key"], undefined);
    assert.deepEqual(fs.readFileSync(filename), nativeBefore, "test does not save draft");
    const models = await settings.listApiModels({ baseUrl: `${baseUrl}/v1/`, apiKey: "", proxyUrl: "" });
    assert.deepEqual(models.map(item => item.modelId), ["claude-opus-5-5", "custom-alias"]);
    assert.equal(models[0].contextWindowTokens, 1000000);
    assert.equal(requests.at(-1).url, "/v1/models");
    assert.deepEqual(fs.readFileSync(filename), nativeBefore);
    for (const mode of ["incomplete", "malformed", "unauthorized", "redirect"]) {
      responseMode = mode;
      result = await settings.testSettings({ baseUrl, apiKey: "draft-key", proxyUrl: "", testModel: "claude-opus-5-5" });
      assert.equal(result.successful, false, mode);
      assert.equal(/fake-|secret-|draft-key|127\.0\.0\.1/.test(result.message), false);
      assert.deepEqual(fs.readFileSync(filename), nativeBefore);
    }
    responseMode = "valid";
    write({ env: { ANTHROPIC_API_KEY: "api-header-key" } });
    assert.equal((await settings.testSettings({ baseUrl, proxyUrl: "", testModel: "custom-alias" })).successful, true);
    assert.equal(requests.at(-1).headers["x-api-key"], "api-header-key");
    assert.equal(requests.at(-1).headers.authorization, undefined);
    console.log("Claude settings: native preservation, secret handling, atomic writes, auth modes, Anthropic API and errors passed");
  } finally {
    cp.spawn = originalSpawn;
    if (server) await new Promise(resolve => server.close(resolve));
    for (const key of Object.keys(process.env)) if (!Object.hasOwn(saved, key)) delete process.env[key];
    Object.assign(process.env, saved);
    fs.rmSync(temporary, { recursive: true, force: true });
  }
}
main().catch(error => { console.error(error); process.exitCode = 1; });

"use strict";

const assert = require("node:assert/strict");
const childProcess = require("node:child_process");
const fs = require("node:fs");
const http = require("node:http");
const os = require("node:os");
const path = require("node:path");
const readline = require("node:readline");

const repository = path.resolve(__dirname, "..");
const bridgePath = path.join(repository, "app/src/main/assets/opencode-bridge.cjs");
const openCodeBin = process.env.OPENCODE_BIN;
const temporaryRoot = fs.mkdtempSync(path.join(os.tmpdir(), "opencode-bridge-integration-"));
const expectedKey = "integration-secret-not-real";
const pending = new Map();
const notifications = [];
const requests = [];
let nextID = 1;
let bridgeProcess;
let bridgeStderr = "";

if (!openCodeBin) {
  throw new Error("Set OPENCODE_BIN to the OpenCode executable before running this test");
}

const jsoncParser = require(require.resolve("jsonc-parser", {
  paths: [path.dirname(path.resolve(openCodeBin)), path.dirname(fs.realpathSync(openCodeBin))],
}));

function listen(server) {
  return new Promise(function (resolve, reject) {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", function () {
      server.removeListener("error", reject);
      resolve(server.address().port);
    });
  });
}

function readJsonBody(request) {
  return new Promise(function (resolve, reject) {
    const chunks = [];
    request.on("data", function (chunk) { chunks.push(chunk); });
    request.on("end", function () {
      try {
        const text = Buffer.concat(chunks).toString("utf8");
        resolve(text ? JSON.parse(text) : {});
      } catch (error) {
        reject(error);
      }
    });
    request.on("error", reject);
  });
}

function completionResponse(model) {
  return {
    id: "chatcmpl-integration",
    object: "chat.completion",
    created: Math.floor(Date.now() / 1000),
    model: model,
    choices: [{
      index: 0,
      message: { role: "assistant", content: "CUSTOM_MODEL_OK" },
      finish_reason: "stop",
    }],
    usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 },
  };
}

function streamCompletion(response, model) {
  response.writeHead(200, {
    "content-type": "text/event-stream",
    "cache-control": "no-cache",
    connection: "keep-alive",
  });
  const created = Math.floor(Date.now() / 1000);
  const base = {
    id: "chatcmpl-integration",
    object: "chat.completion.chunk",
    created: created,
    model: model,
  };
  response.write("data: " + JSON.stringify(Object.assign({}, base, {
    choices: [{ index: 0, delta: { role: "assistant", content: "CUSTOM_MODEL_OK" }, finish_reason: null }],
  })) + "\n\n");
  response.write("data: " + JSON.stringify(Object.assign({}, base, {
    choices: [{ index: 0, delta: {}, finish_reason: "stop" }],
    usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 },
  })) + "\n\n");
  response.end("data: [DONE]\n\n");
}

function sendRpc(method, params, timeoutMs) {
  const id = nextID++;
  const timeout = timeoutMs || 30_000;
  return new Promise(function (resolve, reject) {
    const timer = setTimeout(function () {
      pending.delete(id);
      reject(new Error("Timed out waiting for " + method + "\n" + bridgeStderr.slice(-2000)));
    }, timeout);
    pending.set(id, {
      resolve: function (value) {
        clearTimeout(timer);
        resolve(value);
      },
      reject: function (error) {
        clearTimeout(timer);
        reject(error);
      },
    });
    bridgeProcess.stdin.write(JSON.stringify({ id: id, method: method, params: params || {} }) + "\n");
  });
}

function waitForNotification(method, predicate, timeoutMs) {
  const timeout = timeoutMs || 60_000;
  return new Promise(function (resolve, reject) {
    const started = Date.now();
    function poll() {
      const match = notifications.find(function (item) {
        return item.method === method && (!predicate || predicate(item.params || {}));
      });
      if (match) return resolve(match);
      if (Date.now() - started >= timeout) {
        return reject(new Error("Timed out waiting for notification " + method +
          "\n" + bridgeStderr.slice(-2000)));
      }
      setTimeout(poll, 50);
    }
    poll();
  });
}

async function main() {
  const apiServer = http.createServer(async function (request, response) {
    try {
      const url = new URL(request.url, "http://127.0.0.1");
      if (request.method === "GET" && url.pathname === "/v1/models") {
        response.writeHead(200, { "content-type": "application/json" });
        response.end(JSON.stringify({
          object: "list",
          data: [
            { id: "integration-model", object: "model" },
            { id: "integration-extra", object: "model" },
          ],
        }));
        return;
      }
      if (request.method === "POST" && url.pathname === "/v1/chat/completions") {
        const body = await readJsonBody(request);
        requests.push({ authorization: request.headers.authorization || "", body: body });
        if (body.stream) {
          streamCompletion(response, body.model || "integration-extra");
        } else {
          response.writeHead(200, { "content-type": "application/json" });
          response.end(JSON.stringify(completionResponse(body.model || "integration-extra")));
        }
        return;
      }
      response.writeHead(404, { "content-type": "application/json" });
      response.end(JSON.stringify({ error: { message: "Unexpected route " + url.pathname } }));
    } catch (error) {
      response.writeHead(500, { "content-type": "application/json" });
      response.end(JSON.stringify({ error: { message: error.message || String(error) } }));
    }
  });

  try {
    const apiPort = await listen(apiServer);
    const configDirectory = path.join(temporaryRoot, "config", "opencode");
    fs.mkdirSync(configDirectory, { recursive: true });
    const persistedConfigPath = path.join(configDirectory, "opencode.jsonc");
    fs.writeFileSync(persistedConfigPath, [
      "{",
      "  // This comment and the timeout are not managed by Codex Remote.",
      "  \"provider\": {",
      "    \"codex-remote\": {",
      "      \"name\": \"Preserved provider name\",",
      "      \"npm\": \"@ai-sdk/openai-compatible\",",
      "      \"options\": { \"timeout\": 30 },",
      "      \"models\": {",
      "        \"untouched\": { \"name\": \"Untouched\" },",
      "      },",
      "    },",
      "  },",
      "}",
      "",
    ].join("\n"), { mode: 0o600 });
    bridgeProcess = childProcess.spawn(process.execPath, [bridgePath, "--directory", repository], {
      cwd: repository,
      env: Object.assign({}, process.env, {
        HOME: path.join(temporaryRoot, "home"),
        XDG_CACHE_HOME: path.join(temporaryRoot, "cache"),
        XDG_CONFIG_HOME: path.join(temporaryRoot, "config"),
        XDG_DATA_HOME: path.join(temporaryRoot, "data"),
        OPENCODE_CONFIG_DIR: configDirectory,
        OPENCODE_BIN: openCodeBin,
      }),
      stdio: ["pipe", "pipe", "pipe"],
    });
    bridgeProcess.stderr.on("data", function (chunk) {
      bridgeStderr = (bridgeStderr + chunk.toString("utf8")).slice(-20_000);
    });
    readline.createInterface({ input: bridgeProcess.stdout, crlfDelay: Infinity })
      .on("line", function (line) {
        let message;
        try { message = JSON.parse(line); } catch (error) { return; }
        if (Object.prototype.hasOwnProperty.call(message, "id") && !message.method) {
          const callback = pending.get(Number(message.id));
          if (!callback) return;
          pending.delete(Number(message.id));
          if (message.error) callback.reject(new Error(message.error.message || "RPC failed"));
          else callback.resolve(message.result);
        } else if (message.method) {
          notifications.push(message);
        }
      });

    await sendRpc("initialize", {}, 60_000);
    const initial = await sendRpc("agent/settings/read");
    assert.equal(initial.baseUrl, "");
    assert.equal(initial.model, "");

    const baseUrl = "http://127.0.0.1:" + apiPort + "/v1";
    const saved = await sendRpc("agent/settings/write", {
      baseUrl: baseUrl,
      apiKey: expectedKey,
      proxyUrl: "",
      defaultModel: "codex-remote/integration-model",
      preserveCurrentProvider: false,
      customModels: [{
        modelId: "codex-remote/integration-model",
        displayName: "Integration Model",
        contextWindowTokens: 200000,
        maxOutputTokens: 32000,
      }],
    });
    assert.equal(saved.baseUrl, baseUrl);
    assert.equal(saved.model, "codex-remote/integration-model");
    assert.equal(saved.apiKey, expectedKey);
    assert.equal(saved.hasStoredAuthentication, true);

    await sendRpc("agent/model/ensure", {
      modelId: "codex-remote/integration-extra",
      displayName: "Integration Extra",
      contextWindowTokens: 128000,
      maxOutputTokens: 16000,
    });
    await sendRpc("agent/model/ensure", {
      modelId: "codex-remote/local-only",
      displayName: "Local Only",
      contextWindowTokens: 64000,
      maxOutputTokens: 8000,
    });
    await sendRpc("agent/settings/write", {
      baseUrl: baseUrl,
      apiKey: expectedKey,
      proxyUrl: "",
      defaultModel: "codex-remote/local-only",
      preserveCurrentProvider: true,
      customModels: [],
    });
    const syncResult = await sendRpc("agent/models/sync", {
      models: [{
        modelId: "codex-remote/integration-model",
        displayName: "Integration Model Updated",
        contextWindowTokens: 256000,
        maxOutputTokens: 64000,
      }],
      removeModelIds: ["codex-remote/local-only"],
    });
    assert.equal(syncResult.defaultModel, "codex-remote/untouched");
    assert.equal(syncResult.runtimeRefreshed, true);
    const models = await sendRpc("model/list");
    const managedModels = models.data.filter(function (model) {
      return model.id.startsWith("codex-remote/");
    });
    assert(models.data.some(function (model) {
      return model.id === "codex-remote/integration-model" &&
        model.displayName === "Integration Model Updated" &&
        model.contextWindowTokens === 256000 && model.maxOutputTokens === 64000;
    }), "Updated model metadata is missing: " + JSON.stringify(managedModels));
    assert(models.data.some(function (model) {
      return model.id === "codex-remote/integration-extra" &&
        model.contextWindowTokens === 128000 && model.maxOutputTokens === 16000;
    }), "Existing custom model is missing: " + JSON.stringify(managedModels));
    const persistedConfig = fs.existsSync(persistedConfigPath)
      ? fs.readFileSync(persistedConfigPath, "utf8")
      : "<missing opencode.jsonc>";
    assert(!models.data.some(function (model) {
      return model.id === "codex-remote/local-only";
    }), "Deleted model remains configured:\n" + persistedConfig);
    const parseErrors = [];
    const parsedConfig = jsoncParser.parse(
      persistedConfig,
      parseErrors,
      { allowTrailingComma: true },
    );
    assert.deepEqual(parseErrors, []);
    assert(!Object.prototype.hasOwnProperty.call(
      parsedConfig.provider["codex-remote"].models,
      "local-only",
    ));
    assert.equal(parsedConfig.model, "codex-remote/untouched");
    assert.equal(parsedConfig.provider["codex-remote"].options.timeout, 30);
    assert(persistedConfig.includes("This comment and the timeout are not managed"));

    const started = await sendRpc("thread/start");
    const threadID = started.thread.id;
    assert(threadID);
    await sendRpc("turn/start", {
      threadId: threadID,
      model: "codex-remote/integration-extra",
      input: [{ type: "text", text: "Reply exactly CUSTOM_MODEL_OK" }],
      approvalPolicy: "never",
    });
    await waitForNotification("turn/completed", function (params) {
      return params.threadId === threadID;
    }, 60_000);
    const turnRequest = requests.find(function (request) {
      return request.body.model === "integration-extra";
    });
    assert(turnRequest, "OpenCode did not call the selected custom model");
    assert.equal(turnRequest.authorization, "Bearer " + expectedKey);
    assert(notifications.some(function (message) {
      return message.method === "item/completed" &&
        message.params && message.params.threadId === threadID &&
        message.params.item && message.params.item.type === "agentMessage" &&
        message.params.item.text.includes("CUSTOM_MODEL_OK");
    }));

    const finalRemoval = await sendRpc("agent/models/sync", {
      models: [],
      removeModelIds: [
        "codex-remote/integration-model",
        "codex-remote/integration-extra",
        "codex-remote/untouched",
      ],
    });
    assert.equal(finalRemoval.defaultModel, "");
    assert.equal(finalRemoval.runtimeRefreshed, true);
    const finalSettings = await sendRpc("agent/settings/read");
    assert.equal(finalSettings.model, "");
    const finalModels = await sendRpc("model/list");
    assert(!finalModels.data.some(function (model) {
      return model.id === "codex-remote/integration-model" ||
        model.id === "codex-remote/integration-extra" ||
        model.id === "codex-remote/untouched";
    }));
    const finalConfigText = fs.readFileSync(persistedConfigPath, "utf8");
    const finalParseErrors = [];
    const finalConfig = jsoncParser.parse(
      finalConfigText,
      finalParseErrors,
      { allowTrailingComma: true },
    );
    assert.deepEqual(finalParseErrors, []);
    assert(!Object.prototype.hasOwnProperty.call(finalConfig, "model"));
    assert.deepEqual(finalConfig.provider["codex-remote"].models, {});
    assert.equal(finalConfig.provider["codex-remote"].options.timeout, 30);
    assert(finalConfigText.includes("This comment and the timeout are not managed"));

    process.stdout.write("OpenCode bridge integration tests passed\n");
  } finally {
    for (const callback of pending.values()) callback.reject(new Error("Test shutting down"));
    pending.clear();
    if (bridgeProcess && !bridgeProcess.killed) bridgeProcess.kill("SIGTERM");
    await new Promise(function (resolve) { apiServer.close(resolve); });
    fs.rmSync(temporaryRoot, { recursive: true, force: true });
  }
}

main().catch(function (error) {
  process.stderr.write((error.stack || error.message || String(error)) + "\n");
  process.exitCode = 1;
});

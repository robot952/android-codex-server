"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

// Exercise the actual usage notification path without starting OpenCode or
// contacting a provider. Other legacy bridge tests still load Android assets.
const bridgePath = path.resolve(__dirname, "../flutter_app/assets/opencode-bridge.cjs");
const messages = [];
const context = vm.createContext({
  require,
  module: { exports: {} },
  Buffer,
  process: {
    argv: [], env: {}, cwd: () => process.cwd(), on: () => {},
    stdout: { write: line => messages.push(JSON.parse(line)) },
  },
});
vm.runInContext(fs.readFileSync(bridgePath, "utf8") + "\n" +
  "globalThis.fixture = { activeTurns, modelContextWindows, publishTokenUsageForInfo };", context,
  { filename: bridgePath });
const { activeTurns, modelContextWindows, publishTokenUsageForInfo } = context.fixture;

async function main() {
  const session = "fixture-session";
  activeTurns.set(session, { modelReference: "configured/never-used" });
  modelContextWindows.set("configured/never-used", 1000000);
  const info = (id, fields = {}) => ({
    id, sessionID: session, role: "assistant", tokens: { input: 100, output: 20 }, ...fields,
  });
  const publish = async value => {
    await publishTokenUsageForInfo(value, session);
    const event = messages.at(-1);
    assert.equal(event.method, "thread/tokenUsage/updated");
    assert.equal(event.params.requestMetrics.requestId, value.id);
    return event.params;
  };

  const unknown = await publish(info("unknown-initial"));
  assert.equal(unknown.requestMetrics.model, "", "configured active model is not request evidence");
  assert.equal(unknown.tokenUsage.modelContextWindow, 1000000, "context capacity fallback remains independent");

  const known = await publish(info("known", { providerID: " reported ", modelID: " actual-model " }));
  assert.equal(known.requestMetrics.model, "reported/actual-model");
  activeTurns.set(session, { modelReference: "configured/another-model" });
  const delayed = await publish(info("known", { providerID: "reported", modelID: "actual-model" }));
  assert.equal(delayed.requestMetrics.model, "reported/actual-model", "late message retains its reported model");

  assert.equal((await publish(info("unknown-after-known"))).requestMetrics.model, "");
  assert.equal((await publish(info("partial", { providerID: "reported", modelID: " " }))).requestMetrics.model, "");
  assert.equal((await publish(info("invalid", { providerID: {}, modelID: "actual-model" }))).requestMetrics.model, "");
  process.stdout.write("OpenCode request model attribution tests passed (6 usage snapshots)\n");
}

main().catch(error => { process.stderr.write(error.stack + "\n"); process.exitCode = 1; });

"use strict";

const assert = require("node:assert/strict");
const path = require("node:path");
const bridge = require(path.resolve(__dirname, "../app/src/main/assets/opencode-bridge.cjs"));

function deferred() {
  let resolve;
  const promise = new Promise(function (done) { resolve = done; });
  return { promise: promise, resolve: resolve };
}

function rpcLine(id, method) {
  return JSON.stringify({ id: id, method: method, params: {} });
}

function failAfter(milliseconds, message) {
  return new Promise(function (_, reject) {
    setTimeout(function () { reject(new Error(message)); }, milliseconds);
  });
}

async function interactiveRequestsDoNotWaitForListReads() {
  const listStarted = deferred();
  const releaseList = deferred();
  const events = [];
  const errors = [];
  const scheduler = bridge.createRpcLineScheduler(
    Promise.resolve(),
    function (line) {
      const method = JSON.parse(line).method;
      events.push(method);
      if (method === "model/list") {
        listStarted.resolve();
        return releaseList.promise;
      }
      return Promise.resolve();
    },
    function (error) { errors.push(error); },
  );

  scheduler.enqueue(rpcLine(1, "model/list"));
  await listStarted.promise;
  await Promise.race([
    scheduler.enqueue(rpcLine(2, "thread/start")),
    failAfter(250, "thread/start waited for a blocked model/list"),
  ]);
  assert.deepEqual(events, ["model/list", "thread/start"]);
  assert.deepEqual(errors, []);
  releaseList.resolve();
  await scheduler.idle();
}

async function configurationWritesRetainTheReadBarrier() {
  const listStarted = deferred();
  const releaseList = deferred();
  let writeStarted = false;
  const errors = [];
  const scheduler = bridge.createRpcLineScheduler(
    Promise.resolve(),
    function (line) {
      const method = JSON.parse(line).method;
      if (method === "thread/list") {
        listStarted.resolve();
        return releaseList.promise;
      }
      if (method === "agent/models/sync") writeStarted = true;
      return Promise.resolve();
    },
    function (error) { errors.push(error); },
  );

  scheduler.enqueue(rpcLine(1, "thread/list"));
  await listStarted.promise;
  const write = scheduler.enqueue(rpcLine(2, "agent/models/sync"));
  await new Promise(function (resolve) { setTimeout(resolve, 40); });
  assert.equal(writeStarted, false);
  releaseList.resolve();
  await write;
  assert.equal(writeStarted, true);
  assert.deepEqual(errors, []);
}

async function main() {
  assert.equal(bridge.isConcurrentReadLine(rpcLine(1, "model/list")), true);
  assert.equal(bridge.isConcurrentReadLine(rpcLine(2, "thread/start")), false);
  assert.equal(bridge.requiresConcurrentReadBarrier(rpcLine(3, "agent/models/sync")), true);
  assert.equal(bridge.requiresConcurrentReadBarrier(rpcLine(4, "thread/start")), false);
  await interactiveRequestsDoNotWaitForListReads();
  await configurationWritesRetainTheReadBarrier();
  process.stdout.write("OpenCode bridge scheduling tests passed\n");
}

main().catch(function (error) {
  process.stderr.write((error.stack || error.message || String(error)) + "\n");
  process.exitCode = 1;
});

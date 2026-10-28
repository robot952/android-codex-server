"use strict";
const assert = require("node:assert/strict");
const { RequestMetricsCollector, lineObserver } = require("../flutter_app/assets/codex-request-metrics.cjs");
// Deliberately synthetic events only. No provider connection, credentials or
// user logs. Native-core loopback integration is a separate opt-in fixture.
const base = Date.UTC(2026, 9, 28, 12);
const usage = (multiple = 1) => ({ inputTokens: 100 * multiple, outputTokens: 20 * multiple,
  cachedInputTokens: 50 * multiple, reasoningOutputTokens: 2 * multiple, totalTokens: 120 * multiple });
const event = (name, time, attributes = {}, thread = "thread") => ({ attributes: Object.entries({
  "event.name": name, "event.timestamp": new Date(base + time).toISOString(),
  "conversation.id": thread, model: "fixture-model", ...attributes,
}).map(([key, value]) => ({ key, value: { stringValue: String(value) } })) });
const start = (at, thread = "thread") => event("codex.api_request", at + 50,
  { duration_ms: "50", "http.response.status_code": 200, endpoint: "/responses" }, thread);
const end = (at, thread = "thread") => event("codex.sse_event", at, { "event.kind": "response.completed",
  input_token_count: 100, output_token_count: 20, cached_token_count: 50,
  reasoning_token_count: 2, tool_token_count: 120, ttft_ms: 0 }, thread);
const envelope = records => ({ resourceLogs: [{ scopeLogs: [{ logRecords: records }] }] });
const text = (at, item = "message", turn = "turn", thread = "thread") => ({
  method: "item/agentMessage/delta", emittedAtMs: base + at,
  params: { threadId: thread, turnId: turn, itemId: item, delta: "Synthetic output" },
});
const counters = (at, multiple = 1, turn = "turn", thread = "thread") => ({
  method: "thread/tokenUsage/updated", emittedAtMs: base + at,
  params: { threadId: thread, turnId: turn, tokenUsage: { last: usage(), total: usage(multiple) } },
});
let assertions = 0;
function scenario(name, run) {
  const messages = [];
  const collector = new RequestMetricsCollector(value => messages.push(value));
  run(collector, messages);
  assertions++;
  console.log(`PASS ${name}`);
}
scenario("late server telemetry is independent of phone delivery and deduplicated", (collector, messages) => {
  collector.notification(text(300));
  collector.notification(counters(610));
  assert.equal(messages.length, 0);
  collector.telemetry(envelope([start(0), end(600)]));
  assert.deepEqual(messages[0].params.requestMetrics, { source: "server", startedAtMillis: base,
    firstTokenMillis: 300, durationMillis: 600, model: "fixture-model" });
  collector.telemetry(envelope([start(0), end(600)]));
  collector.notification(counters(200000));
  assert.equal(messages.length, 1);
  assert.equal(messages[0].method, "thread/requestMetrics/updated");
  assert.equal(messages[0].params.requestMetrics.requestId, undefined);
  assert.deepEqual(messages[0].params.tokenUsage.total, usage());
});
scenario("telemetry can arrive before JSONL and first delta can arrive last", (collector, messages) => {
  collector.telemetry(envelope([start(0), end(600)]));
  collector.notification(counters(610));
  assert.equal(messages[0].params.requestMetrics.firstTokenMillis, null);
  collector.notification(text(300));
  assert.equal(messages[1].params.requestMetrics.firstTokenMillis, 300);
});
scenario("two requests exclude intervening tool execution and retain equal-count identities", (collector, messages) => {
  collector.notification(text(300)); collector.notification(counters(610));
  collector.notification({ ...text(3000, "tool"), method: "item/commandExecution/outputDelta" });
  collector.notification(text(5300, "message-2")); collector.notification(counters(5610, 2));
  collector.telemetry(envelope([start(0), end(600), start(5000), end(5600)]));
  assert.equal(messages.length, 2);
  assert.deepEqual(messages.map(x => x.params.requestMetrics.firstTokenMillis), [300, 300]);
  assert.deepEqual(messages.map(x => x.params.requestMetrics.durationMillis), [600, 600]);
  assert.deepEqual(messages.map(x => x.params.tokenUsage.total.totalTokens), [120, 240]);
});
scenario("WS prewarm is not confused with actual equal-count request", (collector, messages) => {
  const ws = at => event("codex.websocket_request", at, { duration_ms: 0, success: true });
  collector.notification(text(1300)); collector.notification(counters(1610));
  collector.telemetry(envelope([ws(0), end(600), ws(1000), end(1600)]));
  assert.equal(messages.length, 1);
  assert.equal(messages[0].params.requestMetrics.startedAtMillis, base + 1000);
  assert.equal(messages[0].params.requestMetrics.firstTokenMillis, 300);
});
scenario("retry/fallback restarts timing and unknown starts never become turn timing", (collector, messages) => {
  collector.telemetry(envelope([event("codex.api_request", 10, { duration_ms: 10, "http.response.status_code": 503, endpoint: "/responses" }), start(1000), end(1600)]));
  collector.notification(text(1300)); collector.notification(counters(1610));
  assert.equal(messages[0].params.requestMetrics.durationMillis, 600);
  collector.notification(counters(4000, 2));
  collector.telemetry(envelope([end(3990)]));
  assert.equal(messages.length, 1);
});
scenario("thread and turn isolation, no prompt or tool-output retention", (collector, messages) => {
  collector.notification(text(100, "wrong-turn", "previous"));
  collector.notification(text(120, "wrong-thread", "turn", "other"));
  collector.notification(text(300)); collector.notification(counters(610));
  collector.telemetry(envelope([event("codex.tool_result", 20, { output: "private-content" }), start(0), end(600)]));
  assert.equal(messages[0].params.requestMetrics.firstTokenMillis, 300);
  assert(!JSON.stringify([...collector.threads]).includes("private-content"));
  assert(!JSON.stringify([...collector.threads]).includes("Synthetic output"));
});
scenario("missing timestamps, non-text and empty deltas never manufacture TTFT", (collector, messages) => {
  collector.notification({ ...text(10), emittedAtMs: undefined });
  collector.notification({ ...text(20), params: { ...text(20).params, delta: " " } });
  collector.notification({ ...text(30), method: "item/started" });
  collector.notification(counters(610));
  collector.telemetry(envelope([start(0), end(600)]));
  assert.equal(messages[0].params.requestMetrics.firstTokenMillis, null);
});
scenario("historical usage and invalid clocks/counts stay unavailable", (collector, messages) => {
  const history = counters(610); history.params.requestMetrics = { historical: true };
  collector.notification(history);
  collector.telemetry(envelope([start(0), end(600)]));
  assert.equal(messages.length, 0);
  const invalid = counters(610); invalid.params.tokenUsage.last.inputTokens = -1;
  collector.notification(invalid);
  assert.equal(messages.length, 0);
});
scenario("delayed start/end export is reconciled in source time order", (collector, messages) => {
  collector.notification(text(300)); collector.notification(counters(610));
  collector.telemetry(envelope([end(600)]));
  assert.equal(messages.length, 0);
  collector.telemetry(envelope([start(0)]));
  assert.equal(messages[0].params.requestMetrics.firstTokenMillis, 300);
});
scenario("unknown OTLP fields and bounded thread state", collector => {
  for (let i = 0; i < 200; i++) collector.notification(text(100, "message", "turn", `thread-${i}`));
  assert.equal(collector.threads.size, 128);
});
scenario("JSONL inspection handles chunk boundaries and oversized lines", () => {
  const values = [];
  const observe = lineObserver(x => values.push(x), 32);
  observe('{"one":'); observe('1}\n{"two":2}\n');
  observe('x'.repeat(100)); observe('\n{"three":3}\n');
  assert.deepEqual(values, [{ one: 1 }, { two: 2 }, { three: 3 }]);
});
console.log(`${assertions} server request-metrics scenarios passed`);

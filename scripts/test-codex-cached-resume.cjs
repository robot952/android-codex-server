// Offline native-protocol check: isolated HOME, no authentication or model call.
const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const readline = require('node:readline');

const binary = process.env.CODEX_CACHED_RESUME_TEST_BIN;
if (!binary) throw new Error('Set CODEX_CACHED_RESUME_TEST_BIN to an installed Codex binary');
const fixtureHome = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-cache-fixture-'));
const children = [];
function start() {
  const config = {
    model_provider: 'fixture', model: 'fixture',
    'model_providers.fixture.name': 'fixture',
    'model_providers.fixture.base_url': 'http://127.0.0.1:1/v1',
    'model_providers.fixture.wire_api': 'responses',
    'model_providers.fixture.requires_openai_auth': false,
    'model_providers.fixture.supports_websockets': false,
  };
  const args = Object.entries(config).flatMap(([k, v]) => ['-c', `${k}=${JSON.stringify(v)}`]);
  args.push('app-server', '--listen', 'stdio://');
  const child = spawn(binary, args, { cwd: fixtureHome,
    env: { PATH: process.env.PATH, HOME: fixtureHome, CODEX_HOME: fixtureHome, RUST_LOG: 'error' },
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  children.push(child);
  child.stderr.resume();
  let id = 0;
  const pending = new Map();
  const send = v => child.stdin.write(`${JSON.stringify(v)}\n`);
  readline.createInterface({ input: child.stdout }).on('line', line => {
    const message = JSON.parse(line);
    pending.get(message.id)?.(message);
  });
  return { send, async rpc(method, params = {}) {
    const requestId = ++id;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        pending.delete(requestId);
        reject(new Error(`${method} timed out`));
      }, 15000);
      pending.set(requestId, result => {
        clearTimeout(timer); pending.delete(requestId); resolve(result);
      });
      send({ id: requestId, method, params });
    });
  } };
}
async function initialize(client) {
  const response = await client.rpc('initialize', {
    clientInfo: { name: 'cache_fixture', version: '1' }, capabilities: { experimentalApi: true },
  });
  assert.ok(!response.error);
  client.send({ method: 'initialized', params: {} });
}
async function main() {
  const owner = start();
  await initialize(owner);
  const started = await owner.rpc('thread/start', {
    cwd: fixtureHome, approvalPolicy: 'never', sandbox: 'danger-full-access',
  });
  assert.ok(!started.error);
  const threadId = started.result.thread.id;
  const executed = await owner.rpc('thread/shellCommand', {
    threadId, command: `printf '${'cache_fixture '.repeat(2000)}'`, timeoutMs: 1000,
  });
  assert.ok(!executed.error);
  // shellCommand accepts before its history transaction has been flushed.
  await new Promise(resolve => setTimeout(resolve, 1000));
  const full = await owner.rpc('thread/resume', {
    threadId, excludeTurns: true,
    initialTurnsPage: { itemsView: 'full', limit: 1, sortDirection: 'desc' },
  });
  assert.ok(!full.error, JSON.stringify(full.error));
  const metadata = await owner.rpc('thread/resume', { threadId, excludeTurns: true });
  assert.ok(!metadata.error);
  assert.equal(metadata.result.thread.id, threadId);
  assert.equal(metadata.result.thread.turns.length, 0);
  assert.ok(!metadata.result.initialTurnsPage);
  const fullBytes = Buffer.byteLength(JSON.stringify(full));
  const metadataBytes = Buffer.byteLength(JSON.stringify(metadata));
  assert.ok(fullBytes > metadataBytes * 5);
  const observer = start();
  await initialize(observer);
  const conflict = await observer.rpc('thread/resume', { threadId, excludeTurns: true });
  assert.equal(conflict.error?.code, -32600);
  assert.match(conflict.error.message, /writer/);
  console.log(JSON.stringify({ fullBytes, metadataBytes, writerConflictVerified: true, modelCalls: 0 }));
}
main().catch(error => { console.error(error); process.exitCode = 1; }).finally(async () => {
  await Promise.all(children.map(child => new Promise(resolve => {
    if (child.exitCode !== null) return resolve();
    const timer = setTimeout(() => child.kill('SIGKILL'), 1000);
    child.once('exit', () => { clearTimeout(timer); resolve(); });
    child.kill('SIGTERM');
  })));
  fs.rmSync(fixtureHome, { recursive: true, force: true });
});

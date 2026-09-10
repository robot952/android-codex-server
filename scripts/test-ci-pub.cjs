const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const root = path.resolve(__dirname, '..');
fs.mkdirSync(path.join(root, '.workflow-cache'), { recursive: true });
const fixture = fs.mkdtempSync(path.join(root, '.workflow-cache/test-ci-pub.'));
const lock = `packages:
  synchronized:
    description:
      name: synchronized
      sha256: "${'a'.repeat(64)}"
      url: "https://pub.dev"
    source: hosted
    version: "3.4.1+1"
  private_package:
    description:
      url: "https://private.example"
    version: "1.0.0"
`;
const runner = path.join(fixture, 'flutter');
fs.writeFileSync(runner, `#!/usr/bin/env node
const fs = require('node:fs');
const source = process.env.PUB_HOSTED_URL;
fs.appendFileSync('calls', JSON.stringify({source, args: process.argv.slice(2), lock: fs.readFileSync('pubspec.lock', 'utf8')}) + '\\n');
const scenario = process.env.PUB_TEST_SCENARIO;
if (scenario === 'hash') { console.log('Content hash changed for synchronized'); process.exit(65); }
if (scenario === 'solver') { console.log('Because dependency versions conflict, version solving failed.'); process.exit(1); }
if (scenario === 'auth') { console.log('401 Unauthorized trying to find package private_package'); process.exit(69); }
if (scenario === 'success' || (scenario === 'fallback' && source === 'https://pub.dev')) { console.log('Got dependencies!'); process.exit(0); }
console.log('424 Failed Dependency trying to find package synchronized at ' + source);
process.exit(69);
`, { mode: 0o755 });

function run(name, scenario, source = 'https://pub.flutter-io.cn') {
  const project = path.join(fixture, name);
  fs.mkdirSync(project);
  fs.writeFileSync(path.join(project, 'pubspec.lock'), lock, { mode: 0o640 });
  fs.writeFileSync(path.join(project, 'pubspec.yaml'), 'name: fixture\n');
  fs.mkdirSync(path.join(project, 'cache'));
  fs.writeFileSync(path.join(project, 'cache/sentinel'), 'keep');
  const result = spawnSync('bash', [path.join(root, 'scripts/prepare-ci-pub.sh'), runner, project], {
    env: {...process.env, PUB_TEST_SCENARIO: scenario, PUB_HOSTED_URL: source},
    encoding: 'utf8', timeout: 10000,
  });
  if (result.error) throw result.error;
  assert.equal(fs.readFileSync(path.join(project, 'pubspec.lock'), 'utf8'), lock);
  assert.equal(fs.statSync(path.join(project, 'pubspec.lock')).mode & 0o777, 0o640);
  assert.equal(fs.readFileSync(path.join(project, 'cache/sentinel'), 'utf8'), 'keep');
  assert.ok(!fs.readdirSync(project).some(name => name.startsWith('.ci-pub.')));
  const calls = fs.readFileSync(path.join(project, 'calls'), 'utf8').trim().split('\n').map(JSON.parse);
  calls.forEach(call => {
    assert.deepEqual(call.args, ['pub', 'get', '--enforce-lockfile']);
    assert.match(call.lock, /version: "3.4.1\+1"/);
    assert.ok(call.lock.includes('a'.repeat(64)));
    assert.match(call.lock, /url: "https:\/\/private.example"/);
  });
  return {...result, calls};
}

try {
  const success = run('success', 'success');
  assert.equal(success.status, 0, success.stdout + success.stderr);
  assert.equal(success.calls.length, 1);
  assert.match(success.calls[0].lock, /url: "https:\/\/pub.flutter-io.cn"/);

  const fallback = run('fallback', 'fallback');
  assert.equal(fallback.status, 0, fallback.stdout + fallback.stderr);
  assert.deepEqual(fallback.calls.map(call => call.source), ['https://pub.flutter-io.cn', 'https://pub.flutter-io.cn', 'https://pub.dev']);
  assert.equal(fallback.calls[2].lock, lock);

  const failed = run('failed', 'failed');
  assert.equal(failed.status, 69);
  assert.equal(failed.calls.length, 4);
  for (const scenario of ['hash', 'solver', 'auth']) {
    const stopped = run(scenario, scenario);
    assert.notEqual(stopped.status, 0);
    assert.equal(stopped.calls.length, 1);
  }
  const privateHost = run('private', 'failed', 'https://private.example');
  assert.equal(privateHost.status, 69);
  assert.deepEqual(privateHost.calls.map(call => call.source), ['https://private.example', 'https://private.example']);
  assert.equal(privateHost.calls[0].lock, lock);
  console.log('CI Pub tests passed: mirror retry/fallback, locked versions/hashes, no private-host fallback, failure cleanup');
} finally {
  fs.rmSync(fixture, { recursive: true, force: true });
}

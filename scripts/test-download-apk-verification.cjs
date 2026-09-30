#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const { test } = require('node:test');
const http = require('node:http');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { createHash } = require('node:crypto');
const { spawn } = require('node:child_process');
const { downloadForVerification } = require('./download-apk-verification.cjs');

const bytes = Buffer.from('signed APK fixture\n'.repeat(14000));
const hash = createHash('sha256').update(bytes).digest('hex');

async function fixture(t, mode) {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'apk-verify-test-'));
  const output = path.join(directory, 'verified.apk');
  await fs.writeFile(output, 'previous verified output');
  const requests = [];
  const timers = new Set();
  const attempts = new Map();
  let active = 0;
  let maximumActive = 0;
  const later = (callback, delay = 15) => {
    const timer = setTimeout(() => { timers.delete(timer); callback(); }, delay);
    timers.add(timer);
  };
  const server = http.createServer((request, response) => {
    requests.push({ range: request.headers.range, ifRange: request.headers['if-range'], path: request.url });
    if (mode === 'redirect' && request.url === '/artifact') {
      response.writeHead(302, { Location: '/file' });
      response.end();
      return;
    }
    if (!request.headers.range) {
      if (mode === 'not-found') { response.writeHead(404); response.end(); return; }
      if (mode === 'direct' || mode === 'direct-hash' || mode === 'direct-size' || mode === 'redirect') {
        const payload = mode === 'direct-hash' ? Buffer.alloc(bytes.length) : bytes;
        response.writeHead(200, { 'Content-Length': mode === 'direct-size' ? bytes.length + 1 : bytes.length });
        response.end(payload);
        return;
      }
      if (mode === 'partial-direct') {
        response.writeHead(200);
        response.end(bytes.subarray(0, 7));
        return;
      }
      // Deliberately stall the normal transfer to exercise the bounded fallback.
      return;
    }
    const match = /^bytes=(\d+)-(\d+)$/.exec(request.headers.range);
    assert.ok(match);
    const start = Number(match[1]);
    const end = Number(match[2]);
    const isProbe = start === 0 && end === 0;
    const count = (attempts.get(request.headers.range) || 0) + 1;
    attempts.set(request.headers.range, count);
    if (mode === 'range-deadline' && !isProbe) return;
    if ((mode === 'failed-chunk' || mode === 'retry-chunk') && !isProbe && start === 0 && (mode === 'failed-chunk' || count === 1)) {
      response.writeHead(503); response.end(); return;
    }
    const total = mode === 'wrong-total' ? bytes.length + 1 : bytes.length;
    const rangeStart = (mode === 'bad-probe' && isProbe) || (mode === 'bad-chunk' && !isProbe) ? start + 1 : start;
    const headers = {
      'Content-Range': `bytes ${rangeStart}-${end}/${total}`,
      ETag: mode === 'weak-etag' ? 'W/"fixture"' : mode === 'changed-etag' && !isProbe ? '"changed"' : '"fixture"',
    };
    if (mode === 'no-etag') delete headers.ETag;
    let payload = Buffer.from(bytes.subarray(start, end + 1));
    if (mode === 'range-hash' && !isProbe && start === 0) payload[0] ^= 1;
    if (mode === 'oversize' && !isProbe) payload = Buffer.concat([payload, Buffer.from('extra')]);
    if (mode === 'short-chunk' && !isProbe) payload = payload.subarray(0, payload.length - 1);
    if (!['oversize', 'short-chunk'].includes(mode)) headers['Content-Length'] = payload.length;
    if ((mode === 'ignored-probe' && isProbe) || (mode === 'ignored-chunk' && !isProbe)) {
      response.writeHead(200, headers); response.end(payload); return;
    }
    active++;
    maximumActive = Math.max(maximumActive, active);
    response.once('close', () => { active--; });
    later(() => { response.writeHead(206, headers); response.end(payload); });
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  t.after(async () => {
    for (const timer of timers) clearTimeout(timer);
    server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
    await fs.rm(directory, { recursive: true, force: true });
  });
  return {
    directory, output, requests, attempts,
    options: { url: `http://127.0.0.1:${server.address().port}/artifact`, output, size: bytes.length, hash, directTimeoutMs: 60, rangeTimeoutMs: 1500 },
    maximumActive: () => maximumActive,
  };
}

async function checkClean(f, success) {
  assert.deepEqual(await fs.readdir(f.directory), ['verified.apk']);
  assert.deepEqual(await fs.readFile(f.output), success ? bytes : Buffer.from('previous verified output'));
}

for (const mode of ['direct', 'redirect', 'partial-direct', 'fallback', 'no-etag', 'retry-chunk']) {
  test(`verified download: ${mode}`, async (t) => {
    const f = await fixture(t, mode);
    const result = await downloadForVerification(f.options);
    assert.equal(result.mode, ['direct', 'redirect'].includes(mode) ? 'direct' : 'ranges');
    assert.equal(result.bytes, bytes.length);
    assert.ok(result.elapsedMs >= 0);
    assert.ok(f.maximumActive() <= 4);
    if (result.mode === 'ranges') {
      assert.ok(f.requests.some((request) => request.range === 'bytes=0-0'));
      if (mode !== 'no-etag') {
        assert.ok(f.requests.filter((request) => request.range && request.range !== 'bytes=0-0').every((request) => request.ifRange === '"fixture"'));
      }
      if (mode === 'retry-chunk') assert.equal(f.attempts.get(`bytes=0-${Math.ceil(bytes.length / 4) - 1}`), 2);
    }
    await checkClean(f, true);
  });
}

for (const [mode, error] of [
  ['not-found', /HTTP status 404/],
  ['direct-hash', /SHA-256/],
  ['direct-size', /Content-Length/],
  ['failed-chunk', /HTTP status 503/],
  ['wrong-total', /Content-Range/],
  ['bad-probe', /Content-Range/],
  ['bad-chunk', /Content-Range/],
  ['ignored-probe', /HTTP status 200/],
  ['ignored-chunk', /HTTP status 200/],
  ['changed-etag', /ETag changed/],
  ['weak-etag', /strong ETag/],
  ['oversize', /expected size/],
  ['short-chunk', /ended before the expected size/],
  ['range-hash', /SHA-256/],
]) {
  test(`reject and preserve previous output: ${mode}`, async (t) => {
    const f = await fixture(t, mode);
    await assert.rejects(downloadForVerification(f.options), error);
    if (['not-found', 'direct-hash', 'direct-size'].includes(mode)) assert.equal(f.requests.length, 1);
    if (mode === 'failed-chunk') assert.equal(f.attempts.get(`bytes=0-${Math.ceil(bytes.length / 4) - 1}`), 2);
    await checkClean(f, false);
  });
}

test('one absolute range deadline cancels all workers', async (t) => {
  const f = await fixture(t, 'range-deadline');
  const start = performance.now();
  await assert.rejects(downloadForVerification({ ...f.options, rangeTimeoutMs: 90 }), /deadline exceeded/);
  assert.ok(performance.now() - start < 800);
  await checkClean(f, false);
});

test('caller cancellation cleans up without fallback or output replacement', async (t) => {
  const f = await fixture(t, 'fallback');
  const controller = new AbortController();
  const promise = downloadForVerification({ ...f.options, signal: controller.signal });
  setTimeout(() => controller.abort(new Error('caller cancelled')), 10);
  await assert.rejects(promise, /caller cancelled/);
  assert.ok(f.requests.every((request) => !request.range));
  await checkClean(f, false);
});

test('explicitly disabled fallback preserves direct timeout failure', async (t) => {
  const f = await fixture(t, 'fallback');
  await assert.rejects(downloadForVerification({ ...f.options, fallback: false }), /timed out/);
  assert.equal(f.requests.length, 1);
  await checkClean(f, false);
});

test('CLI rejects invalid timeout without attempting a download', async (t) => {
  const f = await fixture(t, 'direct');
  const result = await new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [path.join(__dirname, 'download-apk-verification.cjs'), f.options.url, f.output, String(bytes.length), hash], {
      env: { ...process.env, CODEX_LOCAL_VERIFY_TIMEOUT: 'Infinity' }, stdio: ['ignore', 'pipe', 'pipe'],
    });
    let stderr = '';
    child.stderr.on('data', (chunk) => { stderr += chunk; });
    child.once('error', reject);
    child.once('exit', (code) => resolve({ code, stderr }));
  });
  assert.equal(result.code, 1);
  assert.match(result.stderr, /at most 900/);
  assert.equal(f.requests.length, 0);
  assert.ok(!result.stderr.includes(f.options.url));
  await checkClean(f, false);
});

test('CLI verifies through the same bounded range fallback', async (t) => {
  const f = await fixture(t, 'fallback');
  const result = await new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [path.join(__dirname, 'download-apk-verification.cjs'), f.options.url, f.output, String(bytes.length), hash], {
      env: { ...process.env, CODEX_LOCAL_VERIFY_TIMEOUT: '0.06', CODEX_LOCAL_RANGE_TIMEOUT: '1.5', CODEX_LOCAL_RANGE_FALLBACK: '1' },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (chunk) => { stdout += chunk; });
    child.stderr.on('data', (chunk) => { stderr += chunk; });
    child.once('error', reject);
    child.once('exit', (code) => resolve({ code, stdout, stderr }));
  });
  assert.equal(result.code, 0, result.stderr);
  assert.match(result.stdout, /mode=ranges bytes=\d+ elapsedMs=\d+/);
  await checkClean(f, true);
});

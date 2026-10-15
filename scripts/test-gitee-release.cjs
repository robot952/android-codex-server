#!/usr/bin/env node
'use strict';

// Loopback-only regression gate. No real token, hosting service or APK build.
const assert = require('node:assert/strict');
const http = require('node:http');
const { createHash } = require('node:crypto');
const { once } = require('node:events');
const { createPublisher } = require('./publish-gitee-artifact.cjs');

const token = 'fixture-release-token-not-a-secret';
const bytes = Buffer.from('fixture APK bytes; never an installable package');
const artifact = { tag: 'v1.2.3', name: 'Agent-1.2.3.apk', bytes,
  hash: createHash('sha256').update(bytes).digest('hex'), commit: 'a'.repeat(40),
  notes: '- `aaaaaaa` 发布回归 fixture' };
const repoPath = '/api/v5/repos/fixture/repo';

async function fixture(options, check) {
  const state = { requests: [], logs: [], creates: 0, uploads: 0, downloads: 0,
    attached: !!options.existingAsset, created: !!options.existingRelease };
  const release = () => ({ name: 'fixture', id: 42, tag_name: options.wrongTag || artifact.tag,
    prerelease: !!options.prerelease,
    body: `<!-- apk-sha256:${options.conflictingHash || artifact.hash} -->`,
    assets: state.attached ? [{ name: artifact.name }] : [] });
  const server = http.createServer(async (req, res) => {
    try {
      const url = new URL(req.url, 'http://127.0.0.1');
      const chunks = [];
      for await (const chunk of req) chunks.push(chunk);
      const body = Buffer.concat(chunks).toString('utf8');
      state.requests.push({ method: req.method, pathname: url.pathname,
        query: url.search, body, authorization: req.headers.authorization,
        cookie: req.headers.cookie });
      const json = (code, value) => {
        res.writeHead(code, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(value));
      };
      if (url.pathname === repoPath) {
        assert.equal(url.searchParams.get('access_token'), token);
        if (options.hang) return;
        if (options.redirectApi) {
          res.writeHead(302, { Location: '/should-not-follow' });
          return res.end();
        }
        if (options.authFailure) return json(401, { message: token });
        return json(200, { full_name: 'fixture/repo', permission: { push: !options.readOnly } });
      }
      if (url.pathname === `${repoPath}/releases/tags/${artifact.tag}`) {
        if (options.invalidJson) { res.writeHead(200); return res.end(token); }
        if (!state.created) return json(404, {});
        return json(200, release());
      }
      if (url.pathname === `${repoPath}/releases` && req.method === 'POST') {
        state.creates++;
        const form = new URLSearchParams(body);
        assert.equal(form.get('access_token'), token);
        assert.equal(form.get('tag_name'), artifact.tag);
        assert.equal(form.get('target_commitish'), artifact.commit);
        assert.equal(form.get('prerelease'), 'false');
        assert.ok(form.get('body').includes(artifact.hash));
        if (options.createFailure) return json(403, { message: token });
        state.created = true;
        return json(201, release());
      }
      if (url.pathname === `${repoPath}/releases/42/attach_files` && req.method === 'POST') {
        state.uploads++;
        assert.match(req.headers['content-type'], /^multipart\/form-data; boundary=/);
        assert.ok(body.includes(token));
        assert.ok(body.includes(`filename="${artifact.name}"`));
        assert.ok(body.includes(bytes.toString('utf8')));
        if (options.uploadFailure) return json(500, { message: token });
        state.attached = true;
        return json(201, { name: artifact.name, id: 93, size: bytes.length });
      }
      if (url.pathname.includes('/releases/download/') || url.pathname === '/cdn-apk') {
        state.downloads++;
        assert.equal(url.search, '');
        assert.equal(req.headers.authorization, undefined);
        assert.equal(req.headers.cookie, undefined);
        if (options.downloadHang) { res.writeHead(200); res.write(bytes.subarray(0, 1)); return; }
        if (options.redirectDownload && url.pathname !== '/cdn-apk') {
          res.writeHead(302, { Location: '/cdn-apk' });
          return res.end();
        }
        if (options.tokenRedirect) {
          res.writeHead(302, { Location: `/cdn-apk?access_token=${token}` });
          return res.end();
        }
        res.writeHead(200);
        return res.end(options.badDownload ? Buffer.alloc(bytes.length) : bytes);
      }
      return json(404, { message: 'unexpected route' });
    } catch (error) {
      state.handlerError = error;
      res.writeHead(500);
      res.end('fixture assertion failed');
    }
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const base = `http://127.0.0.1:${server.address().port}`;
  const publisher = createPublisher({ token, owner: 'fixture', repo: 'repo',
    apiBase: `${base}/api/v5`, webBase: base,
    apiTimeoutMs: options.hang ? 100 : 3000,
    transferTimeoutMs: options.downloadHang ? 100 : 3000,
    log: line => state.logs.push(line) });
  try {
    await check(publisher, state);
    assert.equal(state.handlerError, undefined);
    assert.ok(!state.logs.join('\n').includes(token));
    assert.ok(state.requests.every(r => !['DELETE', 'PATCH'].includes(r.method)));
    assert.ok(state.requests.every(r => !r.pathname.endsWith('/tags')));
    assert.ok(state.requests.every(r => r.pathname !== '/api/v5/user'));
  } finally {
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
  }
}

async function main() {
  for (const empty of [undefined, '', '  \n']) {
    assert.throws(() => createPublisher({ token: empty }), /CODEX_RELEASE_TOKEN/);
  }
  assert.throws(() => createPublisher({ token, apiBase: 'http://gitee.com/api/v5' }), /HTTPS/);
  assert.throws(() => createPublisher({ token, owner: '../repo' }), /Invalid release repository/);
  await fixture({}, async (publisher, state) => {
    await publisher.preflight();
    assert.equal(state.creates, 0);
    const result = await publisher.publish(artifact);
    assert.equal(result.sha256, artifact.hash);
    assert.equal(state.creates, 1);
    assert.equal(state.uploads, 1);
    assert.equal(state.downloads, 1);
    assert.ok(state.requests.some(r => r.pathname.endsWith(`/tags/${artifact.tag}`) && !r.query));
    await publisher.publish(artifact);
    assert.equal(state.creates, 1);
    assert.equal(state.uploads, 1);
    assert.equal(state.downloads, 2);
  });
  await fixture({ existingRelease: true }, async (publisher, state) => {
    await publisher.publish(artifact);
    assert.equal(state.creates, 0);
    assert.equal(state.uploads, 1);
  });
  await fixture({ existingRelease: true, existingAsset: true, redirectDownload: true },
    async (publisher, state) => {
      await publisher.publish(artifact);
      assert.equal(state.creates, 0);
      assert.equal(state.uploads, 0);
      assert.equal(state.downloads, 2);
    });
  for (const [options, pattern] of [
    [{ authFailure: true }, /HTTP 401/],
    [{ readOnly: true }, /write permission/],
    [{ redirectApi: true }, /HTTP 302/],
    [{ hang: true }, /timed out/],
  ]) {
    await fixture(options, async (publisher, state) => {
      await assert.rejects(publisher.preflight(), pattern);
      assert.equal(state.creates, 0);
      assert.equal(state.uploads, 0);
      assert.ok(!state.requests.some(r => r.pathname === '/should-not-follow'));
    });
  }
  for (const [options, pattern] of [
    [{ createFailure: true }, /HTTP 403/],
    [{ uploadFailure: true }, /HTTP 500/],
    [{ invalidJson: true }, /invalid JSON/],
    [{ existingRelease: true, wrongTag: 'v1.0.0' }, /invalid or non-stable/],
    [{ existingRelease: true, prerelease: true }, /invalid or non-stable/],
    [{ existingRelease: true, conflictingHash: 'b'.repeat(64) }, /different APK/],
    [{ existingRelease: true, existingAsset: true, badDownload: true }, /SHA-256/],
    [{ existingRelease: true, existingAsset: true, tokenRedirect: true }, /credential-bearing/],
    [{ existingRelease: true, existingAsset: true, downloadHang: true }, /timed out/],
  ]) {
    await fixture(options, async (publisher, state) => {
      await assert.rejects(publisher.publish(artifact), error => {
        assert.match(error.message, pattern);
        assert.ok(!error.message.includes(token));
        return true;
      });
      assert.ok(!state.logs.some(line => line.includes('Published and verified:')));
      assert.ok(state.uploads <= 1);
    });
  }
  await fixture({}, async (publisher, state) => {
    await assert.rejects(publisher.publish({ ...artifact, hash: 'b'.repeat(64) }), /Invalid release artifact/);
    assert.equal(state.requests.length, 0);
  });
  console.log('Gitee Release creation, upload, idempotency, public SHA-256, token isolation and timeout regressions passed');
}

main().catch(error => { console.error(error); process.exitCode = 1; });

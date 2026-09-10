const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const { execFile } = require('node:child_process');
const { promisify } = require('node:util');

const [prepare, archivePath, revision, sha, root] = process.argv.slice(2);
const archive = fs.readFileSync(archivePath);
const requests = new Map();
const server = http.createServer((req, res) => {
  const seen = requests.get(req.url) || [];
  seen.push(req.headers.range || '');
  requests.set(req.url, seen);
  if (req.url === '/corrupt') {
    res.end('corrupted archive');
    return;
  }
  if (req.url === '/deferred' && seen.length > 1 && seen.length <= 3) {
    res.writeHead(503).end();
    return;
  }
  if (req.url === '/no-range' && req.headers.range) {
    res.writeHead(416).end();
    return;
  }
  const start = Number((req.headers.range || '').match(/bytes=(\d+)-/)?.[1] || 0);
  res.setHeader('Content-Length', archive.length - start);
  if (start) {
    res.statusCode = 206;
    res.setHeader('Content-Range', `bytes ${start}-${archive.length - 1}/${archive.length}`);
  }
  if (['/interrupted', '/deferred'].includes(req.url) && seen.length === 1) {
    res.write(archive.subarray(0, Math.floor(archive.length / 2)));
    setTimeout(() => res.destroy(), 30);
  } else {
    res.end(archive.subarray(start));
  }
});

async function main() {
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  const run = (name) => promisify(execFile)('bash', [
    prepare, path.join(root, name), '1.2.3', revision, `${base}/${name}`, sha,
  ], { env: { ...process.env, NO_PROXY: '127.0.0.1', no_proxy: '127.0.0.1' }, timeout: 15000 });
  try {
    const resumed = await run('interrupted');
    assert.ok(fs.existsSync(path.join(resumed.stdout.trim(), 'bin/flutter')));
    assert.equal(requests.get('/interrupted').length, 2);
    assert.match(requests.get('/interrupted')[1], /^bytes=[1-9]\d*-$/);

    await assert.rejects(run('deferred'));
    const deferredPart = path.join(root, 'deferred', `flutter-1.2.3-${sha}.tar.xz.part`);
    assert.ok(fs.statSync(deferredPart).size > 0);
    await run('deferred');
    assert.equal(requests.get('/deferred').length, 4);
    assert.match(requests.get('/deferred')[3], /^bytes=[1-9]\d*-$/);

    const noRangeCache = path.join(root, 'no-range');
    fs.mkdirSync(noRangeCache);
    fs.writeFileSync(path.join(noRangeCache, `flutter-1.2.3-${sha}.tar.xz.part`), archive.subarray(0, 64));
    await run('no-range');
    assert.deepEqual(requests.get('/no-range'), ['bytes=64-', '']);

    await assert.rejects(run('corrupt'));
    assert.equal(requests.get('/corrupt').length, 3);
    assert.equal(fs.existsSync(path.join(root, 'corrupt', `sdk-${revision}`)), false);
    console.log('Flutter HTTP tests passed: interrupted/cross-job resume, range fallback, checksum rejection');
  } finally {
    await new Promise(resolve => server.close(resolve));
  }
}
main().catch(error => { console.error(error); process.exitCode = 1; });

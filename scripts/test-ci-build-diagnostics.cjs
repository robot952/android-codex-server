#!/usr/bin/env node
'use strict';

// Cloud-only fixtures: no network, SDK execution or APK build.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { seconds, parseProfile, collectProfiles, cacheSizes } = require('./collect-ci-build-diagnostics.cjs');
const fixture = fs.mkdtempSync(path.join(os.tmpdir(), 'ci-build-diagnostics-'));
try {
  const html = '<header>fixture-secret URL and arguments</header><table>' +
    '<tr><td>Total Build Time</td><td class="numeric">1m30.500s</td></tr>' +
    '<tr><td>All dependencies</td><td class="numeric">10.250s</td></tr>' +
    '<tr><td>Configuring Projects</td><td>5.000s</td></tr>' +
    '<tr><td>:app</td><td>70.000s</td><td>(total)</td></tr>' +
    '<tr><td class="indentPath">:app:compile</td><td>60.000s</td><td></td></tr>' +
    '<tr><td>:app:resources</td><td>0.200s</td><td>FROM-CACHE</td></tr>' +
    '<tr><td>:app:pack</td><td>2.000s</td><td>fixture-secret</td></tr></table>';
  const profile = parseProfile(html);
  assert.equal(profile.summarySeconds['Total Build Time'], 90.5);
  assert.equal(profile.summarySeconds['All dependencies'], 10.25);
  assert.equal(profile.taskCount, 3);
  assert.equal(profile.reusedTaskCount, 1);
  assert.equal(profile.slowestTasks[0].task, ':app:compile');
  assert.equal(JSON.stringify(profile).includes('fixture-secret'), false);
  assert.equal(seconds('1d2h3m4.005s'), 93784.005);
  assert.equal(seconds('bad duration'), null);
  assert.throws(() => parseProfile('<html>not a profile</html>'));
  const reports = path.join(fixture, 'reports');
  fs.mkdirSync(reports);
  fs.writeFileSync(path.join(reports, 'profile-2026-10-15-01-00-00.html'), html);
  assert.equal(collectProfiles(reports, 0).length, 1);
  assert.equal(collectProfiles(reports, Date.now() + 10000).length, 0);
  fs.symlinkSync(path.join(reports, 'profile-2026-10-15-01-00-00.html'), path.join(reports, 'profile-2026-10-15-02-00-00.html'));
  assert.equal(collectProfiles(reports, 0).length, 1);
  fs.writeFileSync(path.join(reports, 'profile-2026-10-15-03-00-00.html'), Buffer.alloc(4 * 1024 * 1024 + 1));
  assert.equal(collectProfiles(reports, 0).length, 1);
  const sizes = cacheSizes({ PUB_CACHE: reports });
  assert.ok(sizes.pub >= 4 * 1024 * 1024);
  assert.equal(sizes.gradleModules, null);

  const root = path.join(fixture, 'repo with spaces');
  const scripts = path.join(root, 'scripts');
  const android = path.join(root, 'flutter_app/android');
  const sdk = path.join(fixture, 'flutter sdk');
  const sdkWrapper = path.join(sdk, 'bin/cache/artifacts/gradle_wrapper');
  for (const directory of [scripts, android, sdkWrapper]) fs.mkdirSync(directory, { recursive: true });
  for (const file of ['run-ci-profiled-apk.sh', 'ci-gradle-profile-wrapper.sh']) {
    fs.copyFileSync(path.join(__dirname, file), path.join(scripts, file));
  }
  fs.writeFileSync(path.join(scripts, 'collect-ci-build-diagnostics.cjs'),
    'process.exit(Number(process.env.FIXTURE_COLLECT_STATUS));\n');
  const original = '#!/usr/bin/env bash\nprintf "%s\\0" "$@" > "$FIXTURE_ARGS"\nexit "$FIXTURE_BUILD_STATUS"\n';
  fs.writeFileSync(path.join(sdkWrapper, 'gradlew'), original);
  const wrapper = path.join(android, 'gradlew');
  const argsFile = path.join(fixture, 'args');
  const args = ['-Pvalue=a b', 'literal$(must-not-run)', 'assembleRelease'];
  for (const existing of [false, true]) {
    for (const buildStatus of [0, 42]) {
      for (const collectStatus of [0, 1]) {
        if (existing) fs.writeFileSync(wrapper, original, { mode: 0o751 });
        const beforeMode = existing ? fs.statSync(wrapper).mode : null;
        const result = spawnSync('bash', [path.join(scripts, 'run-ci-profiled-apk.sh'),
          'release', 'bash', wrapper, ...args], {
          env: { ...process.env, FLUTTER_ROOT: sdk, FIXTURE_ARGS: argsFile,
            FIXTURE_BUILD_STATUS: String(buildStatus), FIXTURE_COLLECT_STATUS: String(collectStatus) },
          timeout: 10000, encoding: 'utf8',
        });
        assert.equal(result.status, buildStatus);
        assert.deepEqual(fs.readFileSync(argsFile, 'utf8').split('\0').slice(0, -1), ['--profile', ...args]);
        assert.equal(fs.existsSync(wrapper), existing);
        if (existing) {
          assert.equal(fs.readFileSync(wrapper, 'utf8'), original);
          assert.equal(fs.statSync(wrapper).mode, beforeMode);
          fs.unlinkSync(wrapper);
        }
        assert.deepEqual(fs.readdirSync(android), []);
      }
    }
  }
  console.log('CI build diagnostics passed (profile fields, freshness, bounds, argument forwarding, launcher restoration, failure status)');
} finally { fs.rmSync(fixture, { recursive: true, force: true }); }

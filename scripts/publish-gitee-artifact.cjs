#!/usr/bin/env node
'use strict';

// Upload the already built/signed artifact. Never build, create/move a Git tag,
// overwrite an attachment, or forward the release token to download hosts.
const fs = require('node:fs');
const path = require('node:path');
const { createHash } = require('node:crypto');
const { execFileSync } = require('node:child_process');

class PublishError extends Error {}
const requireValue = (condition, message) => {
  if (!condition) throw new PublishError(message);
};
const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
const maxApkBytes = 256 * 1024 * 1024;

function safeUrl(value) {
  let url;
  try { url = new URL(value); } catch { throw new PublishError('Invalid release endpoint'); }
  const local = ['127.0.0.1', '[::1]'].includes(url.hostname);
  requireValue(!url.username && !url.password &&
    (url.protocol === 'https:' || (local && url.protocol === 'http:')),
  'Release endpoints require HTTPS (HTTP is only allowed for loopback fixtures)');
  return url;
}

function createPublisher({ token, owner = 'YanGanYuan', repo = 'android-codex-server',
  apiBase = 'https://gitee.com/api/v5', webBase = 'https://gitee.com',
  apiTimeoutMs = 30000, transferTimeoutMs = 300000, log = console.log } = {}) {
  requireValue(typeof token === 'string' && token.trim().length > 0,
    'CODEX_RELEASE_TOKEN is required and must be available to tag builds');
  requireValue([owner, repo].every(v => /^[A-Za-z0-9_-][A-Za-z0-9_.-]*$/.test(v)),
    'Invalid release repository');
  const api = safeUrl(apiBase);
  const web = safeUrl(webBase);
  requireValue(!api.search && !api.hash && web.pathname === '/' && !web.search && !web.hash,
    'Invalid release endpoint configuration');
  const repoPath = `/repos/${owner}/${repo}`;

  async function request(endpoint, { method = 'GET', fields, file, missing = false,
    authenticated = true } = {}) {
    const url = new URL(`${api.href.replace(/\/$/, '')}${endpoint}`);
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), file ? transferTimeoutMs : apiTimeoutMs);
    let body;
    if (method === 'GET' && authenticated) url.searchParams.set('access_token', token);
    if (method !== 'GET') {
      body = file ? new FormData() : new URLSearchParams(fields);
      body.set('access_token', token);
      if (file) body.set('file', new Blob([file.bytes], {
        type: 'application/vnd.android.package-archive',
      }), file.name);
    }
    try {
      const response = await fetch(url, { method, body, redirect: 'manual',
        headers: { Accept: 'application/json' }, signal: controller.signal });
      if (missing && response.status === 404) {
        await response.body?.cancel();
        return null;
      }
      if (!response.ok) {
        await response.body?.cancel();
        throw new PublishError(`Gitee ${method} request failed (HTTP ${response.status}); check token, repository permissions and tag access`);
      }
      const chunks = [];
      let size = 0;
      for await (const chunk of response.body) {
        size += chunk.length;
        requireValue(size <= 2 * 1024 * 1024, 'Gitee JSON response exceeds limit');
        chunks.push(chunk);
      }
      try { return JSON.parse(Buffer.concat(chunks).toString('utf8')); }
      catch { throw new PublishError('Gitee returned invalid JSON'); }
    } catch (error) {
      if (error instanceof PublishError) throw error;
      throw new PublishError(controller.signal.aborted
        ? 'Gitee request timed out; publication is not confirmed'
        : 'Gitee request failed; publication is not confirmed');
    } finally {
      controller.abort();
      clearTimeout(timer);
    }
  }

  async function preflight() {
    // Reuse the repository scope of existing release tokens. /user would also
    // require user_info scope, which publishing does not otherwise need.
    const project = await request(repoPath);
    requireValue(project?.full_name?.toLowerCase() === `${owner}/${repo}`.toLowerCase(),
      'Release repository does not match');
    requireValue(project?.permission?.push !== false || project?.permission?.admin === true,
      'Release token does not have repository write permission');
    log('[Release] Authenticated repository access checked; publishing requires write permission');
  }

  function validateRelease(release, artifact) {
    requireValue(Number.isInteger(release?.id) && release.id > 0 &&
      release.tag_name === artifact.tag && release.prerelease === false,
    'Gitee returned an invalid or non-stable Release');
    const marker = /<!-- apk-sha256:([a-f0-9]{64}) -->/.exec(release.body || '');
    requireValue(!marker || marker[1] === artifact.hash,
      'Existing Release belongs to a different APK; refusing to overwrite');
    requireValue(Array.isArray(release.assets), 'Gitee Release attachment list is missing');
    return release;
  }

  async function verifyDownload(url, artifact) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), transferTimeoutMs);
    try {
      let target = safeUrl(url);
      for (let hop = 0; hop <= 5; hop++) {
        // Deliberately no token, Authorization, cookies or inherited headers.
        requireValue(!target.href.includes(token), 'Refusing a credential-bearing download URL');
        const response = await fetch(target, { redirect: 'manual', signal: controller.signal });
        if ([301, 302, 303, 307, 308].includes(response.status)) {
          const location = response.headers.get('location');
          await response.body?.cancel();
          requireValue(location && hop < 5, 'APK download redirect limit exceeded');
          const next = safeUrl(new URL(location, target));
          requireValue(target.protocol !== 'https:' || next.protocol === 'https:',
            'Refusing an insecure APK download redirect');
          target = next;
          continue;
        }
        requireValue(response.status === 200, `Public APK download failed (HTTP ${response.status})`);
        const hash = createHash('sha256');
        let bytes = 0;
        for await (const chunk of response.body) {
          bytes += chunk.length;
          requireValue(bytes <= artifact.bytes.length, 'Published APK is larger than the built artifact');
          hash.update(chunk);
        }
        requireValue(bytes === artifact.bytes.length && hash.digest('hex') === artifact.hash,
          'Published APK SHA-256 does not match the signed build; refusing to report success');
        return;
      }
    } catch (error) {
      if (error instanceof PublishError) throw error;
      throw new PublishError(controller.signal.aborted
        ? 'Public APK verification timed out' : 'Public APK verification failed');
    } finally {
      controller.abort();
      clearTimeout(timer);
    }
  }

  async function publish(artifact) {
    requireValue(/^v\d+\.\d+\.\d+$/.test(artifact.tag) &&
      artifact.name === `Agent-${artifact.tag.slice(1)}.apk` &&
      /^[a-f0-9]{40}$/.test(artifact.commit) && Buffer.isBuffer(artifact.bytes) &&
      artifact.bytes.length > 0 && artifact.bytes.length <= maxApkBytes &&
      artifact.hash === sha256(artifact.bytes), 'Invalid release artifact');
    const endpoint = `${repoPath}/releases/tags/${encodeURIComponent(artifact.tag)}`;
    let release = await request(endpoint, { missing: true });
    if (!release) {
      log(`[Release] Creating ${artifact.tag}`);
      release = await request(`${repoPath}/releases`, { method: 'POST', fields: {
        tag_name: artifact.tag, target_commitish: artifact.commit, prerelease: 'false',
        name: `Agent ${artifact.tag.slice(1)}`,
        body: `## 更新日志\n\n${artifact.notes}\n\n## APK 校验\n\n` +
          `- 文件：${artifact.name}\n- SHA-256：\`${artifact.hash}\`\n` +
          `- Commit：\`${artifact.commit}\`\n<!-- apk-sha256:${artifact.hash} -->`,
      } });
    }
    validateRelease(release, artifact);
    if (!release.assets.some(asset => asset?.name === artifact.name)) {
      log(`[Release] Uploading ${artifact.name} (${artifact.bytes.length} bytes)`);
      // A single POST: after an ambiguous failure a rerun queries the Release
      // first, rather than blindly creating duplicate uploads.
      const attached = await request(`${repoPath}/releases/${release.id}/attach_files`, {
        method: 'POST', file: artifact,
      });
      requireValue(Number.isInteger(attached?.id) && attached.id > 0 && attached.name === artifact.name,
        'Gitee did not confirm the APK attachment');
    } else {
      log('[Release] Attachment already exists; verifying it without replacement');
    }
    // Check the public view used by the app updater, not only an authenticated
    // response. A temporarily stale list has at most three read-only attempts.
    for (let attempt = 0; attempt < 3; attempt++) {
      const published = await request(endpoint, { authenticated: false });
      validateRelease(published, artifact);
      if (published.assets.some(asset => asset?.name === artifact.name)) break;
      requireValue(attempt < 2, 'Public Release does not contain the APK attachment');
      await new Promise(resolve => setTimeout(resolve, 1000));
    }
    const releaseUrl = `${web.origin}/${owner}/${repo}/releases/tag/${artifact.tag}`;
    const downloadUrl = `${web.origin}/${owner}/${repo}/releases/download/${artifact.tag}/${artifact.name}`;
    log('[Release] Verifying public APK size and SHA-256');
    await verifyDownload(downloadUrl, artifact);
    log(`[Release] Published and verified: ${releaseUrl}`);
    log(`[Release] APK: ${downloadUrl}`);
    return { tag: artifact.tag, commit: artifact.commit, sha256: artifact.hash,
      bytes: artifact.bytes.length, releaseUrl, downloadUrl };
  }
  return { preflight, publish };
}

function loadArtifact(root, outputDir, owner = 'YanGanYuan', repo = 'android-codex-server') {
  const metadataPath = path.join(outputDir, 'release-metadata.txt');
  requireValue(fs.statSync(metadataPath).size <= 8192, 'Release metadata exceeds limit');
  const metadata = Object.fromEntries(fs.readFileSync(metadataPath, 'utf8').trim().split('\n')
    .map(line => { const i = line.indexOf('='); return [line.slice(0, i), line.slice(i + 1)]; }));
  const pubspec = fs.readFileSync(path.join(root, 'flutter_app/pubspec.yaml'), 'utf8');
  const version = /^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$/m.exec(pubspec);
  requireValue(version && metadata.versionName === version[1] && metadata.versionCode === version[2] &&
    metadata.tag === `v${version[1]}` && /^[a-f0-9]{64}$/.test(metadata.apkSha256),
  'Release metadata does not match pubspec');
  const git = args => execFileSync('git', args, { cwd: root, encoding: 'utf8',
    timeout: 60000, maxBuffer: 1024 * 1024, stdio: ['ignore', 'pipe', 'ignore'],
    env: { ...process.env, GIT_TERMINAL_PROMPT: '0', GCM_INTERACTIVE: 'Never',
      GIT_ASKPASS: '/bin/false', SSH_ASKPASS: '/bin/false',
      GIT_SSH_COMMAND: 'ssh -oBatchMode=yes -oConnectTimeout=20' } });
  requireValue(git(['rev-parse', 'HEAD']).trim() === metadata.gitCommit,
    'Release metadata does not match HEAD');
  const origin = git(['remote', 'get-url', 'origin']).trim();
  let originPath;
  const sshOrigin = /^(?:[^@/:]+@)?gitee\.com:(.+)$/.exec(origin);
  if (sshOrigin) originPath = sshOrigin[1];
  else {
    let remote;
    try { remote = new URL(origin); } catch { throw new PublishError('Unrecognized release Git origin'); }
    requireValue(remote.hostname === 'gitee.com', 'Release Git origin must match the Gitee repository');
    originPath = remote.pathname.replace(/^\//, '');
  }
  requireValue(originPath.replace(/\.git$/, '').toLowerCase() === `${owner}/${repo}`.toLowerCase(),
    'Release API repository does not match Git origin');
  const tagRef = `refs/tags/${metadata.tag}`;
  const remoteTags = new Map(git(['ls-remote', 'origin', tagRef, `${tagRef}^{}`]).trim()
    .split('\n').map(line => { const [sha, ref] = line.split(/\s+/); return [ref, sha]; }));
  requireValue((remoteTags.get(`${tagRef}^{}`) || remoteTags.get(tagRef)) === metadata.gitCommit,
    'Remote release tag is missing or does not match HEAD; no tags will be created');
  const name = `Agent-${version[1]}.apk`;
  const filename = path.join(outputDir, name);
  const stat = fs.lstatSync(filename);
  requireValue(stat.isFile() && stat.size > 0 && stat.size <= maxApkBytes, 'Invalid APK file or size');
  const bytes = fs.readFileSync(filename);
  requireValue(sha256(bytes) === metadata.apkSha256, 'APK does not match the signed artifact metadata');
  return { tag: metadata.tag, commit: metadata.gitCommit, name, bytes, hash: metadata.apkSha256,
    notes: git(['log', '-12', '--pretty=format:- `%h` %s']).trim() };
}

async function main() {
  const root = path.resolve(__dirname, '..');
  const owner = process.env.CODEX_RELEASE_OWNER || 'YanGanYuan';
  const repo = process.env.CODEX_RELEASE_REPOSITORY || 'android-codex-server';
  const publisher = createPublisher({ token: process.env.CODEX_RELEASE_TOKEN,
    owner, repo,
    apiBase: process.env.CODEX_GITEE_API_BASE });
  if (process.argv[2] === '--preflight') return publisher.preflight();
  requireValue(process.argv.length === 3, 'Usage: publish-gitee-artifact.cjs OUTPUT_DIR | --preflight');
  const outputDir = path.resolve(process.argv[2]);
  const artifact = loadArtifact(root, outputDir, owner, repo);
  const result = await publisher.publish(artifact);
  fs.writeFileSync(path.join(outputDir, 'release-publication.json'), `${JSON.stringify(result, null, 2)}\n`);
}

if (require.main === module) {
  main().catch(error => {
    // Do not print raw fetch/Git errors, response bodies, URLs with tokens, or stacks.
    console.error(`[Release] ${error instanceof PublishError ? error.message : 'Publication failed during artifact or Git verification'}`);
    process.exitCode = 1;
  });
}
module.exports = { createPublisher, loadArtifact, PublishError };

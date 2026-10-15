#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const metrics = new Set([
  'Total Build Time', 'Startup', 'Settings and buildSrc', 'Loading Projects',
  'Configuring Projects', 'Artifact Transforms', 'Task Execution', 'All dependencies',
]);

function seconds(value) {
  if (!/^(?:\d+d)?(?:\d+h)?(?:\d+m)?\d+(?:\.\d+)?s$/.test(value)) return null;
  let total = 0;
  for (const [, number, unit] of value.matchAll(/(\d+(?:\.\d+)?)([dhms])/g)) {
    total += Number(number) * { d: 86400, h: 3600, m: 60, s: 1 }[unit];
  }
  return Math.round(total * 1000) / 1000;
}

// Only allowlisted numeric fields and conventional Gradle task paths leave the
// runner. Never copy raw HTML, command lines, environment, URLs or exception text.
function parseProfile(html) {
  const summarySeconds = {};
  const tasks = [];
  for (const row of html.matchAll(/<tr\b[^>]*>([\s\S]*?)<\/tr>/g)) {
    const cells = [...row[1].matchAll(/<td\b[^>]*>([\s\S]*?)<\/td>/g)].map(match => match[1].trim());
    const duration = seconds(cells[1] || '');
    if (duration === null) continue;
    if (cells.length === 2 && metrics.has(cells[0])) summarySeconds[cells[0]] = duration;
    if (cells.length === 3 && /^:[A-Za-z0-9_.:-]{1,180}$/.test(cells[0]) && cells[2] !== '(total)') {
      tasks.push({ task: cells[0], seconds: duration,
        outcome: ['', 'UP-TO-DATE', 'FROM-CACHE', 'SKIPPED', 'NO-SOURCE', 'Did No Work'].includes(cells[2])
          ? (cells[2] || 'executed') : 'other' });
    }
  }
  if (!Object.hasOwn(summarySeconds, 'Total Build Time') ||
      !Object.hasOwn(summarySeconds, 'All dependencies')) throw new Error('Unrecognized Gradle profile');
  tasks.sort((a, b) => b.seconds - a.seconds);
  return { summarySeconds, taskCount: tasks.length,
    reusedTaskCount: tasks.filter(task => ['UP-TO-DATE', 'FROM-CACHE'].includes(task.outcome)).length,
    slowestTasks: tasks.slice(0, 20) };
}

function collectProfiles(directory, startedMs) {
  if (!fs.existsSync(directory)) return [];
  return fs.readdirSync(directory).filter(name => /^profile-[0-9-]+\.html$/.test(name)).sort().slice(-8)
    .flatMap(name => {
      const file = path.join(directory, name);
      const stat = fs.lstatSync(file);
      if (!stat.isFile() || stat.mtimeMs < startedMs || stat.size > 4 * 1024 * 1024) return [];
      return [{ ...parseProfile(fs.readFileSync(file, 'utf8')) }];
    });
}

function cacheSizes(env) {
  const candidates = {
    gradleModules: env.GRADLE_USER_HOME && path.join(env.GRADLE_USER_HOME, 'caches/modules-2'),
    gradleBuildCache: env.GRADLE_USER_HOME && path.join(env.GRADLE_USER_HOME, 'caches/build-cache-1'),
    gradleWrapper: env.GRADLE_USER_HOME && path.join(env.GRADLE_USER_HOME, 'wrapper'),
    pub: env.PUB_CACHE, flutterSdk: env.FLUTTER_ROOT, androidSdk: env.ANDROID_HOME,
  };
  return Object.fromEntries(Object.entries(candidates).map(([label, directory]) => {
    if (!directory || !fs.existsSync(directory)) return [label, null];
    try {
      // Dereference just the argument (the isolated Gradle home's cache link).
      const output = execFileSync('du', ['-sbH', '--', directory],
        { encoding: 'utf8', timeout: 2000, maxBuffer: 4096, stdio: ['ignore', 'pipe', 'ignore'] });
      const bytes = Number(output.match(/^\d+/)?.[0]);
      return [label, Number.isSafeInteger(bytes) ? bytes : null];
    } catch { return [label, null]; }
  }));
}

function main(args) {
  const [root, start, variant, status] = args;
  if (args.length !== 4 || !/^\d{13}$/.test(start) || !['debug', 'release'].includes(variant) ||
      !/^\d{1,3}$/.test(status) || Number(status) > 255) throw new Error('Invalid diagnostics arguments');
  const profiles = collectProfiles(path.join(root, 'flutter_app/build/reports/profile'), Number(start));
  const report = { schema: 1, variant, buildExitCode: Number(status), profiles,
    cacheApparentBytes: cacheSizes(process.env), crossJobCacheUpload: 'disabled',
    note: 'Profile operations can overlap; do not add category totals. Dependency resolution includes local work, not just downloads. Cache sizes are uncompressed; null means absent or unavailable.' };
  const output = path.join(process.env.CODEX_RELEASE_OUTPUT_DIR || path.join(root, 'dist'), 'build-diagnostics');
  fs.mkdirSync(output, { recursive: true });
  fs.writeFileSync(path.join(output, `${variant}.json`), `${JSON.stringify(report, null, 2)}\n`);
  console.log(`[CI] Gradle profile: ${profiles.length} new report(s); diagnostics saved to dist/build-diagnostics/${variant}.json`);
  for (const profile of profiles) {
    console.log(`[CI] Gradle timings (seconds): ${JSON.stringify(profile.summarySeconds)}`);
    console.log(`[CI] Gradle slowest tasks: ${JSON.stringify(profile.slowestTasks.slice(0, 10))}`);
  }
  console.log(`[CI] Cache apparent bytes (upload disabled): ${JSON.stringify(report.cacheApparentBytes)}`);
}

module.exports = { seconds, parseProfile, collectProfiles, cacheSizes };
if (require.main === module) {
  try { main(process.argv.slice(2)); }
  catch { console.error('[CI] Unable to collect build diagnostics'); process.exitCode = 1; }
}

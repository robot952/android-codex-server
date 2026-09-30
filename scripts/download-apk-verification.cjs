#!/usr/bin/env node
'use strict';

// Download verification is separate from publication: retrying a slow HTTP link
// must never rebuild or replace the already signed APK.
const http = require('node:http');
const https = require('node:https');
const fs = require('node:fs');
const fsp = require('node:fs/promises');
const path = require('node:path');
const { createHash } = require('node:crypto');
const { Transform } = require('node:stream');
const { pipeline } = require('node:stream/promises');

class VerificationError extends Error {}
class RetryableError extends Error {}
const transientCodes = new Set(['ECONNRESET', 'ECONNREFUSED', 'ETIMEDOUT', 'EPIPE', 'EAI_AGAIN', 'ERR_STREAM_PREMATURE_CLOSE']);
const transientStatuses = new Set([408, 429, 500, 502, 503, 504]);

function retryable(error) {
  return error instanceof RetryableError || transientCodes.has(error.code);
}

function milliseconds(value, fallback) {
  const seconds = value === undefined ? fallback : Number(value);
  if (!Number.isFinite(seconds) || seconds <= 0 || seconds > 900) {
    throw new VerificationError('Download timeout must be greater than 0 and at most 900 seconds');
  }
  return seconds * 1000;
}

async function sha256(file) {
  const hash = createHash('sha256');
  for await (const chunk of fs.createReadStream(file)) hash.update(chunk);
  return hash.digest('hex');
}

async function fetchFile(url, file, { size, range, etag, timeoutMs, signal }) {
  const controller = new AbortController();
  const abort = () => controller.abort(signal.reason);
  signal.addEventListener('abort', abort, { once: true });
  if (signal.aborted) abort();
  const timer = setTimeout(() => controller.abort(new RetryableError('Download request timed out')), timeoutMs);
  const headers = { 'Accept-Encoding': 'identity' };
  if (range) headers.Range = `bytes=${range[0]}-${range[1]}`;
  if (etag) headers['If-Range'] = etag;
  try {
    let target = new URL(url);
    let response;
    for (let redirects = 0; ; redirects++) {
      if (!['http:', 'https:'].includes(target.protocol) || target.username || target.password) {
        throw new VerificationError('Only HTTP(S) download URLs without credentials are supported');
      }
      response = await new Promise((resolve, reject) => {
        const request = (target.protocol === 'https:' ? https : http).get(target, {
          headers, signal: controller.signal, agent: false,
        }, resolve);
        request.on('error', reject);
      });
      if (![301, 302, 303, 307, 308].includes(response.statusCode)) break;
      response.destroy();
      if (redirects === 5 || !response.headers.location) throw new VerificationError('Invalid download redirect');
      target = new URL(response.headers.location, target);
    }
    const expectedStatus = range ? 206 : 200;
    try {
      if (response.statusCode !== expectedStatus) {
        const ErrorType = transientStatuses.has(response.statusCode) ? RetryableError : VerificationError;
        throw new ErrorType(`Unexpected download HTTP status ${response.statusCode}`);
      }
      const encoding = response.headers['content-encoding'];
      if (encoding && encoding !== 'identity') throw new VerificationError('Encoded APK response is not supported');
      const expectedSize = range ? range[1] - range[0] + 1 : size;
      const contentLength = response.headers['content-length'];
      if (contentLength !== undefined && contentLength !== String(expectedSize)) {
        throw new VerificationError('Download Content-Length differs from the signed artifact');
      }
      if (range && response.headers['content-range'] !== `bytes ${range[0]}-${range[1]}/${size}`) {
        throw new VerificationError('Download Content-Range does not match the requested artifact range');
      }
      if (etag && response.headers.etag !== etag) throw new VerificationError('Download ETag changed during verification');
      let received = 0;
      const bounded = new Transform({
        transform(chunk, _encoding, callback) {
          received += chunk.length;
          callback(received > expectedSize ? new VerificationError('Download exceeds the expected size') : null, chunk);
        },
      });
      await pipeline(response, bounded, fs.createWriteStream(file, { flags: 'wx', mode: 0o600 }), { signal: controller.signal });
      if (received !== expectedSize) throw new RetryableError('Download ended before the expected size');
      return response.headers.etag;
    } finally {
      response.destroy();
    }
  } catch (error) {
    if (controller.signal.aborted) throw controller.signal.reason;
    throw error;
  } finally {
    clearTimeout(timer);
    signal.removeEventListener('abort', abort);
  }
}

async function downloadForVerification({ url, output, size, hash, directTimeoutMs = 30000, rangeTimeoutMs = 300000, fallback = true, signal }) {
  if (!Number.isSafeInteger(size) || size < 1 || !/^[a-f0-9]{64}$/.test(hash)) {
    throw new VerificationError('Expected APK size and SHA-256 are required');
  }
  for (const timeout of [directTimeoutMs, rangeTimeoutMs]) {
    if (!Number.isFinite(timeout) || timeout <= 0 || timeout > 900000) throw new VerificationError('Invalid download timeout');
  }
  const began = performance.now();
  const controller = new AbortController();
  const abort = () => controller.abort(signal.reason);
  signal?.addEventListener('abort', abort, { once: true });
  if (signal?.aborted) abort();
  const directory = await fsp.mkdtemp(path.join(path.dirname(path.resolve(output)), '.apk-verification-'));
  const complete = path.join(directory, 'complete.apk');
  let deadlineTimer;
  let mode = 'direct';
  try {
    try {
      await fetchFile(url, complete, { size, timeoutMs: directTimeoutMs, signal: controller.signal });
    } catch (error) {
      if (!fallback || !retryable(error) || controller.signal.aborted) throw error;
      await fsp.rm(complete, { force: true });
      mode = 'ranges';
      // One deadline covers the probe, all four workers and their single retry.
      // A fast failed worker cancels its peers; no background transfer survives.
      deadlineTimer = setTimeout(() => controller.abort(new RetryableError('Range verification deadline exceeded')), rangeTimeoutMs);
      const etag = await fetchFile(url, path.join(directory, 'probe'), {
        size, range: [0, 0], timeoutMs: Math.min(15000, rangeTimeoutMs), signal: controller.signal,
      });
      // ETag is optional; a present validator must be strong so If-Range has its
      // standard meaning. The final artifact hash remains mandatory either way.
      if (etag !== undefined && !/^"[\x21\x23-\x7e]*"$/.test(etag)) throw new VerificationError('Range response needs a strong ETag');
      const count = Math.min(4, size);
      const chunkSize = Math.ceil(size / count);
      const parts = [];
      for (let start = 0; start < size; start += chunkSize) {
        const end = Math.min(size - 1, start + chunkSize - 1);
        const file = path.join(directory, `part-${parts.length}`);
        parts.push({ file, range: [start, end] });
      }
      const results = await Promise.allSettled(parts.map(async ({ file, range }) => {
        try {
          for (let attempt = 0; ; attempt++) {
            try {
              await fetchFile(url, file, { size, range, etag, timeoutMs: rangeTimeoutMs, signal: controller.signal });
              return;
            } catch (error) {
              if (attempt === 1 || !retryable(error) || controller.signal.aborted) throw error;
              await fsp.rm(file, { force: true });
            }
          }
        } catch (error) {
          controller.abort(error);
          throw error;
        }
      }));
      const failure = results.find((result) => result.status === 'rejected');
      if (failure) throw failure.reason;
      async function* orderedParts() {
        for (const { file } of parts) yield* fs.createReadStream(file);
      }
      await pipeline(orderedParts(), fs.createWriteStream(complete, { flags: 'wx', mode: 0o600 }), { signal: controller.signal });
    }
    if ((await fsp.stat(complete)).size !== size || await sha256(complete) !== hash) {
      throw new VerificationError('Downloaded APK SHA-256 or size differs from the signed artifact');
    }
    if (controller.signal.aborted) throw controller.signal.reason;
    await fsp.rename(complete, output);
    return { mode, bytes: size, elapsedMs: Math.round(performance.now() - began) };
  } finally {
    clearTimeout(deadlineTimer);
    signal?.removeEventListener('abort', abort);
    await fsp.rm(directory, { recursive: true, force: true });
  }
}

if (require.main === module) {
  const [url, output, expectedSize, hash, ...extra] = process.argv.slice(2);
  const controller = new AbortController();
  for (const name of ['SIGINT', 'SIGTERM']) process.once(name, () => controller.abort(new VerificationError('Download verification cancelled')));
  Promise.resolve().then(async () => {
    if (!url || !output || !expectedSize || !hash || extra.length) throw new VerificationError('usage: download-apk-verification.cjs URL OUTPUT SIZE SHA256');
    const result = await downloadForVerification({
      url, output, size: Number(expectedSize), hash, signal: controller.signal,
      directTimeoutMs: milliseconds(process.env.CODEX_LOCAL_VERIFY_TIMEOUT, 30),
      rangeTimeoutMs: milliseconds(process.env.CODEX_LOCAL_RANGE_TIMEOUT, 300),
      fallback: process.env.CODEX_LOCAL_RANGE_FALLBACK !== '0',
    });
    console.log(`APK download verified: mode=${result.mode} bytes=${result.bytes} elapsedMs=${result.elapsedMs}`);
  }).catch((error) => {
    // Never print a URL, credentials or the downloaded body in failure logs.
    console.error(error instanceof VerificationError || error instanceof RetryableError ? error.message : `APK download failed (${error.code || error.name})`);
    process.exitCode = 1;
  });
}

module.exports = { downloadForVerification };

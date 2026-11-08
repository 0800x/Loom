import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createServer } from 'node:http';
import { Writable } from 'node:stream';
import type { ServerResponse } from 'node:http';
import {
  LoomTileCacheService,
  countryBounds,
  parseTilePath,
  supportedCountries,
  tileRanges,
  totalTiles,
} from '../src/maps/tile_cache.ts';

// 1x1 transparent PNG.
const pngBytes = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
  'base64',
);

function upstreamServer() {
  const served: string[] = [];
  const server = createServer((request, response) => {
    served.push(request.url ?? '');
    if ((request.url ?? '') === '/tiles/3/4/6.png') {
      response.writeHead(200, { 'content-type': 'text/html' });
      response.end('<html>not an image</html>');
      return;
    }
    response.writeHead(200, { 'content-type': 'image/png' });
    response.end(pngBytes);
  });
  return { server, served };
}

test('tile math covers country bounds and counts tiles', () => {
  const iran = countryBounds('ir');
  assert.ok(iran);
  const ranges = tileRanges(iran, 0, 5);
  assert.equal(ranges.length, 6);
  assert.equal(ranges[0].z, 0);
  assert.equal(ranges[0].x0, 0);
  assert.equal(ranges[0].x1, 0);
  const count = totalTiles(ranges);
  assert.ok(count > 0 && count < 5000);
  assert.ok(supportedCountries().includes('ir'));
  assert.equal(countryBounds('XX'), null);
});

test('tile path parsing accepts xyz with and without extension', () => {
  assert.deepEqual(parseTilePath('/tiles/5/12/13'), [5, 12, 13]);
  assert.deepEqual(parseTilePath('/tiles/5/12/13.png'), [5, 12, 13]);
  assert.equal(parseTilePath('/tiles//12/13'), null);
  assert.equal(parseTilePath('/tiles/a/12/13'), null);
  assert.equal(parseTilePath('/tiles/5/12'), null);
});

test('tile cache serves hits, fetches misses and rejects invalid tiles', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'loom-tiles-'));
  const { server, served } = upstreamServer();
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  const address = server.address();
  const cache = new LoomTileCacheService({
    upstreamTemplate: `http://127.0.0.1:${address.port}/tiles/{z}/{x}/{y}.png`,
    directory: dir,
    warmDelayMs: 0,
  });
  try {
    assert.equal(cache.validTile(5, 0, 0), true);
    assert.equal(cache.validTile(19, 0, 0), false, 'above max zoom');
    assert.equal(cache.validTile(5, 32, 0), false, 'x out of range at z5');

    const makeResponse = () => {
      const chunks: Buffer[] = [];
      const state = { status: 0, headers: {} as Record<string, unknown>, finished: false };
      const response = new Writable({
        write(chunk, _encoding, callback) {
          chunks.push(Buffer.from(chunk));
          callback();
        },
      }) as unknown as ServerResponse & { headersSent: boolean };
      response.headersSent = false;
      (response as unknown as { writeHead: (s: number, h: Record<string, unknown>) => void }).writeHead =
        (status, headers) => { state.status = status; state.headers = headers; };
      response.on('finish', () => { state.finished = true; });
      return {
        state,
        response,
        body: () => Buffer.concat(chunks),
      };
    };

    const miss = makeResponse();
    assert.equal(await cache.serve(3, 4, 5, miss.response), true);
    assert.equal(miss.state.status, 200);
    assert.equal(miss.state.headers['x-loom-tile'], 'miss');
    assert.equal(miss.body().toString('base64'), pngBytes.toString('base64'));
    assert.deepEqual(served, ['/tiles/3/4/5.png']);

    const hit = makeResponse();
    assert.equal(await cache.serve(3, 4, 5, hit.response), true);
    assert.equal(hit.state.headers['x-loom-tile'], 'hit');
    assert.equal(hit.body().toString('base64'), pngBytes.toString('base64'));
    assert.deepEqual(served, ['/tiles/3/4/5.png'], 'upstream not hit again');

    // Non-image upstream content is quarantined, never cached.
    const bad = makeResponse();
    assert.equal(await cache.serve(3, 4, 6, bad.response), false);
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
    rmSync(dir, { recursive: true, force: true });
  }
});

test('warm-up job caches the requested bounds and reports progress', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'loom-tiles-warm-'));
  const { server } = upstreamServer();
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  const address = server.address();
  const cache = new LoomTileCacheService({
    upstreamTemplate: `http://127.0.0.1:${address.port}/tiles/{z}/{x}/{y}.png`,
    directory: dir,
    warmDelayMs: 0,
  });
  try {
    const job = await cache.warm([51.0, 35.0, 51.4, 35.4], 8, 9, 'ir');
    assert.equal(job.country, 'ir');
    assert.ok(job.total > 0);
    // Wait for the background job to finish.
    for (let i = 0; i < 200 && (cache.status().job as { running: boolean }).running; i++) {
      await new Promise((pause) => setTimeout(pause, 20));
    }
    const status = cache.status().job as { running: boolean; done: number; failed: number; total: number };
    assert.equal(status.running, false);
    assert.equal(status.done + status.failed, status.total);
    assert.equal(status.failed, 0);
    const usage = await cache.diskUsage();
    assert.equal(usage.files, status.done);
    assert.ok(usage.bytes > 0);
    // Warming again must be a no-op against the upstream (all hits).
    const before = (await cache.diskUsage()).files;
    await cache.warm([51.0, 35.0, 51.4, 35.4], 8, 9, 'ir');
    for (let i = 0; i < 200 && (cache.status().job as { running: boolean }).running; i++) {
      await new Promise((pause) => setTimeout(pause, 20));
    }
    assert.equal((await cache.diskUsage()).files, before);
    // Purge clears everything.
    await cache.purge();
    assert.equal((await cache.diskUsage()).files, 0);
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
    rmSync(dir, { recursive: true, force: true });
  }
});

test('existing cached files are served even when upstream is down', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'loom-tiles-stale-'));
  mkdirSync(join(dir, '2', '1'), { recursive: true });
  writeFileSync(join(dir, '2', '1', '2.png'), pngBytes);
  // Point at a closed port: only the pre-seeded file must still be served.
  const cache = new LoomTileCacheService({
    upstreamTemplate: 'https://127.0.0.1:1/tiles/{z}/{x}/{y}.png',
    directory: dir,
    fetchTimeoutMs: 200,
  });
  const state = { status: 0, headers: {} as Record<string, unknown> };
  const chunks: Buffer[] = [];
  const response = new Writable({
    write(chunk, _encoding, callback) {
      chunks.push(Buffer.from(chunk));
      callback();
    },
  }) as unknown as ServerResponse & { headersSent: boolean };
  response.headersSent = false;
  (response as unknown as { writeHead: (s: number, h: Record<string, unknown>) => void }).writeHead =
    (status, headers) => { state.status = status; state.headers = headers; };
  assert.equal(await cache.serve(2, 1, 2, response), true);
  assert.equal(state.headers['x-loom-tile'], 'hit');
  const body = Buffer.concat(chunks);
  assert.equal(readFileSync(join(dir, '2', '1', '2.png')).toString('base64'), body.toString('base64'));
  rmSync(dir, { recursive: true, force: true });
});

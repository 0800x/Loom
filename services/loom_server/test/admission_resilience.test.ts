import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { LoomNodeServer } from '../src/bootstrap/server.ts';
import { createDefaultConfig } from '../src/config/config.ts';
import { attachV2DeliveryService } from '../src/delivery/attach_v2_delivery.ts';
import { LoomAdmissionGate, LoomRateLimiter, RateLimitError } from '../src/security/rate_limiter.ts';

test('health probes stay answerable while the shared admission gate is saturated', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'loom-health-admission-'));
  const config = { ...createDefaultConfig(), listenHost: '127.0.0.1', listenPort: 0, dataDirectory: dir, attachmentsDirectory: join(dir, 'attachments') };
  const server = new LoomNodeServer(config);
  await attachV2DeliveryService(server, config);
  const internal = server as unknown as { limiter: LoomRateLimiter };
  const releases = Array.from({ length: 32 }, () => internal.limiter.enter());
  try {
    const address = await server.listen();
    for (const path of ['/healthz', '/readyz']) {
      const response = await fetch(`http://127.0.0.1:${address.port}${path}`);
      assert.notEqual(response.status, 429, `${path} must never be rate limited`);
      await response.arrayBuffer();
    }
    const api = await fetch(`http://127.0.0.1:${address.port}/api/v2/server/info`);
    assert.equal(api.status, 429, 'API stays gated while saturated');
    await api.arrayBuffer();
  } finally {
    releases.forEach(fn => fn());
    await server.close(); rmSync(dir, { recursive: true, force: true });
  }
});

test('attachment downloads use their own gate and never pin shared admission slots', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'loom-download-admission-'));
  const config = { ...createDefaultConfig(), listenHost: '127.0.0.1', listenPort: 0, dataDirectory: dir, attachmentsDirectory: join(dir, 'attachments') };
  const server = new LoomNodeServer(config);
  await attachV2DeliveryService(server, config);
  const internal = server as unknown as { downloads: LoomAdmissionGate };
  const held = Array.from({ length: 16 }, () => internal.downloads.enter());
  try {
    const address = await server.listen();
    const download = await fetch(`http://127.0.0.1:${address.port}/api/v1/attachments/att_${'0'.repeat(64)}`);
    assert.equal(download.status, 429, 'saturated download gate rejects further downloads');
    await download.arrayBuffer();
    // The shared API gate must be untouched by saturated downloads.
    const api = await fetch(`http://127.0.0.1:${address.port}/api/v2/server/info`);
    assert.equal(api.status, 200, 'API stays available while download gate is saturated');
    await api.arrayBuffer();
    held.forEach(fn => fn());
    const recovered = await fetch(`http://127.0.0.1:${address.port}/api/v1/attachments/att_${'0'.repeat(64)}`);
    assert.equal(recovered.status, 404, 'released download gate serves (unknown attachment → 404, not 429)');
    await recovered.arrayBuffer();
  } finally {
    held.forEach(fn => fn());
    await server.close(); rmSync(dir, { recursive: true, force: true });
  }
});

test('idle exact buckets are swept so rotating credentials cannot saturate the map', () => {
  const limiter = new LoomRateLimiter(3, 1, 1, 600_000);
  limiter.consume('auth', 'active-client', 30, 0);
  limiter.consume('auth', 'scanner-token-a', 30, 0);
  limiter.consume('auth', 'scanner-token-b', 30, 0);
  const state = limiter as unknown as { buckets: Map<string, unknown> };
  assert.equal(state.buckets.size, 3);
  // Keep the legit client recently active; the scanner tokens stay idle.
  limiter.consume('auth', 'active-client', 30, 599_999);
  // Ten minutes later a fresh subject arrives: only the idle scanner buckets
  // are evicted, the recently active one survives, and the newcomer gets its
  // own exact bucket instead of a shared overflow shard.
  limiter.consume('auth', 'rotated-client-token', 30, 600_000);
  assert.equal(state.buckets.size, 2, 'only the two idle scanner buckets were swept');
});

test('admission gate reports saturation and releases idempotently', () => {
  const gate = new LoomAdmissionGate(1);
  const release = gate.enter();
  assert.equal(gate.busy, 1);
  assert.throws(() => gate.enter(), RateLimitError);
  release(); release();
  assert.equal(gate.busy, 0);
  gate.enter();
});

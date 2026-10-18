import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { LoomNodeServer } from '../src/bootstrap/server.ts';
import { createDefaultConfig } from '../src/config/config.ts';
import { attachV2DeliveryService } from '../src/delivery/attach_v2_delivery.ts';
import { LoomRateLimiter } from '../src/security/rate_limiter.ts';

test('HTTP admission precedes every delivery adapter and releases slots', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'loom-admission-'));
  const config = { ...createDefaultConfig(), listenHost: '127.0.0.1', listenPort: 0, dataDirectory: dir, attachmentsDirectory: join(dir, 'attachments') };
  const server = new LoomNodeServer(config);
  await attachV2DeliveryService(server, config);
  const internal = server as unknown as { limiter: LoomRateLimiter };
  const releases = Array.from({ length: 32 }, () => internal.limiter.enter());
  try {
    const address = await server.listen();
    for (const [method, path] of [
      ['GET', '/api/v2/server/info'], ['POST', '/api/v2/users/resolve'],
      ['POST', '/api/v2/packets/direct'], ['POST', '/api/v1/messages/direct'],
      ['POST', '/api/v2/gateway/leases/register'], ['POST', '/api/v2/gateway/claim'],
      ['POST', '/api/v2/gateway/custody'], ['PUT', '/api/v2/mailboxes'],
    ]) {
      const response = await fetch(`http://127.0.0.1:${address.port}${path}`, { method });
      assert.equal(response.status, 429, path);
      assert.equal(response.headers.get('retry-after'), '1');
      assert.equal(response.headers.get('referrer-policy'), 'no-referrer');
      await response.arrayBuffer();
    }
    releases.forEach(fn => fn());
    const response = await fetch(`http://127.0.0.1:${address.port}/api/v2/server/info`);
    assert.equal(response.status, 200); await response.arrayBuffer();
    const all = Array.from({ length: 32 }, () => internal.limiter.enter());
    all.forEach(fn => fn());
  } finally {
    releases.forEach(fn => fn());
    await server.close(); rmSync(dir, { recursive: true, force: true });
  }
});

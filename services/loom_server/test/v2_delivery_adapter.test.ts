import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { LoomNodeServer } from '../src/bootstrap/server.ts';
import type { LoomNodeConfig } from '../src/config/config.ts';
import { attachV2DeliveryService } from '../src/delivery/attach_v2_delivery.ts';

function config(dir: string): LoomNodeConfig {
  return {
    schemaVersion: 1,
    mode: 'easy',
    listenHost: '127.0.0.1',
    listenPort: 0,
    publicDomain: 'localhost',
    publicBaseUrl: 'http://localhost',
    dataDirectory: dir,
    attachmentsDirectory: join(dir, 'attachments'),
    registrationPolicy: 'open',
    federationMode: 'disabled',
    networkJurisdiction: 'Test',
    operatorName: 'Test Node',
    adminToken: 'test-admin-token-012345678901234567890123456789',
    maxAttachmentBytes: 1024 * 1024,
    maxRequestBytes: 1024 * 1024,
  };
}

test('v2 delivery adapter delegates v1 and exposes separate v2 discovery', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'loom-v2-adapter-'));
  const cfg = config(dir);
  const server = new LoomNodeServer(cfg);
  await attachV2DeliveryService(server, cfg);
  try {
    const address = await server.listen();
    const base = `http://127.0.0.1:${address.port}`;

    const health = await fetch(`${base}/healthz`);
    assert.equal(health.status, 200);
    assert.equal(await health.text(), 'ok\n');

    const v1InfoResponse = await fetch(`${base}/api/v1/server/info`);
    assert.equal(v1InfoResponse.status, 200);
    const v1Info = await v1InfoResponse.json() as Record<string, unknown>;
    assert.equal(v1Info.protocolVersion, 'loom-node-v1');

    const v2InfoResponse = await fetch(`${base}/api/v2/server/info`);
    assert.equal(v2InfoResponse.status, 200);
    const v2Info = await v2InfoResponse.json() as Record<string, unknown>;
    assert.equal(v2Info.protocolVersion, 'loom-delivery-v2');
    assert.equal(v2Info.packetContentVisibleToServer, false);
    assert.equal(v2Info.recipientDeliveryReceiptEndToEnd, true);
    assert.equal(v2Info.directIngressRequiresHomeNodeRoundTrip, false);
    assert.deepEqual(
      (v2Info.capabilities as string[]).includes('direct-destination-node-ingress'),
      true,
    );
    assert.deepEqual(
      (v2Info.capabilities as string[]).includes('self-certifying-device-transport-proof'),
      true,
    );
  } finally {
    await server.close();
    rmSync(dir, { recursive: true, force: true });
  }
});

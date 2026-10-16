import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { LoomNodeIdentity } from '../src/identity/node_identity.ts';
import { canonicalLanAnnouncement, createLanAnnouncement } from '../src/lan/lan_discovery.ts';
import type { LoomNodeConfig } from '../src/config/config.ts';

function config(dir: string): LoomNodeConfig {
  return {
    schemaVersion: 1, mode: 'easy', listenHost: '127.0.0.1', listenPort: 7483,
    publicDomain: 'node.example.test', publicBaseUrl: 'https://node.example.test',
    dataDirectory: dir, attachmentsDirectory: join(dir, 'attachments'), registrationPolicy: 'closed',
    federationMode: 'disabled', networkJurisdiction: 'IR', operatorName: 'Test Node', adminToken: 'x'.repeat(40),
    maxAttachmentBytes: 1024, maxRequestBytes: 1024 * 1024, lanDiscoveryEnabled: true,
  };
}

test('LAN announcement is signed by persistent Node identity and contains no secret material', () => {
  const dir = mkdtempSync(join(tmpdir(), 'loom-lan-'));
  try {
    const identity = LoomNodeIdentity.loadOrCreate(dir);
    const announcement = createLanAnnouncement(config(dir), identity, new Date('2026-09-01T08:00:00.000Z'));
    const { signature, ...unsigned } = announcement;
    assert.equal(identity.verifyUtf8(canonicalLanAnnouncement(unsigned), signature), true);
    assert.equal(announcement.nodeId, identity.publicInfo().nodeId);
    assert.equal(announcement.endpoint, 'https://node.example.test');
    assert.equal(JSON.stringify(announcement).includes('privateKey'), false);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

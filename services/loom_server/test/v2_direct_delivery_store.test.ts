import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { V2DirectDeliveryStore } from '../src/delivery/v2_direct_delivery_store.ts';

function setupDirectory(): {
  dir: string;
  mailboxToken: string;
  accountId: string;
  deviceId: string;
} {
  const dir = mkdtempSync(join(tmpdir(), 'loom-v2-direct-'));
  const db = new DatabaseSync(join(dir, 'loom.sqlite3'));
  db.exec(`
    CREATE TABLE v2_mailboxes (
      mailbox_token TEXT PRIMARY KEY,
      account_id TEXT NOT NULL,
      device_id TEXT NOT NULL,
      expires_at TEXT NOT NULL,
      registered_at TEXT NOT NULL
    );
    CREATE TABLE v2_delivery_packets (
      packet_id TEXT PRIMARY KEY,
      mailbox_token TEXT NOT NULL,
      envelope_base64 TEXT NOT NULL,
      expires_at TEXT NOT NULL,
      priority TEXT NOT NULL,
      accepted_at TEXT NOT NULL,
      sender_account_id TEXT NOT NULL,
      sender_device_id TEXT NOT NULL,
      acknowledged_at TEXT
    );
  `);
  const mailboxToken = Buffer.alloc(32, 4).toString('base64url');
  const accountId = 'account_local_recipient';
  const deviceId = 'device_local_recipient';
  const now = new Date();
  db.prepare(`
    INSERT INTO v2_mailboxes(
      mailbox_token,account_id,device_id,expires_at,registered_at
    ) VALUES(?,?,?,?,?)
  `).run(
    mailboxToken,
    accountId,
    deviceId,
    new Date(now.getTime() + 2 * 24 * 60 * 60 * 1000).toISOString(),
    now.toISOString(),
  );
  db.close();
  return { dir, mailboxToken, accountId, deviceId };
}

test('direct packets enter recipient mailbox without a local sender account', async () => {
  const fixture = setupDirectory();
  const store = V2DirectDeliveryStore.sqliteStore(fixture.dir);
  try {
    const expiresAt = new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString();
    const input = {
      packetId: 'packet_direct_storage_0001',
      mailboxToken: fixture.mailboxToken,
      envelopeBase64: Buffer.from('opaque-packet-v1').toString('base64url'),
      expiresAt,
      priority: 'normal',
    };
    const sender = Buffer.alloc(32, 8).toString('base64url');

    const first = await store.enqueuePacket(sender, input);
    assert.equal(first.idempotent, false);

    const retry = await store.enqueuePacket(sender, input);
    assert.equal(retry.idempotent, true);
    assert.equal(retry.acceptedAt, first.acceptedAt);

    await assert.rejects(
      store.enqueuePacket(sender, {
        ...input,
        envelopeBase64: Buffer.from('different-ciphertext').toString('base64url'),
      }),
      /packet_id_conflict/,
    );

    const packets = await store.pullPackets(
      fixture.accountId,
      fixture.deviceId,
      fixture.mailboxToken,
      10,
    );
    assert.equal(packets.length, 1);
    assert.equal(packets[0].packetId, input.packetId);
    assert.equal(packets[0].envelopeBase64, input.envelopeBase64);

    assert.equal(
      await store.acknowledgePacket(
        fixture.accountId,
        fixture.deviceId,
        input.packetId,
      ),
      true,
    );
    assert.deepEqual(
      await store.pullPackets(
        fixture.accountId,
        fixture.deviceId,
        fixture.mailboxToken,
        10,
      ),
      [],
    );
  } finally {
    await store.close();
    rmSync(fixture.dir, { recursive: true, force: true });
  }
});

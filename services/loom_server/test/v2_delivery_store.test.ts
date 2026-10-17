import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash, generateKeyPairSync, randomBytes } from 'node:crypto';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { SqliteStore } from '../src/storage/sqlite_store.ts';
import { V2DeliveryStore } from '../src/delivery/v2_delivery_store.ts';

function rawPublicKey(pair: ReturnType<typeof generateKeyPairSync>): Buffer {
  const der = pair.publicKey.export({ type: 'spki', format: 'der' });
  return der.subarray(-32);
}

function fingerprint(bytes: Buffer): string {
  const hex = createHash('sha256').update(bytes).digest('hex').toUpperCase();
  return hex.match(/.{1,4}/g)!.join(' ');
}

function registrationBody(username: string): Record<string, unknown> {
  const pair = generateKeyPairSync('ed25519');
  const raw = rawPublicKey(pair);
  const digest = createHash('sha256').update(raw).digest();
  return {
    username,
    displayName: `Display ${username}`,
    password: 'correct horse battery staple',
    deviceName: `${username} device`,
    identity: {
      identityId: `chn:${digest.toString('base64url')}`,
      publicKey: raw.toString('base64'),
      fingerprint: fingerprint(raw),
    },
    protocolVersion: 'Loom-Identity-v1',
  };
}

function futureIso(milliseconds: number): string {
  return new Date(Date.now() + milliseconds).toISOString();
}

test('v2 delivery store isolates mailboxes and consumes opaque prekeys once', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'loom-v2-delivery-'));
  const base = new SqliteStore(dir);
  const delivery = V2DeliveryStore.sqliteStore(dir);
  try {
    const alice = await base.register(registrationBody('alicev2'), 'localhost');
    const bob = await base.register(registrationBody('bobv2'), 'localhost');

    const mailboxToken = randomBytes(32).toString('base64url');
    const mailbox = await delivery.registerMailbox(
      bob.accountId,
      bob.deviceId,
      mailboxToken,
      futureIso(2 * 24 * 60 * 60 * 1000),
    );
    assert.equal(mailbox.deviceId, bob.deviceId);

    const prekeyBundle = randomBytes(64).toString('base64url');
    const published = await delivery.publishPrekeys(
      bob.accountId,
      bob.deviceId,
      [
        {
          prekeyId: 'prekey-00000001',
          bundleBase64: prekeyBundle,
          expiresAt: futureIso(7 * 24 * 60 * 60 * 1000),
        },
      ],
    );
    assert.equal(published.accepted, 1);

    const claimed = await delivery.claimPrekey(bob.deviceId);
    assert.ok(claimed);
    assert.equal(claimed.prekeyId, 'prekey-00000001');
    assert.equal(claimed.bundleBase64, prekeyBundle);
    assert.equal(await delivery.claimPrekey(bob.deviceId), null);

    const envelopeBase64 = randomBytes(128).toString('base64url');
    const input = {
      packetId: 'packet-000000000001',
      mailboxToken,
      envelopeBase64,
      expiresAt: futureIso(24 * 60 * 60 * 1000),
      priority: 'normal',
    };
    const first = await delivery.enqueuePacket(
      alice.accountId,
      alice.deviceId,
      input,
    );
    assert.equal(first.idempotent, false);
    const retry = await delivery.enqueuePacket(
      alice.accountId,
      alice.deviceId,
      input,
    );
    assert.equal(retry.idempotent, true);
    assert.equal(retry.acceptedAt, first.acceptedAt);

    await assert.rejects(
      delivery.enqueuePacket(alice.accountId, alice.deviceId, {
        ...input,
        envelopeBase64: randomBytes(128).toString('base64url'),
      }),
      /packet_id_conflict/,
    );

    await assert.rejects(
      delivery.pullPackets(
        alice.accountId,
        alice.deviceId,
        mailboxToken,
        50,
      ),
      /mailbox_not_owned/,
    );

    const pulled = await delivery.pullPackets(
      bob.accountId,
      bob.deviceId,
      mailboxToken,
      50,
    );
    assert.equal(pulled.length, 1);
    assert.equal(pulled[0].packetId, input.packetId);
    assert.equal(pulled[0].envelopeBase64, envelopeBase64);

    assert.equal(
      await delivery.acknowledgePacket(
        alice.accountId,
        alice.deviceId,
        input.packetId,
      ),
      false,
    );
    assert.equal(
      await delivery.acknowledgePacket(
        bob.accountId,
        bob.deviceId,
        input.packetId,
      ),
      true,
    );
    assert.deepEqual(
      await delivery.pullPackets(
        bob.accountId,
        bob.deviceId,
        mailboxToken,
        50,
      ),
      [],
    );

    await delivery.prune();
    const lateRetry = await delivery.enqueuePacket(
      alice.accountId,
      alice.deviceId,
      input,
    );
    assert.equal(lateRetry.idempotent, true);
    assert.equal(lateRetry.acceptedAt, first.acceptedAt);
    assert.deepEqual(
      await delivery.pullPackets(
        bob.accountId,
        bob.deviceId,
        mailboxToken,
        50,
      ),
      [],
    );

    await assert.rejects(
      delivery.enqueuePacket(alice.accountId, alice.deviceId, {
        packetId: 'packet-000000000002',
        mailboxToken,
        envelopeBase64: randomBytes(64).toString('base64url'),
        expiresAt: futureIso(3 * 24 * 60 * 60 * 1000),
        priority: 'normal',
      }),
      /invalid_packet_expiry/,
    );
  } finally {
    await delivery.close();
    base.close();
    rmSync(dir, { recursive: true, force: true });
  }
});

test('mailbox tokens cannot be rebound to another device', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'loom-v2-mailbox-'));
  const base = new SqliteStore(dir);
  const delivery = V2DeliveryStore.sqliteStore(dir);
  try {
    const alice = await base.register(registrationBody('alicebox'), 'localhost');
    const bob = await base.register(registrationBody('bobbox'), 'localhost');
    const token = randomBytes(32).toString('base64url');
    await delivery.registerMailbox(
      alice.accountId,
      alice.deviceId,
      token,
      futureIso(24 * 60 * 60 * 1000),
    );
    await assert.rejects(
      delivery.registerMailbox(
        bob.accountId,
        bob.deviceId,
        token,
        futureIso(24 * 60 * 60 * 1000),
      ),
      /mailbox_token_in_use/,
    );
  } finally {
    await delivery.close();
    base.close();
    rmSync(dir, { recursive: true, force: true });
  }
});

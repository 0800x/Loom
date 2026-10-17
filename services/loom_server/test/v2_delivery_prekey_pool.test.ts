import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash, generateKeyPairSync, randomBytes } from 'node:crypto';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { SqliteStore } from '../src/storage/sqlite_store.ts';
import { V2PrekeyPool } from '../src/delivery/v2_prekey_pool.ts';

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

function bundle(): string {
  return randomBytes(64).toString('base64url');
}

test('v2 prekey pool consumes OTKs then reuses only the current fallback', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'loom-v2-prekey-pool-'));
  const base = new SqliteStore(dir);
  const pool = V2PrekeyPool.sqliteStore(dir);
  try {
    const bob = await base.register(registrationBody('bobprekey'), 'localhost');
    const expiresAt = futureIso(7 * 24 * 60 * 60 * 1000);
    const fallback1 = bundle();
    const fallback2 = bundle();
    const oneTime1 = bundle();
    const oneTime2 = bundle();

    const published = await pool.publish(bob.accountId, bob.deviceId, [
      {
        prekeyId: 'otk-00000001',
        keyKind: 'one_time',
        bundleBase64: oneTime1,
        expiresAt,
      },
      {
        prekeyId: 'otk-00000002',
        keyKind: 'one_time',
        bundleBase64: oneTime2,
        expiresAt,
      },
      {
        prekeyId: 'fallback-00000001',
        keyKind: 'fallback',
        bundleBase64: fallback1,
        expiresAt,
      },
    ]);
    assert.equal(published.accepted, 3);

    const first = await pool.claim(bob.deviceId);
    const second = await pool.claim(bob.deviceId);
    assert.ok(first);
    assert.ok(second);
    assert.equal(first.keyKind, 'one_time');
    assert.equal(second.keyKind, 'one_time');
    assert.deepEqual(
      new Set([first.prekeyId, second.prekeyId]),
      new Set(['otk-00000001', 'otk-00000002']),
    );

    const fallbackClaim1 = await pool.claim(bob.deviceId);
    const fallbackClaim2 = await pool.claim(bob.deviceId);
    assert.ok(fallbackClaim1);
    assert.ok(fallbackClaim2);
    assert.equal(fallbackClaim1.keyKind, 'fallback');
    assert.equal(fallbackClaim1.prekeyId, 'fallback-00000001');
    assert.equal(fallbackClaim1.bundleBase64, fallback1);
    assert.equal(fallbackClaim2.prekeyId, fallbackClaim1.prekeyId);
    assert.equal(fallbackClaim2.bundleBase64, fallback1);

    const rotated = await pool.publish(bob.accountId, bob.deviceId, [
      {
        prekeyId: 'fallback-00000002',
        keyKind: 'fallback',
        bundleBase64: fallback2,
        expiresAt,
      },
    ]);
    assert.equal(rotated.accepted, 1);

    const afterRotation = await pool.claim(bob.deviceId);
    assert.ok(afterRotation);
    assert.equal(afterRotation.keyKind, 'fallback');
    assert.equal(afterRotation.prekeyId, 'fallback-00000002');
    assert.equal(afterRotation.bundleBase64, fallback2);

    // Exact retry is idempotent and must not make the retired fallback current.
    const retryOld = await pool.publish(bob.accountId, bob.deviceId, [
      {
        prekeyId: 'fallback-00000001',
        keyKind: 'fallback',
        bundleBase64: fallback1,
        expiresAt,
      },
    ]);
    assert.equal(retryOld.accepted, 0);
    assert.equal((await pool.claim(bob.deviceId))!.prekeyId, 'fallback-00000002');

    await assert.rejects(
      pool.publish(bob.accountId, bob.deviceId, [
        {
          prekeyId: 'fallback-00000001',
          keyKind: 'fallback',
          bundleBase64: bundle(),
          expiresAt,
        },
      ]),
      /prekey_id_conflict/,
    );
  } finally {
    await pool.close();
    base.close();
    rmSync(dir, { recursive: true, force: true });
  }
});

test('legacy prekey publish without keyKind remains one-shot', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'loom-v2-prekey-legacy-'));
  const base = new SqliteStore(dir);
  const pool = V2PrekeyPool.sqliteStore(dir);
  try {
    const bob = await base.register(registrationBody('boblegacykey'), 'localhost');
    const material = bundle();
    const result = await pool.publish(bob.accountId, bob.deviceId, [
      {
        prekeyId: 'legacy-prekey-0001',
        bundleBase64: material,
        expiresAt: futureIso(24 * 60 * 60 * 1000),
      },
    ]);
    assert.equal(result.accepted, 1);
    const claimed = await pool.claim(bob.deviceId);
    assert.ok(claimed);
    assert.equal(claimed.keyKind, 'one_time');
    assert.equal(claimed.bundleBase64, material);
    assert.equal(await pool.claim(bob.deviceId), null);
  } finally {
    await pool.close();
    base.close();
    rmSync(dir, { recursive: true, force: true });
  }
});

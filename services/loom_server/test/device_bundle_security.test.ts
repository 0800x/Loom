import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash, generateKeyPairSync, sign } from 'node:crypto';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { SqliteStore } from '../src/storage/sqlite_store.ts';
import { DeviceBundleStore } from '../src/security/device_bundle_store.ts';

function rawPublicKey(pair: ReturnType<typeof generateKeyPairSync>): Buffer {
  const der = pair.publicKey.export({ type: 'spki', format: 'der' });
  return der.subarray(-32);
}

function fingerprint(bytes: Buffer): string {
  const hex = createHash('sha256').update(bytes).digest('hex').toUpperCase();
  return hex.match(/.{1,4}/g)!.join(' ');
}

function identityMaterial() {
  const pair = generateKeyPairSync('ed25519');
  const raw = rawPublicKey(pair);
  const digest = createHash('sha256').update(raw).digest();
  return {
    pair,
    public: {
      identityId: `chn:${digest.toString('base64url')}`,
      publicKey: raw.toString('base64'),
      fingerprint: fingerprint(raw),
    },
  };
}

function canonicalBundle(input: {
  identityId: string;
  deviceId: string;
  deviceName: string;
  signingPublicKey: string;
  agreementPublicKey: string;
  createdAt: string;
  capabilities: string[];
}): Buffer {
  return Buffer.from(JSON.stringify({
    bundleVersion: 1,
    identityId: input.identityId,
    deviceId: input.deviceId,
    deviceName: input.deviceName,
    signingPublicKey: input.signingPublicKey,
    agreementPublicKey: input.agreementPublicKey,
    createdAt: input.createdAt,
    capabilities: [...input.capabilities].sort(),
  }), 'utf8');
}

function makeBundle(identity: ReturnType<typeof identityMaterial>, deviceId: string) {
  const signingPair = generateKeyPairSync('ed25519');
  const agreementPair = generateKeyPairSync('x25519');
  const unsigned = {
    identityId: identity.public.identityId,
    deviceId,
    deviceName: 'Test Device',
    signingPublicKey: rawPublicKey(signingPair).toString('base64'),
    agreementPublicKey: rawPublicKey(agreementPair).toString('base64'),
    createdAt: new Date().toISOString(),
    capabilities: ['agreement-x25519', 'signing-ed25519'],
  };
  const canonical = canonicalBundle(unsigned);
  return {
    ...unsigned,
    bundleVersion: 1 as const,
    fingerprint: fingerprint(canonical),
    deviceSignature: sign(null, canonical, signingPair.privateKey).toString('base64'),
    identitySignature: sign(null, canonical, identity.pair.privateKey).toString('base64'),
  };
}

test('device bundle requires both device and identity signatures and rejects silent key replacement', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'loom-device-bundle-'));
  const accounts = new SqliteStore(dir);
  const bundles = DeviceBundleStore.sqliteStore(dir);
  try {
    const identity = identityMaterial();
    const registration = await accounts.register({
      username: 'alice',
      displayName: 'Alice',
      password: 'correct horse battery staple',
      deviceName: 'Alice test device',
      identity: identity.public,
      protocolVersion: 'Loom-Identity-v1',
    }, 'loom-a.test');
    const session = accounts.authenticate(registration.accessToken);
    assert.ok(session);

    const bundle = makeBundle(identity, registration.deviceId);
    const stored = await bundles.publish(session.accountId, session.identityId, session.deviceId, bundle);
    assert.equal(stored.fingerprint, bundle.fingerprint);

    const listed = await bundles.listForIdentity(identity.public.identityId);
    assert.equal(listed.length, 1);
    assert.equal(listed[0].deviceId, registration.deviceId);
    assert.equal(listed[0].agreementPublicKey, bundle.agreementPublicKey);

    const tampered = { ...bundle, agreementPublicKey: Buffer.alloc(32, 7).toString('base64') };
    await assert.rejects(
      bundles.publish(session.accountId, session.identityId, session.deviceId, tampered),
      /invalid_device_bundle_fingerprint|invalid_device_bundle_signature|invalid_device_identity_signature/,
    );

    const replacement = makeBundle(identity, registration.deviceId);
    await assert.rejects(
      bundles.publish(session.accountId, session.identityId, session.deviceId, replacement),
      /device_key_change_requires_rotation/,
    );
  } finally {
    await bundles.close();
    accounts.close();
    rmSync(dir, { recursive: true, force: true });
  }
});

test('device bundle cannot be published for another authenticated device', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'loom-device-binding-'));
  const accounts = new SqliteStore(dir);
  const bundles = DeviceBundleStore.sqliteStore(dir);
  try {
    const identity = identityMaterial();
    const first = await accounts.register({
      username: 'alice',
      displayName: 'Alice',
      password: 'correct horse battery staple',
      deviceName: 'First device',
      identity: identity.public,
      protocolVersion: 'Loom-Identity-v1',
    }, 'loom-a.test');
    const second = await accounts.login('alice', 'correct horse battery staple', 'Second device');
    assert.notEqual(first.deviceId, second.deviceId);
    const secondSession = accounts.authenticate(second.accessToken);
    assert.ok(secondSession);
    const bundleForFirst = makeBundle(identity, first.deviceId);
    await assert.rejects(
      bundles.publish(secondSession.accountId, secondSession.identityId, secondSession.deviceId, bundleForFirst),
      /device_bundle_session_mismatch/,
    );
  } finally {
    await bundles.close();
    accounts.close();
    rmSync(dir, { recursive: true, force: true });
  }
});

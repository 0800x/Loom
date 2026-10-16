import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash, generateKeyPairSync, randomBytes, sign } from 'node:crypto';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import type { IncomingMessage } from 'node:http';
import { SqliteStore } from '../src/storage/sqlite_store.ts';
import { DeviceBundleStore } from '../src/security/device_bundle_store.ts';
import { canonicalDeviceRequestProof, DeviceRequestVerifier, sha256Hex } from '../src/security/device_request_proof.ts';

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
    deviceName: 'Proof test device',
    signingPublicKey: rawPublicKey(signingPair).toString('base64'),
    agreementPublicKey: rawPublicKey(agreementPair).toString('base64'),
    createdAt: new Date().toISOString(),
    capabilities: ['agreement-x25519', 'signing-ed25519'],
  };
  const canonical = canonicalBundle(unsigned);
  return {
    signingPair,
    bundle: {
      ...unsigned,
      bundleVersion: 1 as const,
      fingerprint: fingerprint(canonical),
      deviceSignature: sign(null, canonical, signingPair.privateKey).toString('base64'),
      identitySignature: sign(null, canonical, identity.pair.privateKey).toString('base64'),
    },
  };
}

function requestProof(input: {
  method: string;
  target: string;
  deviceId: string;
  credential: string;
  privateKey: ReturnType<typeof generateKeyPairSync>['privateKey'];
  body?: Buffer;
  nonce?: string;
  timestampMs?: number;
}): IncomingMessage {
  const body = input.body ?? Buffer.alloc(0);
  const bodySha256 = sha256Hex(body);
  const timestampMs = input.timestampMs ?? Date.now();
  const nonce = input.nonce ?? randomBytes(24).toString('base64url');
  const canonical = canonicalDeviceRequestProof({
    method: input.method,
    target: input.target,
    bodySha256,
    timestampMs,
    nonce,
    deviceId: input.deviceId,
    credentialSha256: sha256Hex(input.credential),
  });
  return {
    method: input.method,
    url: input.target,
    headers: {
      'x-loom-device-id': input.deviceId,
      'x-loom-request-timestamp': String(timestampMs),
      'x-loom-request-nonce': nonce,
      'x-loom-content-sha256': bodySha256,
      'x-loom-request-signature': sign(null, Buffer.from(canonical), input.privateKey).toString('base64'),
    },
  } as IncomingMessage;
}

test('device-bound request proof accepts a valid signed request and rejects replay', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'loom-device-proof-'));
  const accounts = new SqliteStore(dir);
  const bundles = DeviceBundleStore.sqliteStore(dir);
  try {
    const identity = identityMaterial();
    const registration = accounts.register({
      username: 'alice',
      displayName: 'Alice',
      password: 'correct horse battery staple',
      deviceName: 'Alice test device',
      identity: identity.public,
      protocolVersion: 'Loom-Identity-v1',
    }, 'loom-a.test');
    const session = accounts.authenticate(registration.accessToken);
    assert.ok(session);
    const device = makeBundle(identity, registration.deviceId);
    await bundles.publish(session.accountId, session.identityId, session.deviceId, device.bundle);
    const verifier = new DeviceRequestVerifier(bundles);
    const body = Buffer.from(JSON.stringify({ conversationId: 'conv_test' }));
    const nonce = randomBytes(24).toString('base64url');
    const request = requestProof({
      method: 'POST',
      target: '/api/v1/messages',
      deviceId: registration.deviceId,
      credential: registration.accessToken,
      privateKey: device.signingPair.privateKey,
      body,
      nonce,
    });
    const verified = await verifier.verify(request, session, registration.accessToken);
    assert.equal(verified.deviceId, registration.deviceId);
    assert.equal(verified.bodySha256, sha256Hex(body));
    await assert.rejects(
      verifier.verify(request, session, registration.accessToken),
      /device_request_replay_detected/,
    );
  } finally {
    await bundles.close();
    accounts.close();
    rmSync(dir, { recursive: true, force: true });
  }
});

test('device-bound proof rejects missing signatures, stale timestamps and wrong credential binding', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'loom-device-proof-negative-'));
  const accounts = new SqliteStore(dir);
  const bundles = DeviceBundleStore.sqliteStore(dir);
  try {
    const identity = identityMaterial();
    const registration = accounts.register({
      username: 'alice',
      displayName: 'Alice',
      password: 'correct horse battery staple',
      deviceName: 'Alice test device',
      identity: identity.public,
      protocolVersion: 'Loom-Identity-v1',
    }, 'loom-a.test');
    const session = accounts.authenticate(registration.accessToken);
    assert.ok(session);
    const device = makeBundle(identity, registration.deviceId);
    await bundles.publish(session.accountId, session.identityId, session.deviceId, device.bundle);
    const verifier = new DeviceRequestVerifier(bundles);

    const missing = { method: 'GET', url: '/api/v1/sync', headers: {} } as IncomingMessage;
    await assert.rejects(
      verifier.verify(missing, session, registration.accessToken),
      /device_request_proof_required/,
    );

    const stale = requestProof({
      method: 'GET',
      target: '/api/v1/sync?limit=200',
      deviceId: registration.deviceId,
      credential: registration.accessToken,
      privateKey: device.signingPair.privateKey,
      timestampMs: Date.now() - 5 * 60_000,
    });
    await assert.rejects(
      verifier.verify(stale, session, registration.accessToken),
      /stale_device_request/,
    );

    const wrongCredential = requestProof({
      method: 'GET',
      target: '/api/v1/sync?limit=200',
      deviceId: registration.deviceId,
      credential: 'stolen-or-different-token',
      privateKey: device.signingPair.privateKey,
    });
    await assert.rejects(
      verifier.verify(wrongCredential, session, registration.accessToken),
      /invalid_device_request_signature/,
    );
  } finally {
    await bundles.close();
    accounts.close();
    rmSync(dir, { recursive: true, force: true });
  }
});

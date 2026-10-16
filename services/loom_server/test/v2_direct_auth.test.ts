import test from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync, sign } from 'node:crypto';

import {
  canonicalV2DirectPacketBytes,
  verifyV2DirectTransportProof,
} from '../src/delivery/v2_direct_auth.ts';

function fixture(now = new Date('2026-09-07T07:30:00.000Z')) {
  const { publicKey, privateKey } = generateKeyPairSync('ed25519');
  const spki = publicKey.export({ type: 'spki', format: 'der' });
  const rawPublicKey = Buffer.from(spki).subarray(-32);
  const body: Record<string, unknown> = {
    packetId: 'packet_direct_test_0001',
    mailboxToken: Buffer.alloc(32, 7).toString('base64url'),
    envelopeBase64: Buffer.from('opaque-ciphertext').toString('base64url'),
    expiresAt: '2026-09-08T07:30:00.000Z',
    priority: 'normal',
  };
  const unsigned = {
    devicePublicKey: rawPublicKey.toString('base64url'),
    issuedAt: now.toISOString(),
    nonce: Buffer.alloc(24, 9).toString('base64url'),
  };
  const signature = sign(
    null,
    canonicalV2DirectPacketBytes(body, unsigned),
    privateKey,
  ).toString('base64url');
  return {
    body,
    proof: { ...unsigned, signature },
    now,
  };
}

test('direct transport proof is self-certifying and deterministic', () => {
  const value = fixture();
  const fingerprint = verifyV2DirectTransportProof(
    value.body,
    value.proof,
    value.now.getTime(),
  );
  assert.match(fingerprint, /^[A-Za-z0-9_-]{43}$/);
  assert.equal(
    fingerprint,
    verifyV2DirectTransportProof(value.body, value.proof, value.now.getTime()),
  );
});

test('direct transport proof binds the exact opaque packet request', () => {
  const value = fixture();
  const changed = { ...value.body, priority: 'urgent' };
  assert.throws(
    () => verifyV2DirectTransportProof(changed, value.proof, value.now.getTime()),
    /invalid_direct_transport_signature/,
  );
});

test('direct transport proof rejects stale signed requests', () => {
  const value = fixture();
  assert.throws(
    () => verifyV2DirectTransportProof(
      value.body,
      value.proof,
      value.now.getTime() + 6 * 60_000,
    ),
    /stale_direct_transport_proof/,
  );
});

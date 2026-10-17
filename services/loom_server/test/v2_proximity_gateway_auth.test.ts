import test from 'node:test';
import assert from 'node:assert/strict';
import {
  createHash,
  generateKeyPairSync,
  sign,
  type KeyObject,
} from 'node:crypto';
import {
  canonicalGatewayProofBytes,
  canonicalProximityLeaseBytes,
  verifyGatewayTransportProof,
  verifyRecipientSignedProximityLease,
  type V2GatewayTransportProof,
  type V2ProximityGatewayLease,
} from '../src/delivery/v2_proximity_gateway_auth.ts';

function rawPublic(key: KeyObject): Buffer {
  const der = key.export({ format: 'der', type: 'spki' }) as Buffer;
  return der.subarray(der.length - 32);
}

function baseLease(now = Date.now()): {
  unsigned: Omit<V2ProximityGatewayLease, 'signature'>;
  recipientPrivate: KeyObject;
  recipientPublicBase64: string;
  gatewayPrivate: KeyObject;
} {
  const recipient = generateKeyPairSync('ed25519');
  const gateway = generateKeyPairSync('ed25519');
  const gatewayRaw = rawPublic(gateway.publicKey);
  const unsigned: Omit<V2ProximityGatewayLease, 'signature'> = {
    version: 1,
    leaseId: 'lease-test-0123456789',
    sessionId: 'session-test-0123456789',
    recipientIdentityId: 'chn:recipient-test-identity',
    recipientDeviceId: 'device-recipient-0123456789',
    recipientNodeId: 'node:recipient-test-node',
    recipientNodeDomain: 'chat.example.test',
    gatewayDevicePublicKey: gatewayRaw.toString('base64url'),
    gatewayFingerprint: createHash('sha256').update(gatewayRaw).digest('base64url'),
    gatewayEphemeralPublicKey: Buffer.alloc(32, 0x41).toString('base64url'),
    recipientEphemeralPublicKey: Buffer.alloc(32, 0x42).toString('base64url'),
    bearer: 'ble',
    issuedAt: new Date(now).toISOString(),
    expiresAt: new Date(now + 90_000).toISOString(),
    nonce: Buffer.alloc(24, 0x43).toString('base64url'),
    maxPackets: 20,
    maxBytes: 512 * 1024,
  };
  return {
    unsigned,
    recipientPrivate: recipient.privateKey,
    recipientPublicBase64: rawPublic(recipient.publicKey).toString('base64'),
    gatewayPrivate: gateway.privateKey,
  };
}

function signedLease(now = Date.now()): {
  lease: V2ProximityGatewayLease;
  recipientPublicBase64: string;
  gatewayPrivate: KeyObject;
} {
  const fixture = baseLease(now);
  const signature = sign(
    null,
    canonicalProximityLeaseBytes(fixture.unsigned),
    fixture.recipientPrivate,
  ).toString('base64url');
  return {
    lease: { ...fixture.unsigned, signature },
    recipientPublicBase64: fixture.recipientPublicBase64,
    gatewayPrivate: fixture.gatewayPrivate,
  };
}

test('recipient-signed proximity lease binds node and Nearby transcript', () => {
  const now = Date.now();
  const fixture = signedLease(now);
  const verified = verifyRecipientSignedProximityLease(
    fixture.lease,
    fixture.recipientPublicBase64,
    now,
  );
  assert.equal(verified.recipientNodeDomain, 'chat.example.test');
  assert.equal(
    verified.gatewayEphemeralPublicKey,
    fixture.lease.gatewayEphemeralPublicKey,
  );

  for (const mutation of [
    { recipientNodeDomain: 'evil.example.test' },
    { gatewayEphemeralPublicKey: Buffer.alloc(32, 0x55).toString('base64url') },
    { recipientEphemeralPublicKey: Buffer.alloc(32, 0x56).toString('base64url') },
    { sessionId: 'session-tampered-0123456789' },
  ]) {
    assert.throws(() => verifyRecipientSignedProximityLease(
      { ...fixture.lease, ...mutation },
      fixture.recipientPublicBase64,
      now,
    ), /invalid_gateway_recipient_signature/);
  }
});

test('proximity lease rejects excessive lifetime', () => {
  const now = Date.now();
  const fixture = baseLease(now);
  const unsigned = {
    ...fixture.unsigned,
    expiresAt: new Date(now + 121_000).toISOString(),
  };
  const lease: V2ProximityGatewayLease = {
    ...unsigned,
    signature: sign(
      null,
      canonicalProximityLeaseBytes(unsigned),
      fixture.recipientPrivate,
    ).toString('base64url'),
  };
  assert.throws(() => verifyRecipientSignedProximityLease(
    lease,
    fixture.recipientPublicBase64,
    now,
  ), /invalid_gateway_lease_expiry/);
});

test('gateway proof binds action and claim context', () => {
  const now = Date.now();
  const fixture = signedLease(now);
  const unsignedProof: Omit<V2GatewayTransportProof, 'signature'> = {
    devicePublicKey: fixture.lease.gatewayDevicePublicKey,
    issuedAt: new Date(now).toISOString(),
    nonce: Buffer.alloc(24, 0x77).toString('base64url'),
  };
  const context = {
    leaseId: fixture.lease.leaseId,
    recipientDeviceId: fixture.lease.recipientDeviceId,
    limit: 20,
  };
  const proof: V2GatewayTransportProof = {
    ...unsignedProof,
    signature: sign(
      null,
      canonicalGatewayProofBytes('claim', context, unsignedProof),
      fixture.gatewayPrivate,
    ).toString('base64url'),
  };

  const verified = verifyGatewayTransportProof('claim', context, proof, now);
  assert.equal(verified.publicKey, fixture.lease.gatewayDevicePublicKey);
  assert.throws(() => verifyGatewayTransportProof(
    'register',
    context,
    proof,
    now,
  ), /invalid_gateway_transport_signature/);
  assert.throws(() => verifyGatewayTransportProof(
    'claim',
    { ...context, limit: 21 },
    proof,
    now,
  ), /invalid_gateway_transport_signature/);
});

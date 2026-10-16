import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { LoomNodeIdentity } from '../src/identity/node_identity.ts';
import {
  createHandshake,
  createHandshakeResponse,
  federationHandshakePayload,
  fingerprintForPublicKey,
  handshakeResponsePayload,
  nodeIdForPublicKey,
  validateHandshake,
  verifyDiscovery,
} from '../src/federation/protocol.ts';

test('signed federation discovery and handshake bind node identity, endpoint and nonce', () => {
  const dir = mkdtempSync(join(tmpdir(), 'loom-federation-'));
  try {
    const identity = LoomNodeIdentity.loadOrCreate(dir);
    const info = identity.publicInfo();
    assert.equal(nodeIdForPublicKey(info.publicKey), info.nodeId);
    assert.equal(fingerprintForPublicKey(info.publicKey), info.fingerprint);

    const endpoint = 'https://node.example.com';
    const protocol = 'loom-federation-v1';
    const discoveryPayload = `node.example.com\n${protocol}\n${endpoint}\n${info.nodeId}\n${info.publicKey}`;
    const verifiedDiscovery = verifyDiscovery({
      endpoint,
      nodeId: info.nodeId,
      protocol,
      publicKey: info.publicKey,
      signature: identity.signUtf8(discoveryPayload),
    });
    assert.equal(verifiedDiscovery.domain, 'node.example.com');
    assert.equal(verifiedDiscovery.fingerprint, info.fingerprint);

    assert.throws(() => verifyDiscovery({
      endpoint: 'https://evil.example.com',
      nodeId: info.nodeId,
      protocol,
      publicKey: info.publicKey,
      signature: identity.signUtf8(discoveryPayload),
    }), /invalid_federation_discovery_signature/);

    const handshake = createHandshake(identity, 'node.example.com', endpoint);
    const verifiedHandshake = validateHandshake(handshake);
    assert.equal(verifiedHandshake.nodeId, info.nodeId);
    assert.equal(verifiedHandshake.domain, 'node.example.com');
    assert.ok(LoomNodeIdentity.verifyUtf8(federationHandshakePayload(handshake), handshake.signature, info.publicKey));

    assert.throws(() => validateHandshake({ ...handshake, nonce: 'tampered_nonce_value_1234' }), /invalid_federation_handshake_signature/);
    assert.throws(() => validateHandshake({ ...handshake, issuedAt: new Date(Date.now() - 10 * 60_000).toISOString(), signature: identity.signUtf8(federationHandshakePayload({ ...handshake, issuedAt: new Date(Date.now() - 10 * 60_000).toISOString() })) }), /stale_federation_handshake/);

    const response = createHandshakeResponse(identity, 'node:requester', 'node.example.com', endpoint, handshake.nonce);
    assert.ok(LoomNodeIdentity.verifyUtf8(handshakeResponsePayload(response, 'node:requester'), response.signature, info.publicKey));
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

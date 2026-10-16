import 'dart:convert';

import 'package:loom_federation/loom_federation.dart';
import 'package:cryptography/cryptography.dart';
import 'package:test/test.dart';

class MemoryReplayStore implements LoomFederationReplayStore {
  final Set<String> seen = <String>{};

  @override
  Future<bool> remember(String eventId, DateTime expiresAt) async =>
      seen.add(eventId);
}

void main() {
  test('canonical JSON sorts map keys', () {
    expect(
      loomCanonicalJson({
        'z': 1,
        'a': {'d': 2, 'b': 1},
      }),
      '{"a":{"b":1,"d":2},"z":1}',
    );
  });

  test('signed event validates once and replay is rejected', () async {
    final algorithm = Ed25519();
    final keyPair = await algorithm.newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    final now = DateTime.utc(2026, 9, 1, 12);
    final unsigned = LoomFederationEvent(
      eventId: 'evt_01HSAFE',
      originNodeId: 'chn:node:alpha',
      destinationDomain: 'beta.example',
      conversationId: 'conv_123',
      type: LoomFederationEventType.message,
      createdAt: now,
      expiresAt: now.add(const Duration(hours: 1)),
      hopCount: 0,
      maxHops: 4,
      nonce: 'nonce_123456789',
      body: const {'ciphertext': 'opaque'},
      signature: '',
    );
    final signed = await loomSignFederationEvent(
      unsignedEvent: unsigned,
      keyPair: keyPair,
    );
    final peer = LoomFederationPeer(
      nodeId: 'chn:node:alpha',
      domain: 'alpha.example',
      publicKey: base64Encode(publicKey.bytes),
      fingerprint: 'TEST',
      endpoint: Uri.parse('https://alpha.example/federation/v1'),
    );
    final verifier = LoomFederationVerifier(replayStore: MemoryReplayStore());
    await verifier.validateIncoming(
      event: signed,
      authenticatedPeer: peer,
      originPublicKeyBase64: base64Encode(publicKey.bytes),
      policy: const LoomFederationPolicy(mode: LoomFederationMode.open),
      localDomain: 'beta.example',
      now: now,
    );
    expect(
      () => verifier.validateIncoming(
        event: signed,
        authenticatedPeer: peer,
        originPublicKeyBase64: base64Encode(publicKey.bytes),
        policy: const LoomFederationPolicy(mode: LoomFederationMode.open),
        localDomain: 'beta.example',
        now: now,
      ),
      throwsA(isA<LoomFederationValidationException>()),
    );
  });

  test('request proof binds method path and body', () async {
    final algorithm = Ed25519();
    final keyPair = await algorithm.newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    final now = DateTime.utc(2026, 9, 1, 12);
    final proof = await loomSignFederationRequest(
      nodeId: 'chn:node:alpha',
      method: 'POST',
      path: '/federation/v1/events',
      timestamp: now,
      nonce: 'nonce-request-1',
      body: const {'eventId': 'evt_1'},
      keyPair: keyPair,
    );
    expect(
      await loomVerifyFederationRequest(
        proof: proof,
        method: 'POST',
        path: '/federation/v1/events',
        body: const {'eventId': 'evt_1'},
        publicKeyBase64: base64Encode(publicKey.bytes),
        now: now,
      ),
      isTrue,
    );
    expect(
      await loomVerifyFederationRequest(
        proof: proof,
        method: 'POST',
        path: '/federation/v1/events',
        body: const {'eventId': 'tampered'},
        publicKeyBase64: base64Encode(publicKey.bytes),
        now: now,
      ),
      isFalse,
    );
  });

  test('trusted policy rejects unknown peer', () {
    const policy = LoomFederationPolicy(
      mode: LoomFederationMode.trustedNodesOnly,
      trustedNodeIds: {'chn:node:trusted'},
    );
    final peer = LoomFederationPeer(
      nodeId: 'chn:node:unknown',
      domain: 'unknown.example',
      publicKey: 'unused',
      fingerprint: 'unused',
      endpoint: Uri.parse('https://unknown.example/federation/v1'),
    );
    expect(policy.allowsPeer(peer), isFalse);
  });
}

import 'dart:convert';

import 'package:loom_crypto_bridge/loom_crypto_bridge.dart';
import 'package:loom_models/loom_models.dart';
import 'package:cryptography/cryptography.dart';
import 'package:test/test.dart';

void main() {
  test(
    'compatibility capsule hides message metadata from DTN relays',
    () async {
      final x = X25519();
      final recipient = await x.newKeyPair();
      final recipientPublic = await recipient.extractPublicKey();
      final codec = LoomLegacyDtnCompatibilityCodec();
      final capsule = LoomLegacyDtnMessageCapsule(
        conversationId: 'conv-secret-123',
        clientId: 'client-secret-456',
        senderAddress: '@alice:sender.example',
        type: LoomMessageType.text,
        ciphertext: 'production-e2ee-ciphertext-secret',
        protocolVersion: 'Loom-Direct-v1',
        createdAt: DateTime.utc(2026, 9, 12, 12),
        metadata: const <String, Object?>{'secret-meta': 'private'},
      );

      final draft = await codec.seal(
        capsule: capsule,
        recipientDeviceId: 'device-bob-1',
        recipientAgreementPublicKey: base64Encode(recipientPublic.bytes),
        now: DateTime.utc(2026, 9, 12, 12),
      );

      final wireText = utf8.decode(draft.encryptedPayload);
      for (final forbidden in <String>[
        capsule.conversationId,
        capsule.clientId,
        capsule.senderAddress,
        capsule.ciphertext,
        'secret-meta',
        'private',
      ]) {
        expect(wireText, isNot(contains(forbidden)));
      }

      final sealed = codec.decodeSealedPayload(draft.encryptedPayload);
      final clear = await LoomRelaySealer().open(
        payload: sealed,
        recipientAgreementKeyPair: recipient,
        associatedData: codec.associatedData(
          packetId: draft.packetId,
          mailboxToken: draft.mailboxToken,
          recipientDeviceId: 'device-bob-1',
        ),
      );
      final decoded = codec.decodeClearCapsule(clear);
      expect(decoded.conversationId, capsule.conversationId);
      expect(decoded.clientId, capsule.clientId);
      expect(decoded.senderAddress, capsule.senderAddress);
      expect(decoded.ciphertext, capsule.ciphertext);
      expect(decoded.metadata['secret-meta'], 'private');
    },
  );

  test('packet id is stable per client and recipient device', () async {
    final codec = LoomLegacyDtnCompatibilityCodec();
    final first = await codec.deterministicPacketId(
      clientId: 'client-1',
      recipientDeviceId: 'device-1',
    );
    final again = await codec.deterministicPacketId(
      clientId: 'client-1',
      recipientDeviceId: 'device-1',
    );
    final otherDevice = await codec.deterministicPacketId(
      clientId: 'client-1',
      recipientDeviceId: 'device-2',
    );
    expect(first, again);
    expect(first, isNot(otherDevice));
    expect(first, startsWith('pkt_'));
  });
}

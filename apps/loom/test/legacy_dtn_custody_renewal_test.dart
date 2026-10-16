import 'dart:io';

import 'package:loom_models/loom_models.dart';
import 'package:loom_next/features/messaging/application/legacy_dtn_custody.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'live retries reuse exact custody and expired custody gets a new packet',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'loom-dtn-renewal-',
      );
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });

      final recipient = LoomDeviceKeyBundle.unsigned(
        identityId: 'identity-bob',
        deviceId: 'device-bob-1',
        deviceName: 'Bob phone',
        signingPublicKey: 'unused-in-this-test',
        // RFC 7748 X25519 public-key test vector, base64 encoded.
        agreementPublicKey: 'hSDwCYkwp1R0i33ctD73Wg2/Og0mOBr066SpjqqbTmo=',
        createdAt: DateTime.utc(2026, 9, 1),
        capabilities: const <String>['messaging'],
      );
      const writer = LoomLegacyDtnCustodyWriter();
      final firstAt = DateTime.utc(2026, 9, 12, 12);

      final first = (await writer.persist(
        applicationSupportPath: directory.path,
        destinationNodeDomain: 'node.example',
        senderAddress: '@alice:sender.example',
        conversationId: 'conversation-0001',
        clientId: 'client-message-0001',
        type: LoomMessageType.text,
        ciphertext: 'production-e2ee-ciphertext',
        protocolVersion: 'Loom-Direct-v1',
        recipientDevices: <LoomDeviceKeyBundle>[recipient],
        now: firstAt,
      )).single;

      final retry = (await writer.persist(
        applicationSupportPath: directory.path,
        destinationNodeDomain: 'node.example',
        senderAddress: '@alice:sender.example',
        conversationId: 'conversation-0001',
        clientId: 'client-message-0001',
        type: LoomMessageType.text,
        ciphertext: 'production-e2ee-ciphertext',
        protocolVersion: 'Loom-Direct-v1',
        recipientDevices: <LoomDeviceKeyBundle>[recipient],
        now: firstAt.add(const Duration(days: 1)),
      )).single;

      expect(retry.packetId, first.packetId);
      expect(retry.wireBytes, orderedEquals(first.wireBytes));

      final afterExpiry = firstAt.add(const Duration(days: 7));
      expect(first.expiresAt.isBefore(afterExpiry), isTrue);
      final renewed = (await writer.persist(
        applicationSupportPath: directory.path,
        destinationNodeDomain: 'node.example',
        senderAddress: '@alice:sender.example',
        conversationId: 'conversation-0001',
        clientId: 'client-message-0001',
        type: LoomMessageType.text,
        ciphertext: 'production-e2ee-ciphertext',
        protocolVersion: 'Loom-Direct-v1',
        recipientDevices: <LoomDeviceKeyBundle>[recipient],
        now: afterExpiry,
      )).single;

      expect(renewed.packetId, isNot(first.packetId));
      expect(renewed.expiresAt.isAfter(afterExpiry), isTrue);
    },
  );
}

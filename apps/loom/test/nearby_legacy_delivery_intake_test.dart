import 'dart:io';

import 'package:loom_models/loom_models.dart';
import 'package:loom_next/features/messaging/application/nearby_legacy_delivery_intake.dart';
import 'package:loom_storage/loom_storage.dart';
import 'package:loom_transport/loom_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reverse Nearby ACK follows durable message intake', () async {
    final directory = await Directory.systemTemp.createTemp(
      'loom-nearby-inbound-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final delivery = LoomLegacyGatewayDelivery(
      deliveryId: 'legacy:event-nearby-1',
      conversation: const LoomConversation(
        id: 'conv-nearby-1',
        kind: LoomConversationKind.direct,
        peerAddress: '@alice:node-a.example',
        updatedOrder: 12,
        unreadCount: 1,
        isMuted: false,
        isPinned: false,
      ),
      event: LoomSyncEvent(
        eventId: 'event-nearby-1',
        kind: 'message.created',
        order: 12,
        payload: <String, Object?>{
          'id': 'message-nearby-1',
          'clientId': 'client-nearby-1',
          'conversationId': 'conv-nearby-1',
          'senderAddress': '@alice:node-a.example',
          'type': 'text',
          'ciphertext': 'opaque-nearby-ciphertext',
          'protocolVersion': 'Loom-Direct-v1',
          'serverOrder': 12,
          'createdAt': DateTime.utc(2026, 9, 12, 7).toIso8601String(),
        },
      ),
    );

    expect(
      await LoomNearbyLegacyDeliveryIntake.acceptOnce(
        applicationSupportPath: directory.path,
        ownAddress: '@sara:node-b.example',
        delivery: delivery,
      ),
      isTrue,
    );
    expect(
      await LoomNearbyLegacyDeliveryIntake.acceptOnce(
        applicationSupportPath: directory.path,
        ownAddress: '@sara:node-b.example',
        delivery: delivery,
      ),
      isTrue,
    );

    final store = LoomMessagingStore.openFile(
      '${directory.path}/loom-messages-v1.sqlite3',
    );
    addTearDown(store.close);
    final messages = store.listMessages('conv-nearby-1');
    expect(messages, hasLength(1));
    expect(messages.single.id, 'message-nearby-1');
    expect(messages.single.deliveryState, LoomDeliveryState.delivered);
  });
}

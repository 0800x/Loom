import 'package:loom_models/loom_models.dart';
import 'package:loom_storage/loom_storage.dart';
import 'package:loom_transport/loom_transport.dart';
import 'package:test/test.dart';

void main() {
  test('nearby direct delivery stores only opaque envelope and preserves reconciliation clientId', () async {
    final store = LoomMessagingStore.openInMemory();
    addTearDown(store.close);
    store.upsertConversation(
      const LoomConversation(
        id: 'conv-1',
        kind: LoomConversationKind.direct,
        peerAddress: '@alice:example.org',
        updatedOrder: 0,
        unreadCount: 0,
        isMuted: false,
        isPinned: false,
      ),
    );
    final delivery = LoomNearbyDirectDelivery(store: store);
    final envelope = LoomNearbyDirectEnvelope(
      deliveryId: 'd-1',
      conversationId: 'conv-1',
      clientId: 'client-1',
      senderAddress: '@alice:example.org',
      senderIdentityId: 'identity-a',
      senderDeviceId: 'device-a',
      recipientIdentityId: 'identity-b',
      messageType: LoomMessageType.text,
      ciphertext: 'opaque-ciphertext',
      protocolVersion: 'Loom-TestEnvelope-v1',
      createdAt: DateTime.now().toUtc(),
    );

    final ack = await delivery.receive(
      packetBytes: delivery.encodeEnvelope(envelope),
      localIdentityId: 'identity-b',
      authenticatedRemoteIdentityId: 'identity-a',
      authenticatedRemoteDeviceId: 'device-a',
    );

    expect(ack.accepted, isTrue);
    final message = store.listMessages('conv-1').single;
    expect(message.clientId, 'client-1');
    expect(message.ciphertext, 'opaque-ciphertext');
    expect(message.metadata['receivedVia'], 'nearby-direct-v1');
  });

  test('nearby direct delivery rejects wrong recipient identity', () async {
    final store = LoomMessagingStore.openInMemory();
    addTearDown(store.close);
    store.upsertConversation(
      const LoomConversation(
        id: 'conv-1',
        kind: LoomConversationKind.direct,
        peerAddress: '@alice:example.org',
        updatedOrder: 0,
        unreadCount: 0,
        isMuted: false,
        isPinned: false,
      ),
    );
    final delivery = LoomNearbyDirectDelivery(store: store);
    final envelope = LoomNearbyDirectEnvelope(
      deliveryId: 'd-2',
      conversationId: 'conv-1',
      clientId: 'client-2',
      senderAddress: '@alice:example.org',
      senderIdentityId: 'identity-a',
      senderDeviceId: 'device-a',
      recipientIdentityId: 'identity-c',
      messageType: LoomMessageType.text,
      ciphertext: 'opaque-ciphertext',
      protocolVersion: 'Loom-TestEnvelope-v1',
      createdAt: DateTime.now().toUtc(),
    );

    final ack = await delivery.receive(
      packetBytes: delivery.encodeEnvelope(envelope),
      localIdentityId: 'identity-b',
      authenticatedRemoteIdentityId: 'identity-a',
      authenticatedRemoteDeviceId: 'device-a',
    );

    expect(ack.accepted, isFalse);
    expect(store.listMessages('conv-1'), isEmpty);
  });
}

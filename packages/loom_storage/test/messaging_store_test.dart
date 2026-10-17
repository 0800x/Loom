import 'dart:convert';

import 'package:loom_models/loom_models.dart';
import 'package:loom_storage/loom_storage.dart';
import 'package:test/test.dart';

void main() {
  test(
    'group preferences persist without storing MLS plaintext in legacy tables',
    () {
      final store = LoomMessagingStore.openInMemory();
      addTearDown(store.close);
      const entry = LoomConversation(
        id: 'mls-group',
        kind: LoomConversationKind.group,
        title: 'Friends',
        updatedOrder: 10,
        unreadCount: 0,
        isMuted: false,
        isPinned: false,
      );
      store.setConversationPinned(entry.id, true);
      store.setConversationMuted(entry.id, true);
      store.setConversationMarkedUnread(entry.id, true);
      store.setConversationArchived(entry.id, true);
      final decorated = store.applyConversationPreferences(entry);
      expect(decorated.isPinned, isTrue);
      expect(decorated.isMuted, isTrue);
      expect(decorated.unreadCount, 1);
      expect(store.localConversationStates()[entry.id]!.archived, isTrue);
      expect(store.listConversations(), isEmpty);
      expect(store.listMessages(entry.id), isEmpty);
      store.setConversationPinned(entry.id, false);
      store.setConversationMuted(entry.id, true, until: DateTime.utc(2000));
      store.setConversationMarkedUnread(entry.id, false);
      expect(store.applyConversationPreferences(entry).isPinned, isFalse);
      expect(store.applyConversationPreferences(entry).isMuted, isFalse);
      expect(store.applyConversationPreferences(entry).unreadCount, 0);
    },
  );
  test('outbox failure rolls back the message and conversation ordering', () {
    final store = LoomMessagingStore.openInMemory();
    addTearDown(store.close);
    store.upsertConversation(
      const LoomConversation(
        id: 'conv-1',
        kind: LoomConversationKind.direct,
        peerAddress: '@sara:example.org',
        updatedOrder: 1,
        unreadCount: 0,
        isMuted: false,
        isPinned: false,
      ),
    );
    final now = DateTime.utc(2026, 9, 1);
    final message = LoomMessageRecord(
      id: 'local:c-1',
      clientId: 'c-1',
      conversationId: 'conv-1',
      senderAddress: '@alice:example.org',
      type: LoomMessageType.text,
      ciphertext: 'opaque',
      protocolVersion: 'test-envelope-v1',
      createdOrder: 2,
      createdAt: now,
      deliveryState: LoomDeliveryState.queued,
    );
    LoomPendingOperation operation(Map<String, Object?> payload) =>
        LoomPendingOperation(
          operationId: 'op-1',
          clientId: message.clientId,
          conversationId: message.conversationId,
          kind: LoomPendingOperationKind.sendMessage,
          payload: payload,
          attemptCount: 0,
          nextAttemptAt: now,
          createdAt: now,
        );

    expect(
      () => store.queueOutgoingMessage(message, operation({'bad': Object()})),
      throwsA(isA<JsonUnsupportedObjectError>()),
    );
    expect(store.listMessages('conv-1'), isEmpty);
    expect(store.listConversations().single.updatedOrder, 1);
    expect(store.pendingSendCount, 0);

    // Rollback must also leave the connection usable for the next send.
    store.queueOutgoingMessage(message, operation({'ciphertext': 'opaque'}));
    expect(store.listMessages('conv-1'), hasLength(1));
    expect(store.pendingSendCount, 1);
  });

  test('stale sync and retry state preserve a delivered or read message', () {
    final store = LoomMessagingStore.openInMemory();
    addTearDown(store.close);
    store.upsertConversation(
      const LoomConversation(
        id: 'conv-1',
        kind: LoomConversationKind.direct,
        peerAddress: '@sara:example.org',
        updatedOrder: 0,
        unreadCount: 0,
        isMuted: false,
        isPinned: false,
      ),
    );
    LoomMessageRecord message(String id, LoomDeliveryState state) =>
        LoomMessageRecord(
          id: id,
          clientId: 'c-1',
          conversationId: 'conv-1',
          senderAddress: '@alice:example.org',
          type: LoomMessageType.text,
          ciphertext: 'opaque',
          protocolVersion: 'test-envelope-v1',
          createdOrder: 2,
          createdAt: DateTime.utc(2026, 9, 1),
          deliveryState: state,
        );
    store.putMessage(message('local:c-1', LoomDeliveryState.delivered));
    store.updateDeliveryByClientId('c-1', LoomDeliveryState.queued);
    expect(
      store.listMessages('conv-1').single.deliveryState,
      LoomDeliveryState.delivered,
    );
    store.updateDeliveryByClientId('c-1', LoomDeliveryState.read);
    store.putMessage(message('server:c-1', LoomDeliveryState.sent));
    store.updateDeliveryByClientId('c-1', LoomDeliveryState.failed);
    expect(store.listMessages('conv-1').single.id, 'server:c-1');
    expect(
      store.listMessages('conv-1').single.deliveryState,
      LoomDeliveryState.read,
    );
  });

  test('stores conversations, messages, pending operations and cursors', () {
    final store = LoomMessagingStore.openInMemory();
    addTearDown(store.close);

    store.upsertConversation(
      const LoomConversation(
        id: 'conv-1',
        kind: LoomConversationKind.direct,
        peerAddress: '@sara:example.org',
        updatedOrder: 1,
        unreadCount: 0,
        isMuted: false,
        isPinned: false,
      ),
    );

    final now = DateTime.utc(2026, 9, 1, 8);
    store.putMessage(
      LoomMessageRecord(
        id: 'local:c-1',
        clientId: 'c-1',
        conversationId: 'conv-1',
        senderAddress: '@alice:example.org',
        type: LoomMessageType.text,
        ciphertext: 'opaque',
        protocolVersion: 'test-envelope-v1',
        createdOrder: 2,
        createdAt: now,
        deliveryState: LoomDeliveryState.queued,
      ),
    );

    store.enqueue(
      LoomPendingOperation(
        operationId: 'op-1',
        clientId: 'c-1',
        conversationId: 'conv-1',
        kind: LoomPendingOperationKind.sendMessage,
        payload: const {
          'ciphertext': 'opaque',
          'protocolVersion': 'test-envelope-v1',
        },
        attemptCount: 0,
        nextAttemptAt: now,
        createdAt: now,
      ),
    );

    expect(store.listConversations().single.id, 'conv-1');
    expect(store.listMessages('conv-1').single.clientId, 'c-1');
    expect(store.dueOperations(now).single.operationId, 'op-1');

    store.writeCursor('account', 'cursor-7');
    expect(store.readCursor('account'), 'cursor-7');
    expect(store.markEventSeen('event-1'), isTrue);
    expect(store.markEventSeen('event-1'), isFalse);
  });
}

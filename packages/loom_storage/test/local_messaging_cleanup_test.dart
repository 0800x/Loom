import 'dart:io';

import 'package:loom_models/loom_models.dart';
import 'package:loom_storage/loom_storage.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDirectory;
  late String databasePath;

  setUp(() {
    tempDirectory = Directory.systemTemp.createTempSync('loom-cleanup-test-');
    databasePath = '${tempDirectory.path}/messages.sqlite3';
  });

  tearDown(() {
    if (tempDirectory.existsSync()) tempDirectory.deleteSync(recursive: true);
  });

  test('deleting a local message also cancels its pending send', () {
    final store = LoomMessagingStore.openFile(databasePath);
    _seedConversation(store, 'conversation-1');
    _seedMessageAndPending(
      store,
      conversationId: 'conversation-1',
      clientId: 'client-1',
      operationId: 'operation-1',
    );
    store.close();

    LoomLocalMessagingCleanup.deleteMessageByClientId(
      databasePath: databasePath,
      clientId: 'client-1',
    );

    final reopened = LoomMessagingStore.openFile(databasePath);
    addTearDown(reopened.close);
    expect(reopened.hasMessageClientId('client-1'), isFalse);
    expect(
      reopened.dueOperations(DateTime.utc(2030)),
      isEmpty,
      reason: 'a locally deleted pending message must never retry later',
    );
  });

  test(
    'clearing a local conversation removes its messages and pending sends',
    () {
      final store = LoomMessagingStore.openFile(databasePath);
      _seedConversation(store, 'conversation-1');
      _seedMessageAndPending(
        store,
        conversationId: 'conversation-1',
        clientId: 'client-1',
        operationId: 'operation-1',
      );
      _seedMessageAndPending(
        store,
        conversationId: 'conversation-1',
        clientId: 'client-2',
        operationId: 'operation-2',
        order: 2,
      );
      store.close();

      LoomLocalMessagingCleanup.clearConversation(
        databasePath: databasePath,
        conversationId: 'conversation-1',
      );

      final reopened = LoomMessagingStore.openFile(databasePath);
      addTearDown(reopened.close);
      expect(reopened.listMessages('conversation-1'), isEmpty);
      expect(reopened.dueOperations(DateTime.utc(2030)), isEmpty);
      expect(reopened.listConversations(), hasLength(1));
      expect(reopened.listConversations().single.unreadCount, 0);
    },
  );
}

void _seedConversation(LoomMessagingStore store, String conversationId) {
  store.upsertConversation(
    LoomConversation(
      id: conversationId,
      kind: LoomConversationKind.direct,
      title: 'Test',
      peerAddress: 'peer@example.test',
      updatedOrder: 0,
      unreadCount: 1,
      isMuted: false,
      isPinned: false,
    ),
  );
}

void _seedMessageAndPending(
  LoomMessagingStore store, {
  required String conversationId,
  required String clientId,
  required String operationId,
  int order = 1,
}) {
  final now = DateTime.utc(2026, 9, 15, 12, 0, order);
  store.putMessage(
    LoomMessageRecord(
      id: 'local:$clientId',
      clientId: clientId,
      conversationId: conversationId,
      senderAddress: 'sender@example.test',
      type: LoomMessageType.text,
      ciphertext: 'opaque-$clientId',
      protocolVersion: 'test-v1',
      createdOrder: order,
      createdAt: now,
      deliveryState: LoomDeliveryState.queued,
    ),
  );
  store.enqueue(
    LoomPendingOperation(
      operationId: operationId,
      clientId: clientId,
      conversationId: conversationId,
      kind: LoomPendingOperationKind.sendMessage,
      payload: const <String, Object?>{
        'type': 'text',
        'ciphertext': 'opaque',
        'protocolVersion': 'test-v1',
      },
      attemptCount: 0,
      nextAttemptAt: now,
      createdAt: now,
    ),
  );
}

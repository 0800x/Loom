import 'dart:io';

import 'package:loom_models/loom_models.dart';
import 'package:loom_storage/loom_storage.dart';
import 'package:test/test.dart';

LoomMessageRecord message(String client, int order, {String? id}) =>
    LoomMessageRecord(
      id: id ?? 'server:$client',
      clientId: client,
      conversationId: 'chat',
      senderAddress: 'peer@example',
      type: LoomMessageType.text,
      ciphertext: 'opaque',
      protocolVersion: 'test',
      createdOrder: order,
      createdAt: DateTime.utc(2026),
      deliveryState: LoomDeliveryState.sent,
    );
const chat = LoomConversation(
  id: 'chat',
  kind: LoomConversationKind.direct,
  updatedOrder: 20,
  unreadCount: 0,
  isMuted: false,
  isPinned: false,
);
void main() {
  test(
    'message tombstone survives restart, canonical ID change and DTN replay',
    () async {
      final directory = await Directory.systemTemp.createTemp('loom-delete-');
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}/messages.sqlite';
      var store = LoomMessagingStore.openFile(path);
      store.upsertConversation(chat);
      store.putMessage(message('one', 10, id: 'local:one'));
      store.deleteLocalMessage('wrong-chat', 'one');
      expect(store.listMessages('chat'), hasLength(1));
      store.deleteLocalMessage('chat', 'one');
      store.close();
      store = LoomMessagingStore.openFile(path);
      addTearDown(store.close);
      store.putMessage(message('one', 30));
      store.putMessage(message('one', 40, id: 'dtn_one'));
      expect(store.listMessages('chat'), isEmpty);
    },
  );
  test('delete chat suppresses catalogue/replay; new message unhides without resurrecting history', () {
    final store = LoomMessagingStore.openInMemory();
    addTearDown(store.close);
    store.upsertConversation(chat);
    store.putMessage(message('old', 10));
    // Local timestamps are many orders of magnitude larger than server order.
    store.putMessage(message('queued', 1800000000000000, id: 'local:queued'));
    store.deleteLocalConversation('chat');
    store.upsertConversation(chat);
    store.putMessage(message('old', 10));
    store.putMessage(message('previously-unseen-old', 9));
    store.putMessage(message('queued', 11));
    expect(store.listConversations(), isEmpty);
    expect(store.listMessages('chat'), isEmpty);
    store.putMessage(message('new', 12));
    expect(store.listConversations(), hasLength(1));
    expect(store.listMessages('chat').single.clientId, 'new');
    store.putMessage(message('old', 10));
    expect(store.listMessages('chat'), hasLength(1));
  });
  test('delete cancels queued sends and retry cannot re-enqueue a tombstoned client ID', () {
    final store = LoomMessagingStore.openInMemory();
    addTearDown(store.close);
    store.upsertConversation(chat);
    store.putMessage(message('queued', 10));
    final operation = LoomPendingOperation(
      operationId: 'op',
      attemptCount: 0,
      clientId: 'queued',
      conversationId: 'chat',
      kind: LoomPendingOperationKind.sendMessage,
      payload: const {},
      nextAttemptAt: DateTime.utc(2026),
      createdAt: DateTime.utc(2026),
    );
    store.enqueue(operation);
    expect(store.pendingSendCount, 1);
    store.deleteLocalMessage('chat', 'queued');
    store.enqueue(operation);
    expect(store.pendingSendCount, 0);
  });
}

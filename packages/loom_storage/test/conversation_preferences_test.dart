import 'dart:io';

import 'package:loom_models/loom_models.dart';
import 'package:loom_storage/loom_storage.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

const chat = LoomConversation(
  id: 'chat',
  kind: LoomConversationKind.direct,
  peerAddress: '@peer:example.org',
  updatedOrder: 1,
  unreadCount: 0,
  isMuted: false,
  isPinned: false,
);
LoomMessageRecord message(String id, DateTime at, int order) =>
    LoomMessageRecord(
      id: id,
      clientId: id,
      conversationId: 'chat',
      senderAddress: '@peer:example.org',
      type: LoomMessageType.text,
      ciphertext: 'opaque',
      protocolVersion: 'test',
      createdOrder: order,
      createdAt: at,
      deliveryState: LoomDeliveryState.sent,
    );

void main() {
  test('local flags survive stale remote upserts and incoming messages', () {
    final store = LoomMessagingStore.openInMemory();
    addTearDown(store.close);
    store.upsertConversation(chat);
    store.setConversationArchived('chat', true);
    store.setConversationPinned('chat', true);
    store.setConversationMuted('chat', true);
    store.setConversationMarkedUnread('chat', true);
    store.upsertConversation(chat);
    store.putMessage(message('incoming', DateTime.now().toUtc(), 2));
    final result = store.listConversations().single;
    expect(result.isPinned, isTrue);
    expect(result.isMuted, isTrue);
    expect(result.unreadCount, greaterThan(0));
    expect(store.localConversationStates()['chat']!.archived, isTrue);
    store.setConversationArchived('chat', false);
    store.setConversationPinned('chat', false);
    store.setConversationMuted('chat', false);
    store.setConversationMarkedUnread('chat', false);
    expect(store.localConversationStates()['chat']!.archived, isFalse);
    expect(store.listConversations().single.isMuted, isFalse);
    expect(store.listConversations().single.isPinned, isFalse);
  });

  test('mute duration expires without losing archive or pin state', () {
    final store = LoomMessagingStore.openInMemory();
    addTearDown(store.close);
    store.upsertConversation(chat);
    store.setConversationArchived('chat', true);
    store.setConversationMuted(
      'chat',
      true,
      until: DateTime.now().subtract(const Duration(seconds: 1)),
    );
    expect(store.listConversations().single.isMuted, isFalse);
    store.setConversationMuted(
      'chat',
      true,
      until: DateTime.now().add(const Duration(hours: 1)),
    );
    expect(store.listConversations().single.isMuted, isTrue);
    expect(store.localConversationStates()['chat']!.archived, isTrue);
  });

  test('version 5 migration and disk reopen preserve opaque history', () {
    final folder = Directory.systemTemp.createTempSync(
      'loom-preferences-test-',
    );
    addTearDown(() => folder.deleteSync(recursive: true));
    final path = '${folder.path}/history.sqlite3';
    var store = LoomMessagingStore.openFile(path);
    store.upsertConversation(chat);
    store.putMessage(message('old', DateTime.utc(2026), 1));
    store.close();
    final db = sqlite3.open(path);
    db.execute('DROP TABLE local_conversation_preferences');
    db.execute('DROP INDEX idx_messages_timeline');
    db.execute('PRAGMA user_version = 5');
    db.dispose();
    store = LoomMessagingStore.openFile(path);
    expect(store.listMessages('chat').single.ciphertext, 'opaque');
    expect(store.listConversations().single.isMuted, isFalse);
    store.setConversationArchived('chat', true);
    store.setConversationPinned('chat', true);
    store.setConversationMuted('chat', true);
    store.setConversationMarkedUnread('chat', true);
    store.close();
    store = LoomMessagingStore.openFile(path);
    expect(store.localConversationStates()['chat']!.archived, isTrue);
    expect(store.listConversations().single.isPinned, isTrue);
    expect(store.listConversations().single.isMuted, isTrue);
    expect(store.listMessages('chat').single.clientId, 'old');
    store.close();
  });

  test('clearing history keeps the chat and tombstones erased messages', () {
    final store = LoomMessagingStore.openInMemory();
    addTearDown(store.close);
    store.upsertConversation(chat);
    final original = message('old', DateTime.utc(2026), 1);
    store.putMessage(original);
    store.clearLocalConversationHistory('chat');
    expect(store.listConversations().single.id, 'chat');
    expect(store.listMessages('chat'), isEmpty);
    store.putMessage(original);
    expect(store.listMessages('chat'), isEmpty);
  });

  test('keyset pages handle identical times and mixed local/server orders', () {
    final store = LoomMessagingStore.openInMemory();
    addTearDown(store.close);
    store.upsertConversation(chat);
    final at = DateTime.utc(2026);
    for (var i = 0; i < 130; i++) {
      store.putMessage(
        message(
          'm${i.toString().padLeft(3, '0')}',
          at.add(Duration(seconds: i ~/ 3)),
          i % 7,
        ),
      );
    }
    final first = store.listMessages('chat', limit: 50);
    final second = store.listMessages(
      'chat',
      beforeMessage: first.last,
      limit: 50,
    );
    final third = store.listMessages(
      'chat',
      beforeMessage: second.last,
      limit: 50,
    );
    final all = [...first, ...second, ...third];
    expect(all, hasLength(130));
    expect(all.map((m) => m.clientId).toSet(), hasLength(130));
    expect(
      all.map((m) => m.id),
      store.listMessages('chat', limit: 200).map((m) => m.id),
    );
  });
}

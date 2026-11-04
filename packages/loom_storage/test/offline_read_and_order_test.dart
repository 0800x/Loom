import 'dart:io';

import 'package:loom_models/loom_models.dart';
import 'package:loom_storage/loom_storage.dart';
import 'package:test/test.dart';

const _conversation = LoomConversation(
  id: 'conversation-1',
  kind: LoomConversationKind.direct,
  peerAddress: '@bob:example.org',
  updatedOrder: 1,
  unreadCount: 7,
  isMuted: false,
  isPinned: false,
);

LoomMessageRecord _message(
  String id,
  String clientId,
  int order,
  DateTime time, {
  String sender = '@bob:example.org',
  LoomDeliveryState state = LoomDeliveryState.delivered,
  LoomMessageTransportPath path = LoomMessageTransportPath.unknown,
}) => LoomMessageRecord(
  id: id,
  clientId: clientId,
  conversationId: _conversation.id,
  senderAddress: sender,
  type: LoomMessageType.text,
  ciphertext: 'opaque-$clientId',
  protocolVersion: 'test-v1',
  createdOrder: order,
  createdAt: time,
  deliveryState: state,
  transportPath: path,
);

void main() {
  test('receipt outbox survives restart, deduplicates, and rolls back with inbox writes', () {
    final directory = Directory.systemTemp.createTempSync(
      'loom-receipt-outbox-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final file = '${directory.path}/messages.sqlite3';
    var store = LoomMessagingStore.openFile(file);
    store.upsertConversation(_conversation);
    store.transaction(() {
      store.putMessage(
        _message('local-id', 'client-receipt', 1, DateTime.now()),
      );
      store.queueNearbyReceipt('client-receipt');
      store.queueNearbyReceipt('client-receipt');
    });
    expect(
      () => store.transaction(() {
        store.queueNearbyReceipt('rolled-back');
        throw StateError('simulated commit failure');
      }),
      throwsStateError,
    );
    store.close();
    store = LoomMessagingStore.openFile(file);
    try {
      expect(store.pendingNearbyReceipts(), ['client-receipt']);
      expect(store.messageByClientId('client-receipt')?.id, 'local-id');
      expect(
        store.conversationById(_conversation.id)?.peerAddress,
        _conversation.peerAddress,
      );
      store.updateDeliveryByClientId('client-receipt', LoomDeliveryState.read);
      store.updateDeliveryByClientId(
        'client-receipt',
        LoomDeliveryState.delivered,
      );
      expect(
        store.messageByClientId('client-receipt')?.deliveryState,
        LoomDeliveryState.read,
      );
      store.completeNearbyReceipt('client-receipt');
      expect(store.pendingNearbyReceipts(), isEmpty);
    } finally {
      store.close();
    }
  });

  test(
    'observed incoming route survives restart and canonical ID reconciliation',
    () {
      final dir = Directory.systemTemp.createTempSync('loom-path-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = '${dir.path}/messages.sqlite3';
      var store = LoomMessagingStore.openFile(file);
      store.upsertConversation(_conversation);
      final now = DateTime.utc(2026, 9, 22);
      store.putMessage(
        _message(
          'dtn_copy',
          'route-client',
          100,
          now,
          path: LoomMessageTransportPath.nearby,
        ),
      );
      store.close();
      store = LoomMessagingStore.openFile(file);
      addTearDown(store.close);
      store.putMessage(
        _message(
          'msg_canonical',
          'route-client',
          2,
          now,
          path: LoomMessageTransportPath.internet,
        ),
      );
      final message = store.listMessages(_conversation.id).single;
      expect(message.id, 'msg_canonical');
      expect(message.transportPath, LoomMessageTransportPath.nearby);
    },
  );

  test('an observed outgoing Nearby hop changes route without fabricating delivery', () {
    final store = LoomMessagingStore.openInMemory();
    addTearDown(store.close);
    store.upsertConversation(_conversation);
    final now = DateTime.utc(2026, 9, 22);
    store.putMessage(
      _message(
        'local',
        'path-client',
        1,
        now,
        state: LoomDeliveryState.queued,
        sender: '@alice:example.org',
      ),
    );
    store.recordTransportPath(
      'path-client',
      LoomMessageTransportPath.nearby,
      mergeRoutes: true,
    );
    expect(
      store.listMessages(_conversation.id).single.deliveryState,
      LoomDeliveryState.queued,
    );
    store.reconcileSentMessage(
      clientId: 'path-client',
      serverMessageId: 'server',
      serverOrder: 7,
      createdAt: now,
    );
    final message = store.listMessages(_conversation.id).single;
    expect(message.transportPath, LoomMessageTransportPath.hybrid);
    expect(message.deliveryState, LoomDeliveryState.sent);
  });

  test('an interrupted inbox write leaves the event retryable', () {
    final store = LoomMessagingStore.openInMemory();
    addTearDown(store.close);
    expect(
      () => store.applyEventOnce('event-atomic', () {
        store.upsertConversation(_conversation);
        throw StateError('disk write interrupted');
      }),
      throwsStateError,
    );
    expect(store.listConversations(), isEmpty);
    expect(
      store.applyEventOnce(
        'event-atomic',
        () => store.upsertConversation(_conversation),
      ),
      isTrue,
    );
    expect(
      store.applyEventOnce('event-atomic', () => throw StateError('duplicate')),
      isFalse,
    );
  });

  test('old DTN microsecond order cannot replace the newer server preview', () {
    final store = LoomMessagingStore.openInMemory();
    addTearDown(store.close);
    store.upsertConversation(_conversation);
    final old = DateTime.utc(2026, 9, 20);
    store.putMessage(
      _message('dtn_old', 'old', old.microsecondsSinceEpoch, old),
    );
    store.putMessage(
      _message('msg_new', 'new', 42, old.add(const Duration(hours: 1))),
    );
    expect(store.listMessages(_conversation.id).map((m) => m.clientId), [
      'new',
      'old',
    ]);
  });

  test(
    'a delayed DTN duplicate preserves the canonical server ID and order',
    () {
      final store = LoomMessagingStore.openInMemory();
      addTearDown(store.close);
      store.upsertConversation(_conversation);
      final time = DateTime.utc(2026, 9, 21);
      store.putMessage(_message('msg_server', 'same', 12, time));
      store.putMessage(
        _message(
          'dtn_late',
          'same',
          time.microsecondsSinceEpoch,
          time.subtract(const Duration(hours: 2)),
        ),
      );
      final message = store.listMessages(_conversation.id).single;
      expect(message.id, 'msg_server');
      expect(message.createdOrder, 12);
      expect(message.createdAt, time);
      expect(
        () => store.putMessage(
          _message(
            'dtn_conflict',
            'same',
            99,
            time,
            sender: '@mallory:example.org',
          ),
        ),
        throwsFormatException,
        reason: 'A duplicate must still match the original immutable sender',
      );
    },
  );

  test(
    'offline reads survive restart, stale counts and server reconciliation',
    () {
      final directory = Directory.systemTemp.createTempSync('loom-read-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final path = '${directory.path}/messages.sqlite3';
      var store = LoomMessagingStore.openFile(path);
      final now = DateTime.utc(2026, 9, 21);
      store.upsertConversation(_conversation);
      store.putMessage(
        _message('dtn_packet', 'offline', now.microsecondsSinceEpoch, now),
      );
      store.markMessagesRead(_conversation.id, '@alice:example.org', [
        'offline',
      ]);
      expect(
        store.dueOperations(DateTime.now()),
        isEmpty,
        reason: 'A local DTN order must never mark future server messages read',
      );
      store.close();
      store = LoomMessagingStore.openFile(path);
      addTearDown(store.close);
      store.upsertConversation(
        _conversation,
      ); // Stale server unread count: seven.
      expect(store.listConversations().single.unreadCount, 0);
      store.putMessage(_message('msg_server', 'offline', 12, now));
      expect(
        store
            .dueOperations(DateTime.now().add(const Duration(seconds: 1)))
            .single
            .payload['throughOrder'],
        12,
      );
      expect(store.listConversations().single.unreadCount, 0);
      store.putMessage(
        _message('msg_next', 'next', 13, now.add(const Duration(minutes: 1))),
      );
      expect(store.listConversations().single.unreadCount, 1);
    },
  );

  test(
    'legacy delivery repair replays evidence once without deleting messages',
    () {
      final store = LoomMessagingStore.openInMemory();
      addTearDown(store.close);
      store.upsertConversation(_conversation);
      store.putMessage(
        _message(
          'msg_sent',
          'sent',
          1,
          DateTime.utc(2026, 9, 21),
          sender: '@alice:example.org',
        ),
      );
      store.writeCursor('account', 'old-cursor');
      store.repairLegacyDeliveryEvidence('@alice:example.org');
      expect(store.readCursor('account'), isNull);
      expect(
        store.listMessages(_conversation.id).single.deliveryState,
        LoomDeliveryState.sent,
      );
      store.updateDeliveryByClientId('sent', LoomDeliveryState.delivered);
      store.repairLegacyDeliveryEvidence('@alice:example.org');
      expect(
        store.listMessages(_conversation.id).single.deliveryState,
        LoomDeliveryState.delivered,
      );
    },
  );
}

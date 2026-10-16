import 'dart:io';

import 'package:loom_models/loom_models.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:loom_storage/loom_storage.dart';
import 'package:loom_transport/loom_transport.dart';
import 'package:test/test.dart';

class _PersistenceEncoder implements LoomOutgoingEnvelopeEncoder {
  @override
  Future<LoomOpaqueEnvelope> encodeText({
    required String conversationId,
    required String plaintext,
    String? replyToMessageId,
  }) async => LoomOpaqueEnvelope(
    ciphertext: 'opaque:$plaintext',
    protocolVersion: 'Loom-TestEnvelope-v1',
  );
}

class _PersistenceApi implements LoomMessagingApi {
  _PersistenceApi({this.syncPage});

  final LoomSyncPage? syncPage;
  int sends = 0;
  final readOrders = <int>[];
  bool readOffline = false;

  @override
  Future<List<LoomConversation>> fetchConversations() async => const [];

  @override
  Future<void> markRead({
    required String conversationId,
    required int throughOrder,
  }) async {
    if (readOffline) throw const SocketException('offline');
    readOrders.add(throughOrder);
  }

  @override
  Future<LoomSendReceipt> sendOpaqueMessage({
    required String conversationId,
    required String clientId,
    required LoomMessageType type,
    required String ciphertext,
    required String protocolVersion,
    String? replyToMessageId,
    Map<String, Object?> metadata = const {},
  }) async {
    sends++;
    return LoomSendReceipt(
      messageId: 'server-$clientId',
      clientId: clientId,
      serverOrder: 91,
      createdAt: DateTime.utc(2026, 9, 10, 8),
    );
  }

  @override
  Future<LoomAttachmentReceipt> uploadEncryptedAttachment({
    required String conversationId,
    required File encryptedFile,
    required String contentType,
  }) async => LoomAttachmentReceipt(
    attachmentId: 'att-1',
    sizeBytes: await encryptedFile.length(),
    contentType: contentType,
  );

  @override
  Future<LoomSyncPage> sync({String? cursor, int limit = 200}) async =>
      syncPage ??
      const LoomSyncPage(events: [], nextCursor: 'cursor-1', hasMore: false);
}

void main() {
  test(
    'read receipt retries durably without changing message delivery',
    () async {
      final store = LoomMessagingStore.openInMemory();
      addTearDown(store.close);
      store.upsertConversation(
        const LoomConversation(
          id: 'read-conv',
          kind: LoomConversationKind.direct,
          peerAddress: '@bob:example.org',
          updatedOrder: 1,
          unreadCount: 1,
          isMuted: false,
          isPinned: false,
        ),
      );
      final now = DateTime.now().toUtc();
      store.putMessage(
        LoomMessageRecord(
          id: 'msg_read',
          clientId: 'read-client',
          conversationId: 'read-conv',
          senderAddress: '@bob:example.org',
          type: LoomMessageType.text,
          ciphertext: 'opaque',
          protocolVersion: 'test-v1',
          createdOrder: 7,
          createdAt: now,
          deliveryState: LoomDeliveryState.delivered,
        ),
      );
      store.markMessagesRead('read-conv', '@alice:example.org', [
        'read-client',
      ]);
      final api = _PersistenceApi()..readOffline = true;
      final engine = LoomMessagingEngine(
        store: store,
        client: api,
        senderAddress: '@alice:example.org',
      );
      addTearDown(engine.dispose);
      await engine.flushDue();
      final pending = store
          .dueOperations(now.add(const Duration(minutes: 1)))
          .single;
      expect(pending.kind, LoomPendingOperationKind.markRead);
      expect(pending.attemptCount, 1);
      api.readOffline = false;
      store.rescheduleOperation(
        pending.operationId,
        attemptCount: pending.attemptCount,
        nextAttemptAt: now,
        lastError: 'retry',
      );
      await engine.flushDue();
      expect(api.readOrders, [7]);
      expect(store.dueOperations(now.add(const Duration(minutes: 1))), isEmpty);
      expect(store.listConversations().single.unreadCount, 0);
      expect(
        store.listMessages('read-conv').single.deliveryState,
        LoomDeliveryState.delivered,
      );
    },
  );

  test('queued send survives store restart and flushes after reopen', () async {
    final directory = await Directory.systemTemp.createTemp(
      'loom-send-restart-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final path = '${directory.path}/messages.sqlite3';

    final firstStore = LoomMessagingStore.openFile(path);
    firstStore.upsertConversation(
      const LoomConversation(
        id: 'conv-restart',
        kind: LoomConversationKind.direct,
        peerAddress: '@sara:node-b.example',
        updatedOrder: 0,
        unreadCount: 0,
        isMuted: false,
        isPinned: false,
      ),
    );
    final firstEngine = LoomMessagingEngine(
      store: firstStore,
      client: _PersistenceApi(),
      senderAddress: '@alice:node-a.example',
      encoder: _PersistenceEncoder(),
    );

    final queued = await firstEngine.queueText(
      conversationId: 'conv-restart',
      plaintext: 'persist me',
    );
    expect(queued.deliveryState, LoomDeliveryState.queued);
    firstStore.close();

    final secondStore = LoomMessagingStore.openFile(path);
    addTearDown(secondStore.close);
    expect(
      secondStore.listMessages('conv-restart').single.deliveryState,
      LoomDeliveryState.queued,
    );
    expect(
      secondStore.dueOperations(
        DateTime.now().toUtc().add(const Duration(minutes: 1)),
      ),
      hasLength(1),
    );

    final api = _PersistenceApi();
    final secondEngine = LoomMessagingEngine(
      store: secondStore,
      client: api,
      senderAddress: '@alice:node-a.example',
      encoder: _PersistenceEncoder(),
    );
    await secondEngine.flushDue();

    expect(api.sends, 1);
    expect(
      secondStore.listMessages('conv-restart').single.deliveryState,
      LoomDeliveryState.sent,
    );
    expect(
      secondStore.dueOperations(
        DateTime.now().toUtc().add(const Duration(minutes: 1)),
      ),
      isEmpty,
    );
  });

  test(
    'canonical sender echo stays sent instead of becoming delivered',
    () async {
      final store = LoomMessagingStore.openInMemory();
      addTearDown(store.close);
      store.upsertConversation(
        const LoomConversation(
          id: 'conv-case',
          kind: LoomConversationKind.direct,
          peerAddress: '@sara:node-b.example',
          updatedOrder: 0,
          unreadCount: 0,
          isMuted: false,
          isPinned: false,
        ),
      );
      final api = _PersistenceApi(
        syncPage: LoomSyncPage(
          events: [
            LoomSyncEvent(
              eventId: 'event-case-1',
              kind: 'message.created',
              order: 42,
              payload: <String, Object?>{
                'id': 'message-case-1',
                'clientId': 'client-case-1',
                'conversationId': 'conv-case',
                'senderAddress': '@ALICE:NODE-A.EXAMPLE',
                'type': 'text',
                'ciphertext': 'opaque:test',
                'protocolVersion': 'Loom-TestEnvelope-v1',
                'serverOrder': 42,
                'createdAt': DateTime.utc(2026, 9, 12, 7).toIso8601String(),
              },
            ),
          ],
          nextCursor: 'cursor-case-1',
          hasMore: false,
        ),
      );
      final engine = LoomMessagingEngine(
        store: store,
        client: api,
        senderAddress: '@alice:node-a.example',
        encoder: _PersistenceEncoder(),
      );

      await engine.synchronize();

      expect(
        store.listMessages('conv-case').single.deliveryState,
        LoomDeliveryState.sent,
      );
      engine.applyRealtimeEvent(
        const LoomSyncEvent(
          eventId: 'legacy-node-ack',
          kind: 'message.delivered',
          order: 43,
          payload: {
            'clientId': 'client-case-1',
            'destinationDomain': 'node-b.example',
            'status': 'delivered',
          },
        ),
      );
      expect(
        store.listMessages('conv-case').single.deliveryState,
        LoomDeliveryState.sent,
        reason: 'Old server custody events are not recipient receipts',
      );
      engine.applyRealtimeEvent(
        const LoomSyncEvent(
          eventId: 'recipient-ack',
          kind: 'message.delivered',
          order: 44,
          payload: {
            'clientId': 'client-case-1',
            'deliveryEvidence': 'recipient-device',
          },
        ),
      );
      expect(
        store.listMessages('conv-case').single.deliveryState,
        LoomDeliveryState.delivered,
      );
    },
  );
}

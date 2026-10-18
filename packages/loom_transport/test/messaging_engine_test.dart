import 'dart:async';
import 'dart:io';

import 'package:loom_models/loom_models.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:loom_storage/loom_storage.dart';
import 'package:loom_transport/loom_transport.dart';
import 'package:test/test.dart';

class _TestEncoder implements LoomOutgoingEnvelopeEncoder {
  int encodes = 0;

  @override
  Future<LoomOpaqueEnvelope> encodeText({
    required String conversationId,
    required String plaintext,
    String? replyToMessageId,
  }) async {
    encodes++;
    return LoomOpaqueEnvelope(
      ciphertext: 'opaque:$plaintext',
      protocolVersion: 'Loom-TestEnvelope-v1',
    );
  }
}

class _ControlledApi extends _FakeApi {
  bool offline = false;
  Completer<void>? gate;
  String? gatedConversation;
  int? rejectStatus;
  final fastCompleted = Completer<void>();
  final started = Completer<void>();
  final attempts = <(String, String)>[];

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
    attempts.add((clientId, ciphertext));
    if (!started.isCompleted) {
      started.complete();
    }
    if (gatedConversation == null || conversationId == gatedConversation) {
      await gate?.future;
    }
    if (offline) {
      throw const SocketException('offline');
    }
    if (rejectStatus != null) {
      throw LoomHttpStatusException(
        statusCode: rejectStatus!,
        message: 'rejected',
      );
    }
    final receipt = await super.sendOpaqueMessage(
      conversationId: conversationId,
      clientId: clientId,
      type: type,
      ciphertext: ciphertext,
      protocolVersion: protocolVersion,
      replyToMessageId: replyToMessageId,
      metadata: metadata,
    );
    if (conversationId == 'conv-fast' && !fastCompleted.isCompleted) {
      fastCompleted.complete();
    }
    return receipt;
  }
}

LoomMessagingEngine _engine(
  LoomMessagingStore store,
  _ControlledApi api, {
  _TestEncoder? encoder,
}) {
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
  return LoomMessagingEngine(
    store: store,
    client: api,
    senderAddress: '@alice:example.org',
    encoder: encoder ?? _TestEncoder(),
  );
}

class _FakeApi implements LoomMessagingApi {
  int sends = 0;
  LoomSyncPage page = const LoomSyncPage(
    events: [],
    nextCursor: 'cursor-1',
    hasMore: false,
  );

  @override
  Future<List<LoomConversation>> fetchConversations() async => const [];

  @override
  Future<void> markRead({
    required String conversationId,
    required int throughOrder,
  }) async {}

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
      serverOrder: 55,
      createdAt: DateTime.utc(2026, 9, 1, 9),
    );
  }

  @override
  Future<LoomAttachmentReceipt> uploadEncryptedAttachment({
    required String conversationId,
    required File encryptedFile,
    required String contentType,
  }) async =>
      LoomAttachmentReceipt(
        attachmentId: 'att-1',
        sizeBytes: await encryptedFile.length(),
        contentType: contentType,
      );

  @override
  Future<LoomSyncPage> sync({String? cursor, int limit = 200}) async => page;
}

void main() {
  test(
    'rich content keeps text allowance and persists only encoded ciphertext',
    () async {
      final store = LoomMessagingStore.openInMemory();
      final engine = _engine(store, _ControlledApi());
      try {
        final content = List.filled(33000, 'x').join();
        final record = await engine.queueContent(
          conversationId: 'conv-1',
          encodedContent: content,
          replyToMessageId: 'original',
        );
        expect(record.replyToMessageId, 'original');
        expect(record.ciphertext, 'opaque:$content');
        expect(record.metadata, isEmpty);
        expect(
          store.listMessages('conv-1').single.ciphertext,
          record.ciphertext,
        );
        await expectLater(
          engine.queueText(conversationId: 'conv-1', plaintext: content),
          throwsArgumentError,
        );
        await expectLater(
          engine.queueContent(
            conversationId: 'conv-1',
            encodedContent: List.filled(65537, 'x').join(),
          ),
          throwsArgumentError,
        );
      } finally {
        engine.dispose();
        store.close();
      }
    },
  );
  test(
      'blocked conversation does not hold a healthy send; same chat sends sequentially',
      () async {
    final store = LoomMessagingStore.openInMemory();
    addTearDown(store.close);
    final api = _ControlledApi()
      ..gate = Completer<void>()
      ..gatedConversation = 'conv-1';
    final engine = _engine(store, api);
    addTearDown(engine.dispose);
    store.upsertConversation(
      const LoomConversation(
        id: 'conv-fast',
        kind: LoomConversationKind.direct,
        peerAddress: '@fast:example.org',
        updatedOrder: 0,
        unreadCount: 0,
        isMuted: false,
        isPinned: false,
      ),
    );
    final first = await engine.queueText(
      conversationId: 'conv-1',
      plaintext: 'first',
    );
    final second = await engine.queueText(
      conversationId: 'conv-1',
      plaintext: 'second',
    );
    final fast = await engine.queueText(
      conversationId: 'conv-fast',
      plaintext: 'fast',
    );
    final flushing = engine.flushDue();
    try {
      await api.fastCompleted.future.timeout(const Duration(seconds: 2));
      expect(api.attempts.map((a) => a.$1), [first.clientId, fast.clientId]);
    } finally {
      api.gate!.complete();
      await flushing;
    }
    expect(api.attempts.last.$1, second.clientId);
    expect(store.pendingSendCount, 0);
  });

  test(
      '403 stops automatic retries but explicit retry keeps ciphertext and client id',
      () async {
    final store = LoomMessagingStore.openInMemory();
    addTearDown(store.close);
    final api = _ControlledApi()..rejectStatus = 403;
    final encoder = _TestEncoder();
    final engine = _engine(store, api, encoder: encoder);
    addTearDown(engine.dispose);
    final message = await engine.queueText(
      conversationId: 'conv-1',
      plaintext: 'retained',
    );
    await engine.flushDue();
    expect(
      store.messageByClientId(message.clientId)!.deliveryState,
      LoomDeliveryState.failed,
    );
    store.retryPendingSends();
    await engine.flushDue();
    expect(api.attempts.length, 1);
    api.rejectStatus = null;
    store.retryPendingSends(includeRejected: true);
    await engine.flushDue();
    expect(api.attempts.length, 2);
    expect(api.attempts.first, api.attempts.last);
    expect(encoder.encodes, 1);
    expect(
      store.messageByClientId(message.clientId)!.deliveryState,
      LoomDeliveryState.sent,
    );
  });

  test(
    'offline restart retries the same ciphertext and id without encoding',
    () async {
      final directory = await Directory.systemTemp.createTemp('loom-outbox-');
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}/messages.sqlite3';
      var store = LoomMessagingStore.openFile(path);
      addTearDown(() => store.close());
      final encoder = _TestEncoder();
      final api = _ControlledApi()..offline = true;
      var engine = _engine(store, api, encoder: encoder);
      final queued = await engine.queueText(
        conversationId: 'conv-1',
        plaintext: 'keep this offline',
      );
      await engine.flushDue();
      expect(store.pendingSendCount, 1);
      final pending = store
          .dueOperations(DateTime.now().toUtc().add(const Duration(days: 1)))
          .single;
      expect(pending.attemptCount, 1);
      // Keep this deterministic even on a slow test runner.
      store.rescheduleOperation(
        pending.operationId,
        attemptCount: pending.attemptCount,
        nextAttemptAt: DateTime.now().toUtc().add(const Duration(days: 1)),
        lastError: 'offline',
      );
      engine.dispose();
      store.close();

      store = LoomMessagingStore.openFile(path);
      engine = _engine(store, api, encoder: encoder);
      addTearDown(engine.dispose);
      expect(store.listMessages('conv-1').single.ciphertext, queued.ciphertext);
      expect(store.dueOperations(DateTime.now().toUtc()), isEmpty);
      store.retryPendingSends();
      api.offline = false;
      await engine.flushDue();

      expect(encoder.encodes, 1);
      expect(api.attempts, [
        (queued.clientId, queued.ciphertext),
        (queued.clientId, queued.ciphertext),
      ]);
      expect(store.pendingSendCount, 0);
      expect(
        store.listMessages('conv-1').single.deliveryState,
        LoomDeliveryState.sent,
      );
    },
  );

  test(
    'concurrent drains wait and include a message queued during the send',
    () async {
      final store = LoomMessagingStore.openInMemory();
      addTearDown(store.close);
      final api = _ControlledApi()..gate = Completer<void>();
      final engine = _engine(store, api);
      addTearDown(engine.dispose);
      final first = await engine.queueText(
        conversationId: 'conv-1',
        plaintext: 'first',
      );
      final draining = engine.flushDue();
      await api.started.future;
      final second = await engine.queueText(
        conversationId: 'conv-1',
        plaintext: 'second',
      );
      final joining = engine.flushDue();
      expect(identical(draining, joining), isTrue);
      expect(api.attempts, [(first.clientId, first.ciphertext)]);
      api.gate!.complete();
      await Future.wait([draining, joining]);
      expect(api.attempts.map((attempt) => attempt.$1), [
        first.clientId,
        second.clientId,
      ]);
      expect(store.pendingSendCount, 0);
    },
  );

  test('late HTTP acknowledgement cannot downgrade a read receipt', () async {
    final store = LoomMessagingStore.openInMemory();
    addTearDown(store.close);
    final api = _ControlledApi()..gate = Completer<void>();
    final engine = _engine(store, api);
    addTearDown(engine.dispose);
    final queued = await engine.queueText(
      conversationId: 'conv-1',
      plaintext: 'already read',
    );
    final draining = engine.flushDue();
    await api.started.future;
    engine.applyRealtimeEvent(
      LoomSyncEvent(
        eventId: 'read-before-http',
        kind: 'message.read',
        order: 60,
        payload: {'clientId': queued.clientId},
      ),
    );
    api.gate!.complete();
    await draining;
    final message = store.listMessages('conv-1').single;
    expect(message.id, 'server-${queued.clientId}');
    expect(message.deliveryState, LoomDeliveryState.read);
  });

  test(
    'a stale drain snapshot skips an operation completed by another route',
    () async {
      final store = LoomMessagingStore.openInMemory();
      addTearDown(store.close);
      final api = _ControlledApi()..gate = Completer<void>();
      final engine = _engine(store, api);
      addTearDown(engine.dispose);
      await engine.queueText(conversationId: 'conv-1', plaintext: 'first');
      final second = await engine.queueText(
        conversationId: 'conv-1',
        plaintext: 'second',
      );
      final draining = engine.flushDue();
      await api.started.future;
      store.completeSendOperationsByClientId(second.clientId);
      api.gate!.complete();
      await draining;
      expect(api.attempts, hasLength(1));
    },
  );

  test(
    'disposal during transport does not access the closed database',
    () async {
      final store = LoomMessagingStore.openInMemory();
      addTearDown(store.close);
      final api = _ControlledApi()..gate = Completer<void>();
      final engine = _engine(store, api);
      await engine.queueText(conversationId: 'conv-1', plaintext: 'closing');
      final draining = engine.flushDue();
      await api.started.future;
      engine.dispose();
      store.close();
      api.gate!.complete();
      await draining;
      await expectLater(
        engine.queueText(conversationId: 'conv-1', plaintext: 'too late'),
        throwsStateError,
      );
    },
  );

  test(
    'offline queue persists before transport and flushes idempotently',
    () async {
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
      final api = _FakeApi();
      final engine = LoomMessagingEngine(
        store: store,
        client: api,
        senderAddress: '@alice:example.org',
        encoder: _TestEncoder(),
      );

      final queued = await engine.queueText(
        conversationId: 'conv-1',
        plaintext: 'hello',
      );
      expect(queued.deliveryState, LoomDeliveryState.queued);
      expect(
        store.dueOperations(
          DateTime.now().toUtc().add(const Duration(minutes: 1)),
        ),
        hasLength(1),
      );

      await engine.flushDue();
      expect(api.sends, 1);
      expect(
        store.dueOperations(
          DateTime.now().toUtc().add(const Duration(minutes: 1)),
        ),
        isEmpty,
      );
      expect(
        store.listMessages('conv-1').first.deliveryState,
        LoomDeliveryState.sent,
      );
    },
  );

  test('incoming sync preserves the remote sender address', () async {
    final store = LoomMessagingStore.openInMemory();
    addTearDown(store.close);
    store.upsertConversation(
      const LoomConversation(
        id: 'conv-remote',
        kind: LoomConversationKind.direct,
        peerAddress: '@sara:node-b.example',
        updatedOrder: 0,
        unreadCount: 0,
        isMuted: false,
        isPinned: false,
      ),
    );
    final api = _FakeApi()
      ..page = LoomSyncPage(
        events: [
          LoomSyncEvent(
            eventId: 'evt-remote-1',
            kind: 'message.created',
            order: 77,
            payload: {
              'id': 'msg-remote-1',
              'clientId': 'remote-client-1',
              'conversationId': 'conv-remote',
              'senderAddress': '@sara:node-b.example',
              'type': 'text',
              'ciphertext': 'opaque-remote',
              'protocolVersion': 'Loom-Direct-v1',
              'serverOrder': 77,
              'createdAt': DateTime.utc(2026, 9, 4, 10).toIso8601String(),
            },
          ),
        ],
        nextCursor: 'cursor-2',
        hasMore: false,
      );
    final engine = LoomMessagingEngine(
      store: store,
      client: api,
      senderAddress: '@alice:node-a.example',
      encoder: _TestEncoder(),
    );

    await engine.synchronize();

    final incoming = store.listMessages('conv-remote').single;
    expect(incoming.senderAddress, '@sara:node-b.example');
    expect(incoming.deliveryState, LoomDeliveryState.delivered);
  });

  test('failure sync can recover to delivered after a server retry', () async {
    final store = LoomMessagingStore.openInMemory();
    addTearDown(store.close);
    store.upsertConversation(
      const LoomConversation(
        id: 'conv-delivery',
        kind: LoomConversationKind.direct,
        peerAddress: '@sara:node-b.example',
        updatedOrder: 0,
        unreadCount: 0,
        isMuted: false,
        isPinned: false,
      ),
    );
    final api = _FakeApi();
    final engine = LoomMessagingEngine(
      store: store,
      client: api,
      senderAddress: '@alice:node-a.example',
      encoder: _TestEncoder(),
    );

    final queued = await engine.queueText(
      conversationId: 'conv-delivery',
      plaintext: 'hello federation',
    );
    await engine.flushDue();
    expect(
      store.listMessages('conv-delivery').single.deliveryState,
      LoomDeliveryState.sent,
    );

    api.page = LoomSyncPage(
      events: [
        LoomSyncEvent(
          eventId: 'evt-failed-1',
          kind: 'message.failed',
          order: 88,
          payload: {
            'clientId': queued.clientId,
            'messageId': 'server-${queued.clientId}',
            'destinationDomain': 'node-b.example',
            'status': 'failed',
            'error': 'federation_delivery_http_503',
          },
        ),
      ],
      nextCursor: 'cursor-failed',
      hasMore: false,
    );
    await engine.synchronize();
    expect(
      store.listMessages('conv-delivery').single.deliveryState,
      LoomDeliveryState.failed,
    );

    api.page = LoomSyncPage(
      events: [
        LoomSyncEvent(
          eventId: 'evt-delivered-1',
          kind: 'message.delivered',
          order: 89,
          payload: {
            'clientId': queued.clientId,
            'messageId': 'server-${queued.clientId}',
            'destinationDomain': 'node-b.example',
            'status': 'delivered',
            'deliveryEvidence': 'recipient-device',
          },
        ),
      ],
      nextCursor: 'cursor-delivered',
      hasMore: false,
    );
    await engine.synchronize();
    expect(
      store.listMessages('conv-delivery').single.deliveryState,
      LoomDeliveryState.delivered,
    );
  });
}

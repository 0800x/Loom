import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:loom_models/loom_models.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:loom_storage/loom_storage.dart';

/// Boundary between message semantics and cryptography.
/// Phase 3 deliberately ships no production plaintext encoder.
abstract interface class LoomOutgoingEnvelopeEncoder {
  Future<LoomOpaqueEnvelope> encodeText({
    required String conversationId,
    required String plaintext,
    String? replyToMessageId,
  });
}

class LoomOpaqueEnvelope {
  const LoomOpaqueEnvelope({
    required this.ciphertext,
    required this.protocolVersion,
  });
  final String ciphertext;
  final String protocolVersion;
}

class LoomMessagingEngine {
  LoomMessagingEngine({
    required this.store,
    required this.client,
    required this.senderAddress,
    this.encoder,
    Random? random,
  }) : _random = random ?? Random.secure();

  final LoomMessagingStore store;
  final LoomMessagingApi client;
  final String senderAddress;
  final LoomOutgoingEnvelopeEncoder? encoder;
  final Random _random;
  Future<void>? _flushFuture;
  bool _flushRequested = false;
  bool _disposed = false;
  String? lastSendError;

  Future<LoomMessageRecord> queueText({
    required String conversationId,
    required String plaintext,
    String? replyToMessageId,
  }) => _queue(
    conversationId: conversationId,
    plaintext: plaintext,
    replyToMessageId: replyToMessageId,
    maxCharacters: 32000,
  );

  /// Rich documents are encrypted by the same device-bound encoder. A bounded
  /// quote/descriptor must not consume the user's existing text allowance.
  Future<LoomMessageRecord> queueContent({
    required String conversationId,
    required String encodedContent,
    String? replyToMessageId,
  }) => _queue(
    conversationId: conversationId,
    plaintext: encodedContent,
    replyToMessageId: replyToMessageId,
    maxCharacters: 64 * 1024,
  );

  Future<LoomMessageRecord> _queue({
    required String conversationId,
    required String plaintext,
    required int maxCharacters,
    String? replyToMessageId,
  }) async {
    if (_disposed) {
      throw StateError('Messaging engine is closed');
    }
    final trimmed = plaintext.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('Message cannot be empty');
    }
    if (trimmed.length > maxCharacters) {
      throw ArgumentError('Message exceeds content limit');
    }
    final contentEncoder = encoder;
    if (contentEncoder == null) {
      throw StateError(
        'No production message envelope encoder is configured. Phase 4 must provide one.',
      );
    }
    final envelope = await contentEncoder.encodeText(
      conversationId: conversationId,
      plaintext: trimmed,
      replyToMessageId: replyToMessageId,
    );
    if (_disposed) {
      throw StateError('Messaging engine is closed');
    }
    final now = DateTime.now().toUtc();
    final clientId = _id('c');
    final localId = 'local:$clientId';
    final localOrder = now.microsecondsSinceEpoch;
    final message = LoomMessageRecord(
      id: localId,
      clientId: clientId,
      conversationId: conversationId,
      senderAddress: senderAddress,
      type: LoomMessageType.text,
      ciphertext: envelope.ciphertext,
      protocolVersion: envelope.protocolVersion,
      createdOrder: localOrder,
      createdAt: now,
      deliveryState: LoomDeliveryState.queued,
      replyToMessageId: replyToMessageId,
    );
    store.queueOutgoingMessage(
      message,
      LoomPendingOperation(
        operationId: _id('op'),
        clientId: clientId,
        conversationId: conversationId,
        kind: LoomPendingOperationKind.sendMessage,
        payload: {
          'type': 'text',
          'ciphertext': envelope.ciphertext,
          'protocolVersion': envelope.protocolVersion,
          if (replyToMessageId != null) 'replyToMessageId': replyToMessageId,
        },
        attemptCount: 0,
        nextAttemptAt: now,
        createdAt: now,
      ),
    );
    return message;
  }

  Future<void> flushDue() {
    if (_disposed) {
      return Future<void>.value();
    }
    _flushRequested = true;
    return _flushFuture ??= _flushDue().whenComplete(() => _flushFuture = null);
  }

  Future<void> _flushDue() async {
    while (_flushRequested && !_disposed) {
      _flushRequested = false;
      final due = store.dueOperations(DateTime.now().toUtc());
      // Preserve order inside a chat, without letting an unreachable peer or a
      // read receipt block every other chat. Bound concurrency on mobile radios.
      final chats = <String, List<LoomPendingOperation>>{};
      for (final operation in due) {
        chats.putIfAbsent(operation.conversationId, () => []).add(operation);
      }
      final iterator = chats.values.iterator;
      Future<void> worker() async {
        while (!_disposed && iterator.moveNext()) {
          final operations = iterator.current;
          for (final kind in [
            LoomPendingOperationKind.sendMessage,
            LoomPendingOperationKind.markRead,
          ]) {
            for (final operation in operations.where((op) => op.kind == kind)) {
              if (_disposed) {
                return;
              }
              if (!store.hasPendingOperation(operation.operationId)) {
                continue;
              }
              await _attempt(operation);
            }
          }
        }
      }

      await Future.wait(List.generate(min(4, chats.length), (_) => worker()));
      // Bound each requested drain to one batch. The heartbeat requests the
      // next batch without monopolizing the transport during a long outage.
    }
  }

  void dispose() => _disposed = true;

  Future<void> _attempt(LoomPendingOperation operation) async {
    if (operation.kind == LoomPendingOperationKind.markRead) {
      try {
        await client.markRead(
          conversationId: operation.conversationId,
          throughOrder: operation.payload['throughOrder'] as int,
        );
        if (!_disposed) {
          store.completeOperation(operation.operationId);
        }
      } catch (error) {
        if (!_disposed) {
          store.rescheduleOperation(
            operation.operationId,
            attemptCount: operation.attemptCount + 1,
            nextAttemptAt: DateTime.now().toUtc().add(
              const Duration(seconds: 30),
            ),
            lastError: _safeError(error),
          );
        }
      }
      return;
    }
    final payload = operation.payload;
    final ciphertext = payload['ciphertext'];
    final protocolVersion = payload['protocolVersion'];
    if (ciphertext is! String || protocolVersion is! String) {
      store.completeOperation(operation.operationId);
      store.updateDeliveryByClientId(
        operation.clientId,
        LoomDeliveryState.failed,
      );
      return;
    }
    store.updateDeliveryByClientId(
      operation.clientId,
      LoomDeliveryState.sending,
    );
    try {
      final receipt = await client.sendOpaqueMessage(
        conversationId: operation.conversationId,
        clientId: operation.clientId,
        type: LoomMessageType.text,
        ciphertext: ciphertext,
        protocolVersion: protocolVersion,
        replyToMessageId: payload['replyToMessageId'] as String?,
      );
      if (_disposed || !store.hasPendingOperation(operation.operationId)) {
        return;
      }
      store.reconcileSentMessage(
        clientId: operation.clientId,
        serverMessageId: receipt.messageId,
        serverOrder: receipt.serverOrder,
        createdAt: receipt.createdAt,
      );
      store.completeOperation(operation.operationId);
      store.updateDeliveryByClientId(
        operation.clientId,
        LoomDeliveryState.sent,
      );
      lastSendError = null;
    } catch (error) {
      if (_disposed || !store.hasPendingOperation(operation.operationId)) {
        return;
      }
      // A definitive rejection is not an offline queue. Retain ciphertext and
      // clientId for explicit retry, but do not hammer the server indefinitely.
      if (error is LoomHttpStatusException &&
          error.statusCode >= 400 &&
          error.statusCode < 500 &&
          error.statusCode != 408 &&
          error.statusCode != 425 &&
          error.statusCode != 429 &&
          error.statusCode != 401) {
        lastSendError = _safeError(error);
        store.rescheduleOperation(
          operation.operationId,
          attemptCount: operation.attemptCount + 1,
          nextAttemptAt: DateTime.utc(9999),
          lastError: lastSendError!,
        );
        store.updateDeliveryByClientId(
          operation.clientId,
          LoomDeliveryState.failed,
        );
        return;
      }
      lastSendError = _safeError(error);
      final attempts = operation.attemptCount + 1;
      final cappedSeconds = min(300, 2 << min(7, attempts));
      final jitter = _random.nextInt(1000);
      store.rescheduleOperation(
        operation.operationId,
        attemptCount: attempts,
        nextAttemptAt: DateTime.now().toUtc().add(
          Duration(seconds: cappedSeconds, milliseconds: jitter),
        ),
        lastError: _safeError(error),
      );
      store.updateDeliveryByClientId(
        operation.clientId,
        LoomDeliveryState.queued,
      );
    }
  }

  Future<int> synchronize({int maxPages = 20}) async {
    if (_disposed) {
      return 0;
    }
    if (maxPages < 1 || maxPages > 100) {
      throw ArgumentError.value(maxPages, 'maxPages');
    }
    var cursor = store.readCursor('account');
    var applied = 0;
    for (var pageIndex = 0; pageIndex < maxPages; pageIndex++) {
      final page = await client.sync(cursor: cursor);
      if (_disposed) {
        return applied;
      }
      if (page.hasMore &&
          (page.nextCursor == null ||
              page.nextCursor!.isEmpty ||
              page.nextCursor == cursor)) {
        throw const LoomProtocolException('Non-advancing sync cursor');
      }
      store.transaction(() {
        for (final event in page.events) {
          if (store.applyEventOnce(event.eventId, () => _applyEvent(event)))
            applied++;
        }
        store.writeCursor('account', page.nextCursor);
      });
      cursor = page.nextCursor;
      if (!page.hasMore) {
        break;
      }
      if (cursor == null || cursor.isEmpty) {
        throw const LoomProtocolException(
          'Sync page indicated more data without a cursor',
        );
      }
    }
    return applied;
  }

  void applyRealtimeEvent(LoomSyncEvent event) {
    if (_disposed) {
      return;
    }
    store.applyEventOnce(event.eventId, () => _applyEvent(event));
  }

  void _applyEvent(LoomSyncEvent event) {
    switch (event.kind) {
      case 'conversation.upsert':
        final kind = event.payload['kind'];
        if (kind is String &&
            !LoomConversationKind.values.any(
              (v) => v.name == kind.toLowerCase(),
            )) {
          store.recordUnsupportedEvent(event.eventId, 'conversation-kind');
          return;
        }
        store.upsertConversation(_conversationFromPayload(event.payload));
        break;
      case 'message.created':
        final type = event.payload['type'];
        if (type is String &&
            !LoomMessageType.values.any((v) => v.name == type.toLowerCase())) {
          store.recordUnsupportedEvent(event.eventId, 'message-type');
          return;
        }
        final message = _messageFromPayload(event.payload, event.order);
        store.putMessage(message);
        if (message.senderAddress.toLowerCase() ==
            senderAddress.toLowerCase()) {
          store.completeSendOperationsByClientId(message.clientId);
        }
        break;
      case 'message.nodeAccepted':
        final clientId = event.payload['clientId'];
        if (clientId is String) {
          store.updateDeliveryByClientId(clientId, LoomDeliveryState.sent);
        }
        break;
      case 'message.delivered':
        // Older nodes mislabeled federation/node custody as device delivery.
        // A destination domain alone is not evidence of recipient receipt.
        if (event.payload.containsKey('destinationDomain') &&
            event.payload['deliveryEvidence'] != 'recipient-device') {
          break;
        }
        final clientId = event.payload['clientId'];
        if (clientId is String) {
          store.updateDeliveryByClientId(clientId, LoomDeliveryState.delivered);
        }
        break;
      case 'message.failed':
        final clientId = event.payload['clientId'];
        if (clientId is String) {
          store.updateDeliveryByClientId(clientId, LoomDeliveryState.failed);
        }
        break;
      case 'message.read':
        final clientId = event.payload['clientId'];
        if (clientId is String) {
          store.updateDeliveryByClientId(clientId, LoomDeliveryState.read);
        }
        break;
      default:
        store.recordUnsupportedEvent(event.eventId, 'event-kind');
        return;
    }
  }

  LoomConversation _conversationFromPayload(Map<String, Object?> p) {
    final id = p['id'];
    final kind = p['kind'];
    final order = p['updatedOrder'];
    final unread = p['unreadCount'];
    if (id is! String || kind is! String || order is! int || unread is! int) {
      throw const FormatException('Malformed conversation sync payload');
    }
    return LoomConversation(
      id: id,
      kind: LoomConversationKind.values.byName(kind.toLowerCase()),
      title: p['title'] as String?,
      peerAddress: p['peerAddress'] as String?,
      updatedOrder: order,
      unreadCount: unread,
      isMuted: p['isMuted'] == true,
      isPinned: p['isPinned'] == true,
    );
  }

  LoomMessageRecord _messageFromPayload(
    Map<String, Object?> p,
    int fallbackOrder,
  ) {
    final id = p['id'];
    final clientId = p['clientId'];
    final conversationId = p['conversationId'];
    final eventSenderAddress = p['senderAddress'];
    final ciphertext = p['ciphertext'];
    final protocolVersion = p['protocolVersion'];
    final createdAtRaw = p['createdAt'];
    final typeRaw = p['type'];
    if (id is! String ||
        clientId is! String ||
        conversationId is! String ||
        eventSenderAddress is! String ||
        ciphertext is! String ||
        protocolVersion is! String ||
        createdAtRaw is! String ||
        typeRaw is! String) {
      throw const FormatException('Malformed message sync payload');
    }
    final createdAt = DateTime.tryParse(createdAtRaw)?.toUtc();
    if (createdAt == null) {
      throw const FormatException('Malformed message createdAt');
    }
    final order = p['serverOrder'] is int
        ? p['serverOrder'] as int
        : fallbackOrder;
    final metadata = p['metadata'];
    return LoomMessageRecord(
      id: id,
      clientId: clientId,
      conversationId: conversationId,
      senderAddress: eventSenderAddress,
      type: LoomMessageType.values.byName(typeRaw.toLowerCase()),
      ciphertext: ciphertext,
      protocolVersion: protocolVersion,
      createdOrder: order,
      createdAt: createdAt,
      deliveryState:
          eventSenderAddress.toLowerCase() == senderAddress.toLowerCase()
          ? LoomDeliveryState.sent
          : LoomDeliveryState.delivered,
      transportPath: LoomMessageTransportPath.internet,
      replyToMessageId: p['replyToMessageId'] as String?,
      metadata: metadata is Map<String, Object?> ? metadata : const {},
    );
  }

  String _id(String prefix) {
    final now = DateTime.now().toUtc().microsecondsSinceEpoch.toRadixString(36);
    final random = List<int>.generate(12, (_) => _random.nextInt(256));
    return '$prefix-$now-${base64Url.encode(random).replaceAll('=', '')}';
  }

  String _safeError(Object error) {
    final text = error.toString().replaceAll(RegExp(r'[\r\n]+'), ' ');
    return text.length <= 240 ? text : text.substring(0, 240);
  }
}

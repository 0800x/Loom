import 'dart:convert';
import 'dart:io';

import 'package:loom_models/loom_models.dart';
import 'package:sqlite3/sqlite3.dart';

class LoomLocalConversationState {
  const LoomLocalConversationState({
    this.archived = false,
    this.markedUnread = false,
    this.mutedUntil,
  });
  final bool archived, markedUnread;
  final DateTime? mutedUntil;
}

/// Durable Phase 3 client store.
///
/// The database stores encrypted/opaque message envelopes. It does not own
/// cryptographic keys. Those remain behind the crypto bridge/OS secret store.
class LoomMessagingStore {
  LoomMessagingStore._(this._db);

  final Database _db;
  bool _closed = false;

  static LoomMessagingStore openFile(String path) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    final db = sqlite3.open(path);
    final store = LoomMessagingStore._(db);
    store._configure();
    store._migrate();
    return store;
  }

  static LoomMessagingStore openInMemory() {
    final store = LoomMessagingStore._(sqlite3.openInMemory());
    store._configure();
    store._migrate();
    return store;
  }

  void _configure() {
    _db.execute('PRAGMA foreign_keys = ON');
    _db.execute('PRAGMA journal_mode = WAL');
    _db.execute('PRAGMA synchronous = FULL');
    _db.execute('PRAGMA busy_timeout = 5000');
  }

  void _migrate() {
    final versionRow = _db.select('PRAGMA user_version').first;
    final version = versionRow.values.first as int;
    if (version > 6) {
      throw StateError(
        'Loom database schema $version is newer than supported schema 6',
      );
    }
    if (version == 0) {
      _db.execute('BEGIN IMMEDIATE');
      try {
        _db.execute('''
          CREATE TABLE conversations (
            id TEXT PRIMARY KEY,
            kind TEXT NOT NULL,
            title TEXT,
            peer_address TEXT,
            updated_order INTEGER NOT NULL DEFAULT 0,
            unread_count INTEGER NOT NULL DEFAULT 0,
            is_muted INTEGER NOT NULL DEFAULT 0,
            is_pinned INTEGER NOT NULL DEFAULT 0
          )
        ''');
        _db.execute('''
          CREATE TABLE messages (
            id TEXT PRIMARY KEY,
            client_id TEXT NOT NULL UNIQUE,
            conversation_id TEXT NOT NULL,
            sender_address TEXT NOT NULL,
            type TEXT NOT NULL,
            ciphertext TEXT NOT NULL,
            protocol_version TEXT NOT NULL,
            created_order INTEGER NOT NULL,
            created_at TEXT NOT NULL,
            delivery_state TEXT NOT NULL,
            reply_to_message_id TEXT,
            metadata_json TEXT NOT NULL DEFAULT '{}',
            FOREIGN KEY(conversation_id) REFERENCES conversations(id) ON DELETE CASCADE
          )
        ''');
        _db.execute('''
          CREATE INDEX idx_messages_conversation_order
          ON messages(conversation_id, created_order DESC)
        ''');
        _db.execute('''
          CREATE TABLE pending_operations (
            operation_id TEXT PRIMARY KEY,
            client_id TEXT NOT NULL,
            conversation_id TEXT NOT NULL,
            kind TEXT NOT NULL,
            payload_json TEXT NOT NULL,
            attempt_count INTEGER NOT NULL DEFAULT 0,
            next_attempt_at TEXT NOT NULL,
            created_at TEXT NOT NULL,
            last_error TEXT,
            FOREIGN KEY(conversation_id) REFERENCES conversations(id) ON DELETE CASCADE
          )
        ''');
        _db.execute('''
          CREATE INDEX idx_pending_due
          ON pending_operations(next_attempt_at, created_at)
        ''');
        _db.execute('''
          CREATE TABLE sync_state (
            scope TEXT PRIMARY KEY,
            cursor TEXT,
            updated_at TEXT NOT NULL
          )
        ''');
        _db.execute('''
          CREATE TABLE seen_events (
            event_id TEXT PRIMARY KEY,
            seen_at TEXT NOT NULL
          )
        ''');
        _db.execute(
          'CREATE INDEX idx_seen_events_seen_at ON seen_events(seen_at)',
        );
        _db.execute('PRAGMA user_version = 1');
        _db.execute('COMMIT');
      } catch (_) {
        _db.execute('ROLLBACK');
        rethrow;
      }
    }
    if (version < 2) {
      _db.execute('BEGIN IMMEDIATE');
      try {
        _db.execute(
          'CREATE TABLE local_read_messages (client_id TEXT PRIMARY KEY)',
        );
        _db.execute(
          'CREATE TABLE local_read_state (conversation_id TEXT PRIMARY KEY, own_address TEXT NOT NULL)',
        );
        _db.execute(
          'CREATE INDEX idx_messages_time ON messages(conversation_id, created_at DESC)',
        );
        _db.execute('PRAGMA user_version = 2');
        _db.execute('COMMIT');
      } catch (_) {
        _db.execute('ROLLBACK');
        rethrow;
      }
    }
    if (version < 3) {
      _db.execute('BEGIN IMMEDIATE');
      try {
        _db.execute(
          "ALTER TABLE messages ADD COLUMN transport_path TEXT NOT NULL DEFAULT 'unknown'",
        );
        _db.execute('PRAGMA user_version = 3');
        _db.execute('COMMIT');
      } catch (_) {
        _db.execute('ROLLBACK');
        rethrow;
      }
    }
    if (version < 4) {
      _db.execute('BEGIN IMMEDIATE');
      try {
        _db.execute(
          'CREATE TABLE nearby_receipt_outbox (client_id TEXT PRIMARY KEY)',
        );
        _db.execute('PRAGMA user_version = 4');
        _db.execute('COMMIT');
      } catch (_) {
        _db.execute('ROLLBACK');
        rethrow;
      }
    }
    if (version < 5) {
      transaction(() {
        _db.execute(
          'CREATE TABLE local_deleted_messages (client_id TEXT PRIMARY KEY)',
        );
        _db.execute(
          'CREATE TABLE local_hidden_conversations (conversation_id TEXT PRIMARY KEY, through_order INTEGER NOT NULL, is_hidden INTEGER NOT NULL DEFAULT 1)',
        );
        _db.execute('PRAGMA user_version = 5');
      });
    }
    if (version < 6) {
      transaction(() {
        _db.execute('''CREATE TABLE local_conversation_preferences (
          conversation_id TEXT PRIMARY KEY,
          is_archived INTEGER NOT NULL DEFAULT 0,
          is_pinned INTEGER,
          is_muted INTEGER,
          muted_until TEXT,
          marked_unread INTEGER NOT NULL DEFAULT 0
        )''');
        _db.execute(
          'CREATE INDEX IF NOT EXISTS idx_messages_timeline ON messages(conversation_id, created_at DESC, created_order DESC, id DESC)',
        );
        _db.execute('PRAGMA user_version = 6');
      });
    }
  }

  Map<String, LoomLocalConversationState> localConversationStates() {
    _requireOpen();
    return {
      for (final row in _db.select(
        'SELECT * FROM local_conversation_preferences',
      ))
        row['conversation_id'] as String: LoomLocalConversationState(
          archived: row['is_archived'] == 1,
          markedUnread: row['marked_unread'] == 1,
          mutedUntil: DateTime.tryParse(row['muted_until'] as String? ?? ''),
        ),
    };
  }

  void _preference(String id, String column, Object? value) {
    _requireOpen();
    // column is supplied only by the fixed methods below, never by user input.
    _db.execute(
      'INSERT INTO local_conversation_preferences (conversation_id, $column) '
      'VALUES (?, ?) ON CONFLICT(conversation_id) DO UPDATE SET $column = excluded.$column',
      [id, value],
    );
  }

  /// Apply durable device preferences to an MLS catalogue entry without putting
  /// its messages or plaintext into the legacy messaging database.
  LoomConversation applyConversationPreferences(LoomConversation c) {
    _requireOpen();
    final rows = _db.select(
      'SELECT * FROM local_conversation_preferences WHERE conversation_id = ?',
      [c.id],
    );
    if (rows.isEmpty) return c;
    final p = rows.first;
    final until = p['muted_until'] as String?;
    final muted =
        p['is_muted'] == null
            ? c.isMuted
            : p['is_muted'] == 1 &&
                (until == null ||
                    DateTime.parse(until).isAfter(DateTime.now().toUtc()));
    return LoomConversation(
      id: c.id,
      kind: c.kind,
      title: c.title,
      peerAddress: c.peerAddress,
      updatedOrder: c.updatedOrder,
      unreadCount:
          p['marked_unread'] == 1 && c.unreadCount == 0 ? 1 : c.unreadCount,
      isPinned: p['is_pinned'] == null ? c.isPinned : p['is_pinned'] == 1,
      isMuted: muted,
    );
  }

  void setConversationArchived(String id, bool value) =>
      _preference(id, 'is_archived', value ? 1 : 0);
  void setConversationPinned(String id, bool value) =>
      _preference(id, 'is_pinned', value ? 1 : 0);
  void setConversationMarkedUnread(String id, bool value) =>
      _preference(id, 'marked_unread', value ? 1 : 0);
  void setConversationMuted(String id, bool value, {DateTime? until}) {
    transaction(() {
      _preference(id, 'is_muted', value ? 1 : 0);
      _preference(
        id,
        'muted_until',
        value ? until?.toUtc().toIso8601String() : null,
      );
    });
  }

  /// Tombstone current messages without hiding the conversation or its flags.
  void clearLocalConversationHistory(String id) {
    transaction(() {
      deleteLocalConversation(id);
      restoreLocalConversation(id);
      setConversationMarkedUnread(id, false);
    });
  }

  /// Rebuild receipt evidence once for clients that consumed the old server's
  /// node-custody-as-delivered events. Keep messages/drafts/local reads intact.
  void repairLegacyDeliveryEvidence(String ownAddress) {
    _requireOpen();
    const marker = 'recipient-delivery-evidence-v1';
    if (readCursor(marker) == ownAddress.toLowerCase()) {
      return;
    }
    _db.execute('SAVEPOINT repair_receipts');
    try {
      _db.execute(
        "UPDATE messages SET delivery_state = 'sent' WHERE lower(sender_address) = ? AND delivery_state = 'delivered'",
        [ownAddress.toLowerCase()],
      );
      _db.execute('DELETE FROM seen_events');
      writeCursor('account', null);
      writeCursor(marker, ownAddress.toLowerCase());
      _db.execute('RELEASE SAVEPOINT repair_receipts');
    } catch (_) {
      _db.execute('ROLLBACK TO SAVEPOINT repair_receipts');
      _db.execute('RELEASE SAVEPOINT repair_receipts');
      rethrow;
    }
  }

  bool _locallyDeleted(String clientId) =>
      _db.select('SELECT 1 FROM local_deleted_messages WHERE client_id = ?', [
        clientId,
      ]).isNotEmpty;

  /// Device-only tombstones survive replay and server ID reconciliation.
  /// An already in-flight network send cannot be recalled by local deletion.
  void deleteLocalMessage(String conversationId, String clientId) {
    transaction(() {
      final found = _db.select(
        'SELECT 1 FROM messages WHERE conversation_id = ? AND client_id = ?',
        [conversationId, clientId],
      );
      if (found.isEmpty) return;
      _db.execute('INSERT OR IGNORE INTO local_deleted_messages VALUES (?)', [
        clientId,
      ]);
      _db.execute('DELETE FROM pending_operations WHERE client_id = ?', [
        clientId,
      ]);
      _db.execute('DELETE FROM nearby_receipt_outbox WHERE client_id = ?', [
        clientId,
      ]);
      _db.execute('DELETE FROM local_read_messages WHERE client_id = ?', [
        clientId,
      ]);
      _db.execute('DELETE FROM messages WHERE client_id = ?', [clientId]);
    });
  }

  void deleteLocalConversation(String conversationId) {
    transaction(() {
      _db.execute(
        'INSERT OR IGNORE INTO local_deleted_messages SELECT client_id FROM messages WHERE conversation_id = ?',
        [conversationId],
      );
      _db.execute(
        "INSERT INTO local_hidden_conversations (conversation_id, through_order) SELECT id, COALESCE((SELECT MAX(created_order) FROM messages WHERE conversation_id = ? AND id NOT LIKE 'local:%' AND id NOT LIKE 'dtn_%'), 0) FROM conversations WHERE id = ? ON CONFLICT(conversation_id) DO UPDATE SET through_order = MAX(local_hidden_conversations.through_order, excluded.through_order), is_hidden = 1",
        [conversationId, conversationId],
      );
      _db.execute('DELETE FROM pending_operations WHERE conversation_id = ?', [
        conversationId,
      ]);
      _db.execute(
        'DELETE FROM nearby_receipt_outbox WHERE client_id IN (SELECT client_id FROM messages WHERE conversation_id = ?)',
        [conversationId],
      );
      _db.execute(
        'DELETE FROM local_read_messages WHERE client_id IN (SELECT client_id FROM messages WHERE conversation_id = ?)',
        [conversationId],
      );
      _db.execute('DELETE FROM messages WHERE conversation_id = ?', [
        conversationId,
      ]);
      _db.execute('UPDATE conversations SET unread_count = 0 WHERE id = ?', [
        conversationId,
      ]);
    });
  }

  /// Explicitly starting a new conversation makes its empty local history visible.
  void restoreLocalSavedConversation() {
    _requireOpen();
    _db.execute(
      "UPDATE local_hidden_conversations SET is_hidden = 0 WHERE conversation_id IN (SELECT id FROM conversations WHERE kind = 'self')",
    );
  }

  void restoreLocalConversation(String id) {
    _requireOpen();
    _db.execute(
      'UPDATE local_hidden_conversations SET is_hidden = 0 WHERE conversation_id = ?',
      [id],
    );
  }

  void upsertConversation(LoomConversation conversation) {
    _requireOpen();
    _db.execute(
      '''
      INSERT INTO conversations (
        id, kind, title, peer_address, updated_order, unread_count, is_muted, is_pinned
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        kind=excluded.kind,
        title=excluded.title,
        peer_address=excluded.peer_address,
        updated_order=MAX(conversations.updated_order, excluded.updated_order),
        unread_count=excluded.unread_count,
        is_muted=excluded.is_muted,
        is_pinned=excluded.is_pinned
      ''',
      [
        conversation.id,
        conversation.kind.name,
        conversation.title,
        conversation.peerAddress,
        conversation.updatedOrder,
        conversation.unreadCount,
        conversation.isMuted ? 1 : 0,
        conversation.isPinned ? 1 : 0,
      ],
    );
  }

  List<LoomConversation> listConversations({int limit = 100}) {
    _requireOpen();
    if (limit < 1 || limit > 500) {
      throw ArgumentError.value(limit, 'limit');
    }
    final rows = _db.select(
      '''
      SELECT c.*, COALESCE(p.is_pinned, c.is_pinned) AS local_is_pinned,
        CASE WHEN p.is_muted IS NULL THEN c.is_muted
          WHEN p.is_muted = 1 AND (p.muted_until IS NULL OR p.muted_until > ?) THEN 1
          ELSE 0 END AS local_is_muted,
        COALESCE(p.marked_unread, 0) AS local_marked_unread,
        CASE WHEN rs.conversation_id IS NULL THEN c.unread_count ELSE (
          SELECT COUNT(*) FROM messages m
          WHERE m.conversation_id = c.id AND lower(m.sender_address) != rs.own_address
            AND NOT EXISTS (SELECT 1 FROM local_read_messages r WHERE r.client_id = m.client_id)
        ) END AS visible_unread_count
      FROM conversations c LEFT JOIN local_read_state rs ON rs.conversation_id = c.id
      LEFT JOIN local_conversation_preferences p ON p.conversation_id = c.id
      WHERE NOT EXISTS (SELECT 1 FROM local_hidden_conversations h WHERE h.conversation_id = c.id AND h.is_hidden = 1)
      ORDER BY COALESCE(p.is_pinned, c.is_pinned) DESC,
        (SELECT MAX(m.created_at) FROM messages m WHERE m.conversation_id = c.id) DESC,
        c.updated_order DESC, c.id ASC
      LIMIT ?
      ''',
      [DateTime.now().toUtc().toIso8601String(), limit],
    );
    return rows.map(_conversationFromRow).toList(growable: false);
  }

  T transaction<T>(T Function() action) {
    _requireOpen();
    _db.execute('SAVEPOINT inbox_commit');
    try {
      final value = action();
      _db.execute('RELEASE SAVEPOINT inbox_commit');
      return value;
    } catch (_) {
      _db.execute('ROLLBACK TO SAVEPOINT inbox_commit');
      _db.execute('RELEASE SAVEPOINT inbox_commit');
      rethrow;
    }
  }

  /// Event deduplication and inbox mutation must commit together before an ACK.
  bool applyEventOnce(String eventId, void Function() apply) => transaction(() {
    if (!markEventSeen(eventId)) {
      return false;
    }
    apply();
    return true;
  });

  /// Bounded diagnostics contain only opaque IDs/reason classes, no payload.
  void recordUnsupportedEvent(String eventId, String reason) {
    _db.execute(
      'CREATE TABLE IF NOT EXISTS unsupported_sync_events (event_id TEXT PRIMARY KEY, reason TEXT NOT NULL)',
    );
    _db.execute('INSERT OR IGNORE INTO unsupported_sync_events VALUES (?, ?)', [
      eventId,
      reason,
    ]);
    _db.execute(
      'DELETE FROM unsupported_sync_events WHERE rowid NOT IN (SELECT rowid FROM unsupported_sync_events ORDER BY rowid DESC LIMIT 1000)',
    );
  }

  void putMessage(LoomMessageRecord message) {
    _requireOpen();
    if (_locallyDeleted(message.clientId)) return;
    final hidden = _db.select(
      'SELECT through_order FROM local_hidden_conversations WHERE conversation_id = ?',
      [message.conversationId],
    );
    if (hidden.isNotEmpty &&
        message.createdOrder <= (hidden.first['through_order'] as int))
      return;
    _db.execute('SAVEPOINT put_message');
    try {
      _db.execute(
        'UPDATE local_hidden_conversations SET is_hidden = 0 WHERE conversation_id = ?',
        [message.conversationId],
      );
      final byClient = _db.select(
        'SELECT id, delivery_state, ciphertext, sender_address, protocol_version FROM messages WHERE client_id = ? LIMIT 1',
        [message.clientId],
      );
      if (byClient.isNotEmpty &&
          (byClient.first['ciphertext'] != message.ciphertext ||
              (byClient.first['sender_address'] as String).toLowerCase() !=
                  message.senderAddress.toLowerCase() ||
              byClient.first['protocol_version'] != message.protocolVersion)) {
        throw const FormatException(
          'Message client ID conflicts with immutable envelope',
        );
      }
      // A late DTN copy must never replace a canonical server ID/order or
      // rewrite the chronology of an already committed inbox message.
      if (byClient.isNotEmpty && message.id.startsWith('dtn_')) {
        _db.execute('RELEASE SAVEPOINT put_message');
        return;
      }
      final delivery =
          byClient.isEmpty
              ? message.deliveryState
              : _mergeDeliveryState(
                LoomDeliveryState.values.byName(
                  byClient.first['delivery_state'] as String,
                ),
                message.deliveryState,
              );
      if (byClient.isNotEmpty && byClient.first['id'] != message.id) {
        _db.execute(
          '''UPDATE messages SET
             id = ?, conversation_id = ?, sender_address = ?, type = ?, ciphertext = ?, protocol_version = ?,
             created_order = ?, created_at = ?, delivery_state = ?, reply_to_message_id = ?, metadata_json = ?
             WHERE client_id = ?''',
          [
            message.id,
            message.conversationId,
            message.senderAddress,
            message.type.name,
            message.ciphertext,
            message.protocolVersion,
            message.createdOrder,
            message.createdAt.toUtc().toIso8601String(),
            delivery.name,
            message.replyToMessageId,
            jsonEncode(message.metadata),
            message.clientId,
          ],
        );
      } else {
        _db.execute(
          '''
        INSERT INTO messages (
          id, client_id, conversation_id, sender_address, type, ciphertext,
          protocol_version, created_order, created_at, delivery_state,
          reply_to_message_id, metadata_json
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
          delivery_state=excluded.delivery_state,
          created_order=excluded.created_order,
          created_at=excluded.created_at,
          metadata_json=excluded.metadata_json
        ''',
          [
            message.id,
            message.clientId,
            message.conversationId,
            message.senderAddress,
            message.type.name,
            message.ciphertext,
            message.protocolVersion,
            message.createdOrder,
            message.createdAt.toUtc().toIso8601String(),
            delivery.name,
            message.replyToMessageId,
            jsonEncode(message.metadata),
          ],
        );
      }
      _db.execute(
        'UPDATE conversations SET updated_order = MAX(updated_order, ?) WHERE id = ?',
        [message.createdOrder, message.conversationId],
      );
      recordTransportPath(message.clientId, message.transportPath);
      _queueReadCursor(message.conversationId);
      _db.execute('RELEASE SAVEPOINT put_message');
    } catch (_) {
      _db.execute('ROLLBACK TO SAVEPOINT put_message');
      _db.execute('RELEASE SAVEPOINT put_message');
      rethrow;
    }
  }

  /// The visible message and its retry operation must survive a crash together.
  void queueOutgoingMessage(
    LoomMessageRecord message,
    LoomPendingOperation operation,
  ) {
    _requireOpen();
    if (message.clientId != operation.clientId ||
        message.conversationId != operation.conversationId ||
        operation.kind != LoomPendingOperationKind.sendMessage) {
      throw ArgumentError('Outgoing message and operation must match');
    }
    _db.execute('SAVEPOINT queue_outgoing');
    try {
      putMessage(message);
      enqueue(operation);
      _db.execute('RELEASE SAVEPOINT queue_outgoing');
    } catch (_) {
      _db.execute('ROLLBACK TO SAVEPOINT queue_outgoing');
      _db.execute('RELEASE SAVEPOINT queue_outgoing');
      rethrow;
    }
  }

  static LoomDeliveryState _mergeDeliveryState(
    LoomDeliveryState current,
    LoomDeliveryState incoming,
  ) {
    if (current == LoomDeliveryState.read ||
        incoming == LoomDeliveryState.read) {
      return LoomDeliveryState.read;
    }
    if (current == LoomDeliveryState.delivered ||
        incoming == LoomDeliveryState.delivered) {
      return LoomDeliveryState.delivered;
    }
    if (current == LoomDeliveryState.sent &&
        (incoming == LoomDeliveryState.queued ||
            incoming == LoomDeliveryState.sending)) {
      return current;
    }
    return incoming;
  }

  void updateDeliveryByClientId(String clientId, LoomDeliveryState state) {
    _requireOpen();
    final rows = _db.select(
      'SELECT delivery_state FROM messages WHERE client_id = ?',
      [clientId],
    );
    if (rows.isEmpty) {
      return;
    }
    final current = LoomDeliveryState.values.byName(
      rows.first['delivery_state'] as String,
    );
    _db.execute('UPDATE messages SET delivery_state = ? WHERE client_id = ?', [
      _mergeDeliveryState(current, state).name,
      clientId,
    ]);
  }

  /// Keeps the first incoming route; outgoing sends may observe both routes.
  /// This says nothing about recipient delivery or read confirmation.
  void recordTransportPath(
    String clientId,
    LoomMessageTransportPath path, {
    bool mergeRoutes = false,
  }) {
    _requireOpen();
    if (path == LoomMessageTransportPath.unknown) {
      return;
    }
    _db.execute(
      mergeRoutes
          ? "UPDATE messages SET transport_path = CASE WHEN transport_path = 'unknown' THEN ? WHEN transport_path = ? THEN transport_path ELSE 'hybrid' END WHERE client_id = ?"
          : "UPDATE messages SET transport_path = ? WHERE client_id = ? AND transport_path = 'unknown'",
      mergeRoutes ? [path.name, path.name, clientId] : [path.name, clientId],
    );
  }

  void reconcileSentMessage({
    required String clientId,
    required String serverMessageId,
    required int serverOrder,
    required DateTime createdAt,
  }) {
    _requireOpen();
    _db.execute(
      '''UPDATE messages
         SET id = ?, created_order = ?, created_at = ?,
             delivery_state = CASE
               WHEN delivery_state IN ('delivered', 'read') THEN delivery_state
               ELSE ? END
         WHERE client_id = ?''',
      [
        serverMessageId,
        serverOrder,
        createdAt.toUtc().toIso8601String(),
        LoomDeliveryState.sent.name,
        clientId,
      ],
    );
    recordTransportPath(
      clientId,
      LoomMessageTransportPath.internet,
      mergeRoutes: true,
    );
  }

  List<LoomMessageRecord> listMessages(
    String conversationId, {
    int? beforeOrder,
    LoomMessageRecord? beforeMessage,
    int limit = 50,
  }) {
    _requireOpen();
    if (limit < 1 || limit > 200) {
      throw ArgumentError.value(limit, 'limit');
    }
    if (beforeMessage != null && beforeOrder != null) {
      throw ArgumentError('Use one message cursor');
    }
    final cursor = beforeMessage;
    final rows =
        cursor != null
            ? _db.select(
              '''SELECT * FROM messages WHERE conversation_id = ? AND (
            created_at < ? OR (created_at = ? AND created_order < ?) OR
            (created_at = ? AND created_order = ? AND id < ?))
            ORDER BY created_at DESC, created_order DESC, id DESC LIMIT ?''',
              [
                conversationId,
                cursor.createdAt.toUtc().toIso8601String(),
                cursor.createdAt.toUtc().toIso8601String(),
                cursor.createdOrder,
                cursor.createdAt.toUtc().toIso8601String(),
                cursor.createdOrder,
                cursor.id,
                limit,
              ],
            )
            : beforeOrder == null
            ? _db.select(
              '''SELECT * FROM messages WHERE conversation_id = ?
               ORDER BY created_at DESC, created_order DESC, id DESC LIMIT ?''',
              [conversationId, limit],
            )
            : _db.select(
              '''SELECT * FROM messages WHERE conversation_id = ? AND created_order < ?
               ORDER BY created_at DESC, created_order DESC, id DESC LIMIT ?''',
              [conversationId, beforeOrder, limit],
            );
    return rows.map(_messageFromRow).toList(growable: false);
  }

  /// Read locally first. Client IDs survive DTN/server ID reconciliation, while
  /// the server cursor is queued only for messages with a server-assigned order.
  void markMessagesRead(
    String conversationId,
    String ownAddress,
    Iterable<String> clientIds,
  ) {
    _requireOpen();
    _db.execute('SAVEPOINT local_read');
    try {
      _db.execute('INSERT OR REPLACE INTO local_read_state VALUES (?, ?)', [
        conversationId,
        ownAddress.toLowerCase(),
      ]);
      for (final id in clientIds) {
        _db.execute(
          'INSERT OR IGNORE INTO local_read_messages SELECT client_id FROM messages WHERE client_id = ? AND conversation_id = ?',
          [id, conversationId],
        );
      }
      _queueReadCursor(conversationId);
      _db.execute('RELEASE SAVEPOINT local_read');
    } catch (_) {
      _db.execute('ROLLBACK TO SAVEPOINT local_read');
      _db.execute('RELEASE SAVEPOINT local_read');
      rethrow;
    }
  }

  void _queueReadCursor(String conversationId) {
    // Never send a microsecond local DTN order to the server: it would mark
    // future messages read. Only server IDs participate in the watermark.
    final rows = _db.select(
      "SELECT MAX(created_order) AS through_order FROM messages m JOIN local_read_messages r ON r.client_id = m.client_id WHERE conversation_id = ? AND m.id NOT LIKE 'local:%' AND m.id NOT LIKE 'dtn_%'",
      [conversationId],
    );
    final order = rows.first['through_order'] as int?;
    if (order == null) {
      return;
    }
    final key = 'read:$conversationId';
    final previous = int.tryParse(readCursor(key) ?? '') ?? -1;
    if (order <= previous) {
      return;
    }
    writeCursor(key, order.toString());
    final now = DateTime.now().toUtc();
    enqueue(
      LoomPendingOperation(
        operationId: '$key:$order',
        clientId: key,
        conversationId: conversationId,
        kind: LoomPendingOperationKind.markRead,
        payload: {'throughOrder': order},
        attemptCount: 0,
        nextAttemptAt: now,
        createdAt: now,
      ),
    );
  }

  void queueNearbyReceipt(String clientId) {
    _requireOpen();
    _db.execute(
      'INSERT OR IGNORE INTO nearby_receipt_outbox(client_id) VALUES (?)',
      [clientId],
    );
  }

  List<String> pendingNearbyReceipts() {
    _requireOpen();
    return _db
        .select(
          'SELECT client_id FROM nearby_receipt_outbox ORDER BY rowid LIMIT 50',
        )
        .map((row) => row['client_id'] as String)
        .toList();
  }

  void completeNearbyReceipt(String clientId) {
    _requireOpen();
    _db.execute('DELETE FROM nearby_receipt_outbox WHERE client_id = ?', [
      clientId,
    ]);
  }

  LoomConversation? conversationById(String id) {
    _requireOpen();
    final rows = _db.select(
      'SELECT *, unread_count AS visible_unread_count FROM conversations WHERE id = ?',
      [id],
    );
    return rows.isEmpty ? null : _conversationFromRow(rows.first);
  }

  LoomMessageRecord? messageByClientId(String clientId) {
    _requireOpen();
    final rows = _db.select(
      'SELECT * FROM messages WHERE client_id = ? LIMIT 1',
      [clientId],
    );
    return rows.isEmpty ? null : _messageFromRow(rows.first);
  }

  bool hasMessageClientId(String clientId) {
    _requireOpen();
    if (clientId.isEmpty) {
      return false;
    }
    return _db.select('SELECT 1 FROM messages WHERE client_id = ? LIMIT 1', [
      clientId,
    ]).isNotEmpty;
  }

  void enqueue(LoomPendingOperation operation) {
    _requireOpen();
    if (_locallyDeleted(operation.clientId)) return;
    _db.execute(
      '''
      INSERT INTO pending_operations (
        operation_id, client_id, conversation_id, kind, payload_json,
        attempt_count, next_attempt_at, created_at, last_error
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(operation_id) DO NOTHING
      ''',
      [
        operation.operationId,
        operation.clientId,
        operation.conversationId,
        operation.kind.name,
        jsonEncode(operation.payload),
        operation.attemptCount,
        operation.nextAttemptAt.toUtc().toIso8601String(),
        operation.createdAt.toUtc().toIso8601String(),
        operation.lastError,
      ],
    );
  }

  List<LoomPendingOperation> dueOperations(DateTime now, {int limit = 50}) {
    _requireOpen();
    final rows = _db.select(
      '''
      SELECT * FROM pending_operations
      WHERE next_attempt_at <= ?
      ORDER BY CASE WHEN kind = 'sendMessage' THEN 0 ELSE 1 END,
               next_attempt_at ASC, created_at ASC
      LIMIT ?
      ''',
      [now.toUtc().toIso8601String(), limit],
    );
    return rows.map(_pendingFromRow).toList(growable: false);
  }

  void rescheduleOperation(
    String operationId, {
    required int attemptCount,
    required DateTime nextAttemptAt,
    required String lastError,
  }) {
    _requireOpen();
    _db.execute(
      '''UPDATE pending_operations
         SET attempt_count = ?, next_attempt_at = ?, last_error = ?
         WHERE operation_id = ?''',
      [
        attemptCount,
        nextAttemptAt.toUtc().toIso8601String(),
        lastError,
        operationId,
      ],
    );
  }

  bool hasPendingOperation(String operationId) {
    _requireOpen();
    return _db.select(
      'SELECT 1 FROM pending_operations WHERE operation_id = ?',
      [operationId],
    ).isNotEmpty;
  }

  int get pendingSendCount {
    _requireOpen();
    return _db.select(
          'SELECT COUNT(*) AS count FROM pending_operations WHERE kind = ?',
          [LoomPendingOperationKind.sendMessage.name],
        ).first['count']
        as int;
  }

  /// A new network or explicit retry need not wait for the old backoff window.
  /// Ciphertext, client IDs and attempt counts remain unchanged.
  void retryPendingSends({bool includeRejected = false}) {
    _requireOpen();
    _db.execute(
      'UPDATE pending_operations SET next_attempt_at = ?, last_error = NULL '
      'WHERE kind = ? '
      '${includeRejected ? '' : "AND client_id NOT IN (SELECT client_id FROM messages WHERE delivery_state = 'failed')"}',
      [
        DateTime.now().toUtc().toIso8601String(),
        LoomPendingOperationKind.sendMessage.name,
      ],
    );
  }

  void completeOperation(String operationId) {
    _requireOpen();
    _db.execute('DELETE FROM pending_operations WHERE operation_id = ?', [
      operationId,
    ]);
  }

  /// Closes an ordinary send retry once the same client id has been observed
  /// through sync/realtime. This is what makes online/DTN races idempotent.
  void completeSendOperationsByClientId(String clientId) {
    _requireOpen();
    _db.execute(
      'DELETE FROM pending_operations WHERE client_id = ? AND kind = ?',
      [clientId, LoomPendingOperationKind.sendMessage.name],
    );
  }

  String? readCursor(String scope) {
    _requireOpen();
    final rows = _db.select('SELECT cursor FROM sync_state WHERE scope = ?', [
      scope,
    ]);
    return rows.isEmpty ? null : rows.first['cursor'] as String?;
  }

  void writeCursor(String scope, String? cursor) {
    _requireOpen();
    _db.execute(
      '''INSERT INTO sync_state(scope, cursor, updated_at) VALUES (?, ?, ?)
         ON CONFLICT(scope) DO UPDATE SET cursor=excluded.cursor, updated_at=excluded.updated_at''',
      [scope, cursor, DateTime.now().toUtc().toIso8601String()],
    );
  }

  bool markEventSeen(String eventId) {
    _requireOpen();
    final exists = _db.select(
      'SELECT 1 FROM seen_events WHERE event_id = ? LIMIT 1',
      [eventId],
    );
    if (exists.isNotEmpty) {
      return false;
    }
    _db.execute('INSERT INTO seen_events(event_id, seen_at) VALUES (?, ?)', [
      eventId,
      DateTime.now().toUtc().toIso8601String(),
    ]);
    return true;
  }

  void forgetSeenEvent(String eventId) {
    _requireOpen();
    _db.execute('DELETE FROM seen_events WHERE event_id = ?', [eventId]);
  }

  void pruneSeenEvents(DateTime olderThan) {
    _requireOpen();
    _db.execute('DELETE FROM seen_events WHERE seen_at < ?', [
      olderThan.toUtc().toIso8601String(),
    ]);
  }

  LoomConversation _conversationFromRow(Row row) => LoomConversation(
    id: row['id'] as String,
    kind: LoomConversationKind.values.byName(row['kind'] as String),
    title: row['title'] as String?,
    peerAddress: row['peer_address'] as String?,
    updatedOrder: row['updated_order'] as int,
    unreadCount:
        row['local_marked_unread'] == 1 &&
                (row['visible_unread_count'] ?? row['unread_count']) == 0
            ? 1
            : (row['visible_unread_count'] ?? row['unread_count']) as int,
    isMuted: (row['local_is_muted'] ?? row['is_muted']) != 0,
    isPinned: (row['local_is_pinned'] ?? row['is_pinned']) != 0,
  );

  LoomMessageRecord _messageFromRow(Row row) {
    final metadataRaw = jsonDecode(row['metadata_json'] as String);
    return LoomMessageRecord(
      id: row['id'] as String,
      clientId: row['client_id'] as String,
      conversationId: row['conversation_id'] as String,
      senderAddress: row['sender_address'] as String,
      type: LoomMessageType.values.byName(row['type'] as String),
      ciphertext: row['ciphertext'] as String,
      protocolVersion: row['protocol_version'] as String,
      createdOrder: row['created_order'] as int,
      createdAt: DateTime.parse(row['created_at'] as String).toUtc(),
      deliveryState: LoomDeliveryState.values.byName(
        row['delivery_state'] as String,
      ),
      transportPath: LoomMessageTransportPath.values.byName(
        row['transport_path'] as String,
      ),
      replyToMessageId: row['reply_to_message_id'] as String?,
      metadata: metadataRaw is Map<String, Object?> ? metadataRaw : const {},
    );
  }

  LoomPendingOperation _pendingFromRow(Row row) {
    final payloadRaw = jsonDecode(row['payload_json'] as String);
    return LoomPendingOperation(
      operationId: row['operation_id'] as String,
      clientId: row['client_id'] as String,
      conversationId: row['conversation_id'] as String,
      kind: LoomPendingOperationKind.values.byName(row['kind'] as String),
      payload: payloadRaw is Map<String, Object?> ? payloadRaw : const {},
      attemptCount: row['attempt_count'] as int,
      nextAttemptAt: DateTime.parse(row['next_attempt_at'] as String).toUtc(),
      createdAt: DateTime.parse(row['created_at'] as String).toUtc(),
      lastError: row['last_error'] as String?,
    );
  }

  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    _db.dispose();
  }

  void _requireOpen() {
    if (_closed) {
      throw StateError('LoomMessagingStore is closed');
    }
  }
}

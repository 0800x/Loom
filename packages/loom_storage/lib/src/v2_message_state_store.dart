import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

final class LoomSeenMessageConflict implements Exception {
  const LoomSeenMessageConflict(this.message);

  final String message;

  @override
  String toString() => 'LoomSeenMessageConflict: $message';
}

final class LoomSeenMessageRecord {
  const LoomSeenMessageRecord({
    required this.messageId,
    required this.senderAccountId,
    required this.senderDeviceId,
    required this.firstSeenAt,
    required this.expiresAt,
  });

  final String messageId;
  final String senderAccountId;
  final String senderDeviceId;
  final DateTime firstSeenAt;
  final DateTime expiresAt;
}

final class LoomOutboundMessagePacketRecord {
  const LoomOutboundMessagePacketRecord({
    required this.messageId,
    required this.packetId,
    required this.recipientDeviceId,
    required this.createdAt,
    required this.expiresAt,
  });

  final String messageId;
  final String packetId;
  final String recipientDeviceId;
  final DateTime createdAt;
  final DateTime expiresAt;
}

enum LoomPendingDeliveryReceiptState { pending, applied }

final class LoomPendingDeliveryReceiptRecord {
  const LoomPendingDeliveryReceiptRecord({
    required this.messageId,
    required this.packetId,
    required this.recipientDeviceId,
    required this.receiptObservedAt,
    required this.state,
    required this.appliedAt,
  });

  final String messageId;
  final String packetId;
  final String recipientDeviceId;
  final DateTime receiptObservedAt;
  final LoomPendingDeliveryReceiptState state;
  final DateTime? appliedAt;
}

/// Durable logical-message and E2EE-delivery-receipt bookkeeping for v2.
///
/// This store is intentionally separate from UI message cache state. It uses
/// WAL + `synchronous=FULL` because logical duplicate suppression and receipt
/// recovery affect externally visible delivery semantics.
///
/// It stores no message plaintext or session keys.
final class LoomV2MessageStateStore {
  LoomV2MessageStateStore._(this._db) {
    _configure();
    _migrate();
  }

  final Database _db;
  bool _closed = false;

  static LoomV2MessageStateStore openFile(String path) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    return LoomV2MessageStateStore._(sqlite3.open(path));
  }

  static LoomV2MessageStateStore openInMemory() =>
      LoomV2MessageStateStore._(sqlite3.openInMemory());

  void _configure() {
    _db.execute('PRAGMA journal_mode = WAL');
    _db.execute('PRAGMA synchronous = FULL');
    _db.execute('PRAGMA busy_timeout = 5000');
  }

  void _migrate() {
    final version = _db.select('PRAGMA user_version').first.values.first as int;
    if (version > 1) {
      throw StateError(
        'Loom v2 message-state schema $version is newer than supported schema 1',
      );
    }
    if (version == 1) {
      _verifySchema();
      return;
    }

    _db.execute('BEGIN IMMEDIATE');
    try {
      _db.execute('''
        CREATE TABLE v2_seen_messages (
          message_id TEXT PRIMARY KEY,
          sender_account_id TEXT NOT NULL,
          sender_device_id TEXT NOT NULL,
          first_seen_at TEXT NOT NULL,
          expires_at TEXT NOT NULL
        )
      ''');
      _db.execute('''
        CREATE INDEX idx_v2_seen_messages_expiry
        ON v2_seen_messages(expires_at)
      ''');
      _db.execute('''
        CREATE TABLE v2_outbound_message_packets (
          message_id TEXT NOT NULL,
          recipient_device_id TEXT NOT NULL,
          packet_id TEXT NOT NULL UNIQUE,
          created_at TEXT NOT NULL,
          expires_at TEXT NOT NULL,
          PRIMARY KEY(message_id, recipient_device_id)
        )
      ''');
      _db.execute('''
        CREATE INDEX idx_v2_outbound_packets_expiry
        ON v2_outbound_message_packets(expires_at)
      ''');
      _db.execute('''
        CREATE TABLE v2_pending_delivery_receipts (
          message_id TEXT NOT NULL,
          recipient_device_id TEXT NOT NULL,
          packet_id TEXT NOT NULL,
          receipt_observed_at TEXT NOT NULL,
          state TEXT NOT NULL,
          applied_at TEXT,
          PRIMARY KEY(message_id, recipient_device_id)
        )
      ''');
      _db.execute('''
        CREATE INDEX idx_v2_pending_receipts_state
        ON v2_pending_delivery_receipts(state, receipt_observed_at)
      ''');
      _db.execute('PRAGMA user_version = 1');
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
    _verifySchema();
  }

  void _verifySchema() {
    const required = <String>{
      'v2_seen_messages',
      'v2_outbound_message_packets',
      'v2_pending_delivery_receipts',
    };
    final rows = _db.select(
      "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'v2_%'",
    );
    final present = rows.map((row) => row['name'] as String).toSet();
    if (!present.containsAll(required)) {
      throw StateError(
        'The selected SQLite file is not a Loom v2 message-state database',
      );
    }
  }

  /// Records the protected logical MessageId after successful durable decrypt.
  ///
  /// Returns `true` for first observation and `false` for a duplicate from the
  /// same authenticated sender identity. Reusing a MessageId under a different
  /// sender account/device fails closed instead of suppressing the new content.
  bool markMessageSeen({
    required String messageId,
    required String senderAccountId,
    required String senderDeviceId,
    required DateTime now,
    Duration retention = const Duration(days: 30),
  }) {
    _requireOpen();
    _validateId(messageId, 'message id');
    _validateId(senderAccountId, 'sender account id', maxLength: 256);
    _validateId(senderDeviceId, 'sender device id', maxLength: 256);
    if (retention <= Duration.zero || retention > const Duration(days: 180)) {
      throw ArgumentError.value(retention, 'retention');
    }
    final observed = now.toUtc();
    final expires = observed.add(retention);

    _db.execute('BEGIN IMMEDIATE');
    var began = true;
    try {
      final rows = _db.select(
        'SELECT * FROM v2_seen_messages WHERE message_id = ? LIMIT 1',
        [messageId],
      );
      if (rows.isNotEmpty) {
        final existing = rows.first;
        if (existing['sender_account_id'] != senderAccountId ||
            existing['sender_device_id'] != senderDeviceId) {
          throw LoomSeenMessageConflict(
            'MessageId $messageId was already observed from another sender identity',
          );
        }
        _db.execute('COMMIT');
        began = false;
        return false;
      }

      _db.execute(
        '''
        INSERT INTO v2_seen_messages(
          message_id, sender_account_id, sender_device_id, first_seen_at, expires_at
        ) VALUES (?, ?, ?, ?, ?)
        ''',
        [
          messageId,
          senderAccountId,
          senderDeviceId,
          observed.toIso8601String(),
          expires.toIso8601String(),
        ],
      );
      _db.execute('COMMIT');
      began = false;
      return true;
    } catch (_) {
      if (began) {
        try {
          _db.execute('ROLLBACK');
        } catch (_) {
          // Preserve original failure.
        }
      }
      rethrow;
    }
  }

  LoomSeenMessageRecord? readSeenMessage(String messageId) {
    _requireOpen();
    _validateId(messageId, 'message id');
    final rows = _db.select(
      'SELECT * FROM v2_seen_messages WHERE message_id = ? LIMIT 1',
      [messageId],
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return LoomSeenMessageRecord(
      messageId: row['message_id'] as String,
      senderAccountId: row['sender_account_id'] as String,
      senderDeviceId: row['sender_device_id'] as String,
      firstSeenAt: DateTime.parse(row['first_seen_at'] as String).toUtc(),
      expiresAt: DateTime.parse(row['expires_at'] as String).toUtc(),
    );
  }

  /// Correlates one logical MessageId/recipient-device pair with its stable
  /// visible PacketId.
  ///
  /// A logical message may legitimately be encrypted separately to multiple
  /// authorized recipient devices, so MessageId alone is not a unique packet
  /// key. The receipt carries recipientDeviceId and resolves this composite key.
  LoomOutboundMessagePacketRecord registerOutboundPacket({
    required String messageId,
    required String packetId,
    required String recipientDeviceId,
    required DateTime createdAt,
    required DateTime expiresAt,
  }) {
    _requireOpen();
    _validateId(messageId, 'message id');
    _validateId(packetId, 'packet id');
    _validateId(recipientDeviceId, 'recipient device id', maxLength: 256);
    final created = createdAt.toUtc();
    final expires = expiresAt.toUtc();
    if (!expires.isAfter(created) ||
        expires.isAfter(created.add(const Duration(days: 7)))) {
      throw const FormatException(
        'Invalid outbound message/packet correlation expiry',
      );
    }

    _db.execute('BEGIN IMMEDIATE');
    var began = true;
    try {
      final rows = _db.select(
        '''
        SELECT * FROM v2_outbound_message_packets
        WHERE message_id = ? AND recipient_device_id = ? LIMIT 1
        ''',
        [messageId, recipientDeviceId],
      );
      if (rows.isNotEmpty) {
        final existing = _outboundFromRow(rows.first);
        if (existing.packetId != packetId ||
            existing.createdAt != created ||
            existing.expiresAt != expires) {
          throw LoomSeenMessageConflict(
            'MessageId $messageId / recipient $recipientDeviceId already maps to different outbound packet metadata',
          );
        }
        _db.execute('COMMIT');
        began = false;
        return existing;
      }
      final packetRows = _db.select(
        'SELECT message_id,recipient_device_id FROM v2_outbound_message_packets WHERE packet_id = ? LIMIT 1',
        [packetId],
      );
      if (packetRows.isNotEmpty) {
        throw LoomSeenMessageConflict(
          'PacketId $packetId is already correlated to another logical/device send',
        );
      }
      _db.execute(
        '''
        INSERT INTO v2_outbound_message_packets(
          message_id, recipient_device_id, packet_id, created_at, expires_at
        ) VALUES (?, ?, ?, ?, ?)
        ''',
        [
          messageId,
          recipientDeviceId,
          packetId,
          created.toIso8601String(),
          expires.toIso8601String(),
        ],
      );
      _db.execute('COMMIT');
      began = false;
      return LoomOutboundMessagePacketRecord(
        messageId: messageId,
        packetId: packetId,
        recipientDeviceId: recipientDeviceId,
        createdAt: created,
        expiresAt: expires,
      );
    } catch (_) {
      if (began) {
        try {
          _db.execute('ROLLBACK');
        } catch (_) {
          // Preserve original failure.
        }
      }
      rethrow;
    }
  }

  LoomOutboundMessagePacketRecord? readOutboundPacket({
    required String messageId,
    required String recipientDeviceId,
  }) {
    _requireOpen();
    _validateId(messageId, 'message id');
    _validateId(recipientDeviceId, 'recipient device id', maxLength: 256);
    final rows = _db.select(
      '''
      SELECT * FROM v2_outbound_message_packets
      WHERE message_id = ? AND recipient_device_id = ? LIMIT 1
      ''',
      [messageId, recipientDeviceId],
    );
    return rows.isEmpty ? null : _outboundFromRow(rows.first);
  }

  /// Durably stages an authenticated E2EE delivery receipt for cross-database
  /// application to the DTN packet store.
  ///
  /// Staging before the DTN mutation means a process crash cannot lose the
  /// receipt between the two independent SQLite domains. Recovery replays
  /// [listPendingDeliveryReceipts].
  LoomPendingDeliveryReceiptRecord stageDeliveryReceipt({
    required String messageId,
    required String packetId,
    required String recipientDeviceId,
    required DateTime observedAt,
  }) {
    _requireOpen();
    _validateId(messageId, 'message id');
    _validateId(packetId, 'packet id');
    _validateId(recipientDeviceId, 'recipient device id', maxLength: 256);
    final observed = observedAt.toUtc();

    _db.execute('BEGIN IMMEDIATE');
    var began = true;
    try {
      final rows = _db.select(
        '''
        SELECT * FROM v2_pending_delivery_receipts
        WHERE message_id = ? AND recipient_device_id = ? LIMIT 1
        ''',
        [messageId, recipientDeviceId],
      );
      if (rows.isNotEmpty) {
        final existing = _pendingReceiptFromRow(rows.first);
        if (existing.packetId != packetId) {
          throw LoomSeenMessageConflict(
            'Delivery receipt for $messageId / $recipientDeviceId conflicts with prior packet identity',
          );
        }
        _db.execute('COMMIT');
        began = false;
        return existing;
      }

      _db.execute(
        '''
        INSERT INTO v2_pending_delivery_receipts(
          message_id, recipient_device_id, packet_id, receipt_observed_at,
          state, applied_at
        ) VALUES (?, ?, ?, ?, ?, NULL)
        ''',
        [
          messageId,
          recipientDeviceId,
          packetId,
          observed.toIso8601String(),
          LoomPendingDeliveryReceiptState.pending.name,
        ],
      );
      _db.execute('COMMIT');
      began = false;
      return LoomPendingDeliveryReceiptRecord(
        messageId: messageId,
        packetId: packetId,
        recipientDeviceId: recipientDeviceId,
        receiptObservedAt: observed,
        state: LoomPendingDeliveryReceiptState.pending,
        appliedAt: null,
      );
    } catch (_) {
      if (began) {
        try {
          _db.execute('ROLLBACK');
        } catch (_) {
          // Preserve original failure.
        }
      }
      rethrow;
    }
  }

  List<LoomPendingDeliveryReceiptRecord> listPendingDeliveryReceipts({
    int limit = 100,
  }) {
    _requireOpen();
    if (limit < 1 || limit > 1000) throw ArgumentError.value(limit, 'limit');
    final rows = _db.select(
      '''
      SELECT * FROM v2_pending_delivery_receipts
      WHERE state = ?
      ORDER BY receipt_observed_at ASC, message_id ASC, recipient_device_id ASC
      LIMIT ?
      ''',
      [LoomPendingDeliveryReceiptState.pending.name, limit],
    );
    return rows.map(_pendingReceiptFromRow).toList(growable: false);
  }

  LoomPendingDeliveryReceiptRecord markDeliveryReceiptApplied({
    required String messageId,
    required String recipientDeviceId,
    required DateTime appliedAt,
  }) {
    _requireOpen();
    _validateId(messageId, 'message id');
    _validateId(recipientDeviceId, 'recipient device id', maxLength: 256);
    final applied = appliedAt.toUtc();
    _db.execute(
      '''
      UPDATE v2_pending_delivery_receipts
      SET state = ?, applied_at = COALESCE(applied_at, ?)
      WHERE message_id = ? AND recipient_device_id = ?
      ''',
      [
        LoomPendingDeliveryReceiptState.applied.name,
        applied.toIso8601String(),
        messageId,
        recipientDeviceId,
      ],
    );
    final rows = _db.select(
      '''
      SELECT * FROM v2_pending_delivery_receipts
      WHERE message_id = ? AND recipient_device_id = ? LIMIT 1
      ''',
      [messageId, recipientDeviceId],
    );
    if (rows.isEmpty) {
      throw StateError(
        'Delivery receipt $messageId / $recipientDeviceId does not exist',
      );
    }
    return _pendingReceiptFromRow(rows.first);
  }

  int prune(DateTime now) {
    _requireOpen();
    final current = now.toUtc().toIso8601String();
    _db.execute('DELETE FROM v2_seen_messages WHERE expires_at <= ?', [
      current,
    ]);
    final seenDeleted = _db.updatedRows;
    _db.execute(
      '''
      DELETE FROM v2_outbound_message_packets AS o
      WHERE o.expires_at <= ?
        AND NOT EXISTS (
          SELECT 1 FROM v2_pending_delivery_receipts AS r
          WHERE r.message_id = o.message_id
            AND r.recipient_device_id = o.recipient_device_id
            AND r.state = ?
        )
      ''',
      [current, LoomPendingDeliveryReceiptState.pending.name],
    );
    final outboundDeleted = _db.updatedRows;
    return seenDeleted + outboundDeleted;
  }

  LoomOutboundMessagePacketRecord _outboundFromRow(Row row) =>
      LoomOutboundMessagePacketRecord(
        messageId: row['message_id'] as String,
        packetId: row['packet_id'] as String,
        recipientDeviceId: row['recipient_device_id'] as String,
        createdAt: DateTime.parse(row['created_at'] as String).toUtc(),
        expiresAt: DateTime.parse(row['expires_at'] as String).toUtc(),
      );

  LoomPendingDeliveryReceiptRecord _pendingReceiptFromRow(Row row) {
    final rawState = row['state'] as String;
    LoomPendingDeliveryReceiptState? state;
    for (final candidate in LoomPendingDeliveryReceiptState.values) {
      if (candidate.name == rawState) {
        state = candidate;
        break;
      }
    }
    if (state == null) {
      throw StateError('Unknown delivery receipt state $rawState');
    }
    return LoomPendingDeliveryReceiptRecord(
      messageId: row['message_id'] as String,
      packetId: row['packet_id'] as String,
      recipientDeviceId: row['recipient_device_id'] as String,
      receiptObservedAt:
          DateTime.parse(row['receipt_observed_at'] as String).toUtc(),
      state: state,
      appliedAt:
          row['applied_at'] == null
              ? null
              : DateTime.parse(row['applied_at'] as String).toUtc(),
    );
  }

  static void _validateId(
    String value,
    String label, {
    int minLength = 8,
    int maxLength = 128,
  }) {
    if (value.trim() != value ||
        value.length < minLength ||
        value.length > maxLength ||
        value.contains('\r') ||
        value.contains('\n')) {
      throw FormatException('Invalid $label');
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _db.dispose();
  }

  void _requireOpen() {
    if (_closed) throw StateError('LoomV2MessageStateStore is closed');
  }
}

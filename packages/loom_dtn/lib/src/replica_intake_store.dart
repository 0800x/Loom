import 'dart:io';
import 'dart:typed_data';

import 'package:loom_protocol/loom_protocol.dart';
import 'package:sqlite3/sqlite3.dart';

enum LoomReplicaIntakeDisposition {
  accepted,
  duplicate,
}

/// Result returned only after the inbound packet is known to be durably stored.
///
/// Both [accepted] and [duplicate] are safe reasons for a hop-local transfer ACK:
/// a duplicate means durable custody for this PacketId already existed. Neither
/// disposition is an end-to-end delivery receipt.
final class LoomReplicaIntakeResult {
  const LoomReplicaIntakeResult({
    required this.packetId,
    required this.disposition,
    required this.effectiveCopiesRemaining,
    required this.storedAt,
  });

  final String packetId;
  final LoomReplicaIntakeDisposition disposition;
  final int effectiveCopiesRemaining;
  final DateTime storedAt;

  bool get shouldAcknowledgeTransfer => true;
}

/// Raised when a PacketId already exists but immutable packet identity differs.
final class LoomReplicaConflict implements Exception {
  const LoomReplicaConflict(this.message);

  final String message;

  @override
  String toString() => 'LoomReplicaConflict: $message';
}

/// Durable receive-side custody for authenticated DTN peer transfers.
///
/// This class intentionally opens the same SQLite file as
/// `LoomSqlitePacketStore`. The main packet store owns schema creation and
/// migration; this receive-side view only accepts an already-migrated schema.
/// Keeping the intake implementation separate avoids giving transports access
/// to the packet store's broader mutation surface.
///
/// The caller MUST authenticate the peer/link before calling [acceptReplica].
/// This store validates packet structure, TTL, hop/copy bounds and PacketId
/// consistency, but peer authentication belongs to the peer-session layer.
final class LoomSqliteReplicaIntakeStore {
  LoomSqliteReplicaIntakeStore._(this._db) {
    _configure();
    _verifySchema();
  }

  final Database _db;
  bool _closed = false;

  /// Local policy cap. Forwarding fields are untrusted input; values encoded
  /// above this cap may be retained byte-for-byte for duplicate identity, but
  /// never become additional local forwarding authority.
  static const int maxAcceptedLocalCopies = 8;

  static LoomSqliteReplicaIntakeStore openExistingFile(String path) {
    final file = File(path);
    if (!file.existsSync()) {
      throw StateError(
        'DTN packet database does not exist; open LoomSqlitePacketStore first',
      );
    }
    return LoomSqliteReplicaIntakeStore._(sqlite3.open(path));
  }

  void _configure() {
    _db.execute('PRAGMA foreign_keys = ON');
    _db.execute('PRAGMA journal_mode = WAL');
    _db.execute('PRAGMA synchronous = FULL');
    _db.execute('PRAGMA busy_timeout = 5000');
  }

  void _verifySchema() {
    final version = _db.select('PRAGMA user_version').first.values.first as int;
    if (version != 2) {
      throw StateError(
        'Inbound replica intake requires Loom DTN schema 2; found $version',
      );
    }
    final columns = _db.select('PRAGMA table_info(dtn_packets)');
    const required = <String>{
      'packet_id',
      'origin',
      'operation_id',
      'message_id',
      'wire_bytes',
      'routing_scope',
      'mailbox_token',
      'expires_at',
      'priority',
      'initial_hop_limit',
      'hops_used',
      'copies_remaining',
      'current_copies_remaining',
      'stored_at',
      'state',
      'attempt_count',
      'next_attempt_at',
    };
    final present = columns.map((row) => row['name'] as String).toSet();
    if (!present.containsAll(required)) {
      throw StateError(
          'Loom DTN packet schema is incomplete for replica intake');
    }
  }

  LoomReplicaIntakeResult acceptReplica({
    required Uint8List exactOuterEnvelopeBytes,
    required DateTime now,
  }) {
    _requireOpen();
    final exactBytes = Uint8List.fromList(exactOuterEnvelopeBytes);
    if (exactBytes.isEmpty ||
        exactBytes.length > LoomEnvelopeV2Codec.maxWireBytes) {
      throw const FormatException('Invalid inbound DTN packet size');
    }

    final outer = LoomEnvelopeV2Codec.decodeOuter(exactBytes);
    outer.validate();
    final current = now.toUtc();
    final expiry = outer.expiresAtBucket.toUtc();

    if (!expiry.isAfter(current)) {
      throw const FormatException('Inbound DTN packet is already expired');
    }
    if (expiry.isAfter(current.add(const Duration(days: 7)))) {
      throw const FormatException(
          'Inbound DTN packet exceeds seven-day custody limit');
    }
    if (outer.forwardingState.hopsUsed < 1) {
      throw const FormatException(
          'Peer-delivered DTN packet must have advanced one hop');
    }
    if (outer.forwardingState.hopsUsed > outer.initialHopLimit) {
      throw const FormatException('Inbound DTN packet exceeded hop limit');
    }

    // The model currently permits up to 16 encoded copies. That field is
    // untrusted. The exact source bytes remain stored, while local forwarding
    // authority is clamped to our stricter policy cap.
    final effectiveCopies =
        outer.forwardingState.copiesRemaining.clamp(1, maxAcceptedLocalCopies);

    _db.execute('BEGIN IMMEDIATE');
    var began = true;
    try {
      final existingRows = _db.select(
        'SELECT * FROM dtn_packets WHERE packet_id = ? LIMIT 1',
        [outer.packetId],
      );
      if (existingRows.isNotEmpty) {
        final existing = existingRows.first;
        _verifySameImmutablePacket(existing, outer);
        final storedAt =
            DateTime.parse(existing['stored_at'] as String).toUtc();
        final currentCopies = existing['current_copies_remaining'] as int;
        _db.execute('COMMIT');
        began = false;
        return LoomReplicaIntakeResult(
          packetId: outer.packetId,
          disposition: LoomReplicaIntakeDisposition.duplicate,
          effectiveCopiesRemaining: currentCopies,
          storedAt: storedAt,
        );
      }

      _db.execute(
        '''
        INSERT INTO dtn_packets (
          packet_id, origin, operation_id, message_id, wire_bytes,
          routing_scope, mailbox_token, expires_at, priority,
          initial_hop_limit, hops_used, copies_remaining,
          current_copies_remaining, stored_at, state,
          attempt_count, next_attempt_at, last_error_code,
          gateway_accepted_at, relay_accepted_at, recipient_confirmed_at,
          terminal_at
        ) VALUES (?, ?, NULL, NULL, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, NULL,
                  NULL, NULL, NULL, NULL)
        ''',
        [
          outer.packetId,
          'carriedReplica',
          exactBytes,
          outer.routingHint.scope.name,
          outer.routingHint.mailboxToken,
          expiry.toIso8601String(),
          outer.priority.name,
          outer.initialHopLimit,
          outer.forwardingState.hopsUsed,
          outer.forwardingState.copiesRemaining,
          effectiveCopies,
          current.toIso8601String(),
          'queued',
          current.toIso8601String(),
        ],
      );
      _db.execute('COMMIT');
      began = false;
      return LoomReplicaIntakeResult(
        packetId: outer.packetId,
        disposition: LoomReplicaIntakeDisposition.accepted,
        effectiveCopiesRemaining: effectiveCopies,
        storedAt: current,
      );
    } catch (_) {
      if (began) {
        try {
          _db.execute('ROLLBACK');
        } catch (_) {
          // Preserve the original error.
        }
      }
      rethrow;
    }
  }

  void _verifySameImmutablePacket(Row existing, LoomOuterEnvelopeV2 incoming) {
    final storedWire = Uint8List.fromList(existing['wire_bytes'] as Uint8List);
    final stored = LoomEnvelopeV2Codec.decodeOuter(storedWire);

    if (stored.packetId != incoming.packetId ||
        stored.routingHint.scope != incoming.routingHint.scope ||
        !_sameBytes(stored.routingHint.mailboxToken,
            incoming.routingHint.mailboxToken) ||
        stored.expiresAtBucket.toUtc() != incoming.expiresAtBucket.toUtc() ||
        stored.priority != incoming.priority ||
        stored.initialHopLimit != incoming.initialHopLimit ||
        !_sameBytes(stored.encryptedPayload, incoming.encryptedPayload)) {
      throw LoomReplicaConflict(
        'PacketId ${incoming.packetId} conflicts with existing immutable packet data',
      );
    }

    // Forwarding state is intentionally excluded from immutable identity.
    // Different legitimate replicas of the same PacketId can arrive with
    // different hop/copy revisions. First durable custody wins; later replicas
    // never increase the locally retained copy budget.
  }

  static bool _sameBytes(List<int> left, List<int> right) {
    if (left.length != right.length) return false;
    for (var i = 0; i < left.length; i++) {
      if (left[i] != right[i]) return false;
    }
    return true;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _db.dispose();
  }

  void _requireOpen() {
    if (_closed) throw StateError('LoomSqliteReplicaIntakeStore is closed');
  }
}

import 'dart:io';
import 'dart:typed_data';

import 'package:loom_protocol/loom_protocol.dart';
import 'package:sqlite3/sqlite3.dart';

import 'packet_store.dart';
import 'router.dart';
import 'transfer_store.dart';

/// SQLite implementation of Architecture v2 packet custody and transfer
/// preparation.
///
/// The source OuterEnvelope bytes are immutable. Spray-and-Wait forwarding
/// changes only the runtime local copy budget and creates a separate exact
/// next-hop transfer revision, which is itself committed before a transport may
/// send it.
final class LoomSqlitePacketStore
    implements LoomPacketStore, LoomTransferStore, LoomNearbyPacketSource {
  LoomSqlitePacketStore._(this._db) {
    _configure();
    _migrate();
    // Repair retained packets paused by the old destination-node ACK policy.
    // Never recreate spent copy tokens or reopen recipient-confirmed packets.
    _db.execute(
      "UPDATE dtn_packets SET state = 'gatewayAccepted', gateway_accepted_at = COALESCE(gateway_accepted_at, relay_accepted_at) WHERE state = 'relayAccepted' AND current_copies_remaining > 0 AND recipient_confirmed_at IS NULL AND EXISTS (SELECT 1 FROM dtn_transfers t WHERE t.packet_id = dtn_packets.packet_id AND t.reason = 'destinationNode' AND t.state = 'accepted')",
    );
  }

  final Database _db;
  bool _closed = false;
  bool _transactionActive = false;

  static LoomSqlitePacketStore openFile(String path) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    return LoomSqlitePacketStore._(sqlite3.open(path));
  }

  static LoomSqlitePacketStore openInMemory() =>
      LoomSqlitePacketStore._(sqlite3.openInMemory());

  void _configure() {
    _db.execute('PRAGMA foreign_keys = ON');
    _db.execute('PRAGMA journal_mode = WAL');
    _db.execute('PRAGMA synchronous = FULL');
    _db.execute('PRAGMA busy_timeout = 5000');
  }

  void _migrate() {
    final version = _db.select('PRAGMA user_version').first.values.first as int;
    if (version > 2) {
      throw StateError(
        'Loom DTN database schema $version is newer than supported schema 2',
      );
    }
    if (version == 2) {
      _verifySchema();
      return;
    }

    _db.execute('BEGIN IMMEDIATE');
    try {
      if (version == 0) {
        _createPacketSchemaV2();
        _createTransferSchemaV2();
      } else if (version == 1) {
        _db.execute(
          'ALTER TABLE dtn_packets ADD COLUMN current_copies_remaining INTEGER',
        );
        _db.execute(
          'UPDATE dtn_packets SET current_copies_remaining = copies_remaining',
        );
        _createTransferSchemaV2();
      }
      _db.execute('PRAGMA user_version = 2');
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
    _verifySchema();
  }

  void _createPacketSchemaV2() {
    _db.execute('''
      CREATE TABLE dtn_packets (
        packet_id TEXT PRIMARY KEY,
        origin TEXT NOT NULL,
        operation_id TEXT UNIQUE,
        message_id TEXT,
        wire_bytes BLOB NOT NULL,
        routing_scope TEXT NOT NULL,
        mailbox_token BLOB NOT NULL,
        expires_at TEXT NOT NULL,
        priority TEXT NOT NULL,
        initial_hop_limit INTEGER NOT NULL,
        hops_used INTEGER NOT NULL,
        copies_remaining INTEGER NOT NULL,
        current_copies_remaining INTEGER NOT NULL,
        stored_at TEXT NOT NULL,
        state TEXT NOT NULL,
        attempt_count INTEGER NOT NULL DEFAULT 0,
        next_attempt_at TEXT NOT NULL,
        last_error_code TEXT,
        gateway_accepted_at TEXT,
        relay_accepted_at TEXT,
        recipient_confirmed_at TEXT,
        terminal_at TEXT
      )
    ''');
    _db.execute('''
      CREATE INDEX idx_dtn_packets_eligible
      ON dtn_packets(state, next_attempt_at, expires_at, priority)
    ''');
    _db.execute('''
      CREATE INDEX idx_dtn_packets_message
      ON dtn_packets(message_id, stored_at)
    ''');
    _db.execute('''
      CREATE INDEX idx_dtn_packets_terminal
      ON dtn_packets(state, terminal_at, expires_at)
    ''');
  }

  void _createTransferSchemaV2() {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS dtn_transfers (
        transmission_id TEXT PRIMARY KEY,
        packet_id TEXT NOT NULL REFERENCES dtn_packets(packet_id)
          ON DELETE CASCADE,
        opportunity_id TEXT NOT NULL,
        reason TEXT NOT NULL,
        wire_bytes BLOB NOT NULL,
        copies_before INTEGER NOT NULL,
        copies_granted INTEGER NOT NULL,
        copies_retained INTEGER NOT NULL,
        requires_single_copy_handoff INTEGER NOT NULL
          CHECK(requires_single_copy_handoff IN (0, 1)),
        state TEXT NOT NULL,
        prepared_at TEXT NOT NULL,
        completed_at TEXT,
        error_code TEXT
      )
    ''');
    _db.execute('''
      CREATE INDEX IF NOT EXISTS idx_dtn_transfers_packet_state
      ON dtn_transfers(packet_id, state, prepared_at)
    ''');
    _db.execute('''
      CREATE UNIQUE INDEX IF NOT EXISTS idx_dtn_transfers_one_prepared
      ON dtn_transfers(packet_id)
      WHERE state = 'prepared'
    ''');
  }

  void _verifySchema() {
    const requiredTables = <String>{'dtn_packets', 'dtn_transfers'};
    final tables = _db.select(
      "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'dtn_%'",
    );
    final presentTables = tables.map((row) => row['name'] as String).toSet();
    if (!presentTables.containsAll(requiredTables)) {
      throw StateError(
        'The selected SQLite file is not a complete Loom DTN database',
      );
    }

    final packetColumns = _db.select('PRAGMA table_info(dtn_packets)');
    const requiredPacketColumns = <String>{
      'packet_id',
      'wire_bytes',
      'operation_id',
      'state',
      'expires_at',
      'copies_remaining',
      'current_copies_remaining',
    };
    final presentPacketColumns = packetColumns
        .map((row) => row['name'] as String)
        .toSet();
    if (!presentPacketColumns.containsAll(requiredPacketColumns)) {
      throw StateError('Loom DTN packet database schema is incomplete');
    }

    final transferColumns = _db.select('PRAGMA table_info(dtn_transfers)');
    const requiredTransferColumns = <String>{
      'transmission_id',
      'packet_id',
      'wire_bytes',
      'copies_before',
      'copies_granted',
      'copies_retained',
      'state',
    };
    final presentTransferColumns = transferColumns
        .map((row) => row['name'] as String)
        .toSet();
    if (!presentTransferColumns.containsAll(requiredTransferColumns)) {
      throw StateError('Loom DTN transfer database schema is incomplete');
    }
  }

  @override
  LoomStoredDtnPacket putLocalOutbound({
    required String operationId,
    required String messageId,
    required String packetId,
    required Uint8List exactOuterEnvelopeBytes,
    required DateTime now,
  }) {
    _requireAvailableOutsideTransaction();
    _validateOpaqueId(operationId, 'operation id', maxLength: 256);
    _validateOpaqueId(messageId, 'message id');
    _validateOpaqueId(packetId, 'packet id');
    final exactBytes = Uint8List.fromList(exactOuterEnvelopeBytes);
    if (exactBytes.isEmpty ||
        exactBytes.length > LoomEnvelopeV2Codec.maxWireBytes) {
      throw const FormatException('Invalid encoded DTN packet size');
    }

    final outer = LoomEnvelopeV2Codec.decodeOuter(exactBytes);
    if (outer.packetId != packetId) {
      throw const LoomDtnPacketConflict(
        'PacketId does not match the encoded OuterEnvelopeV2',
      );
    }
    final current = now.toUtc();
    if (outer.isExpiredAt(current)) {
      throw const FormatException('Cannot store an already-expired DTN packet');
    }
    if (outer.expiresAtBucket.toUtc().isAfter(
      current.add(const Duration(days: 7)),
    )) {
      throw const FormatException('DTN packet exceeds seven-day custody limit');
    }
    if (outer.forwardingState.hopsUsed != 0) {
      throw const FormatException(
        'Local outbound packet must enter DTN custody at hop zero',
      );
    }
    if (outer.forwardingState.copiesRemaining > 8) {
      throw const FormatException(
        'Local outbound packet exceeds initial replication budget',
      );
    }

    return _transaction(() {
      final existing = _readPacketDirect(packetId);
      if (existing != null) {
        if (_sameLocalIdentity(
          existing,
          operationId: operationId,
          messageId: messageId,
          exactBytes: exactBytes,
        )) {
          return existing;
        }
        throw LoomDtnPacketConflict(
          'PacketId $packetId already exists with different immutable data',
        );
      }

      final operationRows = _db.select(
        'SELECT packet_id FROM dtn_packets WHERE operation_id = ? LIMIT 1',
        [operationId],
      );
      if (operationRows.isNotEmpty) {
        throw LoomDtnPacketConflict(
          'Operation $operationId is already assigned to another PacketId',
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
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, NULL,
                  NULL, NULL, NULL, NULL)
        ''',
        [
          packetId,
          LoomDtnPacketOrigin.localOutbound.name,
          operationId,
          messageId,
          exactBytes,
          outer.routingHint.scope.name,
          outer.routingHint.mailboxToken,
          outer.expiresAtBucket.toUtc().toIso8601String(),
          outer.priority.name,
          outer.initialHopLimit,
          outer.forwardingState.hopsUsed,
          outer.forwardingState.copiesRemaining,
          outer.forwardingState.copiesRemaining,
          current.toIso8601String(),
          LoomDtnPacketState.queued.name,
          current.toIso8601String(),
        ],
      );
      return _readPacketDirect(packetId)!;
    });
  }

  @override
  LoomStoredDtnPacket? read(String packetId) {
    _requireAvailableOutsideTransaction();
    _validateOpaqueId(packetId, 'packet id');
    return _readPacketDirect(packetId);
  }

  @override
  List<LoomStoredDtnPacket> listNearbyCandidates(
    DateTime now, {
    int limit = 50,
  }) {
    _requireAvailableOutsideTransaction();
    if (limit < 1 || limit > 500) throw ArgumentError.value(limit, 'limit');
    final current = now.toUtc().toIso8601String();
    return _db
        .select(
          '''SELECT * FROM dtn_packets
               WHERE state IN ('queued', 'gatewayAccepted', 'relayAccepted')
                 AND expires_at > ?
                 AND (next_attempt_at <= ?
                      OR last_error_code LIKE 'destination-%'
                      OR last_error_code LIKE 'direct-%')
               ORDER BY stored_at DESC, packet_id LIMIT ?''',
          [current, current, limit],
        )
        .map(_packetFromRow)
        .toList(growable: false);
  }

  @override
  List<LoomStoredDtnPacket> listEligible(DateTime now, {int limit = 50}) {
    _requireAvailableOutsideTransaction();
    if (limit < 1 || limit > 500) throw ArgumentError.value(limit, 'limit');
    final current = now.toUtc().toIso8601String();
    final rows = _db.select(
      '''
      SELECT p.* FROM dtn_packets p
      WHERE p.state IN (?, ?)
        AND p.current_copies_remaining > 0
        AND p.expires_at > ?
        AND p.next_attempt_at <= ?
        AND NOT EXISTS (
          SELECT 1 FROM dtn_transfers t
          WHERE t.packet_id = p.packet_id AND t.state = ?
        )
      ORDER BY
        CASE p.priority WHEN ? THEN 0 ELSE 1 END,
        p.next_attempt_at ASC,
        p.stored_at ASC,
        p.packet_id ASC
      LIMIT ?
      ''',
      [
        LoomDtnPacketState.queued.name,
        LoomDtnPacketState.gatewayAccepted.name,
        current,
        current,
        LoomDtnTransferState.prepared.name,
        LoomPriorityClassV2.urgent.name,
        limit,
      ],
    );
    return rows.map(_packetFromRow).toList(growable: false);
  }

  @override
  LoomStoredDtnPacket recordAttempt(
    String packetId, {
    required DateTime attemptedAt,
    required DateTime nextAttemptAt,
    String? errorCode,
  }) {
    _requireAvailableOutsideTransaction();
    _validateOpaqueId(packetId, 'packet id');
    _validateErrorCode(errorCode);
    final attempted = attemptedAt.toUtc();
    var next = nextAttemptAt.toUtc();
    if (next.isBefore(attempted)) {
      throw const FormatException('DTN retry time precedes the attempt time');
    }

    return _transaction(() {
      var packet = _requirePacketDirect(packetId);
      if (!packet.expiresAt.isAfter(attempted) && !packet.isTerminal) {
        _setExpiredDirect(packetId, attempted);
        _cancelPreparedForPacket(packetId, attempted, 'packet_expired');
        return _requirePacketDirect(packetId);
      }
      if (!packet.isEligibleForForwarding) {
        throw LoomDtnPacketConflict(
          'Packet $packetId is not eligible for another forwarding attempt',
        );
      }
      if (next.isAfter(packet.expiresAt)) next = packet.expiresAt;
      _db.execute(
        '''
        UPDATE dtn_packets
        SET attempt_count = attempt_count + 1,
            next_attempt_at = ?,
            last_error_code = ?
        WHERE packet_id = ?
        ''',
        [next.toIso8601String(), errorCode, packetId],
      );
      packet = _requirePacketDirect(packetId);
      return packet;
    });
  }

  @override
  LoomStoredDtnPacket markGatewayAccepted(
    String packetId,
    DateTime acceptedAt,
  ) {
    _requireAvailableOutsideTransaction();
    _validateOpaqueId(packetId, 'packet id');
    final accepted = acceptedAt.toUtc();
    return _transaction(() {
      final packet = _requirePacketDirect(packetId);
      if (packet.state == LoomDtnPacketState.gatewayAccepted ||
          packet.state == LoomDtnPacketState.relayAccepted ||
          packet.state == LoomDtnPacketState.recipientConfirmed) {
        return packet;
      }
      _rejectTerminalTransition(packet, 'gateway acceptance');
      if (!packet.expiresAt.isAfter(accepted)) {
        _setExpiredDirect(packetId, accepted);
        _cancelPreparedForPacket(packetId, accepted, 'packet_expired');
        return _requirePacketDirect(packetId);
      }
      _db.execute(
        '''
        UPDATE dtn_packets
        SET state = ?, gateway_accepted_at = COALESCE(gateway_accepted_at, ?),
            last_error_code = NULL
        WHERE packet_id = ?
        ''',
        [
          LoomDtnPacketState.gatewayAccepted.name,
          accepted.toIso8601String(),
          packetId,
        ],
      );
      return _requirePacketDirect(packetId);
    });
  }

  @override
  LoomStoredDtnPacket markRelayAccepted(String packetId, DateTime acceptedAt) {
    _requireAvailableOutsideTransaction();
    _validateOpaqueId(packetId, 'packet id');
    final accepted = acceptedAt.toUtc();
    return _transaction(() {
      final packet = _requirePacketDirect(packetId);
      if (packet.state == LoomDtnPacketState.relayAccepted ||
          packet.state == LoomDtnPacketState.recipientConfirmed) {
        return packet;
      }
      _rejectTerminalTransition(packet, 'relay acceptance');
      if (!packet.expiresAt.isAfter(accepted)) {
        _setExpiredDirect(packetId, accepted);
        _cancelPreparedForPacket(packetId, accepted, 'packet_expired');
        return _requirePacketDirect(packetId);
      }
      _cancelPreparedForPacket(packetId, accepted, 'relay_accepted');
      _db.execute(
        '''
        UPDATE dtn_packets
        SET state = ?, relay_accepted_at = COALESCE(relay_accepted_at, ?),
            last_error_code = NULL
        WHERE packet_id = ?
        ''',
        [
          LoomDtnPacketState.relayAccepted.name,
          accepted.toIso8601String(),
          packetId,
        ],
      );
      return _requirePacketDirect(packetId);
    });
  }

  @override
  LoomStoredDtnPacket markRecipientConfirmed(
    String packetId,
    DateTime confirmedAt,
  ) {
    _requireAvailableOutsideTransaction();
    _validateOpaqueId(packetId, 'packet id');
    final confirmed = confirmedAt.toUtc();
    return _transaction(() {
      final packet = _requirePacketDirect(packetId);
      if (packet.state == LoomDtnPacketState.recipientConfirmed) return packet;
      _rejectTerminalTransition(packet, 'recipient confirmation');
      _cancelPreparedForPacket(packetId, confirmed, 'recipient_confirmed');
      _db.execute(
        '''
        UPDATE dtn_packets
        SET state = ?,
            recipient_confirmed_at = COALESCE(recipient_confirmed_at, ?),
            terminal_at = COALESCE(terminal_at, ?),
            last_error_code = NULL
        WHERE packet_id = ?
        ''',
        [
          LoomDtnPacketState.recipientConfirmed.name,
          confirmed.toIso8601String(),
          confirmed.toIso8601String(),
          packetId,
        ],
      );
      return _requirePacketDirect(packetId);
    });
  }

  @override
  LoomStoredDtnPacket cancelLocal(String packetId, DateTime cancelledAt) {
    _requireAvailableOutsideTransaction();
    _validateOpaqueId(packetId, 'packet id');
    final cancelled = cancelledAt.toUtc();
    return _transaction(() {
      final packet = _requirePacketDirect(packetId);
      if (packet.state == LoomDtnPacketState.cancelledLocal ||
          packet.state == LoomDtnPacketState.recipientConfirmed ||
          packet.state == LoomDtnPacketState.expired) {
        return packet;
      }
      _cancelPreparedForPacket(packetId, cancelled, 'packet_cancelled');
      _db.execute(
        '''
        UPDATE dtn_packets
        SET state = ?, terminal_at = COALESCE(terminal_at, ?)
        WHERE packet_id = ?
        ''',
        [
          LoomDtnPacketState.cancelledLocal.name,
          cancelled.toIso8601String(),
          packetId,
        ],
      );
      return _requirePacketDirect(packetId);
    });
  }

  @override
  int expireDue(DateTime now) {
    _requireAvailableOutsideTransaction();
    final current = now.toUtc();
    return _transaction(() {
      final dueRows = _db.select(
        '''
        SELECT packet_id FROM dtn_packets
        WHERE expires_at <= ? AND state IN (?, ?, ?)
        ''',
        [
          current.toIso8601String(),
          LoomDtnPacketState.queued.name,
          LoomDtnPacketState.gatewayAccepted.name,
          LoomDtnPacketState.relayAccepted.name,
        ],
      );
      for (final row in dueRows) {
        final packetId = row['packet_id'] as String;
        _cancelPreparedForPacket(packetId, current, 'packet_expired');
        _setExpiredDirect(packetId, current);
      }
      return dueRows.length;
    });
  }

  @override
  int pruneTerminal(
    DateTime now, {
    Duration tombstoneRetention = const Duration(days: 30),
  }) {
    _requireAvailableOutsideTransaction();
    if (tombstoneRetention.isNegative) {
      throw ArgumentError.value(tombstoneRetention, 'tombstoneRetention');
    }
    final current = now.toUtc();
    final cutoff = current.subtract(tombstoneRetention).toIso8601String();
    _db.execute(
      '''
      DELETE FROM dtn_packets
      WHERE state IN (?, ?, ?)
        AND expires_at <= ?
        AND terminal_at IS NOT NULL
        AND terminal_at <= ?
      ''',
      [
        LoomDtnPacketState.recipientConfirmed.name,
        LoomDtnPacketState.expired.name,
        LoomDtnPacketState.cancelledLocal.name,
        current.toIso8601String(),
        cutoff,
      ],
    );
    return _db.updatedRows;
  }

  @override
  LoomStoredDtnTransfer prepareTransfer({
    required String transmissionId,
    required LoomDtnTransferPlan plan,
    required DateTime now,
  }) {
    _requireAvailableOutsideTransaction();
    _validateOpaqueId(transmissionId, 'transmission id', maxLength: 256);
    _validateOpaqueId(plan.packetId, 'packet id');
    _validateOpportunityId(plan.opportunityId);
    final current = now.toUtc();

    return _transaction(() {
      final existing = _readTransferDirect(transmissionId);
      if (existing != null) {
        _verifyTransferPlanIdentity(existing, plan);
        return existing;
      }

      final packet = _requirePacketDirect(plan.packetId);
      if (!packet.isEligibleForForwarding ||
          !packet.expiresAt.isAfter(current)) {
        throw LoomDtnPacketConflict(
          'Packet ${packet.packetId} is not eligible for transfer preparation',
        );
      }
      if (plan.copiesBefore != packet.copiesRemaining) {
        throw LoomDtnPacketConflict(
          'Transfer plan copy budget is stale for ${packet.packetId}',
        );
      }
      _validateTransferPlan(plan);

      final competing = _db.select(
        '''
        SELECT transmission_id FROM dtn_transfers
        WHERE packet_id = ? AND state = ? LIMIT 1
        ''',
        [packet.packetId, LoomDtnTransferState.prepared.name],
      );
      if (competing.isNotEmpty) {
        throw LoomDtnPacketConflict(
          'Packet ${packet.packetId} already has a prepared transfer',
        );
      }

      final wireBytes = _buildTransferBytes(packet, plan);
      _db.execute(
        '''
        INSERT INTO dtn_transfers (
          transmission_id, packet_id, opportunity_id, reason, wire_bytes,
          copies_before, copies_granted, copies_retained,
          requires_single_copy_handoff, state, prepared_at, completed_at,
          error_code
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL)
        ''',
        [
          transmissionId,
          plan.packetId,
          plan.opportunityId,
          plan.reason.name,
          wireBytes,
          plan.copiesBefore,
          plan.copiesGranted,
          plan.copiesRetainedAfterSuccess,
          plan.requiresSingleCopyCustodyHandoff ? 1 : 0,
          LoomDtnTransferState.prepared.name,
          current.toIso8601String(),
        ],
      );
      return _readTransferDirect(transmissionId)!;
    });
  }

  @override
  LoomStoredDtnTransfer? readTransfer(String transmissionId) {
    _requireAvailableOutsideTransaction();
    _validateOpaqueId(transmissionId, 'transmission id', maxLength: 256);
    return _readTransferDirect(transmissionId);
  }

  @override
  bool hasAcceptedTransfer(String packetId, String opportunityId) {
    _requireAvailableOutsideTransaction();
    return _db.select(
      "SELECT 1 FROM dtn_transfers WHERE packet_id = ? AND opportunity_id = ? AND state = 'accepted' LIMIT 1",
      [packetId, opportunityId],
    ).isNotEmpty;
  }

  @override
  List<LoomStoredDtnTransfer> listPreparedTransfers({int limit = 50}) {
    _requireAvailableOutsideTransaction();
    if (limit < 1 || limit > 500) throw ArgumentError.value(limit, 'limit');
    final rows = _db.select(
      '''
      SELECT * FROM dtn_transfers
      WHERE state = ?
      ORDER BY prepared_at ASC, transmission_id ASC
      LIMIT ?
      ''',
      [LoomDtnTransferState.prepared.name, limit],
    );
    return rows.map(_transferFromRow).toList(growable: false);
  }

  @override
  LoomStoredDtnTransfer markTransferAccepted(
    String transmissionId,
    DateTime acceptedAt,
  ) {
    _requireAvailableOutsideTransaction();
    _validateOpaqueId(transmissionId, 'transmission id', maxLength: 256);
    final accepted = acceptedAt.toUtc();

    return _transaction(() {
      final transfer = _requireTransferDirect(transmissionId);
      if (transfer.state == LoomDtnTransferState.accepted ||
          transfer.state == LoomDtnTransferState.custodyReleased) {
        return transfer;
      }
      if (transfer.state != LoomDtnTransferState.prepared) {
        throw LoomDtnPacketConflict(
          'Transfer $transmissionId cannot be accepted from ${transfer.state.name}',
        );
      }

      final packet = _requirePacketDirect(transfer.packetId);
      if (!packet.expiresAt.isAfter(accepted)) {
        _setExpiredDirect(packet.packetId, accepted);
        _setTransferTerminalDirect(
          transmissionId,
          LoomDtnTransferState.cancelled,
          accepted,
          'packet_expired',
        );
        return _requireTransferDirect(transmissionId);
      }
      if (packet.copiesRemaining != transfer.copiesBefore) {
        throw LoomDtnPacketConflict(
          'Packet ${packet.packetId} copy budget changed after transfer preparation',
        );
      }

      final isGateway =
          transfer.reason == LoomDtnTransferReason.verifiedGateway ||
          transfer.reason == LoomDtnTransferReason.claimedGateway;
      if (transfer.reason != LoomDtnTransferReason.directRecipient) {
        _db.execute(
          '''
          UPDATE dtn_packets
          SET current_copies_remaining = ?,
              state = CASE WHEN ? = 1 THEN ? ELSE state END,
              gateway_accepted_at = CASE
                WHEN ? = 1 THEN COALESCE(gateway_accepted_at, ?)
                ELSE gateway_accepted_at
              END,
              next_attempt_at = ?, last_error_code = NULL
          WHERE packet_id = ? AND current_copies_remaining = ?
          ''',
          [
            transfer.copiesRetainedAfterSuccess,
            isGateway ? 1 : 0,
            LoomDtnPacketState.gatewayAccepted.name,
            isGateway ? 1 : 0,
            accepted.toIso8601String(),
            accepted.toIso8601String(),
            packet.packetId,
            transfer.copiesBefore,
          ],
        );
        if (_db.updatedRows != 1) {
          throw LoomDtnPacketConflict(
            'Packet ${packet.packetId} copy-budget CAS failed',
          );
        }
      }

      _setTransferTerminalDirect(
        transmissionId,
        LoomDtnTransferState.accepted,
        accepted,
        null,
      );
      return _requireTransferDirect(transmissionId);
    });
  }

  @override
  LoomStoredDtnTransfer markTransferFailed(
    String transmissionId,
    DateTime failedAt, {
    required String errorCode,
  }) {
    _requireAvailableOutsideTransaction();
    _validateOpaqueId(transmissionId, 'transmission id', maxLength: 256);
    _validateErrorCode(errorCode);
    final failed = failedAt.toUtc();
    return _transaction(() {
      final transfer = _requireTransferDirect(transmissionId);
      if (transfer.state == LoomDtnTransferState.failed) return transfer;
      if (transfer.state != LoomDtnTransferState.prepared) {
        throw LoomDtnPacketConflict(
          'Transfer $transmissionId cannot fail from ${transfer.state.name}',
        );
      }
      _setTransferTerminalDirect(
        transmissionId,
        LoomDtnTransferState.failed,
        failed,
        errorCode,
      );
      return _requireTransferDirect(transmissionId);
    });
  }

  @override
  LoomStoredDtnTransfer cancelPreparedTransfer(
    String transmissionId,
    DateTime cancelledAt,
  ) {
    _requireAvailableOutsideTransaction();
    _validateOpaqueId(transmissionId, 'transmission id', maxLength: 256);
    final cancelled = cancelledAt.toUtc();
    return _transaction(() {
      final transfer = _requireTransferDirect(transmissionId);
      if (transfer.state == LoomDtnTransferState.cancelled) return transfer;
      if (transfer.state != LoomDtnTransferState.prepared) {
        throw LoomDtnPacketConflict(
          'Transfer $transmissionId cannot be cancelled from ${transfer.state.name}',
        );
      }
      _setTransferTerminalDirect(
        transmissionId,
        LoomDtnTransferState.cancelled,
        cancelled,
        'cancelled',
      );
      return _requireTransferDirect(transmissionId);
    });
  }

  @override
  LoomStoredDtnTransfer releaseSingleCopyHandoff(
    String transmissionId,
    DateTime releasedAt, {
    required String errorCode,
  }) {
    _requireAvailableOutsideTransaction();
    _validateOpaqueId(transmissionId, 'transmission id', maxLength: 256);
    _validateErrorCode(errorCode);
    final released = releasedAt.toUtc();

    return _transaction(() {
      final transfer = _requireTransferDirect(transmissionId);
      if (transfer.state == LoomDtnTransferState.custodyReleased) {
        return transfer;
      }
      if (transfer.state != LoomDtnTransferState.accepted ||
          !transfer.requiresSingleCopyCustodyHandoff ||
          transfer.reason != LoomDtnTransferReason.verifiedGateway ||
          transfer.copiesBefore != 1 ||
          transfer.copiesGranted != 1 ||
          transfer.copiesRetainedAfterSuccess != 0) {
        throw LoomDtnPacketConflict(
          'Transfer $transmissionId is not a releasable single-copy gateway handoff',
        );
      }

      final packet = _requirePacketDirect(transfer.packetId);
      if (packet.state != LoomDtnPacketState.gatewayAccepted ||
          packet.copiesRemaining != 0 ||
          packet.isTerminal ||
          !packet.expiresAt.isAfter(released)) {
        throw LoomDtnPacketConflict(
          'Packet ${packet.packetId} can no longer recover gateway custody',
        );
      }

      _db.execute(
        '''
        UPDATE dtn_packets
        SET current_copies_remaining = 1,
            state = ?,
            next_attempt_at = ?,
            last_error_code = ?
        WHERE packet_id = ?
          AND state = ?
          AND current_copies_remaining = 0
        ''',
        [
          LoomDtnPacketState.queued.name,
          released.toIso8601String(),
          errorCode,
          packet.packetId,
          LoomDtnPacketState.gatewayAccepted.name,
        ],
      );
      if (_db.updatedRows != 1) {
        throw LoomDtnPacketConflict(
          'Packet ${packet.packetId} gateway-custody release CAS failed',
        );
      }
      _setTransferTerminalDirect(
        transmissionId,
        LoomDtnTransferState.custodyReleased,
        released,
        errorCode,
      );
      return _requireTransferDirect(transmissionId);
    });
  }

  LoomStoredDtnPacket? _readPacketDirect(String packetId) {
    final rows = _db.select(
      'SELECT * FROM dtn_packets WHERE packet_id = ? LIMIT 1',
      [packetId],
    );
    return rows.isEmpty ? null : _packetFromRow(rows.first);
  }

  LoomStoredDtnPacket _requirePacketDirect(String packetId) {
    final packet = _readPacketDirect(packetId);
    if (packet == null) throw StateError('DTN packet $packetId does not exist');
    return packet;
  }

  LoomStoredDtnTransfer? _readTransferDirect(String transmissionId) {
    final rows = _db.select(
      'SELECT * FROM dtn_transfers WHERE transmission_id = ? LIMIT 1',
      [transmissionId],
    );
    return rows.isEmpty ? null : _transferFromRow(rows.first);
  }

  LoomStoredDtnTransfer _requireTransferDirect(String transmissionId) {
    final transfer = _readTransferDirect(transmissionId);
    if (transfer == null) {
      throw StateError('DTN transfer $transmissionId does not exist');
    }
    return transfer;
  }

  LoomStoredDtnPacket _packetFromRow(Row row) {
    final wire = Uint8List.fromList(row['wire_bytes'] as Uint8List);
    final mailboxToken = Uint8List.fromList(row['mailbox_token'] as Uint8List);
    final outer = LoomEnvelopeV2Codec.decodeOuter(wire);

    final packetId = row['packet_id'] as String;
    final routingScope = _routingScopeFromName(row['routing_scope'] as String);
    final priority = _priorityFromName(row['priority'] as String);
    final expiresAt = DateTime.parse(row['expires_at'] as String).toUtc();
    final initialHopLimit = row['initial_hop_limit'] as int;
    final hopsUsed = row['hops_used'] as int;
    final initialCopies = row['copies_remaining'] as int;
    final currentCopies = row['current_copies_remaining'] as int?;
    if (currentCopies == null ||
        currentCopies < 0 ||
        currentCopies > initialCopies) {
      throw StateError('Invalid persisted DTN runtime copy budget');
    }

    if (outer.packetId != packetId ||
        outer.routingHint.scope != routingScope ||
        !_sameBytes(outer.routingHint.mailboxToken, mailboxToken) ||
        outer.expiresAtBucket.toUtc() != expiresAt ||
        outer.priority != priority ||
        outer.initialHopLimit != initialHopLimit ||
        outer.forwardingState.hopsUsed != hopsUsed ||
        outer.forwardingState.copiesRemaining != initialCopies) {
      throw StateError(
        'Durable DTN metadata does not match stored source OuterEnvelopeV2 bytes',
      );
    }

    return LoomStoredDtnPacket(
      packetId: packetId,
      origin: _originFromName(row['origin'] as String),
      operationId: row['operation_id'] as String?,
      messageId: row['message_id'] as String?,
      wireBytes: wire,
      routingScope: routingScope,
      mailboxToken: mailboxToken,
      expiresAt: expiresAt,
      priority: priority,
      initialHopLimit: initialHopLimit,
      hopsUsed: hopsUsed,
      initialCopiesRemaining: initialCopies,
      copiesRemaining: currentCopies,
      storedAt: DateTime.parse(row['stored_at'] as String).toUtc(),
      state: _packetStateFromName(row['state'] as String),
      attemptCount: row['attempt_count'] as int,
      nextAttemptAt: DateTime.parse(row['next_attempt_at'] as String).toUtc(),
      lastErrorCode: row['last_error_code'] as String?,
      gatewayAcceptedAt: _nullableDate(row['gateway_accepted_at']),
      relayAcceptedAt: _nullableDate(row['relay_accepted_at']),
      recipientConfirmedAt: _nullableDate(row['recipient_confirmed_at']),
      terminalAt: _nullableDate(row['terminal_at']),
    );
  }

  LoomStoredDtnTransfer _transferFromRow(Row row) {
    final transfer = LoomStoredDtnTransfer(
      transmissionId: row['transmission_id'] as String,
      packetId: row['packet_id'] as String,
      opportunityId: row['opportunity_id'] as String,
      reason: _transferReasonFromName(row['reason'] as String),
      wireBytes: Uint8List.fromList(row['wire_bytes'] as Uint8List),
      copiesBefore: row['copies_before'] as int,
      copiesGranted: row['copies_granted'] as int,
      copiesRetainedAfterSuccess: row['copies_retained'] as int,
      requiresSingleCopyCustodyHandoff:
          (row['requires_single_copy_handoff'] as int) == 1,
      preparedAt: DateTime.parse(row['prepared_at'] as String).toUtc(),
      state: _transferStateFromName(row['state'] as String),
      completedAt: _nullableDate(row['completed_at']),
      errorCode: row['error_code'] as String?,
    );
    final packet = _requirePacketDirect(transfer.packetId);
    _validatePreparedTransferBytes(packet, transfer);
    return transfer;
  }

  Uint8List _buildTransferBytes(
    LoomStoredDtnPacket packet,
    LoomDtnTransferPlan plan,
  ) {
    final source = LoomEnvelopeV2Codec.decodeOuter(packet.wireBytes);
    final nextHop = source.forwardingState.hopsUsed + 1;
    if (nextHop > source.initialHopLimit) {
      throw const LoomDtnPacketConflict('DTN hop budget is exhausted');
    }
    final transferCopies = plan.reason == LoomDtnTransferReason.directRecipient
        ? 1
        : plan.copiesGranted;
    if (transferCopies < 1 || transferCopies > 16) {
      throw const LoomDtnPacketConflict('Invalid next-hop copy budget');
    }

    final transferOuter = LoomOuterEnvelopeV2(
      packetId: source.packetId,
      routingHint: LoomRoutingHintV2(
        scope: source.routingHint.scope,
        mailboxToken: source.routingHint.mailboxToken,
      ),
      expiresAtBucket: source.expiresAtBucket,
      priority: source.priority,
      initialHopLimit: source.initialHopLimit,
      forwardingState: LoomForwardingStateV2(
        hopsUsed: nextHop,
        copiesRemaining: transferCopies,
      ),
      encryptedPayload: source.encryptedPayload,
    );
    return LoomEnvelopeV2Codec.encodeOuter(transferOuter);
  }

  void _validatePreparedTransferBytes(
    LoomStoredDtnPacket packet,
    LoomStoredDtnTransfer transfer,
  ) {
    final source = LoomEnvelopeV2Codec.decodeOuter(packet.wireBytes);
    final forwarded = LoomEnvelopeV2Codec.decodeOuter(transfer.wireBytes);
    final expectedCopies =
        transfer.reason == LoomDtnTransferReason.directRecipient
        ? 1
        : transfer.copiesGranted;

    if (forwarded.packetId != source.packetId ||
        forwarded.routingHint.scope != source.routingHint.scope ||
        !_sameBytes(
          forwarded.routingHint.mailboxToken,
          source.routingHint.mailboxToken,
        ) ||
        forwarded.expiresAtBucket.toUtc() != source.expiresAtBucket.toUtc() ||
        forwarded.priority != source.priority ||
        forwarded.initialHopLimit != source.initialHopLimit ||
        forwarded.forwardingState.hopsUsed !=
            source.forwardingState.hopsUsed + 1 ||
        forwarded.forwardingState.copiesRemaining != expectedCopies ||
        !_sameBytes(forwarded.encryptedPayload, source.encryptedPayload)) {
      throw StateError(
        'Durable DTN transfer bytes violate source packet invariants',
      );
    }
  }

  T _transaction<T>(T Function() action) {
    _requireOpen();
    if (_transactionActive) {
      throw StateError('Nested or concurrent DTN transaction is not allowed');
    }
    _transactionActive = true;
    var began = false;
    try {
      _db.execute('BEGIN IMMEDIATE');
      began = true;
      final result = action();
      _db.execute('COMMIT');
      began = false;
      return result;
    } catch (_) {
      if (began) {
        try {
          _db.execute('ROLLBACK');
        } catch (_) {
          // Preserve the original failure.
        }
      }
      rethrow;
    } finally {
      _transactionActive = false;
    }
  }

  void _setExpiredDirect(String packetId, DateTime at) {
    _db.execute(
      '''
      UPDATE dtn_packets
      SET state = ?, terminal_at = COALESCE(terminal_at, ?)
      WHERE packet_id = ? AND state IN (?, ?, ?)
      ''',
      [
        LoomDtnPacketState.expired.name,
        at.toUtc().toIso8601String(),
        packetId,
        LoomDtnPacketState.queued.name,
        LoomDtnPacketState.gatewayAccepted.name,
        LoomDtnPacketState.relayAccepted.name,
      ],
    );
  }

  void _cancelPreparedForPacket(
    String packetId,
    DateTime at,
    String errorCode,
  ) {
    _db.execute(
      '''
      UPDATE dtn_transfers
      SET state = ?, completed_at = ?, error_code = ?
      WHERE packet_id = ? AND state = ?
      ''',
      [
        LoomDtnTransferState.cancelled.name,
        at.toUtc().toIso8601String(),
        errorCode,
        packetId,
        LoomDtnTransferState.prepared.name,
      ],
    );
  }

  void _setTransferTerminalDirect(
    String transmissionId,
    LoomDtnTransferState state,
    DateTime at,
    String? errorCode,
  ) {
    _db.execute(
      '''
      UPDATE dtn_transfers
      SET state = ?, completed_at = ?, error_code = ?
      WHERE transmission_id = ?
      ''',
      [state.name, at.toUtc().toIso8601String(), errorCode, transmissionId],
    );
  }

  static void _validateTransferPlan(LoomDtnTransferPlan plan) {
    if (plan.copiesBefore < 1 || plan.copiesBefore > 16) {
      throw const LoomDtnPacketConflict('Invalid transfer source copy budget');
    }
    if (plan.reason == LoomDtnTransferReason.directRecipient) {
      if (plan.copiesGranted != 0 ||
          plan.copiesRetainedAfterSuccess != plan.copiesBefore ||
          plan.requiresSingleCopyCustodyHandoff) {
        throw const LoomDtnPacketConflict('Invalid direct-recipient plan');
      }
      return;
    }

    if (plan.copiesBefore == 1) {
      final trustedSingleCopyCustodian =
          plan.reason == LoomDtnTransferReason.destinationNode ||
          plan.reason == LoomDtnTransferReason.verifiedGateway;
      if (!trustedSingleCopyCustodian ||
          plan.copiesGranted != 1 ||
          plan.copiesRetainedAfterSuccess != 0 ||
          !plan.requiresSingleCopyCustodyHandoff) {
        throw const LoomDtnPacketConflict(
          'Single-copy wait phase requires verified destination/gateway custody handoff',
        );
      }
      return;
    }

    if (plan.copiesGranted < 1 ||
        plan.copiesRetainedAfterSuccess < 1 ||
        plan.copiesGranted + plan.copiesRetainedAfterSuccess !=
            plan.copiesBefore ||
        plan.requiresSingleCopyCustodyHandoff) {
      throw const LoomDtnPacketConflict('Invalid Spray-and-Wait copy split');
    }
  }

  static void _verifyTransferPlanIdentity(
    LoomStoredDtnTransfer transfer,
    LoomDtnTransferPlan plan,
  ) {
    if (transfer.packetId != plan.packetId ||
        transfer.opportunityId != plan.opportunityId ||
        transfer.reason != plan.reason ||
        transfer.copiesBefore != plan.copiesBefore ||
        transfer.copiesGranted != plan.copiesGranted ||
        transfer.copiesRetainedAfterSuccess !=
            plan.copiesRetainedAfterSuccess ||
        transfer.requiresSingleCopyCustodyHandoff !=
            plan.requiresSingleCopyCustodyHandoff) {
      throw const LoomDtnPacketConflict(
        'TransmissionId already exists with a different transfer plan',
      );
    }
  }

  static void _rejectTerminalTransition(
    LoomStoredDtnPacket packet,
    String operation,
  ) {
    if (packet.state == LoomDtnPacketState.expired ||
        packet.state == LoomDtnPacketState.cancelledLocal) {
      throw LoomDtnPacketConflict(
        'Cannot apply $operation to terminal packet ${packet.packetId}',
      );
    }
  }

  static bool _sameLocalIdentity(
    LoomStoredDtnPacket existing, {
    required String operationId,
    required String messageId,
    required Uint8List exactBytes,
  }) {
    return existing.origin == LoomDtnPacketOrigin.localOutbound &&
        existing.operationId == operationId &&
        existing.messageId == messageId &&
        _sameBytes(existing.wireBytes, exactBytes);
  }

  static bool _sameBytes(List<int> left, List<int> right) {
    if (left.length != right.length) return false;
    for (var i = 0; i < left.length; i++) {
      if (left[i] != right[i]) return false;
    }
    return true;
  }

  static void _validateOpaqueId(
    String value,
    String label, {
    int minLength = 8,
    int maxLength = 128,
  }) {
    if (value.trim() != value ||
        value.length < minLength ||
        value.length > maxLength) {
      throw FormatException('Invalid $label');
    }
  }

  static void _validateOpportunityId(String value) {
    if (value.trim() != value || value.length < 4 || value.length > 256) {
      throw const FormatException('Invalid DTN opportunity id');
    }
  }

  static void _validateErrorCode(String? value) {
    if (value == null) return;
    if (!RegExp(r'^[a-z0-9][a-z0-9_.-]{0,63}$').hasMatch(value)) {
      throw const FormatException('Invalid structured DTN error code');
    }
  }

  static LoomDtnPacketOrigin _originFromName(String value) {
    for (final item in LoomDtnPacketOrigin.values) {
      if (item.name == value) return item;
    }
    throw StateError('Unknown stored DTN origin $value');
  }

  static LoomDtnPacketState _packetStateFromName(String value) {
    for (final item in LoomDtnPacketState.values) {
      if (item.name == value) return item;
    }
    throw StateError('Unknown stored DTN state $value');
  }

  static LoomDtnTransferState _transferStateFromName(String value) {
    for (final item in LoomDtnTransferState.values) {
      if (item.name == value) return item;
    }
    throw StateError('Unknown stored transfer state $value');
  }

  static LoomDtnTransferReason _transferReasonFromName(String value) {
    for (final item in LoomDtnTransferReason.values) {
      if (item.name == value) return item;
    }
    throw StateError('Unknown stored transfer reason $value');
  }

  static LoomRoutingScopeV2 _routingScopeFromName(String value) {
    for (final item in LoomRoutingScopeV2.values) {
      if (item.name == value) return item;
    }
    throw StateError('Unknown stored routing scope $value');
  }

  static LoomPriorityClassV2 _priorityFromName(String value) {
    for (final item in LoomPriorityClassV2.values) {
      if (item.name == value) return item;
    }
    throw StateError('Unknown stored priority $value');
  }

  static DateTime? _nullableDate(Object? value) =>
      value == null ? null : DateTime.parse(value as String).toUtc();

  void _requireOpen() {
    if (_closed) throw StateError('LoomSqlitePacketStore is closed');
  }

  void _requireAvailableOutsideTransaction() {
    _requireOpen();
    if (_transactionActive) {
      throw StateError('DTN store cannot be re-entered during a transaction');
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _db.dispose();
  }
}

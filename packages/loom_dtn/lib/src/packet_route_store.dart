import 'dart:io';

import 'package:loom_protocol/loom_protocol.dart';
import 'package:sqlite3/sqlite3.dart';

import 'packet_store.dart';

final class LoomDtnDestinationRoute {
  const LoomDtnDestinationRoute({
    required this.packetId,
    required this.destinationNodeDomain,
    required this.recordedAt,
  });

  final String packetId;
  final String destinationNodeDomain;
  final DateTime recordedAt;
}

abstract interface class LoomPacketRouteStore {
  LoomDtnDestinationRoute rememberDestinationRoute({
    required String packetId,
    required String destinationNodeDomain,
    required DateTime now,
  });

  LoomDtnDestinationRoute? readDestinationRoute(String packetId);
}

/// Durable routing sidecar for an opaque DTN packet.
///
/// The Architecture-v2 outer envelope intentionally omits account and Node
/// identity. A forwarding device therefore needs a separate bounded hint to
/// know which Node to verify before attempting direct ingress. This table is
/// stored beside the packet DB and is never authority: the gateway must still
/// independently verify the advertised Node before network IO.
final class LoomSqlitePacketRouteStore implements LoomPacketRouteStore {
  LoomSqlitePacketRouteStore._(this._db) {
    _db.execute('PRAGMA foreign_keys = ON');
    _db.execute('PRAGMA journal_mode = WAL');
    _db.execute('PRAGMA synchronous = FULL');
    _db.execute('PRAGMA busy_timeout = 5000');
    _migrate();
  }

  final Database _db;
  bool _closed = false;

  static LoomSqlitePacketRouteStore openExistingFile(String path) {
    final file = File(path);
    if (!file.existsSync()) {
      throw StateError('Loom DTN packet database does not exist');
    }
    return LoomSqlitePacketRouteStore._(sqlite3.open(path));
  }

  void _migrate() {
    final packets = _db.select(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='dtn_packets'",
    );
    if (packets.isEmpty) {
      throw StateError('The selected SQLite file is not a Loom DTN database');
    }
    _db.execute('''
      CREATE TABLE IF NOT EXISTS dtn_packet_routes (
        packet_id TEXT PRIMARY KEY REFERENCES dtn_packets(packet_id)
          ON DELETE CASCADE,
        destination_node_domain TEXT NOT NULL,
        recorded_at TEXT NOT NULL
      )
    ''');
    _db.execute('''
      CREATE INDEX IF NOT EXISTS idx_dtn_packet_routes_domain
      ON dtn_packet_routes(destination_node_domain, recorded_at)
    ''');
  }

  @override
  LoomDtnDestinationRoute rememberDestinationRoute({
    required String packetId,
    required String destinationNodeDomain,
    required DateTime now,
  }) {
    _requireOpen();
    _validateOpaqueId(packetId, 'packet id');
    final domain = LoomAddress.normalizeHomeNode(destinationNodeDomain);
    final current = now.toUtc();
    if (current.year < 2020 || current.year >= 2200) {
      throw const FormatException('Invalid DTN route timestamp');
    }
    final packet = _db.select(
      'SELECT packet_id FROM dtn_packets WHERE packet_id = ? LIMIT 1',
      <Object?>[packetId],
    );
    if (packet.isEmpty) {
      throw StateError('Cannot attach a route to missing DTN packet $packetId');
    }
    final existing = _db.select(
      '''SELECT destination_node_domain, recorded_at
         FROM dtn_packet_routes WHERE packet_id = ? LIMIT 1''',
      <Object?>[packetId],
    );
    if (existing.isNotEmpty) {
      final storedDomain = existing.first['destination_node_domain'] as String;
      if (storedDomain != domain) {
        throw const LoomDtnPacketConflict(
          'Destination Node route conflicts with existing packet route',
        );
      }
      return LoomDtnDestinationRoute(
        packetId: packetId,
        destinationNodeDomain: storedDomain,
        recordedAt:
            DateTime.parse(existing.first['recorded_at'] as String).toUtc(),
      );
    }
    _db.execute(
      '''INSERT INTO dtn_packet_routes (
           packet_id, destination_node_domain, recorded_at
         ) VALUES (?, ?, ?)''',
      <Object?>[packetId, domain, current.toIso8601String()],
    );
    return LoomDtnDestinationRoute(
      packetId: packetId,
      destinationNodeDomain: domain,
      recordedAt: current,
    );
  }

  @override
  LoomDtnDestinationRoute? readDestinationRoute(String packetId) {
    _requireOpen();
    _validateOpaqueId(packetId, 'packet id');
    final rows = _db.select(
      '''SELECT destination_node_domain, recorded_at
         FROM dtn_packet_routes WHERE packet_id = ? LIMIT 1''',
      <Object?>[packetId],
    );
    if (rows.isEmpty) return null;
    return LoomDtnDestinationRoute(
      packetId: packetId,
      destinationNodeDomain: rows.first['destination_node_domain'] as String,
      recordedAt: DateTime.parse(rows.first['recorded_at'] as String).toUtc(),
    );
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _db.dispose();
  }

  void _requireOpen() {
    if (_closed) throw StateError('DTN packet route store is closed');
  }
}

void _validateOpaqueId(
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

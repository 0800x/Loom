import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

class LoomStoredRelayBundle {
  const LoomStoredRelayBundle({
    required this.bundleId,
    required this.recipientTag,
    required this.createdAt,
    required this.expiresAt,
    required this.hopCount,
    required this.maxHops,
    required this.payloadJson,
    required this.sizeBytes,
  });

  final String bundleId;
  final String recipientTag;
  final DateTime createdAt;
  final DateTime expiresAt;
  final int hopCount;
  final int maxHops;
  final Map<String, Object?> payloadJson;
  final int sizeBytes;
}

/// Separate durable spool for opaque relay bundles.
///
/// This store never contains message plaintext or recipient private keys.
class LoomRelayStore {
  LoomRelayStore._(this._db) {
    _db.execute('PRAGMA journal_mode = WAL');
    _db.execute('PRAGMA synchronous = NORMAL');
    _db.execute('PRAGMA busy_timeout = 5000');
    _migrate();
  }

  final Database _db;
  bool _closed = false;

  static LoomRelayStore openFile(String path) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    return LoomRelayStore._(sqlite3.open(path));
  }

  static LoomRelayStore openInMemory() =>
      LoomRelayStore._(sqlite3.openInMemory());

  void _migrate() {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS relay_bundles (
        bundle_id TEXT PRIMARY KEY,
        recipient_tag TEXT NOT NULL,
        created_at TEXT NOT NULL,
        expires_at TEXT NOT NULL,
        hop_count INTEGER NOT NULL,
        max_hops INTEGER NOT NULL,
        payload_json TEXT NOT NULL,
        size_bytes INTEGER NOT NULL,
        stored_at TEXT NOT NULL
      )
    ''');
    _db.execute(
      'CREATE INDEX IF NOT EXISTS idx_relay_expiry ON relay_bundles(expires_at)',
    );
    _db.execute(
      'CREATE INDEX IF NOT EXISTS idx_relay_tag ON relay_bundles(recipient_tag, expires_at)',
    );
  }

  bool contains(String bundleId) {
    _requireOpen();
    return _db.select(
      'SELECT 1 FROM relay_bundles WHERE bundle_id = ? LIMIT 1',
      [bundleId],
    ).isNotEmpty;
  }

  bool putIfAbsent(LoomStoredRelayBundle bundle, {required DateTime now}) {
    _requireOpen();
    if (!bundle.expiresAt.isAfter(now)) return false;
    _db.execute(
      '''INSERT OR IGNORE INTO relay_bundles (
           bundle_id, recipient_tag, created_at, expires_at, hop_count, max_hops,
           payload_json, size_bytes, stored_at
         ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)''',
      [
        bundle.bundleId,
        bundle.recipientTag,
        bundle.createdAt.toUtc().toIso8601String(),
        bundle.expiresAt.toUtc().toIso8601String(),
        bundle.hopCount,
        bundle.maxHops,
        jsonEncode(bundle.payloadJson),
        bundle.sizeBytes,
        now.toUtc().toIso8601String(),
      ],
    );
    return _db.updatedRows == 1;
  }

  List<LoomStoredRelayBundle> findByRecipientTags(
    Set<String> tags, {
    required DateTime now,
    int limit = 64,
  }) {
    _requireOpen();
    if (tags.isEmpty) return const <LoomStoredRelayBundle>[];
    if (tags.length > 32)
      throw ArgumentError.value(tags.length, 'tags', 'Maximum 32 tags');
    if (limit < 1 || limit > 256) throw ArgumentError.value(limit, 'limit');
    final placeholders = List.filled(tags.length, '?').join(',');
    final rows = _db.select(
      '''SELECT * FROM relay_bundles
         WHERE recipient_tag IN ($placeholders) AND expires_at > ?
         ORDER BY created_at ASC LIMIT ?''',
      [...tags, now.toUtc().toIso8601String(), limit],
    );
    return rows.map(_fromRow).toList(growable: false);
  }

  List<LoomStoredRelayBundle> nextForForwarding({
    required DateTime now,
    int limit = 32,
  }) {
    _requireOpen();
    if (limit < 1 || limit > 128) throw ArgumentError.value(limit, 'limit');
    final rows = _db.select(
      '''SELECT * FROM relay_bundles
         WHERE expires_at > ? AND hop_count < max_hops
         ORDER BY created_at ASC LIMIT ?''',
      [now.toUtc().toIso8601String(), limit],
    );
    return rows.map(_fromRow).toList(growable: false);
  }

  int totalBytes({required DateTime now}) {
    _requireOpen();
    final row = _db.select(
      'SELECT COALESCE(SUM(size_bytes), 0) AS total FROM relay_bundles WHERE expires_at > ?',
      [now.toUtc().toIso8601String()],
    ).first;
    return row['total'] as int;
  }

  int pruneExpired(DateTime now) {
    _requireOpen();
    _db.execute('DELETE FROM relay_bundles WHERE expires_at <= ?', [
      now.toUtc().toIso8601String(),
    ]);
    return _db.updatedRows;
  }

  void remove(String bundleId) {
    _requireOpen();
    _db.execute('DELETE FROM relay_bundles WHERE bundle_id = ?', [bundleId]);
  }

  LoomStoredRelayBundle _fromRow(Row row) => LoomStoredRelayBundle(
    bundleId: row['bundle_id'] as String,
    recipientTag: row['recipient_tag'] as String,
    createdAt: DateTime.parse(row['created_at'] as String).toUtc(),
    expiresAt: DateTime.parse(row['expires_at'] as String).toUtc(),
    hopCount: row['hop_count'] as int,
    maxHops: row['max_hops'] as int,
    payloadJson: (jsonDecode(row['payload_json'] as String) as Map)
        .cast<String, Object?>(),
    sizeBytes: row['size_bytes'] as int,
  );

  void close() {
    if (_closed) return;
    _closed = true;
    _db.dispose();
  }

  void _requireOpen() {
    if (_closed) throw StateError('LoomRelayStore is closed');
  }
}

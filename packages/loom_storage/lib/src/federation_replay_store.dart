import 'dart:io';

import 'package:loom_federation/loom_federation.dart';
import 'package:sqlite3/sqlite3.dart';

/// Durable replay cache for server-side federation ingress.
///
/// This database contains only event identifiers and expiry metadata; it must
/// never contain message plaintext or cryptographic private keys.
class LoomSqliteFederationReplayStore implements LoomFederationReplayStore {
  LoomSqliteFederationReplayStore._(this._db) {
    _db.execute('PRAGMA journal_mode = WAL');
    _db.execute('PRAGMA synchronous = NORMAL');
    _db.execute('PRAGMA busy_timeout = 5000');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS federation_seen_events (
        event_id TEXT PRIMARY KEY,
        expires_at TEXT NOT NULL,
        seen_at TEXT NOT NULL
      )
    ''');
    _db.execute(
      'CREATE INDEX IF NOT EXISTS idx_federation_seen_expiry ON federation_seen_events(expires_at)',
    );
  }

  final Database _db;
  bool _closed = false;

  static LoomSqliteFederationReplayStore openFile(String path) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    return LoomSqliteFederationReplayStore._(sqlite3.open(path));
  }

  static LoomSqliteFederationReplayStore openInMemory() =>
      LoomSqliteFederationReplayStore._(sqlite3.openInMemory());

  @override
  Future<bool> remember(String eventId, DateTime expiresAt) async {
    _requireOpen();
    _db.execute('BEGIN IMMEDIATE');
    try {
      final found = _db.select(
        'SELECT 1 FROM federation_seen_events WHERE event_id = ? LIMIT 1',
        [eventId],
      );
      if (found.isNotEmpty) {
        _db.execute('COMMIT');
        return false;
      }
      _db.execute(
        'INSERT INTO federation_seen_events(event_id, expires_at, seen_at) VALUES (?, ?, ?)',
        [
          eventId,
          expiresAt.toUtc().toIso8601String(),
          DateTime.now().toUtc().toIso8601String(),
        ],
      );
      _db.execute('COMMIT');
      return true;
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  void prune(DateTime now) {
    _requireOpen();
    _db.execute('DELETE FROM federation_seen_events WHERE expires_at < ?', [
      now.toUtc().toIso8601String(),
    ]);
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _db.dispose();
  }

  void _requireOpen() {
    if (_closed) throw StateError('Federation replay store is closed');
  }
}

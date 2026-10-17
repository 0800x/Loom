import 'dart:io';

import 'package:loom_federation/loom_federation.dart';
import 'package:sqlite3/sqlite3.dart';

class LoomSqliteFederationRequestReplayStore
    implements LoomFederationRequestReplayStore {
  LoomSqliteFederationRequestReplayStore._(this._db) {
    _db.execute('PRAGMA journal_mode = WAL');
    _db.execute('PRAGMA synchronous = NORMAL');
    _db.execute('PRAGMA busy_timeout = 5000');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS federation_request_nonces (
        node_id TEXT NOT NULL,
        nonce TEXT NOT NULL,
        expires_at TEXT NOT NULL,
        seen_at TEXT NOT NULL,
        PRIMARY KEY(node_id, nonce)
      )
    ''');
    _db.execute(
      'CREATE INDEX IF NOT EXISTS idx_federation_request_expiry ON federation_request_nonces(expires_at)',
    );
  }

  final Database _db;
  bool _closed = false;

  static LoomSqliteFederationRequestReplayStore openFile(String path) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    return LoomSqliteFederationRequestReplayStore._(sqlite3.open(path));
  }

  static LoomSqliteFederationRequestReplayStore openInMemory() =>
      LoomSqliteFederationRequestReplayStore._(sqlite3.openInMemory());

  @override
  Future<bool> rememberRequestNonce({
    required String nodeId,
    required String nonce,
    required DateTime expiresAt,
  }) async {
    _requireOpen();
    _db.execute('BEGIN IMMEDIATE');
    try {
      final found = _db.select(
        'SELECT 1 FROM federation_request_nonces WHERE node_id = ? AND nonce = ? LIMIT 1',
        [nodeId, nonce],
      );
      if (found.isNotEmpty) {
        _db.execute('COMMIT');
        return false;
      }
      _db.execute(
        '''INSERT INTO federation_request_nonces(node_id, nonce, expires_at, seen_at)
           VALUES (?, ?, ?, ?)''',
        [
          nodeId,
          nonce,
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
    _db.execute('DELETE FROM federation_request_nonces WHERE expires_at < ?', [
      now.toUtc().toIso8601String(),
    ]);
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _db.dispose();
  }

  void _requireOpen() {
    if (_closed) throw StateError('Federation request replay store is closed');
  }
}

import 'dart:convert';
import 'dart:io';

import 'package:loom_models/loom_models.dart';
import 'package:sqlite3/sqlite3.dart';

class LoomGroupOutbox {
  const LoomGroupOutbox({
    required this.id,
    required this.groupId,
    required this.path,
    required this.body,
    required this.checkpoint,
    required this.localPayload,
  });
  final String id, groupId, path;
  final Map<String, Object?> body;
  final LoomMlsSealedState? checkpoint;

  /// Encrypted local history; the store must never receive plaintext.
  final String? localPayload;
}

/// A separate device-scoped database; never include it in recovery exports.
/// Native state and immutable outbox bytes share a FULL synchronous transaction.
class LoomGroupStore {
  LoomGroupStore._(this._db) {
    _db.execute('PRAGMA journal_mode=WAL');
    _db.execute('PRAGMA synchronous=FULL');
    _db.execute('PRAGMA busy_timeout=5000');
    _db.execute(
      '''CREATE TABLE IF NOT EXISTS mls_device(singleton INTEGER PRIMARY KEY CHECK(singleton=1), version INTEGER NOT NULL, state_json TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS mls_outbox(id TEXT PRIMARY KEY,group_id TEXT NOT NULL,path TEXT NOT NULL,body_json TEXT NOT NULL,checkpoint_json TEXT,local_payload TEXT);
      CREATE TABLE IF NOT EXISTS mls_catalogue(id TEXT PRIMARY KEY,state_json TEXT NOT NULL,cursor INTEGER NOT NULL DEFAULT 0);
      CREATE TABLE IF NOT EXISTS mls_own(group_id TEXT NOT NULL,sequence INTEGER NOT NULL,operation_id TEXT NOT NULL,state_json TEXT,PRIMARY KEY(group_id,sequence));
      CREATE TABLE IF NOT EXISTS mls_failed(id TEXT PRIMARY KEY,group_id TEXT NOT NULL,payload TEXT);
      CREATE TABLE IF NOT EXISTS mls_history(group_id TEXT NOT NULL,sequence INTEGER NOT NULL,payload TEXT NOT NULL,PRIMARY KEY(group_id,sequence));''',
    );
    _db.execute(
      'CREATE TABLE IF NOT EXISTS mls_read(group_id TEXT PRIMARY KEY,sequence INTEGER NOT NULL)',
    );
    _db.execute(
      'CREATE TABLE IF NOT EXISTS mls_quarantine(group_id TEXT NOT NULL,sequence INTEGER NOT NULL,reason TEXT NOT NULL,recorded_at TEXT NOT NULL,PRIMARY KEY(group_id,sequence))',
    );
  }
  final Database _db;
  static LoomGroupStore openFile(String path) {
    File(path).parent.createSync(recursive: true);
    return LoomGroupStore._(sqlite3.open(path));
  }

  static LoomGroupStore openInMemory() =>
      LoomGroupStore._(sqlite3.openInMemory());
  void close() => _db.dispose();
  int get version =>
      _db
              .select('SELECT version FROM mls_device WHERE singleton=1')
              .firstOrNull?['version']
          as int? ??
      0;
  LoomMlsSealedState? get state {
    final row = _db
        .select('SELECT state_json FROM mls_device WHERE singleton=1')
        .firstOrNull;
    return row == null
        ? null
        : LoomMlsSealedState.fromJson(
            Map<String, Object?>.from(
              jsonDecode(row['state_json'] as String) as Map,
            ),
          );
  }

  List<LoomGroupOutbox> get outbox => _db
      .select('SELECT * FROM mls_outbox ORDER BY rowid')
      .map(
        (row) => LoomGroupOutbox(
          id: row['id'] as String,
          groupId: row['group_id'] as String,
          path: row['path'] as String,
          body: Map<String, Object?>.from(
            jsonDecode(row['body_json'] as String) as Map,
          ),
          checkpoint: row['checkpoint_json'] == null
              ? null
              : LoomMlsSealedState.fromJson(
                  Map<String, Object?>.from(
                    jsonDecode(row['checkpoint_json'] as String) as Map,
                  ),
                ),
          localPayload: row['local_payload'] as String?,
        ),
      )
      .toList();
  List<LoomGroupState> get groups => _db
      .select('SELECT state_json FROM mls_catalogue')
      .map(
        (r) => LoomGroupState.fromJson(
          Map<String, Object?>.from(
            jsonDecode(r['state_json'] as String) as Map,
          ),
        ),
      )
      .toList();
  int cursor(String id) =>
      _db.select('SELECT cursor FROM mls_catalogue WHERE id=?', [
            id,
          ]).firstOrNull?['cursor']
          as int? ??
      0;
  int readSequence(String id) =>
      _db.select('SELECT sequence FROM mls_read WHERE group_id=?', [
            id,
          ]).firstOrNull?['sequence']
          as int? ??
      0;
  void markRead(String id, int sequence) => _db.execute(
    'INSERT INTO mls_read VALUES(?,?) ON CONFLICT(group_id) DO UPDATE SET sequence=MAX(mls_read.sequence,excluded.sequence)',
    [id, sequence],
  );
  List<({int sequence, String payload})> history(String id) => _db
      .select(
        'SELECT sequence,payload FROM mls_history WHERE group_id=? ORDER BY sequence',
        [id],
      )
      .map(
        (r) =>
            (sequence: r['sequence'] as int, payload: r['payload'] as String),
      )
      .toList();
  T _transaction<T>(T Function() action) {
    _db.execute('BEGIN IMMEDIATE');
    try {
      final result = action();
      _db.execute('COMMIT');
      return result;
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  void _writeState(int expectedVersion, LoomMlsSealedState next) {
    if (version != expectedVersion) throw StateError('MLS state CAS conflict');
    _db.execute(
      'INSERT INTO mls_device VALUES(1,?,?) ON CONFLICT(singleton) DO UPDATE SET version=excluded.version,state_json=excluded.state_json',
      [expectedVersion + 1, jsonEncode(next.toJson())],
    );
  }

  void _catalogue(LoomGroupState state, int cursor) => _db.execute(
    'INSERT INTO mls_catalogue VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET state_json=excluded.state_json,cursor=excluded.cursor',
    [state.id, jsonEncode(state.toJson()), cursor],
  );
  void saveState(int expectedVersion, LoomMlsSealedState next) =>
      _transaction(() => _writeState(expectedVersion, next));
  void stage(
    int expectedVersion,
    LoomMlsSealedState next,
    LoomGroupOutbox outbox,
  ) => _transaction(() {
    // Commit deliveries rewrite the sealed state when their receipt is
    // accepted, so they must stay exclusive. Queued messages, typing frames
    // and key-package publications acknowledge without touching the state and
    // may accumulate while the device is offline.
    if (this.outbox.any((pending) => pending.checkpoint != null))
      throw StateError('Resolve pending MLS commit first');
    _writeState(expectedVersion, next);
    _db.execute('INSERT INTO mls_outbox VALUES(?,?,?,?,?,?)', [
      outbox.id,
      outbox.groupId,
      outbox.path,
      jsonEncode(outbox.body),
      outbox.checkpoint == null
          ? null
          : jsonEncode(outbox.checkpoint!.toJson()),
      outbox.localPayload,
    ]);
  });
  void acknowledge(
    String id, {
    LoomMlsSealedState? next,
    int? expectedVersion,
    LoomGroupState? group,
    int? sequence,
  }) => _transaction(() {
    final pending = outbox.where((o) => o.id == id).firstOrNull;
    if (pending == null) throw StateError('Unknown MLS outbox item');
    if (next != null) _writeState(expectedVersion!, next);
    if (group != null && !pending.path.endsWith('/commits'))
      _catalogue(group, group.sequence);
    final ownSequence = group?.sequence ?? sequence;
    if (ownSequence != null)
      _db.execute('INSERT INTO mls_own VALUES(?,?,?,?)', [
        pending.groupId,
        ownSequence,
        id,
        group == null ? null : jsonEncode(group.toJson()),
      ]);
    if (sequence != null && pending.localPayload != null)
      _db.execute(
        'INSERT INTO mls_history VALUES(?,?,?) ON CONFLICT DO NOTHING',
        [pending.groupId, sequence, pending.localPayload],
      );
    _db.execute('DELETE FROM mls_outbox WHERE id=?', [id]);
  });

  /// Only after an authoritative 409 rejects the immutable request. Network
  /// timeouts and unknown outcomes must retain and retry the exact outbox.
  void rejectCommit(String id, int expectedVersion) => _transaction(() {
    final pending = outbox.where((o) => o.id == id).firstOrNull;
    if (pending == null) throw StateError('Unknown MLS outbox item');
    if (pending.checkpoint == null) throw StateError('No commit checkpoint');
    _writeState(expectedVersion, pending.checkpoint!);
    _db.execute('DELETE FROM mls_outbox WHERE id=?', [id]);
  });
  void rejectMessage(String id) => _transaction(() {
    final pending = outbox.where((o) => o.id == id).firstOrNull;
    if (pending == null) throw StateError('Unknown MLS outbox item');
    if (pending.checkpoint != null)
      throw StateError('Not an application message');
    _db.execute('INSERT INTO mls_failed VALUES(?,?,?)', [
      id,
      pending.groupId,
      pending.localPayload,
    ]);
    _db.execute('DELETE FROM mls_outbox WHERE id=?', [id]);
  });
  List<({String id, String? payload})> failed(String groupId) => _db
      .select('SELECT id,payload FROM mls_failed WHERE group_id=?', [groupId])
      .map((r) => (id: r['id'] as String, payload: r['payload'] as String?))
      .toList();
  bool isOwnOperation(String groupId, int sequence, String? operationId) {
    final row = _db.select(
      'SELECT operation_id FROM mls_own WHERE group_id=? AND sequence=?',
      [groupId, sequence],
    ).firstOrNull;
    if (row == null) return false;
    if (operationId != null && row['operation_id'] != operationId)
      throw StateError('Own echo operation mismatch');
    return true;
  }

  LoomGroupState? ownCommitState(String groupId, int sequence) {
    final row = _db.select(
      'SELECT state_json FROM mls_own WHERE group_id=? AND sequence=?',
      [groupId, sequence],
    ).firstOrNull;
    return row?['state_json'] == null
        ? null
        : LoomGroupState.fromJson(
            Map<String, Object?>.from(
              jsonDecode(row!['state_json'] as String) as Map,
            ),
          );
  }

  void apply(
    int expectedVersion,
    LoomMlsSealedState next,
    LoomGroupState group,
    int sequence, {
    String? encryptedPayload,
  }) => _transaction(() {
    if (sequence <= cursor(group.id))
      throw StateError('MLS event already applied');
    // Receiving inbox events composes with queued messages; only an
    // undelivered commit rewrites the state on acknowledgement and therefore
    // conflicts with this write.
    if (outbox.any((pending) => pending.checkpoint != null))
      throw StateError('Resolve pending MLS commit first');
    _writeState(expectedVersion, next);
    _catalogue(group, sequence);
    if (encryptedPayload != null)
      _db.execute('INSERT INTO mls_history VALUES(?,?,?)', [
        group.id,
        sequence,
        encryptedPayload,
      ]);
  });

  /// Records a rejected inbox event and advances the sync cursor past it, so
  /// one malformed or undecryptable member message cannot permanently break
  /// the whole group. Returns false when the group is unknown locally and the
  /// event cannot be skipped meaningfully.
  bool quarantine(String groupId, int sequence, String reason) =>
      _transaction(() {
        if (sequence <= cursor(groupId)) return true;
        if (_db
            .select('SELECT 1 FROM mls_catalogue WHERE id=?', [groupId])
            .isEmpty)
          return false;
        _db.execute(
          'INSERT INTO mls_quarantine VALUES(?,?,?,?) ON CONFLICT(group_id,sequence) DO UPDATE SET reason=excluded.reason,recorded_at=excluded.recorded_at',
          [groupId, sequence, reason, DateTime.now().toUtc().toIso8601String()],
        );
        _db.execute(
          'UPDATE mls_catalogue SET cursor=? WHERE id=?',
          [sequence, groupId],
        );
        return true;
      });

  List<({int sequence, String reason, String recordedAt})> quarantined(
    String groupId,
  ) => _db
      .select(
        'SELECT sequence,reason,recorded_at FROM mls_quarantine WHERE group_id=? ORDER BY sequence',
        [groupId],
      )
      .map(
        (r) => (
          sequence: r['sequence'] as int,
          reason: r['reason'] as String,
          recordedAt: r['recorded_at'] as String,
        ),
      )
      .toList();
  int quarantineCount(String groupId) =>
      _db.select(
        'SELECT COUNT(*) value FROM mls_quarantine WHERE group_id=?',
        [groupId],
      ).firstOrNull?['value'] as int? ?? 0;

  /// Self echoes were already advanced by send/commit; only their cursor moves.
  void acknowledgeEcho(LoomGroupState group, int sequence) => _transaction(() {
    if (sequence <= cursor(group.id)) return;
    _catalogue(group, sequence);
  });
}

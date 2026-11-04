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
  void _transaction(void Function() action) {
    _db.execute('BEGIN IMMEDIATE');
    try {
      action();
      _db.execute('COMMIT');
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
    if (this.outbox.isNotEmpty)
      throw StateError('Resolve pending MLS delivery first');
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
    final pending = outbox.singleWhere((o) => o.id == id);
    if (pending.checkpoint == null) throw StateError('No commit checkpoint');
    _writeState(expectedVersion, pending.checkpoint!);
    _db.execute('DELETE FROM mls_outbox WHERE id=?', [id]);
  });
  void rejectMessage(String id) => _transaction(() {
    final pending = outbox.singleWhere((o) => o.id == id);
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
    if (outbox.isNotEmpty)
      throw StateError('Resolve pending MLS delivery first');
    _writeState(expectedVersion, next);
    _catalogue(group, sequence);
    if (encryptedPayload != null)
      _db.execute('INSERT INTO mls_history VALUES(?,?,?)', [
        group.id,
        sequence,
        encryptedPayload,
      ]);
  });

  /// Self echoes were already advanced by send/commit; only their cursor moves.
  void acknowledgeEcho(LoomGroupState group, int sequence) => _transaction(() {
    if (sequence <= cursor(group.id)) return;
    _catalogue(group, sequence);
  });
}

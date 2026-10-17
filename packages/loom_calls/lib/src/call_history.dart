import 'dart:io';

import 'package:loom_models/loom_models.dart';
import 'package:sqlite3/sqlite3.dart';

enum LoomCallHistoryOutcome {
  answered,
  missed,
  declined,
  busy,
  failed,
  canceled,
}

class LoomCallHistoryEntry {
  const LoomCallHistoryEntry({
    required this.callId,
    required this.conversationId,
    required this.peerIdentityId,
    required this.peerAddress,
    required this.peerDisplayName,
    required this.kind,
    required this.direction,
    required this.outcome,
    required this.startedAt,
    this.answeredAt,
    this.endedAt,
    this.endReason,
  });

  final String callId;
  final String conversationId;
  final String peerIdentityId;
  final String peerAddress;
  final String peerDisplayName;
  final LoomCallKind kind;
  final LoomCallDirection direction;
  final LoomCallHistoryOutcome outcome;
  final DateTime startedAt;
  final DateTime? answeredAt;
  final DateTime? endedAt;
  final LoomCallEndReason? endReason;

  Duration get duration {
    if (answeredAt == null || endedAt == null) return Duration.zero;
    final value = endedAt!.difference(answeredAt!);
    return value.isNegative ? Duration.zero : value;
  }

  bool get missed => outcome == LoomCallHistoryOutcome.missed;
}

class LoomCallHistoryStore {
  LoomCallHistoryStore._(this._db);

  final Database _db;
  bool _closed = false;

  static LoomCallHistoryStore openFile(String path) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    final store = LoomCallHistoryStore._(sqlite3.open(path));
    store._configure();
    store._migrate();
    return store;
  }

  static LoomCallHistoryStore openInMemory() {
    final store = LoomCallHistoryStore._(sqlite3.openInMemory());
    store._configure();
    store._migrate();
    return store;
  }

  void _configure() {
    _db.execute('PRAGMA journal_mode = WAL');
    _db.execute('PRAGMA synchronous = NORMAL');
    _db.execute('PRAGMA busy_timeout = 5000');
  }

  void _migrate() {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS call_history_v1 (
        call_id TEXT PRIMARY KEY,
        conversation_id TEXT NOT NULL,
        peer_identity_id TEXT NOT NULL,
        peer_address TEXT NOT NULL,
        peer_display_name TEXT NOT NULL,
        kind TEXT NOT NULL,
        direction TEXT NOT NULL,
        outcome TEXT NOT NULL,
        started_at TEXT NOT NULL,
        answered_at TEXT,
        ended_at TEXT,
        end_reason TEXT
      )
    ''');
    _db.execute(
      'CREATE INDEX IF NOT EXISTS idx_call_history_started ON call_history_v1(started_at DESC)',
    );
    _db.execute(
      'CREATE INDEX IF NOT EXISTS idx_call_history_outcome ON call_history_v1(outcome, started_at DESC)',
    );
  }

  void upsert(LoomCallHistoryEntry entry) {
    _requireOpen();
    _db.execute(
      '''
      INSERT INTO call_history_v1 (
        call_id, conversation_id, peer_identity_id, peer_address,
        peer_display_name, kind, direction, outcome, started_at,
        answered_at, ended_at, end_reason
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(call_id) DO UPDATE SET
        conversation_id=excluded.conversation_id,
        peer_identity_id=excluded.peer_identity_id,
        peer_address=excluded.peer_address,
        peer_display_name=excluded.peer_display_name,
        kind=excluded.kind,
        direction=excluded.direction,
        outcome=excluded.outcome,
        started_at=excluded.started_at,
        answered_at=excluded.answered_at,
        ended_at=excluded.ended_at,
        end_reason=excluded.end_reason
      ''',
      [
        entry.callId,
        entry.conversationId,
        entry.peerIdentityId,
        entry.peerAddress,
        entry.peerDisplayName,
        entry.kind.name,
        entry.direction.name,
        entry.outcome.name,
        entry.startedAt.toUtc().toIso8601String(),
        entry.answeredAt?.toUtc().toIso8601String(),
        entry.endedAt?.toUtc().toIso8601String(),
        entry.endReason?.name,
      ],
    );
  }

  LoomCallHistoryEntry? get(String callId) {
    _requireOpen();
    final rows = _db.select(
      'SELECT * FROM call_history_v1 WHERE call_id = ? LIMIT 1',
      [callId],
    );
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  List<LoomCallHistoryEntry> list({
    bool missedOnly = false,
    int limit = 300,
  }) {
    _requireOpen();
    if (limit < 1 || limit > 1000) throw ArgumentError.value(limit, 'limit');
    final rows = missedOnly
        ? _db.select(
            '''SELECT * FROM call_history_v1
               WHERE outcome = ?
               ORDER BY started_at DESC LIMIT ?''',
            [LoomCallHistoryOutcome.missed.name, limit],
          )
        : _db.select(
            'SELECT * FROM call_history_v1 ORDER BY started_at DESC LIMIT ?',
            [limit],
          );
    return rows.map(_fromRow).toList(growable: false);
  }

  LoomCallHistoryEntry _fromRow(Row row) => LoomCallHistoryEntry(
        callId: row['call_id'] as String,
        conversationId: row['conversation_id'] as String,
        peerIdentityId: row['peer_identity_id'] as String,
        peerAddress: row['peer_address'] as String,
        peerDisplayName: row['peer_display_name'] as String,
        kind: LoomCallKind.values.byName(row['kind'] as String),
        direction: LoomCallDirection.values.byName(row['direction'] as String),
        outcome: LoomCallHistoryOutcome.values.byName(row['outcome'] as String),
        startedAt: DateTime.parse(row['started_at'] as String).toUtc(),
        answeredAt: row['answered_at'] == null
            ? null
            : DateTime.parse(row['answered_at'] as String).toUtc(),
        endedAt: row['ended_at'] == null
            ? null
            : DateTime.parse(row['ended_at'] as String).toUtc(),
        endReason: row['end_reason'] == null
            ? null
            : LoomCallEndReason.values.byName(row['end_reason'] as String),
      );

  void close() {
    if (_closed) return;
    _closed = true;
    _db.dispose();
  }

  void _requireOpen() {
    if (_closed) throw StateError('LoomCallHistoryStore is closed');
  }
}

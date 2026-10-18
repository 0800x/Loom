import 'dart:io';
import 'dart:typed_data';

import 'package:loom_sessions/loom_sessions.dart';
import 'package:sqlite3/sqlite3.dart';

enum LoomCryptoOutboxState { pending, acknowledged, expired }

final class LoomStoredCryptoOutboxRecord {
  const LoomStoredCryptoOutboxRecord({
    required this.record,
    required this.state,
    required this.attemptCount,
    required this.nextAttemptAt,
    required this.acknowledgedAt,
  });

  final LoomCryptoOutboxRecord record;
  final LoomCryptoOutboxState state;
  final int attemptCount;
  final DateTime nextAttemptAt;
  final DateTime? acknowledgedAt;
}

/// Crash-safe persistence for ratcheting session state, provider account/prekey
/// state, and retryable ciphertext.
///
/// This store deliberately uses a separate durability policy from ordinary UI
/// caches: WAL plus `synchronous=FULL`. Session/account-state advancement and
/// exact immutable outbound ciphertext/PacketId are committed through one
/// SQLite transaction. Transports should read only committed outbox rows and
/// must never receive ciphertext directly from an in-flight crypto transaction.
final class LoomCryptoStateStore implements LoomCryptoTransactionRunner {
  LoomCryptoStateStore._(this._db);

  final Database _db;
  bool _closed = false;
  bool _transactionActive = false;

  static LoomCryptoStateStore openFile(String path) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    final store = LoomCryptoStateStore._(sqlite3.open(path));
    store._configure();
    store._migrate();
    return store;
  }

  static LoomCryptoStateStore openInMemory() {
    final store = LoomCryptoStateStore._(sqlite3.openInMemory());
    store._configure();
    store._migrate();
    return store;
  }

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
        'Loom crypto database schema $version is newer than supported schema 2',
      );
    }

    if (version == 0) {
      _db.execute('BEGIN IMMEDIATE');
      try {
        _db.execute('''
          CREATE TABLE crypto_sessions (
            session_id TEXT PRIMARY KEY,
            remote_account_id TEXT NOT NULL,
            remote_device_id TEXT NOT NULL,
            remote_device_key_version INTEGER NOT NULL,
            protocol_version TEXT NOT NULL,
            mode TEXT NOT NULL,
            revision INTEGER NOT NULL CHECK(revision >= 0),
            protected_state BLOB NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
          )
        ''');
        _db.execute('''
          CREATE INDEX idx_crypto_sessions_remote_device
          ON crypto_sessions(remote_account_id, remote_device_id)
        ''');
        _db.execute('''
          CREATE TABLE crypto_provider_state (
            state_id TEXT PRIMARY KEY,
            state_kind TEXT NOT NULL,
            revision INTEGER NOT NULL CHECK(revision >= 0),
            protected_state BLOB NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
          )
        ''');
        _db.execute('''
          CREATE INDEX idx_crypto_provider_state_kind
          ON crypto_provider_state(state_kind)
        ''');
        _db.execute('''
          CREATE TABLE crypto_outbox (
            operation_id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL,
            session_revision INTEGER NOT NULL CHECK(session_revision >= 0),
            message_id TEXT NOT NULL,
            packet_id TEXT NOT NULL UNIQUE,
            protocol_version TEXT NOT NULL,
            session_locator TEXT NOT NULL,
            ciphertext BLOB NOT NULL,
            state TEXT NOT NULL,
            attempt_count INTEGER NOT NULL DEFAULT 0,
            next_attempt_at TEXT NOT NULL,
            created_at TEXT NOT NULL,
            acknowledged_at TEXT,
            FOREIGN KEY(session_id) REFERENCES crypto_sessions(session_id) ON DELETE RESTRICT
          )
        ''');
        _db.execute('''
          CREATE INDEX idx_crypto_outbox_due
          ON crypto_outbox(state, next_attempt_at, created_at)
        ''');
        _db.execute('''
          CREATE INDEX idx_crypto_outbox_message
          ON crypto_outbox(message_id)
        ''');
        _db.execute('''
          CREATE TABLE crypto_replay (
            replay_key TEXT PRIMARY KEY,
            consumed_at TEXT NOT NULL,
            expires_at TEXT NOT NULL
          )
        ''');
        _db.execute('''
          CREATE INDEX idx_crypto_replay_expiry
          ON crypto_replay(expires_at)
        ''');
        _db.execute('PRAGMA user_version = 2');
        _db.execute('COMMIT');
      } catch (_) {
        _db.execute('ROLLBACK');
        rethrow;
      }
    } else if (version == 1) {
      // Additive migration from the first Architecture-v2 crypto schema. Existing
      // session/outbox/replay data remains byte-for-byte untouched.
      _db.execute('BEGIN IMMEDIATE');
      try {
        _db.execute('''
          CREATE TABLE crypto_provider_state (
            state_id TEXT PRIMARY KEY,
            state_kind TEXT NOT NULL,
            revision INTEGER NOT NULL CHECK(revision >= 0),
            protected_state BLOB NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
          )
        ''');
        _db.execute('''
          CREATE INDEX idx_crypto_provider_state_kind
          ON crypto_provider_state(state_kind)
        ''');
        _db.execute('PRAGMA user_version = 2');
        _db.execute('COMMIT');
      } catch (_) {
        _db.execute('ROLLBACK');
        rethrow;
      }
    }

    _verifySchema();
  }

  void _verifySchema() {
    const requiredTables = <String>{
      'crypto_sessions',
      'crypto_provider_state',
      'crypto_outbox',
      'crypto_replay',
    };
    final rows = _db.select(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'crypto_%'",
    );
    final present = rows.map((row) => row['name'] as String).toSet();
    if (!present.containsAll(requiredTables)) {
      throw StateError(
        'The selected SQLite file is not a Loom crypto-state database',
      );
    }
    final columns = _db.select('PRAGMA table_info(crypto_outbox)');
    if (!columns.any((row) => row['name'] == 'packet_id')) {
      throw StateError(
        'Experimental crypto-state schema is missing stable PacketId support; reset this pre-alpha crypto database',
      );
    }
  }

  @override
  Future<T> runDurably<T>(
    Future<T> Function(LoomCryptoTransaction transaction) operation,
  ) async {
    _requireOpen();
    if (_transactionActive) {
      throw StateError(
        'Nested or concurrent crypto transaction is not allowed',
      );
    }

    _transactionActive = true;
    final transaction = _SqliteCryptoTransaction(this);
    var began = false;
    try {
      _db.execute('BEGIN IMMEDIATE');
      began = true;
      final result = await operation(transaction);
      transaction._close();
      _db.execute('COMMIT');
      began = false;
      return result;
    } catch (_) {
      transaction._close();
      if (began) {
        try {
          _db.execute('ROLLBACK');
        } catch (_) {
          // Preserve the original failure; the connection should be discarded
          // by the caller if SQLite itself can no longer roll back safely.
        }
      }
      rethrow;
    } finally {
      _transactionActive = false;
    }
  }

  LoomSessionRecord? readSession(String sessionId) {
    _requireAvailableOutsideTransaction();
    return _readSessionDirect(sessionId);
  }

  LoomProviderStateRecord? readProviderState(String stateId) {
    _requireAvailableOutsideTransaction();
    return _readProviderStateDirect(stateId);
  }

  LoomCryptoOutboxRecord? readOutbox(String operationId) {
    _requireAvailableOutsideTransaction();
    return _readOutboxDirect(operationId);
  }

  List<LoomStoredCryptoOutboxRecord> listPendingOutbox(
    DateTime now, {
    int limit = 50,
  }) {
    _requireAvailableOutsideTransaction();
    if (limit < 1 || limit > 500) throw ArgumentError.value(limit, 'limit');
    final rows = _db.select(
      '''
      SELECT * FROM crypto_outbox
      WHERE state = ? AND next_attempt_at <= ?
      ORDER BY next_attempt_at ASC, created_at ASC, operation_id ASC
      LIMIT ?
      ''',
      [
        LoomCryptoOutboxState.pending.name,
        now.toUtc().toIso8601String(),
        limit,
      ],
    );
    return rows.map(_storedOutboxFromRow).toList(growable: false);
  }

  void rescheduleOutbox(
    String operationId, {
    required int attemptCount,
    required DateTime nextAttemptAt,
  }) {
    _requireAvailableOutsideTransaction();
    if (attemptCount < 0)
      throw ArgumentError.value(attemptCount, 'attemptCount');
    _db.execute(
      '''
      UPDATE crypto_outbox
      SET attempt_count = ?, next_attempt_at = ?
      WHERE operation_id = ? AND state = ?
      ''',
      [
        attemptCount,
        nextAttemptAt.toUtc().toIso8601String(),
        operationId,
        LoomCryptoOutboxState.pending.name,
      ],
    );
  }

  void acknowledgeOutbox(String operationId, DateTime acknowledgedAt) {
    _requireAvailableOutsideTransaction();
    _db.execute(
      '''
      UPDATE crypto_outbox
      SET state = ?, acknowledged_at = ?
      WHERE operation_id = ? AND state = ?
      ''',
      [
        LoomCryptoOutboxState.acknowledged.name,
        acknowledgedAt.toUtc().toIso8601String(),
        operationId,
        LoomCryptoOutboxState.pending.name,
      ],
    );
  }

  void expireOutbox(String operationId) {
    _requireAvailableOutsideTransaction();
    _db.execute(
      'UPDATE crypto_outbox SET state = ? WHERE operation_id = ? AND state = ?',
      [
        LoomCryptoOutboxState.expired.name,
        operationId,
        LoomCryptoOutboxState.pending.name,
      ],
    );
  }

  void pruneReplay(DateTime now) {
    _requireAvailableOutsideTransaction();
    _db.execute('DELETE FROM crypto_replay WHERE expires_at <= ?', [
      now.toUtc().toIso8601String(),
    ]);
  }

  LoomSessionRecord? _readSessionDirect(String sessionId) {
    _validateIdentifier(sessionId, 'session id');
    final rows = _db.select(
      'SELECT * FROM crypto_sessions WHERE session_id = ? LIMIT 1',
      [sessionId],
    );
    return rows.isEmpty ? null : _sessionFromRow(rows.first);
  }

  LoomProviderStateRecord? _readProviderStateDirect(String stateId) {
    _validateIdentifier(stateId, 'provider state id');
    final rows = _db.select(
      'SELECT * FROM crypto_provider_state WHERE state_id = ? LIMIT 1',
      [stateId],
    );
    return rows.isEmpty ? null : _providerStateFromRow(rows.first);
  }

  LoomCryptoOutboxRecord? _readOutboxDirect(String operationId) {
    _validateIdentifier(operationId, 'operation id');
    final rows = _db.select(
      'SELECT * FROM crypto_outbox WHERE operation_id = ? LIMIT 1',
      [operationId],
    );
    return rows.isEmpty ? null : _outboxFromRow(rows.first);
  }

  void _writeSessionDirect(
    LoomSessionRecord session, {
    required int? expectedRevision,
  }) {
    session.validate();
    final rows = _db.select(
      'SELECT * FROM crypto_sessions WHERE session_id = ? LIMIT 1',
      [session.sessionId],
    );

    if (expectedRevision == null) {
      if (rows.isNotEmpty) {
        throw LoomCryptoStateConflict(
          'Session ${session.sessionId} already exists',
        );
      }
      if (session.revision != 0) {
        throw const LoomCryptoStateConflict(
          'New sessions must start at revision zero',
        );
      }
      _db.execute(
        '''
        INSERT INTO crypto_sessions (
          session_id, remote_account_id, remote_device_id,
          remote_device_key_version, protocol_version, mode, revision,
          protected_state, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ''',
        [
          session.sessionId,
          session.remoteDevice.accountId,
          session.remoteDevice.deviceId,
          session.remoteDevice.deviceKeyVersion,
          session.protocolVersion,
          session.mode.name,
          session.revision,
          session.protectedState,
          session.createdAt.toUtc().toIso8601String(),
          session.updatedAt.toUtc().toIso8601String(),
        ],
      );
      return;
    }

    if (expectedRevision < 0) {
      throw const LoomCryptoStateConflict(
        'Expected revision must be non-negative',
      );
    }
    if (rows.isEmpty) {
      throw LoomCryptoStateConflict(
        'Session ${session.sessionId} does not exist',
      );
    }
    final existing = rows.first;
    final persistedRevision = existing['revision'] as int;
    if (persistedRevision != expectedRevision) {
      throw LoomCryptoStateConflict(
        'Session ${session.sessionId} revision conflict: expected '
        '$expectedRevision, found $persistedRevision',
      );
    }
    if (session.revision != expectedRevision + 1) {
      throw LoomCryptoStateConflict(
        'Session ${session.sessionId} must advance exactly one revision',
      );
    }
    if (existing['remote_account_id'] != session.remoteDevice.accountId ||
        existing['remote_device_id'] != session.remoteDevice.deviceId ||
        existing['remote_device_key_version'] !=
            session.remoteDevice.deviceKeyVersion ||
        existing['protocol_version'] != session.protocolVersion ||
        existing['created_at'] != session.createdAt.toUtc().toIso8601String()) {
      throw LoomCryptoStateConflict(
        'Immutable session identity fields changed for ${session.sessionId}',
      );
    }

    _db.execute(
      '''
      UPDATE crypto_sessions
      SET mode = ?, revision = ?, protected_state = ?, updated_at = ?
      WHERE session_id = ? AND revision = ?
      ''',
      [
        session.mode.name,
        session.revision,
        session.protectedState,
        session.updatedAt.toUtc().toIso8601String(),
        session.sessionId,
        expectedRevision,
      ],
    );
  }

  void _writeProviderStateDirect(
    LoomProviderStateRecord state, {
    required int? expectedRevision,
  }) {
    state.validate();
    final rows = _db.select(
      'SELECT * FROM crypto_provider_state WHERE state_id = ? LIMIT 1',
      [state.stateId],
    );

    if (expectedRevision == null) {
      if (rows.isNotEmpty) {
        throw LoomCryptoStateConflict(
          'Provider state ${state.stateId} already exists',
        );
      }
      if (state.revision != 0) {
        throw const LoomCryptoStateConflict(
          'New provider state must start at revision zero',
        );
      }
      _db.execute(
        '''
        INSERT INTO crypto_provider_state(
          state_id, state_kind, revision, protected_state, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?)
        ''',
        [
          state.stateId,
          state.stateKind,
          state.revision,
          state.protectedState,
          state.createdAt.toUtc().toIso8601String(),
          state.updatedAt.toUtc().toIso8601String(),
        ],
      );
      return;
    }

    if (expectedRevision < 0) {
      throw const LoomCryptoStateConflict(
        'Expected provider state revision must be non-negative',
      );
    }
    if (rows.isEmpty) {
      throw LoomCryptoStateConflict(
        'Provider state ${state.stateId} does not exist',
      );
    }
    final existing = rows.first;
    final persistedRevision = existing['revision'] as int;
    if (persistedRevision != expectedRevision) {
      throw LoomCryptoStateConflict(
        'Provider state ${state.stateId} revision conflict: expected '
        '$expectedRevision, found $persistedRevision',
      );
    }
    if (state.revision != expectedRevision + 1) {
      throw LoomCryptoStateConflict(
        'Provider state ${state.stateId} must advance exactly one revision',
      );
    }
    if (existing['state_kind'] != state.stateKind ||
        existing['created_at'] != state.createdAt.toUtc().toIso8601String()) {
      throw LoomCryptoStateConflict(
        'Immutable provider-state identity fields changed for ${state.stateId}',
      );
    }

    _db.execute(
      '''
      UPDATE crypto_provider_state
      SET revision = ?, protected_state = ?, updated_at = ?
      WHERE state_id = ? AND revision = ?
      ''',
      [
        state.revision,
        state.protectedState,
        state.updatedAt.toUtc().toIso8601String(),
        state.stateId,
        expectedRevision,
      ],
    );
  }

  void _putOutboxDirect(LoomCryptoOutboxRecord record) {
    record.validate();
    final sessionRows = _db.select(
      'SELECT revision FROM crypto_sessions WHERE session_id = ? LIMIT 1',
      [record.sessionId],
    );
    if (sessionRows.isEmpty ||
        (sessionRows.first['revision'] as int) != record.sessionRevision) {
      throw LoomCryptoStateConflict(
        'Outbox ${record.operationId} is not tied to the current committed session revision',
      );
    }

    final existingRows = _db.select(
      'SELECT * FROM crypto_outbox WHERE operation_id = ? LIMIT 1',
      [record.operationId],
    );
    if (existingRows.isNotEmpty) {
      final existing = _outboxFromRow(existingRows.first);
      if (_sameOutbox(existing, record)) return;
      throw LoomCryptoStateConflict(
        'Operation ${record.operationId} already exists with different ciphertext or metadata',
      );
    }

    final packetRows = _db.select(
      'SELECT operation_id FROM crypto_outbox WHERE packet_id = ? LIMIT 1',
      [record.packetId],
    );
    if (packetRows.isNotEmpty) {
      throw LoomCryptoStateConflict(
        'PacketId ${record.packetId} is already assigned to another operation',
      );
    }

    _db.execute(
      '''
      INSERT INTO crypto_outbox (
        operation_id, session_id, session_revision, message_id, packet_id,
        protocol_version, session_locator, ciphertext, state,
        attempt_count, next_attempt_at, created_at, acknowledged_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, NULL)
      ''',
      [
        record.operationId,
        record.sessionId,
        record.sessionRevision,
        record.messageId,
        record.packetId,
        record.ciphertext.protocolVersion,
        record.ciphertext.sessionLocator,
        record.ciphertext.bytes,
        LoomCryptoOutboxState.pending.name,
        record.createdAt.toUtc().toIso8601String(),
        record.createdAt.toUtc().toIso8601String(),
      ],
    );
  }

  void _markReplayConsumedDirect(String replayKey, DateTime expiresAt) {
    _validateIdentifier(replayKey, 'replay key', maxLength: 512);
    final exists = _db.select(
      'SELECT 1 FROM crypto_replay WHERE replay_key = ? LIMIT 1',
      [replayKey],
    );
    if (exists.isNotEmpty) {
      throw LoomCryptoStateConflict(
        'Replay key $replayKey is already consumed',
      );
    }
    _db.execute(
      'INSERT INTO crypto_replay(replay_key, consumed_at, expires_at) VALUES (?, ?, ?)',
      [
        replayKey,
        DateTime.now().toUtc().toIso8601String(),
        expiresAt.toUtc().toIso8601String(),
      ],
    );
  }

  bool _isReplayConsumedDirect(String replayKey) {
    _validateIdentifier(replayKey, 'replay key', maxLength: 512);
    return _db.select(
      'SELECT 1 FROM crypto_replay WHERE replay_key = ? LIMIT 1',
      [replayKey],
    ).isNotEmpty;
  }

  LoomSessionRecord _sessionFromRow(Row row) => LoomSessionRecord(
    sessionId: row['session_id'] as String,
    remoteDevice: LoomRemoteDeviceRef(
      accountId: row['remote_account_id'] as String,
      deviceId: row['remote_device_id'] as String,
      deviceKeyVersion: row['remote_device_key_version'] as int,
    ),
    protocolVersion: row['protocol_version'] as String,
    mode: LoomCryptoSessionMode.values.byName(row['mode'] as String),
    revision: row['revision'] as int,
    protectedState: row['protected_state'] as Uint8List,
    createdAt: DateTime.parse(row['created_at'] as String).toUtc(),
    updatedAt: DateTime.parse(row['updated_at'] as String).toUtc(),
  );

  LoomProviderStateRecord _providerStateFromRow(Row row) =>
      LoomProviderStateRecord(
        stateId: row['state_id'] as String,
        stateKind: row['state_kind'] as String,
        revision: row['revision'] as int,
        protectedState: row['protected_state'] as Uint8List,
        createdAt: DateTime.parse(row['created_at'] as String).toUtc(),
        updatedAt: DateTime.parse(row['updated_at'] as String).toUtc(),
      );

  LoomCryptoOutboxRecord _outboxFromRow(Row row) => LoomCryptoOutboxRecord(
    operationId: row['operation_id'] as String,
    sessionId: row['session_id'] as String,
    sessionRevision: row['session_revision'] as int,
    messageId: row['message_id'] as String,
    packetId: row['packet_id'] as String,
    ciphertext: LoomSessionCiphertext(
      protocolVersion: row['protocol_version'] as String,
      sessionLocator: row['session_locator'] as String,
      bytes: row['ciphertext'] as Uint8List,
    ),
    createdAt: DateTime.parse(row['created_at'] as String).toUtc(),
  );

  LoomStoredCryptoOutboxRecord _storedOutboxFromRow(Row row) =>
      LoomStoredCryptoOutboxRecord(
        record: _outboxFromRow(row),
        state: LoomCryptoOutboxState.values.byName(row['state'] as String),
        attemptCount: row['attempt_count'] as int,
        nextAttemptAt: DateTime.parse(row['next_attempt_at'] as String).toUtc(),
        acknowledgedAt:
            row['acknowledged_at'] == null
                ? null
                : DateTime.parse(row['acknowledged_at'] as String).toUtc(),
      );

  bool _sameOutbox(LoomCryptoOutboxRecord a, LoomCryptoOutboxRecord b) =>
      a.operationId == b.operationId &&
      a.sessionId == b.sessionId &&
      a.sessionRevision == b.sessionRevision &&
      a.messageId == b.messageId &&
      a.packetId == b.packetId &&
      a.ciphertext.protocolVersion == b.ciphertext.protocolVersion &&
      a.ciphertext.sessionLocator == b.ciphertext.sessionLocator &&
      a.createdAt.toUtc() == b.createdAt.toUtc() &&
      _sameBytes(a.ciphertext.bytes, b.ciphertext.bytes);

  bool _sameBytes(Uint8List a, Uint8List b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  void _validateIdentifier(String value, String label, {int maxLength = 256}) {
    if (value.trim().isEmpty ||
        value.length > maxLength ||
        value.contains('\u0000') ||
        value.contains('\r') ||
        value.contains('\n')) {
      throw FormatException('Invalid $label');
    }
  }

  void close() {
    if (_closed) return;
    if (_transactionActive) {
      throw StateError('Cannot close crypto store during active transaction');
    }
    _closed = true;
    _db.dispose();
  }

  void _requireOpen() {
    if (_closed) throw StateError('LoomCryptoStateStore is closed');
  }

  void _requireAvailableOutsideTransaction() {
    _requireOpen();
    if (_transactionActive) {
      throw StateError(
        'Use the provided LoomCryptoTransaction while a crypto transaction is active',
      );
    }
  }
}

final class _SqliteCryptoTransaction
    implements LoomSessionBootstrapTransaction {
  _SqliteCryptoTransaction(this._store);

  final LoomCryptoStateStore _store;
  bool _active = true;

  @override
  Future<LoomSessionRecord?> readSession(String sessionId) async {
    _requireActive();
    return _store._readSessionDirect(sessionId);
  }

  @override
  Future<LoomProviderStateRecord?> readProviderState(String stateId) async {
    _requireActive();
    return _store._readProviderStateDirect(stateId);
  }

  @override
  Future<LoomCryptoOutboxRecord?> readOutbox(String operationId) async {
    _requireActive();
    return _store._readOutboxDirect(operationId);
  }

  @override
  Future<void> writeSession(
    LoomSessionRecord session, {
    required int? expectedRevision,
  }) async {
    _requireActive();
    _store._writeSessionDirect(session, expectedRevision: expectedRevision);
  }

  @override
  Future<void> writeProviderState(
    LoomProviderStateRecord state, {
    required int? expectedRevision,
  }) async {
    _requireActive();
    _store._writeProviderStateDirect(state, expectedRevision: expectedRevision);
  }

  @override
  Future<void> putOutbox(LoomCryptoOutboxRecord record) async {
    _requireActive();
    _store._putOutboxDirect(record);
  }

  @override
  Future<void> markReplayConsumed(String replayKey, DateTime expiresAt) async {
    _requireActive();
    _store._markReplayConsumedDirect(replayKey, expiresAt);
  }

  @override
  Future<bool> isReplayConsumed(String replayKey) async {
    _requireActive();
    return _store._isReplayConsumedDirect(replayKey);
  }

  void _close() => _active = false;

  void _requireActive() {
    if (!_active) {
      throw StateError('Crypto transaction is no longer active');
    }
  }
}

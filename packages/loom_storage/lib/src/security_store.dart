import 'dart:convert';
import 'dart:io';

import 'package:loom_models/loom_models.dart';
import 'package:sqlite3/sqlite3.dart';

/// Public/trust metadata store for device security state.
///
/// Private keys, MLS secrets and recovery material never belong in this DB.
/// Callers must cryptographically validate remote bundles before observing them.
class LoomSecurityStore {
  LoomSecurityStore._(this._db) {
    _db.execute('PRAGMA foreign_keys = ON');
    _db.execute('PRAGMA journal_mode = WAL');
    _db.execute('PRAGMA synchronous = NORMAL');
    _migrate();
  }

  final Database _db;
  bool _closed = false;

  static LoomSecurityStore openFile(String path) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    return LoomSecurityStore._(sqlite3.open(path));
  }

  static LoomSecurityStore openInMemory() =>
      LoomSecurityStore._(sqlite3.openInMemory());

  void _migrate() {
    final version = _db.select('PRAGMA user_version').first.values.first as int;
    if (version > 1) {
      throw StateError(
        'Security DB schema $version is newer than supported schema 1',
      );
    }
    if (version == 1) return;
    _db.execute('BEGIN IMMEDIATE');
    try {
      _db.execute('''
        CREATE TABLE known_devices (
          identity_id TEXT NOT NULL,
          device_id TEXT NOT NULL,
          bundle_json TEXT NOT NULL,
          fingerprint TEXT NOT NULL,
          trust_state TEXT NOT NULL,
          first_seen_at TEXT NOT NULL,
          last_seen_at TEXT NOT NULL,
          verified_at TEXT,
          PRIMARY KEY(identity_id, device_id)
        )
      ''');
      _db.execute('''
        CREATE TABLE device_key_history (
          identity_id TEXT NOT NULL,
          device_id TEXT NOT NULL,
          fingerprint TEXT NOT NULL,
          bundle_json TEXT NOT NULL,
          observed_at TEXT NOT NULL,
          PRIMARY KEY(identity_id, device_id, fingerprint)
        )
      ''');
      _db.execute('''
        CREATE TABLE security_events (
          event_id TEXT PRIMARY KEY,
          kind TEXT NOT NULL,
          identity_id TEXT NOT NULL,
          device_id TEXT NOT NULL,
          created_at TEXT NOT NULL,
          summary TEXT NOT NULL
        )
      ''');
      _db.execute(
        'CREATE INDEX idx_security_events_time ON security_events(created_at DESC)',
      );
      _db.execute('PRAGMA user_version = 1');
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  LoomDeviceTrustState observeDevice(
    LoomDeviceKeyBundle bundle, {
    required DateTime observedAt,
  }) {
    _requireOpen();
    final existing = _db.select(
      'SELECT fingerprint, trust_state, first_seen_at, verified_at FROM known_devices WHERE identity_id = ? AND device_id = ?',
      <Object?>[bundle.identityId, bundle.deviceId],
    );
    final now = observedAt.toUtc();
    if (existing.isEmpty) {
      _db.execute(
        '''INSERT INTO known_devices (
          identity_id, device_id, bundle_json, fingerprint, trust_state,
          first_seen_at, last_seen_at, verified_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, NULL)''',
        <Object?>[
          bundle.identityId,
          bundle.deviceId,
          jsonEncode(bundle.toJson()),
          bundle.fingerprint,
          LoomDeviceTrustState.unknown.name,
          now.toIso8601String(),
          now.toIso8601String(),
        ],
      );
      _recordHistory(bundle, now);
      return LoomDeviceTrustState.unknown;
    }

    final oldFingerprint = existing.first['fingerprint'] as String;
    final oldTrust = LoomDeviceTrustState.values.byName(
      existing.first['trust_state'] as String,
    );
    final changed = oldFingerprint != bundle.fingerprint;
    // Revocation is sticky. A Node is not allowed to resurrect a device simply
    // by replaying the old, still-valid identity-signed bundle.
    final nextTrust = oldTrust == LoomDeviceTrustState.revoked
        ? LoomDeviceTrustState.revoked
        : changed
        ? LoomDeviceTrustState.changed
        : oldTrust;
    _db.execute(
      '''UPDATE known_devices SET
         bundle_json = ?, fingerprint = ?, trust_state = ?, last_seen_at = ?,
         verified_at = CASE WHEN ? THEN NULL ELSE verified_at END
         WHERE identity_id = ? AND device_id = ?''',
      <Object?>[
        jsonEncode(bundle.toJson()),
        bundle.fingerprint,
        nextTrust.name,
        now.toIso8601String(),
        changed ? 1 : 0,
        bundle.identityId,
        bundle.deviceId,
      ],
    );
    if (changed) _recordHistory(bundle, now);
    return nextTrust;
  }

  void markVerified({
    required String identityId,
    required String deviceId,
    required String expectedFingerprint,
    required DateTime verifiedAt,
  }) {
    _requireOpen();
    final result = _db.select(
      'SELECT fingerprint, trust_state FROM known_devices WHERE identity_id = ? AND device_id = ?',
      <Object?>[identityId, deviceId],
    );
    if (result.isEmpty) throw StateError('Cannot verify an unknown device');
    if (result.first['fingerprint'] != expectedFingerprint) {
      throw StateError(
        'Device fingerprint changed before verification completed',
      );
    }
    if (result.first['trust_state'] == LoomDeviceTrustState.revoked.name) {
      throw StateError('A revoked device cannot be re-verified');
    }
    _db.execute(
      '''UPDATE known_devices SET trust_state = ?, verified_at = ?
         WHERE identity_id = ? AND device_id = ?''',
      <Object?>[
        LoomDeviceTrustState.verified.name,
        verifiedAt.toUtc().toIso8601String(),
        identityId,
        deviceId,
      ],
    );
  }

  void markRevoked({required String identityId, required String deviceId}) {
    _requireOpen();
    _db.execute(
      'UPDATE known_devices SET trust_state = ?, verified_at = NULL WHERE identity_id = ? AND device_id = ?',
      <Object?>[LoomDeviceTrustState.revoked.name, identityId, deviceId],
    );
  }

  /// Reconciles a freshly authenticated device-directory snapshot.
  ///
  /// Any previously observed device omitted from the new active set is marked
  /// revoked locally. Revocation is deliberately sticky: a later replay of an
  /// old signed bundle cannot silently make that device active again.
  List<String> reconcileActiveDeviceSet({
    required String identityId,
    required Set<String> activeDeviceIds,
    required DateTime observedAt,
  }) {
    _requireOpen();
    if (identityId.trim().isEmpty || identityId.length > 512) {
      throw const FormatException('Invalid identity device-directory binding');
    }
    if (activeDeviceIds.length > 256 ||
        activeDeviceIds.any(
          (id) =>
              id.trim().isEmpty ||
              id.length > 256 ||
              id.contains(RegExp(r'[\r\n]')),
        )) {
      throw const FormatException('Invalid active device directory');
    }
    final rows = _db.select(
      'SELECT device_id, trust_state FROM known_devices WHERE identity_id = ?',
      <Object?>[identityId],
    );
    final newlyRevoked = <String>[];
    final now = observedAt.toUtc();
    _db.execute('BEGIN IMMEDIATE');
    try {
      for (final row in rows) {
        final deviceId = row['device_id'] as String;
        final trust = LoomDeviceTrustState.values.byName(
          row['trust_state'] as String,
        );
        if (activeDeviceIds.contains(deviceId) ||
            trust == LoomDeviceTrustState.revoked) {
          continue;
        }
        _db.execute(
          '''UPDATE known_devices
             SET trust_state = ?, verified_at = NULL
             WHERE identity_id = ? AND device_id = ?''',
          <Object?>[LoomDeviceTrustState.revoked.name, identityId, deviceId],
        );
        _db.execute(
          '''INSERT OR IGNORE INTO security_events
             (event_id, kind, identity_id, device_id, created_at, summary)
             VALUES (?, ?, ?, ?, ?, ?)''',
          <Object?>[
            'directory-revoked:$identityId:$deviceId:${now.microsecondsSinceEpoch}',
            LoomSecurityEventKind.deviceRevoked.name,
            identityId,
            deviceId,
            now.toIso8601String(),
            'Device disappeared from a freshly authenticated active-device directory.',
          ],
        );
        newlyRevoked.add(deviceId);
      }
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
    return List<String>.unmodifiable(newlyRevoked);
  }

  List<LoomKnownDevice> listDevices(String identityId) {
    _requireOpen();
    final rows = _db.select(
      'SELECT * FROM known_devices WHERE identity_id = ? ORDER BY last_seen_at DESC, device_id ASC',
      <Object?>[identityId],
    );
    return rows
        .map((row) {
          final decoded = jsonDecode(row['bundle_json'] as String);
          if (decoded is! Map<String, Object?>) {
            throw const FormatException('Stored device bundle is malformed');
          }
          return LoomKnownDevice(
            bundle: LoomDeviceKeyBundle.fromJson(decoded),
            trustState: LoomDeviceTrustState.values.byName(
              row['trust_state'] as String,
            ),
            firstSeenAt: DateTime.parse(row['first_seen_at'] as String).toUtc(),
            lastSeenAt: DateTime.parse(row['last_seen_at'] as String).toUtc(),
            verifiedAt: row['verified_at'] == null
                ? null
                : DateTime.parse(row['verified_at'] as String).toUtc(),
          );
        })
        .toList(growable: false);
  }

  void addEvent(LoomSecurityEvent event) {
    _requireOpen();
    _db.execute(
      '''INSERT OR IGNORE INTO security_events
         (event_id, kind, identity_id, device_id, created_at, summary)
         VALUES (?, ?, ?, ?, ?, ?)''',
      <Object?>[
        event.eventId,
        event.kind.name,
        event.identityId,
        event.deviceId,
        event.createdAt.toUtc().toIso8601String(),
        event.summary,
      ],
    );
  }

  List<LoomSecurityEvent> listEvents({int limit = 100}) {
    _requireOpen();
    if (limit < 1 || limit > 500) throw ArgumentError.value(limit, 'limit');
    final rows = _db.select(
      'SELECT * FROM security_events ORDER BY created_at DESC LIMIT ?',
      <Object?>[limit],
    );
    return rows
        .map(
          (row) => LoomSecurityEvent(
            eventId: row['event_id'] as String,
            kind: LoomSecurityEventKind.values.byName(row['kind'] as String),
            identityId: row['identity_id'] as String,
            deviceId: row['device_id'] as String,
            createdAt: DateTime.parse(row['created_at'] as String).toUtc(),
            summary: row['summary'] as String,
          ),
        )
        .toList(growable: false);
  }

  void _recordHistory(LoomDeviceKeyBundle bundle, DateTime observedAt) {
    _db.execute(
      '''INSERT OR IGNORE INTO device_key_history
         (identity_id, device_id, fingerprint, bundle_json, observed_at)
         VALUES (?, ?, ?, ?, ?)''',
      <Object?>[
        bundle.identityId,
        bundle.deviceId,
        bundle.fingerprint,
        jsonEncode(bundle.toJson()),
        observedAt.toUtc().toIso8601String(),
      ],
    );
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _db.dispose();
  }

  void _requireOpen() {
    if (_closed) throw StateError('Security store is closed');
  }
}

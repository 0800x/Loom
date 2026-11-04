import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:loom_identity/loom_identity.dart';
import 'package:loom_sessions/loom_sessions.dart';
import 'package:sqlite3/sqlite3.dart';

final class LoomStoredAuthorizedDeviceV2 {
  LoomStoredAuthorizedDeviceV2({
    required this.accountId,
    required this.deviceId,
    required this.deviceKeyVersion,
    required Uint8List signingPublicKey,
    required Uint8List agreementPublicKey,
    required this.issuedAt,
    required this.expiresAt,
    required List<String> capabilities,
  }) : signingPublicKey = Uint8List.fromList(signingPublicKey),
       agreementPublicKey = Uint8List.fromList(agreementPublicKey),
       capabilities = List.unmodifiable(capabilities);

  final String accountId;
  final String deviceId;
  final int deviceKeyVersion;
  final Uint8List signingPublicKey;
  final Uint8List agreementPublicKey;
  final DateTime issuedAt;
  final DateTime expiresAt;
  final List<String> capabilities;
}

/// Durable cache for cryptographically verified Architecture-v2 device
/// directories.
///
/// This store never verifies server data itself. [applyVerifiedSnapshot] accepts
/// only the result of [LoomDeviceDirectoryVerifierV2]. Directory revisions are
/// monotonic, revocation is sticky, and an older device-key version becomes
/// unavailable as soon as a higher verified version is present.
final class LoomDeviceDirectoryStoreV2
    implements LoomAuthorizedDeviceSigningKeyResolver {
  LoomDeviceDirectoryStoreV2._(this._db) {
    _db.execute('PRAGMA foreign_keys = ON');
    _db.execute('PRAGMA journal_mode = WAL');
    _db.execute('PRAGMA synchronous = FULL');
    _db.execute('PRAGMA busy_timeout = 5000');
    _migrate();
  }

  final Database _db;
  bool _closed = false;

  static LoomDeviceDirectoryStoreV2 openFile(String path) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    return LoomDeviceDirectoryStoreV2._(sqlite3.open(path));
  }

  static LoomDeviceDirectoryStoreV2 openInMemory() =>
      LoomDeviceDirectoryStoreV2._(sqlite3.openInMemory());

  void _migrate() {
    final version = _db.select('PRAGMA user_version').first.values.first as int;
    if (version > 1) {
      throw StateError(
        'Device-directory DB schema $version is newer than supported schema 1',
      );
    }
    if (version == 1) return;
    _db.execute('BEGIN IMMEDIATE');
    try {
      _db.execute('''
        CREATE TABLE v2_directory_meta (
          account_id TEXT PRIMARY KEY,
          directory_revision INTEGER NOT NULL,
          account_key_version INTEGER NOT NULL,
          generated_at TEXT NOT NULL,
          snapshot_canonical BLOB NOT NULL,
          snapshot_signature BLOB NOT NULL
        )
      ''');
      _db.execute('''
        CREATE TABLE v2_device_authorizations (
          account_id TEXT NOT NULL,
          device_id TEXT NOT NULL,
          key_version INTEGER NOT NULL,
          signing_public_key BLOB NOT NULL,
          agreement_public_key BLOB NOT NULL,
          issued_at TEXT NOT NULL,
          expires_at TEXT NOT NULL,
          capabilities_json TEXT NOT NULL,
          account_signature BLOB NOT NULL,
          PRIMARY KEY(account_id, device_id, key_version)
        )
      ''');
      _db.execute('''
        CREATE TABLE v2_device_revocations (
          account_id TEXT NOT NULL,
          device_id TEXT NOT NULL,
          revocation_sequence INTEGER NOT NULL,
          revoked_through_key_version INTEGER NOT NULL,
          revoked_at TEXT NOT NULL,
          reason_code TEXT NOT NULL,
          account_signature BLOB NOT NULL,
          PRIMARY KEY(account_id, device_id, revocation_sequence)
        )
      ''');
      _db.execute('''
        CREATE TABLE v2_device_revocation_sticky (
          account_id TEXT NOT NULL,
          device_id TEXT NOT NULL,
          max_revoked_key_version INTEGER NOT NULL,
          last_revocation_sequence INTEGER NOT NULL,
          PRIMARY KEY(account_id, device_id)
        )
      ''');
      _db.execute(
        'CREATE INDEX idx_v2_auth_device ON v2_device_authorizations(account_id, device_id, key_version DESC)',
      );
      _db.execute('PRAGMA user_version = 1');
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  void applyVerifiedSnapshot(LoomVerifiedDeviceDirectorySnapshotV2 verified) {
    _requireOpen();
    final snapshot = verified.snapshot;
    snapshot.validate();
    final canonical = snapshot.canonicalBytes();
    final existing = _db.select(
      'SELECT directory_revision, snapshot_canonical, snapshot_signature FROM v2_directory_meta WHERE account_id = ?',
      <Object?>[snapshot.accountId.value],
    );
    if (existing.isNotEmpty) {
      final previousRevision = existing.first['directory_revision'] as int;
      if (snapshot.directoryRevision < previousRevision) {
        throw StateError('Device-directory revision rollback rejected');
      }
      if (snapshot.directoryRevision == previousRevision) {
        final previousCanonical =
            existing.first['snapshot_canonical'] as Uint8List;
        final previousSignature =
            existing.first['snapshot_signature'] as Uint8List;
        if (!_bytesEqual(previousCanonical, canonical) ||
            !_bytesEqual(previousSignature, snapshot.accountSignature)) {
          throw StateError(
            'Conflicting device-directory snapshot at same revision',
          );
        }
        return;
      }
    }

    _db.execute('BEGIN IMMEDIATE');
    try {
      _db.execute(
        'DELETE FROM v2_device_authorizations WHERE account_id = ?',
        <Object?>[snapshot.accountId.value],
      );
      for (final authorization in snapshot.authorizations) {
        _db.execute(
          '''INSERT INTO v2_device_authorizations (
             account_id, device_id, key_version, signing_public_key,
             agreement_public_key, issued_at, expires_at, capabilities_json,
             account_signature
           ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)''',
          <Object?>[
            snapshot.accountId.value,
            authorization.deviceId.value,
            authorization.deviceKeyVersion,
            authorization.signingPublicKey,
            authorization.agreementPublicKey,
            authorization.issuedAt.toUtc().toIso8601String(),
            authorization.expiresAt.toUtc().toIso8601String(),
            jsonEncode(authorization.capabilities.toList()..sort()),
            authorization.accountSignature,
          ],
        );
      }

      for (final revocation in snapshot.revocations) {
        _db.execute(
          '''INSERT OR IGNORE INTO v2_device_revocations (
             account_id, device_id, revocation_sequence,
             revoked_through_key_version, revoked_at, reason_code,
             account_signature
           ) VALUES (?, ?, ?, ?, ?, ?, ?)''',
          <Object?>[
            snapshot.accountId.value,
            revocation.deviceId.value,
            revocation.revocationSequence,
            revocation.revokedThroughKeyVersion,
            revocation.revokedAt.toUtc().toIso8601String(),
            revocation.reasonCode,
            revocation.accountSignature,
          ],
        );
        final sticky = _db.select(
          '''SELECT max_revoked_key_version, last_revocation_sequence
             FROM v2_device_revocation_sticky
             WHERE account_id = ? AND device_id = ?''',
          <Object?>[snapshot.accountId.value, revocation.deviceId.value],
        );
        final previousMax = sticky.isEmpty
            ? 0
            : sticky.first['max_revoked_key_version'] as int;
        final previousSequence = sticky.isEmpty
            ? 0
            : sticky.first['last_revocation_sequence'] as int;
        _db.execute(
          '''INSERT INTO v2_device_revocation_sticky (
             account_id, device_id, max_revoked_key_version, last_revocation_sequence
           ) VALUES (?, ?, ?, ?)
           ON CONFLICT(account_id, device_id) DO UPDATE SET
             max_revoked_key_version = excluded.max_revoked_key_version,
             last_revocation_sequence = excluded.last_revocation_sequence''',
          <Object?>[
            snapshot.accountId.value,
            revocation.deviceId.value,
            previousMax > revocation.revokedThroughKeyVersion
                ? previousMax
                : revocation.revokedThroughKeyVersion,
            previousSequence > revocation.revocationSequence
                ? previousSequence
                : revocation.revocationSequence,
          ],
        );
      }

      _db.execute(
        '''INSERT INTO v2_directory_meta (
           account_id, directory_revision, account_key_version, generated_at,
           snapshot_canonical, snapshot_signature
         ) VALUES (?, ?, ?, ?, ?, ?)
         ON CONFLICT(account_id) DO UPDATE SET
           directory_revision = excluded.directory_revision,
           account_key_version = excluded.account_key_version,
           generated_at = excluded.generated_at,
           snapshot_canonical = excluded.snapshot_canonical,
           snapshot_signature = excluded.snapshot_signature''',
        <Object?>[
          snapshot.accountId.value,
          snapshot.directoryRevision,
          snapshot.accountKeyVersion,
          snapshot.generatedAt.toUtc().toIso8601String(),
          canonical,
          snapshot.accountSignature,
        ],
      );
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  int? directoryRevision(String accountId) {
    _requireOpen();
    final rows = _db.select(
      'SELECT directory_revision FROM v2_directory_meta WHERE account_id = ?',
      <Object?>[accountId],
    );
    return rows.isEmpty ? null : rows.first['directory_revision'] as int;
  }

  LoomStoredAuthorizedDeviceV2? resolveDevice({
    required String accountId,
    required String deviceId,
    required int deviceKeyVersion,
    required DateTime now,
  }) {
    _requireOpen();
    LoomAccountId.parse(accountId);
    LoomDeviceId.parse(deviceId);
    if (deviceKeyVersion < 1) return null;

    final latest = _db
        .select(
          '''SELECT MAX(key_version) AS latest
         FROM v2_device_authorizations
         WHERE account_id = ? AND device_id = ?''',
          <Object?>[accountId, deviceId],
        )
        .first['latest'];
    if (latest is! int || latest != deviceKeyVersion) return null;

    final sticky = _db.select(
      '''SELECT max_revoked_key_version FROM v2_device_revocation_sticky
         WHERE account_id = ? AND device_id = ?''',
      <Object?>[accountId, deviceId],
    );
    if (sticky.isNotEmpty &&
        deviceKeyVersion <= (sticky.first['max_revoked_key_version'] as int)) {
      return null;
    }

    final rows = _db.select(
      '''SELECT * FROM v2_device_authorizations
         WHERE account_id = ? AND device_id = ? AND key_version = ?''',
      <Object?>[accountId, deviceId, deviceKeyVersion],
    );
    if (rows.length != 1) return null;
    final row = rows.single;
    final issued = DateTime.parse(row['issued_at'] as String).toUtc();
    final expires = DateTime.parse(row['expires_at'] as String).toUtc();
    final current = now.toUtc();
    if (current.isBefore(issued) || !current.isBefore(expires)) return null;
    final capabilitiesRaw = jsonDecode(row['capabilities_json'] as String);
    if (capabilitiesRaw is! List || capabilitiesRaw.any((e) => e is! String)) {
      throw const FormatException(
        'Stored v2 device capabilities are malformed',
      );
    }
    return LoomStoredAuthorizedDeviceV2(
      accountId: accountId,
      deviceId: deviceId,
      deviceKeyVersion: deviceKeyVersion,
      signingPublicKey: row['signing_public_key'] as Uint8List,
      agreementPublicKey: row['agreement_public_key'] as Uint8List,
      issuedAt: issued,
      expiresAt: expires,
      capabilities: capabilitiesRaw.cast<String>(),
    );
  }

  @override
  Future<LoomAuthorizedDeviceSigningKey?> resolveAuthorizedSigningKey({
    required String accountId,
    required String deviceId,
    required int deviceKeyVersion,
    required DateTime now,
  }) async {
    final device = resolveDevice(
      accountId: accountId,
      deviceId: deviceId,
      deviceKeyVersion: deviceKeyVersion,
      now: now,
    );
    if (device == null) return null;
    return LoomAuthorizedDeviceSigningKey(
      accountId: accountId,
      deviceId: deviceId,
      deviceKeyVersion: deviceKeyVersion,
      ed25519PublicKey: device.signingPublicKey,
    );
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _db.dispose();
  }

  void _requireOpen() {
    if (_closed) throw StateError('Device-directory store is closed');
  }
}

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var difference = 0;
  for (var i = 0; i < a.length; i += 1) {
    difference |= a[i] ^ b[i];
  }
  return difference == 0;
}

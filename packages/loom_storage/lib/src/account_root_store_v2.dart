import 'dart:io';
import 'dart:typed_data';

import 'package:loom_identity/loom_identity.dart';
import 'package:sqlite3/sqlite3.dart';

/// Durable local trust anchor store for Architecture-v2 account signing roots.
///
/// A Delivery Service or directory response is never allowed to call [pinRoot]
/// implicitly. Product identity/recovery code must explicitly pin a root after
/// authenticating it through the account bootstrap/recovery ceremony.
final class LoomAccountRootStoreV2 implements LoomTrustedAccountRootResolverV2 {
  LoomAccountRootStoreV2._(this._db) {
    _db.execute('PRAGMA journal_mode = WAL');
    _db.execute('PRAGMA synchronous = FULL');
    _db.execute('PRAGMA busy_timeout = 5000');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS trusted_account_roots_v2 (
        account_id TEXT NOT NULL,
        key_version INTEGER NOT NULL CHECK(key_version >= 1),
        public_key BLOB NOT NULL,
        valid_from TEXT NOT NULL,
        valid_until TEXT,
        pinned_at TEXT NOT NULL,
        PRIMARY KEY(account_id, key_version)
      )
    ''');
  }

  final Database _db;
  bool _closed = false;

  static LoomAccountRootStoreV2 openFile(String path) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    return LoomAccountRootStoreV2._(sqlite3.open(path));
  }

  static LoomAccountRootStoreV2 openInMemory() =>
      LoomAccountRootStoreV2._(sqlite3.openInMemory());

  /// Pins one already-authenticated root key version. Exact repetition is
  /// idempotent; rebinding the same `(AccountId, version)` to different key or
  /// validity data fails closed.
  void pinRoot(LoomTrustedAccountRootKeyV2 root, {required DateTime now}) {
    _requireOpen();
    final rows = _db.select(
      '''SELECT public_key, valid_from, valid_until
         FROM trusted_account_roots_v2
         WHERE account_id = ? AND key_version = ? LIMIT 1''',
      <Object?>[root.accountId.value, root.accountKeyVersion],
    );
    final validFrom = root.validFrom.toUtc().toIso8601String();
    final validUntil = root.validUntil?.toUtc().toIso8601String();
    if (rows.isNotEmpty) {
      final existing = rows.first;
      final key = Uint8List.fromList(existing['public_key'] as List<int>);
      if (!_sameBytes(key, root.ed25519PublicKey) ||
          existing['valid_from'] != validFrom ||
          existing['valid_until'] != validUntil) {
        throw StateError(
          'Trusted account root version cannot be rebound to different material',
        );
      }
      return;
    }
    _db.execute(
      '''INSERT INTO trusted_account_roots_v2(
           account_id, key_version, public_key, valid_from, valid_until, pinned_at
         ) VALUES (?, ?, ?, ?, ?, ?)''',
      <Object?>[
        root.accountId.value,
        root.accountKeyVersion,
        root.ed25519PublicKey,
        validFrom,
        validUntil,
        now.toUtc().toIso8601String(),
      ],
    );
  }

  @override
  Future<LoomTrustedAccountRootKeyV2?> resolveTrustedAccountRoot({
    required LoomAccountId accountId,
    required int accountKeyVersion,
    required DateTime now,
  }) async {
    _requireOpen();
    if (accountKeyVersion < 1) return null;
    final rows = _db.select(
      '''SELECT public_key, valid_from, valid_until
         FROM trusted_account_roots_v2
         WHERE account_id = ? AND key_version = ? LIMIT 1''',
      <Object?>[accountId.value, accountKeyVersion],
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    final key = Uint8List.fromList(row['public_key'] as List<int>);
    if (key.length != 32) return null;
    final validFrom = DateTime.tryParse(row['valid_from'] as String)?.toUtc();
    final validUntilRaw = row['valid_until'] as String?;
    final validUntil =
        validUntilRaw == null
            ? null
            : DateTime.tryParse(validUntilRaw)?.toUtc();
    if (validFrom == null || (validUntilRaw != null && validUntil == null)) {
      return null;
    }
    final root = LoomTrustedAccountRootKeyV2(
      accountId: accountId,
      accountKeyVersion: accountKeyVersion,
      ed25519PublicKey: key,
      validFrom: validFrom,
      validUntil: validUntil,
    );
    return root.isValidAt(now) ? root : null;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _db.dispose();
  }

  void _requireOpen() {
    if (_closed) throw StateError('LoomAccountRootStoreV2 is closed');
  }

  static bool _sameBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}

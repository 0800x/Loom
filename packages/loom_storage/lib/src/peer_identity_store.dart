import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

enum LoomPeerIdentityObservation { firstSeen, unchanged, changed }

class LoomPeerIdentityPin {
  const LoomPeerIdentityPin({
    required this.address,
    required this.identityId,
    required this.publicKey,
    required this.fingerprint,
    required this.firstSeenAt,
    required this.lastSeenAt,
  });

  final String address;
  final String identityId;
  final String publicKey;
  final String fingerprint;
  final DateTime firstSeenAt;
  final DateTime lastSeenAt;
}

/// TOFU pin for address -> long-term user identity.
///
/// A Node can route and authenticate a fresh lookup, but once an address has
/// been observed this store refuses to silently replace its identity key. Key
/// replacement requires an explicit future verification/recovery flow.
class LoomPeerIdentityStore {
  LoomPeerIdentityStore._(this._db) {
    _db.execute('PRAGMA journal_mode = WAL');
    _db.execute('PRAGMA synchronous = NORMAL');
    _db.execute('PRAGMA busy_timeout = 5000');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS peer_identity_pins (
        address TEXT PRIMARY KEY COLLATE NOCASE,
        identity_id TEXT NOT NULL,
        public_key TEXT NOT NULL,
        fingerprint TEXT NOT NULL,
        first_seen_at TEXT NOT NULL,
        last_seen_at TEXT NOT NULL
      )
    ''');
  }

  final Database _db;
  bool _closed = false;

  static LoomPeerIdentityStore openFile(String path) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    return LoomPeerIdentityStore._(sqlite3.open(path));
  }

  static LoomPeerIdentityStore openInMemory() =>
      LoomPeerIdentityStore._(sqlite3.openInMemory());

  LoomPeerIdentityObservation observe({
    required String address,
    required String identityId,
    required String publicKey,
    required String fingerprint,
    required DateTime observedAt,
  }) {
    _requireOpen();
    final normalized = _normalizeAddress(address);
    final now = observedAt.toUtc().toIso8601String();
    final rows = _db.select(
      'SELECT identity_id, public_key, fingerprint FROM peer_identity_pins WHERE address = ?',
      <Object?>[normalized],
    );
    if (rows.isEmpty) {
      _db.execute(
        '''INSERT INTO peer_identity_pins
           (address, identity_id, public_key, fingerprint, first_seen_at, last_seen_at)
           VALUES (?, ?, ?, ?, ?, ?)''',
        <Object?>[normalized, identityId, publicKey, fingerprint, now, now],
      );
      return LoomPeerIdentityObservation.firstSeen;
    }
    final row = rows.first;
    if (row['identity_id'] != identityId ||
        row['public_key'] != publicKey ||
        row['fingerprint'] != fingerprint) {
      return LoomPeerIdentityObservation.changed;
    }
    _db.execute(
      'UPDATE peer_identity_pins SET last_seen_at = ? WHERE address = ?',
      <Object?>[now, normalized],
    );
    return LoomPeerIdentityObservation.unchanged;
  }

  LoomPeerIdentityPin? pinForAddress(String address) {
    _requireOpen();
    final rows = _db.select(
      'SELECT * FROM peer_identity_pins WHERE address = ?',
      <Object?>[_normalizeAddress(address)],
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return LoomPeerIdentityPin(
      address: row['address'] as String,
      identityId: row['identity_id'] as String,
      publicKey: row['public_key'] as String,
      fingerprint: row['fingerprint'] as String,
      firstSeenAt: DateTime.parse(row['first_seen_at'] as String).toUtc(),
      lastSeenAt: DateTime.parse(row['last_seen_at'] as String).toUtc(),
    );
  }

  /// Resolve only previously pinned account roots; invitations cannot add trust.
  LoomPeerIdentityPin? pinForIdentity(String identityId) {
    _requireOpen();
    final rows = _db.select(
      'SELECT address FROM peer_identity_pins WHERE identity_id = ? ORDER BY address LIMIT 1',
      [identityId],
    );
    return rows.isEmpty ? null : pinForAddress(rows.first['address'] as String);
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _db.dispose();
  }

  String _normalizeAddress(String value) {
    final address = value.trim().toLowerCase();
    if (address.length < 5 ||
        address.length > 512 ||
        !address.startsWith('@') ||
        address.indexOf(':', 1) < 2 ||
        address.contains(RegExp(r'[\r\n\s]'))) {
      throw const FormatException('Invalid Loom peer address');
    }
    return address;
  }

  void _requireOpen() {
    if (_closed) throw StateError('Peer identity store is closed');
  }
}

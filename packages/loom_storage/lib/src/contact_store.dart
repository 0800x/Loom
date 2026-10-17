import 'dart:io';

import 'package:loom_models/loom_models.dart';
import 'package:sqlite3/sqlite3.dart';

class LoomContactStore {
  LoomContactStore._(this._db);

  final Database _db;
  bool _closed = false;

  static LoomContactStore openFile(String path) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    final store = LoomContactStore._(sqlite3.open(path));
    store._configure();
    store._migrate();
    return store;
  }

  static LoomContactStore openInMemory() {
    final store = LoomContactStore._(sqlite3.openInMemory());
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
    final version = _db.select('PRAGMA user_version').first.values.first as int;
    if (version > 1) {
      throw StateError(
        'Loom contacts schema $version is newer than supported schema 1',
      );
    }
    if (version != 0) return;
    _db.execute('BEGIN IMMEDIATE');
    try {
      _db.execute('''
        CREATE TABLE contacts (
          canonical_address TEXT PRIMARY KEY COLLATE NOCASE,
          identity_id TEXT NOT NULL,
          account_id TEXT,
          username TEXT NOT NULL,
          display_name TEXT NOT NULL,
          home_node TEXT NOT NULL,
          security_state TEXT NOT NULL,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          last_resolved_at TEXT NOT NULL
        )
      ''');
      _db.execute(
        'CREATE INDEX idx_contacts_display_name ON contacts(display_name COLLATE NOCASE)',
      );
      _db.execute(
        'CREATE INDEX idx_contacts_username ON contacts(username COLLATE NOCASE)',
      );
      _db.execute('PRAGMA user_version = 1');
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  void upsert(LoomContact contact) {
    _requireOpen();
    _db.execute(
      '''
      INSERT INTO contacts (
        canonical_address, identity_id, account_id, username, display_name,
        home_node, security_state, created_at, updated_at, last_resolved_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(canonical_address) DO UPDATE SET
        identity_id=excluded.identity_id,
        account_id=COALESCE(excluded.account_id, contacts.account_id),
        username=excluded.username,
        display_name=excluded.display_name,
        home_node=excluded.home_node,
        security_state=excluded.security_state,
        updated_at=excluded.updated_at,
        last_resolved_at=excluded.last_resolved_at
      ''',
      [
        contact.canonicalAddress,
        contact.identityId,
        contact.accountId,
        contact.username,
        contact.displayName,
        contact.homeNode,
        contact.securityState.name,
        contact.createdAt.toUtc().toIso8601String(),
        contact.updatedAt.toUtc().toIso8601String(),
        contact.lastResolvedAt.toUtc().toIso8601String(),
      ],
    );
  }

  List<LoomContact> list({int limit = 500}) {
    _requireOpen();
    if (limit < 1 || limit > 1000) throw ArgumentError.value(limit, 'limit');
    final rows = _db.select(
      '''SELECT * FROM contacts
         ORDER BY display_name COLLATE NOCASE, username COLLATE NOCASE
         LIMIT ?''',
      [limit],
    );
    return rows.map(_fromRow).toList(growable: false);
  }

  LoomContact? findByAddress(String canonicalAddress) {
    _requireOpen();
    final rows = _db.select(
      'SELECT * FROM contacts WHERE canonical_address = ? COLLATE NOCASE LIMIT 1',
      [canonicalAddress],
    );
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  void delete(String canonicalAddress) {
    _requireOpen();
    _db.execute(
      'DELETE FROM contacts WHERE canonical_address = ? COLLATE NOCASE',
      [canonicalAddress],
    );
  }

  LoomContact _fromRow(Row row) => LoomContact(
    identityId: row['identity_id'] as String,
    accountId: row['account_id'] as String?,
    username: row['username'] as String,
    displayName: row['display_name'] as String,
    canonicalAddress: row['canonical_address'] as String,
    homeNode: row['home_node'] as String,
    securityState: LoomContactSecurityState.values.byName(
      row['security_state'] as String,
    ),
    createdAt: DateTime.parse(row['created_at'] as String).toUtc(),
    updatedAt: DateTime.parse(row['updated_at'] as String).toUtc(),
    lastResolvedAt: DateTime.parse(row['last_resolved_at'] as String).toUtc(),
  );

  void close() {
    if (_closed) return;
    _closed = true;
    _db.dispose();
  }

  void _requireOpen() {
    if (_closed) throw StateError('LoomContactStore is closed');
  }
}

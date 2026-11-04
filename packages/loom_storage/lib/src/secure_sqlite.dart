import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

/// Applies SQLCipher before SQLite touches a database page.
///
/// The app loads the random database key from platform secure storage and
/// configures this boundary before opening the first messaging database.
abstract final class LoomSqliteEncryption {
  static String? _keyHex;
  static bool _required = false;

  static bool get configured => _keyHex != null;
  static bool get requireCipher => _required;
  static String? get keyHex => _keyHex;

  static void disable() {
    _keyHex = null;
    _required = false;
  }

  static void configureKey(
    String encodedKey, {
    required bool requireCipher,
  }) {
    final normalized = base64Url.normalize(encodedKey);
    final bytes = base64Url.decode(normalized);
    if (bytes.length != 32) {
      throw const FormatException('The SQLCipher key must contain 256 bits');
    }
    _keyHex = bytes
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
    _required = requireCipher;
    bytes.fillRange(0, bytes.length, 0);
  }

  /// Refuses to open a file when encryption is required but no key is loaded.
  static void assertOpenable(String path) {
    if (_required && _keyHex == null) {
      throw StateError(
        'The encrypted Loom database key is unavailable; refusing plaintext fallback',
      );
    }
  }

  /// Must be the first database operation after sqlite3.open().
  static void attachKey(Database database) {
    final key = _keyHex;
    if (key == null) {
      if (_required) {
        throw StateError('SQLCipher is required but no database key is loaded');
      }
      return;
    }
    database.execute("PRAGMA key = 'x''$key'''");
    database.execute('PRAGMA cipher_memory_security = ON');
  }

  /// Confirms that this connection is using SQLCipher and that the key opens
  /// the schema. A plain SQLite build or a wrong key fails closed.
  static void verify(Database database) {
    final key = _keyHex;
    if (key == null) {
      if (_required) {
        throw StateError('SQLCipher is required but no database key is loaded');
      }
      return;
    }
    final cipherVersion = database.select('PRAGMA cipher_version');
    if (cipherVersion.isEmpty ||
        cipherVersion.first.values.isEmpty ||
        cipherVersion.first.values.first.toString().trim().isEmpty) {
      throw StateError('The loaded SQLite engine does not provide SQLCipher');
    }
    database.select('SELECT count(*) FROM sqlite_master');
  }

  /// SQL string literal helper for the legacy-database migration path.
  static String quoteLiteral(String value) =>
      "'" + value.replaceAll("'", "''") + "'";
}

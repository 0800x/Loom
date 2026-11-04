import 'dart:io';

import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:sqlcipher_flutter_libs/sqlcipher_flutter_libs.dart';

/// Loads SQLCipher before any package opens a database.
abstract final class LoomSqlCipherLoader {
  static Future<void> prepare() async {
    if (Platform.isAndroid) {
      // Load the Android SQLCipher library before Dart FFI resolves sqlite3.
      await applyWorkaroundToOpenSqlCipherOnOldAndroidVersions();
      open.overrideFor(OperatingSystem.android, openCipherOnAndroid);
    }

    final database = sqlite3.openInMemory();
    try {
      final rows = database.select('PRAGMA cipher_version');
      if (rows.isEmpty ||
          rows.first.values.isEmpty ||
          rows.first.values.first.toString().trim().isEmpty) {
        throw StateError('The native SQLite engine is not SQLCipher');
      }
    } finally {
      database.dispose();
    }
  }
}

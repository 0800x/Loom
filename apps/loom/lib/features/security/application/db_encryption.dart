import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:loom_crypto_bridge/loom_crypto_bridge.dart';
import 'package:loom_storage/loom_storage.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../accounts/application/account_workspace.dart';
import 'sqlcipher_loader.dart';

/// One-way opt-in SQLCipher protection for the local messaging database.
///
/// The key and consent flag are kept in Loom's scoped secure storage. Existing
/// plaintext databases are migrated on a cold start before the messaging store
/// is opened. A failed migration leaves the original database untouched.
abstract final class LoomDbEncryption {
  static const _enabledKey = 'loom.local_database_encryption.enabled.v1';
  static const _databaseKey = 'loom.local_database_encryption.key.v1';
  static const _databaseFile = 'loom-messages-v1.sqlite3';
  static final LoomSecretStorage _secrets = LoomSecretStorage();

  static Future<bool> preferenceEnabled() async {
    return await _secrets.read(key: _enabledKey) == 'true';
  }

  /// Schedules encryption for the next startup. Once enabled, this is a
  /// deliberate one-way choice because disabling it would require a reverse
  /// plaintext migration and could expose message history.
  static Future<String?> setEnabled(bool value) async {
    try {
      final currentlyEnabled = await preferenceEnabled();
      if (!value && currentlyEnabled) {
        return 'Local database encryption is a one-way opt-in and cannot be disabled from this screen.';
      }
      if (!value) return null;

      var key = await _secrets.read(key: _databaseKey);
      if (key == null) {
        final bytes = List<int>.generate(
          32,
          (_) => Random.secure().nextInt(256),
        );
        try {
          key = base64UrlEncode(bytes);
          await _secrets.write(key: _databaseKey, value: key);
        } finally {
          bytes.fillRange(0, bytes.length, 0);
        }
      }
      _validateKey(key);
      await _secrets.write(key: _enabledKey, value: 'true');
      return null;
    } catch (_) {
      return 'Could not securely store the database-encryption preference. No database was changed.';
    }
  }

  /// Loads the active account key and migrates its messaging database before
  /// any messaging/call controller opens a database connection.
  static Future<void> prepareAtStartup() async {
    // Never let a previous account's process-global SQLCipher key leak into
    // the next account when preferences or secure storage reads fail.
    LoomSqliteEncryption.disable();
    final enabled = await preferenceEnabled();
    if (!enabled) return;

    await LoomSqlCipherLoader.prepare();
    final encodedKey = await _secrets.read(key: _databaseKey);
    if (encodedKey == null) {
      throw StateError(
        'SQLCipher is enabled but the account database key is unavailable',
      );
    }
    _validateKey(encodedKey);
    LoomSqliteEncryption.configureKey(encodedKey, requireCipher: true);

    final workspace = await LoomAccountWorkspace.active();
    final path = workspace.path + Platform.pathSeparator + _databaseFile;
    await _migratePlaintextDatabase(path);
  }

  static void _validateKey(String encodedKey) {
    final decoded = base64Url.decode(base64Url.normalize(encodedKey));
    if (decoded.length != 32) {
      throw const FormatException('Invalid SQLCipher key material');
    }
    decoded.fillRange(0, decoded.length, 0);
  }

  static Future<void> _migratePlaintextDatabase(String path) async {
    final source = File(path);
    final backup = File(path + '.plaintext-migration-backup');

    // Recover an interrupted rename before attempting another migration.
    if (await backup.exists() && !await source.exists()) {
      await backup.rename(path);
    }
    if (!await source.exists()) return;

    // First try the configured key. A successful schema read means this is
    // already a SQLCipher database for the active account. If a backup remains
    // from a process interruption after the final rename, it is now safe to
    // remove because the canonical encrypted database was verified.
    try {
      final encrypted = sqlite3.open(path);
      try {
        LoomSqliteEncryption.attachKey(encrypted);
        LoomSqliteEncryption.verify(encrypted);
        if (await backup.exists()) await backup.delete();
        return;
      } finally {
        encrypted.dispose();
      }
    } catch (_) {
      // Distinguish a legacy plaintext database from a database encrypted with
      // a different key. Only the former is eligible for automatic migration.
    }

    final temporaryPath = path + '.sqlcipher-migration.tmp';
    final temporary = File(temporaryPath);
    if (await temporary.exists()) await temporary.delete();

    final plain = sqlite3.open(path);
    try {
      // This read is the discriminator. An encrypted database with a wrong
      // key cannot be treated as plaintext and is never overwritten.
      plain.select('SELECT count(*) FROM sqlite_master');
      final keyHex = LoomSqliteEncryption.keyHex;
      if (keyHex == null) {
        throw StateError('SQLCipher key was not configured');
      }
      final escapedPath = LoomSqliteEncryption.quoteLiteral(temporaryPath);
      final escapedKey = ("x'" + keyHex + "'").replaceAll("'", "''");
      plain.execute(
        'ATTACH DATABASE $escapedPath AS loom_encrypted KEY \'$escapedKey\'',
      );
      try {
        plain.select("SELECT sqlcipher_export('loom_encrypted')");
      } finally {
        plain.execute('DETACH DATABASE loom_encrypted');
      }
    } catch (_) {
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    } finally {
      plain.dispose();
    }

    // Verify the exported database before replacing the original file.
    final verification = sqlite3.open(temporaryPath);
    try {
      LoomSqliteEncryption.attachKey(verification);
      LoomSqliteEncryption.verify(verification);
    } catch (_) {
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    } finally {
      verification.dispose();
    }

    final backupPath = backup.path;
    if (await backup.exists()) {
      throw StateError(
        'A previous SQLCipher migration backup exists and needs recovery',
      );
    }

    await source.rename(backupPath);
    try {
      await temporary.rename(path);
      // The original is removed only after the encrypted copy was verified
      // and moved into the canonical path.
      await backup.delete();
    } catch (_) {
      final installed = File(path);
      if (await installed.exists()) await installed.delete();
      if (await backup.exists()) await backup.rename(path);
      rethrow;
    }
  }
}

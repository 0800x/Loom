import 'dart:convert';

import 'package:loom_storage/loom_storage.dart';
import 'package:test/test.dart';

void main() {
  tearDown(LoomSqliteEncryption.disable);

  test('unconfigured databases keep legacy SQLite behavior', () {
    LoomSqliteEncryption.disable();

    expect(LoomSqliteEncryption.configured, isFalse);
    expect(LoomSqliteEncryption.requireCipher, isFalse);
    expect(() => LoomSqliteEncryption.assertOpenable('legacy.sqlite3'), returnsNormally);
  });

  test('configured key requires SQLCipher and a secure key', () {
    final key = base64UrlEncode(List<int>.filled(32, 0x5a));

    LoomSqliteEncryption.configureKey(key, requireCipher: true);

    expect(LoomSqliteEncryption.configured, isTrue);
    expect(LoomSqliteEncryption.requireCipher, isTrue);
    expect(LoomSqliteEncryption.keyHex, hasLength(64));
    expect(() => LoomSqliteEncryption.assertOpenable('messages.sqlite3'), returnsNormally);
  });

  test('rejects keys that are not exactly 256 bits', () {
    final shortKey = base64UrlEncode(List<int>.filled(31, 0x5a));

    expect(
      () => LoomSqliteEncryption.configureKey(shortKey, requireCipher: true),
      throwsFormatException,
    );
    expect(LoomSqliteEncryption.configured, isFalse);
  });
}

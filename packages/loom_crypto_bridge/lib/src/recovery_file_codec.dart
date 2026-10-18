import 'dart:convert';
import 'dart:typed_data';

import 'package:bip39_mnemonic/bip39_mnemonic.dart';
import 'package:cryptography/cryptography.dart';
import 'package:cryptography/helpers.dart' show randomBytes;

class LoomRecoveryFileCodec {
  LoomRecoveryFileCodec({
    this.memoryKiB = 19456,
    this.iterations = 2,
    this.parallelism = 1,
  });

  static const String format = 'Loom-Recovery-v1';
  final int memoryKiB;
  final int iterations;
  final int parallelism;

  Argon2id get _kdf => Argon2id(
    memory: memoryKiB,
    iterations: iterations,
    parallelism: parallelism,
    hashLength: 32,
  );
  final AesGcm _cipher = AesGcm.with256bits();

  Future<Uint8List> encryptWords({
    required List<String> words,
    required String password,
  }) async {
    if (password.length < 12) {
      throw ArgumentError.value(
        password,
        'password',
        'must be at least 12 characters',
      );
    }
    final mnemonic = Mnemonic.fromWords(
      words: words,
      language: Language.english,
    );
    if (mnemonic.entropy.length != 32) {
      throw const FormatException('Loom Recovery v1 requires a 24-word phrase');
    }
    final salt = randomBytes(16);
    final key = await _kdf.deriveKeyFromPassword(
      password: password,
      nonce: salt,
    );
    try {
      final box = await _cipher.encrypt(
        mnemonic.entropy,
        secretKey: key,
        aad: utf8.encode(format),
      );
      final document = <String, Object?>{
        'format': format,
        'kdf': {
          'name': 'argon2id',
          'memoryKiB': memoryKiB,
          'iterations': iterations,
          'parallelism': parallelism,
          'salt': base64Encode(salt),
        },
        'cipher': {
          'name': 'AES-256-GCM',
          'box': base64Encode(box.concatenation()),
        },
      };
      return Uint8List.fromList(utf8.encode(jsonEncode(document)));
    } finally {
      key.destroy();
      salt.fillRange(0, salt.length, 0);
    }
  }

  Future<List<String>> decryptWords({
    required List<int> fileBytes,
    required String password,
  }) async {
    if (fileBytes.length > 64 * 1024) {
      throw const FormatException('Recovery file exceeds size limit');
    }
    final decoded = jsonDecode(utf8.decode(fileBytes));
    if (decoded is! Map<String, Object?> || decoded['format'] != format) {
      throw const FormatException('Unsupported recovery file');
    }
    final kdfJson = decoded['kdf'];
    final cipherJson = decoded['cipher'];
    if (kdfJson is! Map<String, Object?> ||
        cipherJson is! Map<String, Object?>) {
      throw const FormatException('Malformed recovery file');
    }
    if (kdfJson['name'] != 'argon2id' || cipherJson['name'] != 'AES-256-GCM') {
      throw const FormatException('Unsupported recovery algorithms');
    }
    final fileMemory = kdfJson['memoryKiB'];
    final fileIterations = kdfJson['iterations'];
    final fileParallelism = kdfJson['parallelism'];
    if (fileMemory is! int ||
        fileIterations is! int ||
        fileParallelism is! int) {
      throw const FormatException('Invalid recovery KDF parameters');
    }
    if (fileMemory < 1024 ||
        fileMemory > 262144 ||
        fileIterations < 1 ||
        fileIterations > 10 ||
        fileParallelism < 1 ||
        fileParallelism > 4) {
      throw const FormatException(
        'Recovery KDF parameters are outside accepted bounds',
      );
    }
    final saltRaw = kdfJson['salt'];
    final boxRaw = cipherJson['box'];
    if (saltRaw is! String || boxRaw is! String) {
      throw const FormatException('Malformed recovery payload');
    }
    final salt = base64Decode(saltRaw);
    final boxBytes = base64Decode(boxRaw);
    if (salt.length != 16) throw const FormatException('Invalid recovery salt');
    final fileKdf = Argon2id(
      memory: fileMemory,
      iterations: fileIterations,
      parallelism: fileParallelism,
      hashLength: 32,
    );
    final key = await fileKdf.deriveKeyFromPassword(
      password: password,
      nonce: salt,
    );
    try {
      final box = SecretBox.fromConcatenation(
        boxBytes,
        nonceLength: _cipher.nonceLength,
        macLength: _cipher.macAlgorithm.macLength,
      );
      final entropy = await _cipher.decrypt(
        box,
        secretKey: key,
        aad: utf8.encode(format),
      );
      if (entropy.length != 32) {
        throw const FormatException('Invalid recovery entropy length');
      }
      return List<String>.unmodifiable(
        Mnemonic(entropy, Language.english).words,
      );
    } on SecretBoxAuthenticationError catch (_) {
      throw const FormatException(
        'Recovery password is incorrect or file authentication failed',
      );
    } finally {
      key.destroy();
      salt.fillRange(0, salt.length, 0);
    }
  }
}

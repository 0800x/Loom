import 'app_lock.dart';

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'identity_core.dart';

typedef LoomRecoveryEntropyProvider = Future<List<int>> Function();

/// Encrypts the account's private Saved Messages conversation.
///
/// The key is derived from the recovery entropy, so the same identity can open
/// its Saved Messages after a verified recovery. The Home Node only receives
/// the opaque authenticated-encryption envelope.
class LoomSelfMessageCodec {
  LoomSelfMessageCodec({
    FlutterSecureStorage? storage,
    LoomRecoveryEntropyProvider? recoveryEntropyProvider,
    AesGcm? cipher,
    Hkdf? kdf,
    Random? random,
  })  : _storage = LoomSecretStorage(storage),
        _recoveryEntropyProvider = recoveryEntropyProvider,
        _cipher = cipher ?? AesGcm.with256bits(),
        _kdf = kdf ?? Hkdf(hmac: Hmac.sha256(), outputLength: 32),
        _random = random ?? Random.secure();

  static const protocolVersion = 'loom-self-message-v1';

  final LoomSecretStorage _storage;
  final LoomRecoveryEntropyProvider? _recoveryEntropyProvider;
  final AesGcm _cipher;
  final Hkdf _kdf;
  final Random _random;

  Future<String> encryptText({
    required String identityId,
    required String conversationId,
    required String plaintext,
  }) async {
    final clear = utf8.encode(plaintext);
    if (clear.isEmpty || clear.length > 128 * 1024) {
      throw ArgumentError.value(
        clear.length,
        'plaintext',
        'Saved Message must be 1..131072 UTF-8 bytes',
      );
    }
    final material = await _material(identityId, conversationId);
    final nonce = Uint8List.fromList(
      List<int>.generate(12, (_) => _random.nextInt(256)),
    );
    try {
      final box = await _cipher.encrypt(
        clear,
        secretKey: material.key,
        nonce: nonce,
        aad: material.aad,
      );
      return jsonEncode({
        'v': 1,
        'nonce': base64Encode(nonce),
        'ciphertext': base64Encode(box.cipherText),
        'mac': base64Encode(box.mac.bytes),
      });
    } finally {
      nonce.fillRange(0, nonce.length, 0);
      material.key.destroy();
    }
  }

  Future<String> decryptText({
    required String identityId,
    required String conversationId,
    required String envelope,
  }) async {
    final decoded = jsonDecode(envelope);
    if (decoded is! Map<String, Object?> || decoded['v'] != 1) {
      throw const FormatException('Unsupported Saved Message envelope');
    }
    final nonce = _bytes(decoded, 'nonce', expectedLength: 12);
    final ciphertext = _bytes(decoded, 'ciphertext');
    final mac = _bytes(decoded, 'mac', expectedLength: 16);
    final material = await _material(identityId, conversationId);
    try {
      final clear = await _cipher.decrypt(
        SecretBox(ciphertext, nonce: nonce, mac: Mac(mac)),
        secretKey: material.key,
        aad: material.aad,
      );
      return utf8.decode(clear);
    } on SecretBoxAuthenticationError {
      throw const FormatException('Saved Message authentication failed');
    } finally {
      material.key.destroy();
    }
  }

  Future<_SelfMessageMaterial> _material(
    String identityId,
    String conversationId,
  ) async {
    if (identityId.trim().isEmpty || conversationId.trim().isEmpty) {
      throw ArgumentError('Identity and conversation identifiers are required');
    }
    final entropy = Uint8List.fromList(await _readRecoveryEntropy());
    if (entropy.length != 32) {
      entropy.fillRange(0, entropy.length, 0);
      throw const FormatException('Stored Loom recovery entropy is invalid');
    }
    final root = SecretKey(entropy);
    final aad = utf8.encode('$protocolVersion\n$identityId\n$conversationId');
    try {
      final key = await _kdf.deriveKey(
        secretKey: root,
        nonce: utf8.encode('Loom-Self-Message-KDF-v1'),
        info: aad,
      );
      return _SelfMessageMaterial(key, aad);
    } finally {
      entropy.fillRange(0, entropy.length, 0);
      root.destroy();
    }
  }

  Future<List<int>> _readRecoveryEntropy() async {
    final provider = _recoveryEntropyProvider;
    if (provider != null) {
      return provider();
    }
    final encoded = await _storage.read(
      key: LoomIdentityCoreV1.recoveryEntropyStorageKey,
    );
    if (encoded == null) {
      throw StateError('Committed Loom recovery material is unavailable');
    }
    try {
      return base64Decode(encoded);
    } on FormatException {
      throw const FormatException('Stored Loom recovery entropy is invalid');
    }
  }

  List<int> _bytes(
    Map<String, Object?> json,
    String key, {
    int? expectedLength,
  }) {
    final value = json[key];
    if (value is! String) {
      throw FormatException('Missing envelope field: $key');
    }
    final bytes = base64Decode(value);
    if (expectedLength != null && bytes.length != expectedLength) {
      throw FormatException('Invalid envelope field: $key');
    }
    return bytes;
  }
}

class _SelfMessageMaterial {
  const _SelfMessageMaterial(this.key, this.aad);

  final SecretKey key;
  final List<int> aad;
}

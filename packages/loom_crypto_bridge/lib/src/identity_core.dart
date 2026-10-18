import 'app_lock.dart';

import 'dart:convert';
import 'dart:typed_data';

import 'package:bip39_mnemonic/bip39_mnemonic.dart';
import 'package:loom_models/loom_models.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract interface class LoomIdentitySigner {
  Future<List<int>> signIdentityBinding(List<int> payload);
}

abstract interface class LoomIdentityCore implements LoomIdentitySigner {
  Future<LoomPendingIdentity> createIdentity();
  Future<void> commitPendingIdentity(LoomPendingIdentity pending);
  Future<LoomPendingIdentity> restoreIdentityFromWords(List<String> words);
  Future<LoomIdentityPublic?> readIdentity();
  Future<List<int>> exportRecoveryEntropy();
  Future<LoomIdentityPublic> importRecoveryEntropy(List<int> entropy);
  Future<void> clearIdentity();
  void discardPendingIdentity();

  @override
  Future<List<int>> signIdentityBinding(List<int> payload);
}

class LoomIdentityCoreV1 implements LoomIdentityCore {
  LoomIdentityCoreV1({FlutterSecureStorage? storage})
    : _storage = LoomSecretStorage(storage);

  static const _privateKeyKey = 'loom.identity.ed25519.private.v1';
  static const _publicKeyKey = 'loom.identity.ed25519.public.v1';
  static const _identityIdKey = 'loom.identity.id.v1';
  static const _fingerprintKey = 'loom.identity.fingerprint.v1';
  static const _createdAtKey = 'loom.identity.created_at.v1';
  static const recoveryEntropyStorageKey = 'loom.recovery.entropy.v1';

  final LoomSecretStorage _storage;
  final Ed25519 _ed25519 = Ed25519();
  final Sha256 _sha256 = Sha256();

  @override
  Future<LoomPendingIdentity> createIdentity() async {
    final mnemonic = Mnemonic.generate(
      Language.english,
      length: MnemonicLength.words24,
    );
    final recoveryEntropy = Uint8List.fromList(mnemonic.entropy);
    final derived = await _deriveIdentity(recoveryEntropy);
    try {
      _pendingPrivate = Uint8List.fromList(derived.privateKey);
      _pendingRecoveryEntropy = recoveryEntropy;
      return LoomPendingIdentity(
        identity: derived.identity,
        recovery: LoomRecoveryMaterial(
          mnemonicWords: mnemonic.words,
          recoveryId: _base64UrlNoPadding(
            (await _sha256.hash(recoveryEntropy)).bytes,
          ).substring(0, 16),
        ),
      );
    } finally {
      derived.privateKey.fillRange(0, derived.privateKey.length, 0);
    }
  }

  Uint8List? _pendingPrivate;
  Uint8List? _pendingRecoveryEntropy;

  @override
  Future<LoomPendingIdentity> restoreIdentityFromWords(
    List<String> words,
  ) async {
    final mnemonic = Mnemonic.fromWords(
      words: words,
      language: Language.english,
    );
    final recoveryEntropy = Uint8List.fromList(mnemonic.entropy);
    if (recoveryEntropy.length != 32) {
      throw const FormatException(
        'Loom Identity v1 requires a 24-word recovery phrase',
      );
    }
    final derived = await _deriveIdentity(recoveryEntropy);
    try {
      final pending = LoomPendingIdentity(
        identity: derived.identity,
        recovery: LoomRecoveryMaterial(
          mnemonicWords: List<String>.unmodifiable(
            words.map((w) => w.trim().toLowerCase()),
          ),
          recoveryId: _base64UrlNoPadding(
            (await _sha256.hash(recoveryEntropy)).bytes,
          ).substring(0, 16),
        ),
      );
      _pendingPrivate = Uint8List.fromList(derived.privateKey);
      _pendingRecoveryEntropy = recoveryEntropy;
      return pending;
    } finally {
      derived.privateKey.fillRange(0, derived.privateKey.length, 0);
    }
  }

  @override
  Future<void> commitPendingIdentity(LoomPendingIdentity pending) async {
    final privateKey = _pendingPrivate;
    final recoveryEntropy = _pendingRecoveryEntropy;
    if (privateKey == null || recoveryEntropy == null) {
      throw StateError('No pending identity material exists in this process');
    }
    await _writeIdentity(
      identity: pending.identity,
      privateKey: privateKey,
      recoveryEntropy: recoveryEntropy,
    );
    privateKey.fillRange(0, privateKey.length, 0);
    recoveryEntropy.fillRange(0, recoveryEntropy.length, 0);
    _pendingPrivate = null;
    _pendingRecoveryEntropy = null;
  }

  @override
  Future<LoomIdentityPublic?> readIdentity() async {
    final values = await Future.wait([
      _storage.read(key: _identityIdKey),
      _storage.read(key: _publicKeyKey),
      _storage.read(key: _fingerprintKey),
      _storage.read(key: _createdAtKey),
    ]);
    if (values.every((value) => value == null)) {
      return null;
    }
    if (values.any((value) => value == null)) {
      throw const FormatException('Stored identity metadata is incomplete');
    }
    final created = DateTime.tryParse(values[3]!);
    if (created == null) {
      throw const FormatException('Stored identity timestamp is invalid');
    }
    return LoomIdentityPublic(
      identityId: values[0]!,
      publicKey: values[1]!,
      fingerprint: values[2]!,
      createdAt: created.toUtc(),
    );
  }

  @override
  Future<List<int>> exportRecoveryEntropy() async {
    final encoded = await _storage.read(key: recoveryEntropyStorageKey);
    if (encoded == null) {
      throw StateError('Committed Loom recovery material is unavailable');
    }
    final entropy = base64Decode(encoded);
    try {
      if (entropy.length != 32) {
        throw const FormatException('Stored Loom recovery entropy is invalid');
      }
      return Uint8List.fromList(entropy);
    } finally {
      entropy.fillRange(0, entropy.length, 0);
    }
  }

  @override
  Future<LoomIdentityPublic> importRecoveryEntropy(List<int> entropy) async {
    if (entropy.length != 32) {
      throw const FormatException(
        'Loom Identity v1 recovery entropy must be 32 bytes',
      );
    }
    final material = Uint8List.fromList(entropy);
    _DerivedIdentity? derived;
    try {
      derived = await _deriveIdentity(material);
      final existing = await readIdentity();
      if (existing != null &&
          existing.identityId != derived.identity.identityId) {
        throw StateError(
          'A different Loom identity already exists on this device',
        );
      }
      final identity = existing ?? derived.identity;
      await _writeIdentity(
        identity: identity,
        privateKey: derived.privateKey,
        recoveryEntropy: material,
      );
      return identity;
    } finally {
      derived?.privateKey.fillRange(0, derived.privateKey.length, 0);
      material.fillRange(0, material.length, 0);
    }
  }

  Future<_DerivedIdentity> _deriveIdentity(Uint8List recoveryEntropy) async {
    if (recoveryEntropy.length != 32) {
      throw const FormatException('Loom Identity v1 entropy must be 32 bytes');
    }
    final keyPair = await _ed25519.newKeyPairFromSeed(recoveryEntropy);
    try {
      final keyData = await keyPair.extract();
      final publicKey = await keyPair.extractPublicKey();
      final digest = await _sha256.hash(publicKey.bytes);
      return _DerivedIdentity(
        LoomIdentityPublic(
          identityId: 'chn:${_base64UrlNoPadding(digest.bytes)}',
          publicKey: base64Encode(publicKey.bytes),
          fingerprint: _formatFingerprint(digest.bytes),
          createdAt: DateTime.now().toUtc(),
        ),
        Uint8List.fromList(keyData.bytes),
      );
    } finally {
      keyPair.destroy();
    }
  }

  Future<void> _writeIdentity({
    required LoomIdentityPublic identity,
    required List<int> privateKey,
    required List<int> recoveryEntropy,
  }) async {
    if (privateKey.length != 32 || recoveryEntropy.length != 32) {
      throw const FormatException('Invalid Loom identity secret material');
    }
    await _storage.write(key: _privateKeyKey, value: base64Encode(privateKey));
    await _storage.write(key: _publicKeyKey, value: identity.publicKey);
    await _storage.write(key: _identityIdKey, value: identity.identityId);
    await _storage.write(key: _fingerprintKey, value: identity.fingerprint);
    await _storage.write(
      key: _createdAtKey,
      value: identity.createdAt.toIso8601String(),
    );
    await _storage.write(
      key: recoveryEntropyStorageKey,
      value: base64Encode(recoveryEntropy),
    );
  }

  @override
  void discardPendingIdentity() {
    _pendingPrivate?.fillRange(0, _pendingPrivate!.length, 0);
    _pendingRecoveryEntropy?.fillRange(0, _pendingRecoveryEntropy!.length, 0);
    _pendingPrivate = null;
    _pendingRecoveryEntropy = null;
  }

  @override
  Future<List<int>> signIdentityBinding(List<int> payload) async {
    final encoded = await _storage.read(key: _privateKeyKey);
    if (encoded == null) {
      throw StateError('Identity signing key is unavailable');
    }
    final secret = base64Decode(encoded);
    try {
      final pair = await _ed25519.newKeyPairFromSeed(secret);
      try {
        final signature = await _ed25519.sign(payload, keyPair: pair);
        return signature.bytes;
      } finally {
        pair.destroy();
      }
    } finally {
      secret.fillRange(0, secret.length, 0);
    }
  }

  @override
  Future<void> clearIdentity() async {
    for (final key in [
      _privateKeyKey,
      _publicKeyKey,
      _identityIdKey,
      _fingerprintKey,
      _createdAtKey,
      recoveryEntropyStorageKey,
    ]) {
      await _storage.delete(key: key);
    }
    discardPendingIdentity();
  }

  String _formatFingerprint(List<int> bytes) {
    final hex = bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join()
        .toUpperCase();
    return [for (var i = 0; i < hex.length; i += 4) hex.substring(i, i + 4)]
        .join(' ');
  }

  String _base64UrlNoPadding(List<int> bytes) =>
      base64UrlEncode(bytes).replaceAll('=', '');
}

class _DerivedIdentity {
  const _DerivedIdentity(this.identity, this.privateKey);

  final LoomIdentityPublic identity;
  final Uint8List privateKey;
}

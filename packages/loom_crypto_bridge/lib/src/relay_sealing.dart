import 'dart:convert';
import 'dart:typed_data';

import 'package:loom_models/loom_models.dart';
import 'package:cryptography/cryptography.dart';
import 'package:cryptography/helpers.dart' show randomBytes;

/// Recipient-only envelope used by store-carry-forward relays.
///
/// Relays can validate framing, expiry and routing metadata, but cannot open
/// [ciphertext]. A fresh ephemeral X25519 key is used for every sealed bundle.
class LoomRelaySealer {
  LoomRelaySealer({X25519? keyAgreement, AesGcm? cipher, Hkdf? kdf})
      : _keyAgreement = keyAgreement ?? X25519(),
        _cipher = cipher ?? AesGcm.with256bits(),
        _kdf = kdf ?? Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  final X25519 _keyAgreement;
  final AesGcm _cipher;
  final Hkdf _kdf;

  Future<LoomRelaySealedPayload> seal({
    required List<int> plaintext,
    required String recipientAgreementPublicKey,
    required List<int> associatedData,
  }) async {
    if (plaintext.isEmpty || plaintext.length > 256 * 1024) {
      throw ArgumentError.value(
        plaintext.length,
        'plaintext',
        'Relay payload must be 1..262144 bytes',
      );
    }
    final recipientBytes = base64Decode(recipientAgreementPublicKey);
    if (recipientBytes.length != 32) {
      throw const FormatException(
        'Recipient X25519 public key must be 32 bytes',
      );
    }

    final ephemeral = await _keyAgreement.newKeyPair();
    final ephemeralPublic = await ephemeral.extractPublicKey();
    final shared = await _keyAgreement.sharedSecretKey(
      keyPair: ephemeral,
      remotePublicKey: SimplePublicKey(
        recipientBytes,
        type: KeyPairType.x25519,
      ),
    );
    final derived = await _kdf.deriveKey(
      secretKey: shared,
      nonce: utf8.encode('Loom-Relay-Seal-v1'),
      info: associatedData,
    );
    final nonce = randomBytes(12);
    try {
      final box = await _cipher.encrypt(
        plaintext,
        secretKey: derived,
        nonce: nonce,
        aad: associatedData,
      );
      return LoomRelaySealedPayload(
        version: 1,
        ephemeralPublicKey: base64Encode(ephemeralPublic.bytes),
        nonce: base64Encode(nonce),
        ciphertext: base64Encode(box.cipherText),
        mac: base64Encode(box.mac.bytes),
      );
    } finally {
      nonce.fillRange(0, nonce.length, 0);
      shared.destroy();
      derived.destroy();
      ephemeral.destroy();
    }
  }

  Future<String> recipientTag({
    required String recipientAgreementPublicKey,
    required DateTime time,
  }) async {
    final publicBytes = base64Decode(recipientAgreementPublicKey);
    if (publicBytes.length != 32) {
      throw const FormatException(
        'Recipient X25519 public key must be 32 bytes',
      );
    }
    final epoch = time.toUtc().millisecondsSinceEpoch ~/
        const Duration(hours: 6).inMilliseconds;
    final digest = await Sha256().hash(<int>[
      ...utf8.encode('Loom-Relay-RecipientTag-v1'),
      ...publicBytes,
      ...utf8.encode(epoch.toString()),
    ]);
    return base64UrlEncode(digest.bytes.take(18).toList()).replaceAll('=', '');
  }

  Future<Uint8List> open({
    required LoomRelaySealedPayload payload,
    required KeyPair recipientAgreementKeyPair,
    required List<int> associatedData,
  }) async {
    final ephemeralBytes = base64Decode(payload.ephemeralPublicKey);
    final shared = await _keyAgreement.sharedSecretKey(
      keyPair: recipientAgreementKeyPair,
      remotePublicKey: SimplePublicKey(
        ephemeralBytes,
        type: KeyPairType.x25519,
      ),
    );
    final derived = await _kdf.deriveKey(
      secretKey: shared,
      nonce: utf8.encode('Loom-Relay-Seal-v1'),
      info: associatedData,
    );
    try {
      final clear = await _cipher.decrypt(
        SecretBox(
          base64Decode(payload.ciphertext),
          nonce: base64Decode(payload.nonce),
          mac: Mac(base64Decode(payload.mac)),
        ),
        secretKey: derived,
        aad: associatedData,
      );
      return Uint8List.fromList(clear);
    } finally {
      shared.destroy();
      derived.destroy();
    }
  }
}

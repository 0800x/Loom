import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Sensitive material transferred from an already trusted Loom device to a
/// newly password-authenticated device.
///
/// The payload is encrypted client-side. The Home Node only stores and relays
/// the opaque envelope and never receives recovery entropy or agreement keys in
/// plaintext.
class LoomDeviceLinkPackage {
  const LoomDeviceLinkPackage({
    required this.identityId,
    required this.sourceDeviceId,
    required this.recoveryEntropy,
    required this.sourceAgreementSecret,
  });

  final String identityId;
  final String sourceDeviceId;
  final Uint8List recoveryEntropy;
  final Uint8List sourceAgreementSecret;
}

class LoomDeviceLinkQrData {
  const LoomDeviceLinkQrData({
    required this.homeNode,
    required this.linkId,
    required this.token,
    required this.encryptionSecret,
  });

  final String homeNode;
  final String linkId;
  final String token;
  final String encryptionSecret;
}

class LoomDeviceLinkCodec {
  LoomDeviceLinkCodec({
    Random? random,
    AesGcm? cipher,
    Hkdf? kdf,
  })  : _random = random ?? Random.secure(),
        _cipher = cipher ?? AesGcm.with256bits(),
        _kdf = kdf ?? Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  static const String protocolVersion = 'loom-device-link-v2';
  static const String _qrPrefix = 'loom-device-link:';

  final Random _random;
  final AesGcm _cipher;
  final Hkdf _kdf;
  final Sha256 _sha256 = Sha256();

  String createLinkId() => 'dl_${_base64UrlNoPadding(_randomBytes(18))}';

  String createEncryptionSecret() => _base64UrlNoPadding(_randomBytes(32));

  String createToken() => _base64UrlNoPadding(_randomBytes(32));

  Future<String> tokenHash(String token) async {
    final bytes = _secretBytes(token);
    try {
      // Match the redeem wire contract: server hashes the base64url token text.
      final digest = await _sha256.hash(utf8.encode(token));
      return digest.bytes
          .map((value) => value.toRadixString(16).padLeft(2, '0'))
          .join();
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  String qrPayload({
    required String homeNode,
    required String linkId,
    required String token,
    required String encryptionSecret,
  }) {
    final node = homeNode.trim().toLowerCase();
    _validateLinkId(linkId);
    final secretBytes = _secretBytes(encryptionSecret);
    secretBytes.fillRange(0, secretBytes.length, 0);
    if (encryptionSecret == token) {
      throw const FormatException("Independent device-link secrets required");
    }
    final tokenBytes = _secretBytes(token);
    tokenBytes.fillRange(0, tokenBytes.length, 0);
    if (node.isEmpty || node.length > 512 || node.contains(RegExp(r'[\r\n]'))) {
      throw ArgumentError.value(homeNode, 'homeNode');
    }
    final encoded = utf8.encode(jsonEncode(<String, Object?>{
      'v': 2,
      'protocol': protocolVersion,
      'homeNode': node,
      'linkId': linkId,
      'token': token,
      'encryptionSecret': encryptionSecret,
    }));
    return '$_qrPrefix${_base64UrlNoPadding(encoded)}';
  }

  LoomDeviceLinkQrData parseQrPayload(String value) {
    final cleaned = value.trim();
    if (!cleaned.startsWith(_qrPrefix) || cleaned.length > 4096) {
      throw const FormatException('Invalid Loom device-link QR');
    }
    final encoded = cleaned.substring(_qrPrefix.length);
    final decoded = jsonDecode(utf8.decode(_base64UrlDecode(encoded)));
    if (decoded is! Map<String, Object?> ||
        decoded['v'] != 2 ||
        decoded['protocol'] != protocolVersion) {
      throw const FormatException('Unsupported Loom device-link QR');
    }
    final homeNode = decoded['homeNode'];
    final linkId = decoded['linkId'];
    final token = decoded['token'];
    final encryptionSecret = decoded['encryptionSecret'];
    if (homeNode is! String ||
        homeNode.trim().isEmpty ||
        homeNode.length > 512 ||
        linkId is! String ||
        token is! String ||
        encryptionSecret is! String) {
      throw const FormatException('Malformed Loom device-link QR');
    }
    _validateLinkId(linkId);
    final secretBytes = _secretBytes(encryptionSecret);
    secretBytes.fillRange(0, secretBytes.length, 0);
    if (encryptionSecret == token) {
      throw const FormatException("Independent device-link secrets required");
    }
    final tokenBytes = _secretBytes(token);
    tokenBytes.fillRange(0, tokenBytes.length, 0);
    return LoomDeviceLinkQrData(
      homeNode: homeNode.trim().toLowerCase(),
      linkId: linkId,
      token: token,
      encryptionSecret: encryptionSecret,
    );
  }

  Future<String> seal({
    required String linkId,
    required String encryptionSecret,
    required String identityId,
    required String sourceDeviceId,
    required List<int> recoveryEntropy,
    required List<int> sourceAgreementSecret,
  }) async {
    _validateLinkId(linkId);
    _validateIdentityAndDevice(identityId, sourceDeviceId);
    if (recoveryEntropy.length != 32 || sourceAgreementSecret.length != 32) {
      throw const FormatException('Invalid Loom device-link secret material');
    }

    final secretBytes = _secretBytes(encryptionSecret);
    final nonce = _randomBytes(12);
    final clear = Uint8List.fromList(utf8.encode(jsonEncode(<String, Object?>{
      'v': 2,
      'identityId': identityId,
      'sourceDeviceId': sourceDeviceId,
      'recoveryEntropy': base64Encode(recoveryEntropy),
      'sourceAgreementSecret': base64Encode(sourceAgreementSecret),
      'createdAt': DateTime.now().toUtc().toIso8601String(),
    })));
    final material = await _material(
      secretBytes: secretBytes,
      linkId: linkId,
      identityId: identityId,
      sourceDeviceId: sourceDeviceId,
    );
    try {
      final box = await _cipher.encrypt(
        clear,
        secretKey: material.key,
        nonce: nonce,
        aad: material.aad,
      );
      return jsonEncode(<String, Object?>{
        'v': 2,
        'protocol': protocolVersion,
        'nonce': base64Encode(nonce),
        'ciphertext': base64Encode(box.cipherText),
        'mac': base64Encode(box.mac.bytes),
      });
    } finally {
      secretBytes.fillRange(0, secretBytes.length, 0);
      nonce.fillRange(0, nonce.length, 0);
      clear.fillRange(0, clear.length, 0);
      material.key.destroy();
    }
  }

  Future<LoomDeviceLinkPackage> open({
    required String envelope,
    required String linkId,
    required String encryptionSecret,
    required String expectedIdentityId,
    required String sourceDeviceId,
  }) async {
    _validateLinkId(linkId);
    _validateIdentityAndDevice(expectedIdentityId, sourceDeviceId);
    if (envelope.isEmpty || utf8.encode(envelope).length > 96 * 1024) {
      throw const FormatException('Invalid Loom device-link envelope size');
    }
    final decoded = jsonDecode(envelope);
    if (decoded is! Map<String, Object?> ||
        decoded['v'] != 2 ||
        decoded['protocol'] != protocolVersion) {
      throw const FormatException('Unsupported Loom device-link envelope');
    }
    final nonce = _fieldBytes(decoded, 'nonce', expectedLength: 12);
    final ciphertext = _fieldBytes(decoded, 'ciphertext');
    final mac = _fieldBytes(decoded, 'mac', expectedLength: 16);
    final secretBytes = _secretBytes(encryptionSecret);
    final material = await _material(
      secretBytes: secretBytes,
      linkId: linkId,
      identityId: expectedIdentityId,
      sourceDeviceId: sourceDeviceId,
    );
    List<int>? clear;
    try {
      clear = await _cipher.decrypt(
        SecretBox(ciphertext, nonce: nonce, mac: Mac(mac)),
        secretKey: material.key,
        aad: material.aad,
      );
      final payload = jsonDecode(utf8.decode(clear));
      if (payload is! Map<String, Object?> ||
          payload['v'] != 2 ||
          payload['identityId'] != expectedIdentityId ||
          payload['sourceDeviceId'] != sourceDeviceId) {
        throw const FormatException('Device-link identity binding mismatch');
      }
      final recovery =
          _fieldBytes(payload, 'recoveryEntropy', expectedLength: 32);
      final history =
          _fieldBytes(payload, 'sourceAgreementSecret', expectedLength: 32);
      return LoomDeviceLinkPackage(
        identityId: expectedIdentityId,
        sourceDeviceId: sourceDeviceId,
        recoveryEntropy: Uint8List.fromList(recovery),
        sourceAgreementSecret: Uint8List.fromList(history),
      );
    } on SecretBoxAuthenticationError {
      throw const FormatException('Device-link authentication failed');
    } finally {
      clear?.fillRange(0, clear.length, 0);
      secretBytes.fillRange(0, secretBytes.length, 0);
      material.key.destroy();
    }
  }

  Future<_LinkMaterial> _material({
    required Uint8List secretBytes,
    required String linkId,
    required String identityId,
    required String sourceDeviceId,
  }) async {
    final aad = utf8.encode(
      '$protocolVersion\n$linkId\n$identityId\n$sourceDeviceId',
    );
    final root = SecretKey(secretBytes);
    try {
      final key = await _kdf.deriveKey(
        secretKey: root,
        nonce: utf8.encode('Loom-Device-Link-KDF-v2'),
        info: aad,
      );
      return _LinkMaterial(key, aad);
    } finally {
      root.destroy();
    }
  }

  void _validateLinkId(String value) {
    if (!RegExp(r'^dl_[A-Za-z0-9_-]{20,80}$').hasMatch(value)) {
      throw const FormatException('Invalid Loom device-link id');
    }
  }

  void _validateIdentityAndDevice(String identityId, String deviceId) {
    if (identityId.isEmpty ||
        identityId.length > 512 ||
        deviceId.isEmpty ||
        deviceId.length > 256 ||
        identityId.contains(RegExp(r'[\r\n]')) ||
        deviceId.contains(RegExp(r'[\r\n]'))) {
      throw const FormatException('Invalid Loom device-link binding');
    }
  }

  Uint8List _secretBytes(String token) {
    final decoded = _base64UrlDecode(token);
    if (decoded.length != 32) {
      throw const FormatException('Invalid Loom device-link token');
    }
    return decoded;
  }

  Uint8List _fieldBytes(
    Map<String, Object?> source,
    String key, {
    int? expectedLength,
  }) {
    final value = source[key];
    if (value is! String) {
      throw FormatException('Missing device-link field: $key');
    }
    final bytes = base64Decode(value);
    if (expectedLength != null && bytes.length != expectedLength) {
      throw FormatException('Invalid device-link field: $key');
    }
    return Uint8List.fromList(bytes);
  }

  Uint8List _randomBytes(int length) => Uint8List.fromList(
        List<int>.generate(length, (_) => _random.nextInt(256)),
      );

  String _base64UrlNoPadding(List<int> bytes) =>
      base64UrlEncode(bytes).replaceAll('=', '');

  Uint8List _base64UrlDecode(String value) {
    if (value.isEmpty ||
        value.length > 4096 ||
        !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value)) {
      throw const FormatException('Invalid base64url value');
    }
    final padding = (4 - value.length % 4) % 4;
    final padded = '$value${List<String>.filled(padding, '=').join()}';
    return Uint8List.fromList(base64Url.decode(padded));
  }
}

class _LinkMaterial {
  const _LinkMaterial(this.key, this.aad);
  final SecretKey key;
  final List<int> aad;
}

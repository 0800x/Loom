import 'dart:convert';

import 'package:loom_models/loom_models.dart';

/// Strict parser for the legacy Loom device-envelope migration protocol.
///
/// This adapter does not reinterpret or re-encrypt legacy ciphertext. Actual
/// decryption requires the original legacy device private key material and is
/// deliberately delegated to a separately reviewed migration provider.
class LoomLegacyDeviceEnvelopeAdapter {
  static const protocolVersion = 'Loom-DeviceEnvelope-v2';

  LoomLegacyEnvelope inspect(String encodedEnvelope) {
    final decoded = jsonDecode(encodedEnvelope);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('Legacy envelope root must be an object');
    }
    final version = decoded['protocolVersion'];
    if (version != protocolVersion) {
      throw FormatException('Unsupported legacy envelope protocol: $version');
    }
    String requireString(String key) {
      final value = decoded[key];
      if (value is! String || value.isEmpty) {
        throw FormatException('Legacy envelope has invalid $key');
      }
      return value;
    }

    final wrapped = decoded['wrappedKeys'];
    if (wrapped is! Map) {
      throw const FormatException('Legacy wrappedKeys must be an object');
    }
    final wrappedKeys = <String, String>{};
    for (final entry in wrapped.entries) {
      if (entry.key is! String || entry.value is! String) {
        throw const FormatException('Legacy wrappedKeys entry is invalid');
      }
      wrappedKeys[entry.key as String] = entry.value as String;
    }
    if (wrappedKeys.isEmpty) {
      throw const FormatException('Legacy envelope contains no wrapped keys');
    }
    return LoomLegacyEnvelope(
      protocolVersion: protocolVersion,
      ciphertext: requireString('ciphertext'),
      nonce: requireString('nonce'),
      wrappedKeys: Map<String, String>.unmodifiable(wrappedKeys),
    );
  }
}

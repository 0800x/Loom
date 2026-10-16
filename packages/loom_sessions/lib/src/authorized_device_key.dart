import 'dart:typed_data';

/// Currently authorized device signing key resolved from Loom's device-trust
/// cache/directory layer.
///
/// Session/prekey code must never treat the delivery server as the authority for
/// this record. Implementations are expected to apply sticky revocation and key
/// supersession policy before returning a key.
final class LoomAuthorizedDeviceSigningKey {
  LoomAuthorizedDeviceSigningKey({
    required this.accountId,
    required this.deviceId,
    required this.deviceKeyVersion,
    required Uint8List ed25519PublicKey,
  }) : ed25519PublicKey = Uint8List.fromList(ed25519PublicKey) {
    if (accountId.trim() != accountId ||
        accountId.isEmpty ||
        accountId.length > 256 ||
        deviceId.trim() != deviceId ||
        deviceId.isEmpty ||
        deviceId.length > 256 ||
        deviceKeyVersion < 1 ||
        this.ed25519PublicKey.length != 32) {
      throw const FormatException('Invalid authorized device signing key');
    }
  }

  final String accountId;
  final String deviceId;
  final int deviceKeyVersion;
  final Uint8List ed25519PublicKey;
}

/// Resolves only the currently authorized signing key for an exact device-key
/// version.
///
/// Implementations MUST return null for unknown, changed, revoked, expired or
/// superseded keys. This deliberately lives in the provider-neutral sessions
/// package so a pure-Dart trust store can implement it without depending on a
/// Flutter/native crypto package.
abstract interface class LoomAuthorizedDeviceSigningKeyResolver {
  Future<LoomAuthorizedDeviceSigningKey?> resolveAuthorizedSigningKey({
    required String accountId,
    required String deviceId,
    required int deviceKeyVersion,
    required DateTime now,
  });
}

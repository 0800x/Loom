import 'dart:typed_data';

import 'package:loom_sessions/loom_sessions.dart';
import 'package:cryptography/cryptography.dart';

import 'device_security_core.dart';

final class LoomDevicePrekeyAuthorizationSigner
    implements LoomPrekeyAuthorizationSigner {
  const LoomDevicePrekeyAuthorizationSigner({
    required this.deviceSecurityCore,
    required this.identityId,
    required this.deviceId,
  });

  final LoomDeviceSecurityCore deviceSecurityCore;
  final String identityId;
  final String deviceId;

  @override
  Future<LoomAuthorizedPrekeyBundle> authorize({
    required LoomPrekeyAuthorizationStatement statement,
    required Uint8List providerBundle,
  }) async {
    statement.validate();
    if (statement.accountId != identityId || statement.deviceId != deviceId) {
      throw const FormatException(
        'Prekey authorization statement does not match local device',
      );
    }
    if (!statement.authorizesBundle(providerBundle)) {
      throw const FormatException(
        'Prekey authorization bundle digest mismatch',
      );
    }
    final signature = await deviceSecurityCore.signDevicePayload(
      identityId: identityId,
      deviceId: deviceId,
      payload: statement.canonicalBytes(),
    );
    return LoomAuthorizedPrekeyBundle(
      statement: statement,
      providerBundle: providerBundle,
      deviceSignature: Uint8List.fromList(signature),
    );
  }
}

final class LoomDevicePrekeySignatureVerifier
    implements LoomAuthorizedDeviceSignatureVerifier {
  LoomDevicePrekeySignatureVerifier({required this.keyResolver});

  final LoomAuthorizedDeviceSigningKeyResolver keyResolver;
  final Ed25519 _ed25519 = Ed25519();

  @override
  Future<bool> verifyAuthorizedDeviceSignature({
    required String accountId,
    required String deviceId,
    required int deviceKeyVersion,
    required Uint8List canonicalPayload,
    required Uint8List signature,
    required DateTime now,
  }) async {
    if (signature.length != 64 || canonicalPayload.isEmpty) return false;
    final resolved = await keyResolver.resolveAuthorizedSigningKey(
      accountId: accountId,
      deviceId: deviceId,
      deviceKeyVersion: deviceKeyVersion,
      now: now.toUtc(),
    );
    if (resolved == null ||
        resolved.accountId != accountId ||
        resolved.deviceId != deviceId ||
        resolved.deviceKeyVersion != deviceKeyVersion) {
      return false;
    }
    return _ed25519.verify(
      canonicalPayload,
      signature: Signature(
        signature,
        publicKey: SimplePublicKey(
          resolved.ed25519PublicKey,
          type: KeyPairType.ed25519,
        ),
      ),
    );
  }
}

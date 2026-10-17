import 'dart:convert';
import 'dart:typed_data';

import 'package:loom_crypto_bridge/loom_crypto_bridge.dart';
import 'package:loom_transport/loom_transport.dart';

/// Reuses the existing Architecture-v2 authorized Ed25519 device key for
/// direct-destination transport proofs.
///
/// No second fingerprint/key hierarchy is introduced. The private key remains
/// behind [LoomDeviceSecurityCore] (FlutterSecureStorage today; hardware-
/// backed platform providers can implement the same boundary later).
final class LoomAuthorizedDeviceDirectTransportSigner
    implements LoomDirectTransportSigner {
  LoomAuthorizedDeviceDirectTransportSigner({
    required this.deviceSecurity,
    required this.identityId,
    required this.deviceId,
  });

  final LoomDeviceSecurityCore deviceSecurity;
  final String identityId;
  final String deviceId;
  Uint8List? _cachedPublicKey;

  @override
  Future<Uint8List> ed25519PublicKey() async {
    final cached = _cachedPublicKey;
    if (cached != null) return Uint8List.fromList(cached);

    final bundle = await deviceSecurity.readDevice(
      identityId: identityId,
      deviceId: deviceId,
    );
    if (bundle == null) {
      throw StateError('Authorized Loom device key is unavailable');
    }
    if (bundle.identityId != identityId || bundle.deviceId != deviceId) {
      throw const FormatException('Authorized device key binding mismatch');
    }
    final bytes = base64Decode(bundle.signingPublicKey);
    if (bytes.length != 32) {
      bytes.fillRange(0, bytes.length, 0);
      throw const FormatException('Authorized device Ed25519 public key is invalid');
    }
    _cachedPublicKey = Uint8List.fromList(bytes);
    bytes.fillRange(0, bytes.length, 0);
    return Uint8List.fromList(_cachedPublicKey!);
  }

  @override
  Future<Uint8List> sign(Uint8List canonicalBytes) async {
    if (canonicalBytes.isEmpty || canonicalBytes.length > 2 * 1024 * 1024) {
      throw const FormatException('Invalid direct transport signing payload');
    }
    final signature = await deviceSecurity.signDevicePayload(
      identityId: identityId,
      deviceId: deviceId,
      payload: canonicalBytes,
    );
    if (signature.length != 64) {
      throw const FormatException('Authorized device Ed25519 signature is invalid');
    }
    return Uint8List.fromList(signature);
  }
}

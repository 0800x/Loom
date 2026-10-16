import 'dart:convert';

import 'package:loom_models/loom_models.dart';
import 'package:cryptography/cryptography.dart';

class LoomVerificationService {
  final Sha256 _sha256 = Sha256();
  final Ed25519 _ed25519 = Ed25519();

  Future<LoomVerificationComparison> compare({
    required LoomIdentityPublic localIdentity,
    required LoomDeviceKeyBundle localDevice,
    required LoomIdentityPublic remoteIdentity,
    required LoomDeviceKeyBundle remoteDevice,
  }) async {
    final entries = <String>[
      _identityLine(localIdentity),
      _deviceLine(localDevice),
      _identityLine(remoteIdentity),
      _deviceLine(remoteDevice),
    ]..sort();
    final digest = await _sha256.hash(utf8.encode(entries.join('\n')));
    final hex = digest.bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join()
        .toUpperCase();
    final groups = <String>[
      for (var index = 0; index < 48; index += 4)
        hex.substring(index, index + 4),
    ];
    return LoomVerificationComparison(
      displayGroups: List<String>.unmodifiable(groups),
      qrPayload: jsonEncode(<String, Object?>{
        'v': 1,
        'kind': 'loom-verification',
        'digest': base64UrlEncode(digest.bytes).replaceAll('=', ''),
      }),
    );
  }

  Future<bool> verifyCompleteDeviceBundle({
    required LoomDeviceKeyBundle bundle,
    required LoomIdentityPublic identity,
  }) async {
    if (!await verifyFingerprint(bundle)) return false;
    if (!await verifyDeviceSelfSignature(bundle)) return false;
    return verifyIdentityBinding(bundle: bundle, identity: identity);
  }

  Future<bool> verifyFingerprint(LoomDeviceKeyBundle bundle) async {
    final digest = await _sha256.hash(bundle.canonicalBindingBytes());
    final hex = digest.bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join()
        .toUpperCase();
    final expected = <String>[
      for (var index = 0; index < hex.length; index += 4)
        hex.substring(index, index + 4),
    ].join(' ');
    return expected == bundle.fingerprint;
  }

  Future<bool> verifyDeviceSelfSignature(LoomDeviceKeyBundle bundle) async {
    try {
      final publicKeyBytes = base64Decode(bundle.signingPublicKey);
      final signatureBytes = base64Decode(bundle.deviceSignature);
      if (publicKeyBytes.length != 32 || signatureBytes.length != 64) {
        return false;
      }
      return await _ed25519.verify(
        bundle.canonicalBindingBytes(),
        signature: Signature(
          signatureBytes,
          publicKey: SimplePublicKey(publicKeyBytes, type: KeyPairType.ed25519),
        ),
      );
    } on FormatException {
      return false;
    }
  }

  Future<bool> verifyIdentityBinding({
    required LoomDeviceKeyBundle bundle,
    required LoomIdentityPublic identity,
  }) async {
    if (bundle.identityId != identity.identityId) return false;
    try {
      final publicKeyBytes = base64Decode(identity.publicKey);
      final signatureBytes = base64Decode(bundle.identitySignature);
      if (publicKeyBytes.length != 32 || signatureBytes.length != 64) {
        return false;
      }
      return await _ed25519.verify(
        bundle.canonicalBindingBytes(),
        signature: Signature(
          signatureBytes,
          publicKey: SimplePublicKey(publicKeyBytes, type: KeyPairType.ed25519),
        ),
      );
    } on FormatException {
      return false;
    }
  }

  String _identityLine(LoomIdentityPublic identity) =>
      'identity|${identity.identityId}|${identity.publicKey}|${identity.fingerprint}';

  String _deviceLine(LoomDeviceKeyBundle device) =>
      'device|${device.identityId}|${device.deviceId}|${device.signingPublicKey}|${device.agreementPublicKey}';
}

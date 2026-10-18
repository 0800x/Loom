import 'dart:convert';

import 'package:loom_models/loom_models.dart';
import 'package:cryptography/cryptography.dart';

import 'node_client.dart';

class LoomDeviceBundleVerifier {
  LoomDeviceBundleVerifier()
      : _ed25519 = Ed25519(),
        _sha256 = Sha256();

  final Ed25519 _ed25519;
  final Sha256 _sha256;

  Future<LoomDeviceKeyBundle> verify({
    required LoomDeviceKeyBundle bundle,
    required String identityId,
    required String identityPublicKey,
  }) async {
    try {
      final identityKey = base64Decode(identityPublicKey);
      final signingKey = base64Decode(bundle.signingPublicKey);
      final agreementKey = base64Decode(bundle.agreementPublicKey);
      final deviceSignature = base64Decode(bundle.deviceSignature);
      final identitySignature = base64Decode(bundle.identitySignature);
      if (identityKey.length != 32 ||
          signingKey.length != 32 ||
          agreementKey.length != 32 ||
          deviceSignature.length != 64 ||
          identitySignature.length != 64) {
        throw const LoomProtocolException('Invalid device key material');
      }
      final identityDigest = await _sha256.hash(identityKey);
      final derivedIdentityId =
          'chn:${base64UrlEncode(identityDigest.bytes).replaceAll('=', '')}';
      if (identityId != derivedIdentityId || bundle.identityId != identityId) {
        throw const LoomProtocolException(
          'Device bundle identity binding is invalid',
        );
      }
      if (!bundle.capabilities.contains('signing-ed25519') ||
          !bundle.capabilities.contains('agreement-x25519')) {
        throw const LoomProtocolException(
          'Device bundle lacks required cryptographic capabilities',
        );
      }
      final canonical = bundle.canonicalBindingBytes();
      final fingerprintDigest = await _sha256.hash(canonical);
      if (_formatFingerprint(fingerprintDigest.bytes) !=
          bundle.fingerprint.toUpperCase()) {
        throw const LoomProtocolException(
          'Device bundle fingerprint is invalid',
        );
      }
      final deviceOk = await _ed25519.verify(
        canonical,
        signature: Signature(
          deviceSignature,
          publicKey: SimplePublicKey(signingKey, type: KeyPairType.ed25519),
        ),
      );
      if (!deviceOk) {
        throw const LoomProtocolException(
          'Device bundle self-signature is invalid',
        );
      }
      final identityOk = await _ed25519.verify(
        canonical,
        signature: Signature(
          identitySignature,
          publicKey: SimplePublicKey(identityKey, type: KeyPairType.ed25519),
        ),
      );
      if (!identityOk) {
        throw const LoomProtocolException(
          'Device bundle identity signature is invalid',
        );
      }
      return bundle;
    } on FormatException {
      throw const LoomProtocolException('Malformed device key bundle');
    }
  }

  String _formatFingerprint(List<int> bytes) {
    final hex = bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join()
        .toUpperCase();
    return <String>[
      for (var index = 0; index < hex.length; index += 4)
        hex.substring(index, index + 4),
    ].join(' ');
  }
}

import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

class LoomFederationChallenge {
  const LoomFederationChallenge({
    required this.challengeId,
    required this.nonce,
    required this.requesterNodeId,
    required this.responderNodeId,
    required this.createdAt,
    required this.expiresAt,
  });

  final String challengeId;
  final String nonce;
  final String requesterNodeId;
  final String responderNodeId;
  final DateTime createdAt;
  final DateTime expiresAt;

  List<int> signingBytes() => utf8.encode(
        [
          'loom-node-auth-v1',
          challengeId,
          nonce,
          requesterNodeId,
          responderNodeId,
          createdAt.toUtc().toIso8601String(),
          expiresAt.toUtc().toIso8601String(),
        ].join('\n'),
      );
}

class LoomFederationChallengeFactory {
  LoomFederationChallengeFactory({Random? random})
      : _random = random ?? Random.secure();
  final Random _random;

  LoomFederationChallenge create({
    required String requesterNodeId,
    required String responderNodeId,
    DateTime? now,
  }) {
    final clock = (now ?? DateTime.now()).toUtc();
    String token(int bytes) =>
        base64UrlEncode(List<int>.generate(bytes, (_) => _random.nextInt(256)))
            .replaceAll('=', '');
    return LoomFederationChallenge(
      challengeId: 'fac_${token(18)}',
      nonce: token(32),
      requesterNodeId: requesterNodeId,
      responderNodeId: responderNodeId,
      createdAt: clock,
      expiresAt: clock.add(const Duration(minutes: 2)),
    );
  }
}

Future<String> loomSignFederationChallenge(
  LoomFederationChallenge challenge,
  KeyPair keyPair,
) async {
  final signature = await Ed25519().sign(
    challenge.signingBytes(),
    keyPair: keyPair,
  );
  return base64Encode(signature.bytes);
}

Future<bool> loomVerifyFederationChallenge({
  required LoomFederationChallenge challenge,
  required String signatureBase64,
  required String publicKeyBase64,
  DateTime? now,
}) async {
  final clock = (now ?? DateTime.now()).toUtc();
  if (challenge.expiresAt.isBefore(clock) ||
      challenge.createdAt.isAfter(clock.add(const Duration(minutes: 1)))) {
    return false;
  }
  try {
    final keyBytes = base64Decode(publicKeyBase64);
    final signatureBytes = base64Decode(signatureBase64);
    if (keyBytes.length != 32 || signatureBytes.length != 64) return false;
    return await Ed25519().verify(
      challenge.signingBytes(),
      signature: Signature(
        signatureBytes,
        publicKey: SimplePublicKey(keyBytes, type: KeyPairType.ed25519),
      ),
    );
  } on FormatException {
    return false;
  }
}

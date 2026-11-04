import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import 'canonical_json.dart';

class LoomFederationRequestProof {
  const LoomFederationRequestProof({
    required this.nodeId,
    required this.timestamp,
    required this.nonce,
    required this.signature,
  });

  final String nodeId;
  final DateTime timestamp;
  final String nonce;
  final String signature;

  Map<String, String> toHeaders() => <String, String>{
    'X-Loom-Node-Id': nodeId,
    'X-Loom-Timestamp': timestamp.toUtc().toIso8601String(),
    'X-Loom-Nonce': nonce,
    'X-Loom-Signature': signature,
    'X-Loom-Federation-Version': 'loom-federation-v1',
  };
}

List<int> loomFederationRequestSigningBytes({
  required String method,
  required String path,
  required DateTime timestamp,
  required String nonce,
  required Object? body,
}) {
  final canonicalBody = loomCanonicalJson(body);
  return utf8.encode(
    [
      'loom-federation-request-v1',
      method.toUpperCase(),
      path,
      timestamp.toUtc().toIso8601String(),
      nonce,
      canonicalBody,
    ].join('\n'),
  );
}

Future<LoomFederationRequestProof> loomSignFederationRequest({
  required String nodeId,
  required String method,
  required String path,
  required DateTime timestamp,
  required String nonce,
  required Object? body,
  required KeyPair keyPair,
}) async {
  final bytes = loomFederationRequestSigningBytes(
    method: method,
    path: path,
    timestamp: timestamp,
    nonce: nonce,
    body: body,
  );
  final signature = await Ed25519().sign(bytes, keyPair: keyPair);
  return LoomFederationRequestProof(
    nodeId: nodeId,
    timestamp: timestamp.toUtc(),
    nonce: nonce,
    signature: base64Encode(signature.bytes),
  );
}

Future<bool> loomVerifyFederationRequest({
  required LoomFederationRequestProof proof,
  required String method,
  required String path,
  required Object? body,
  required String publicKeyBase64,
  DateTime? now,
  Duration maxClockSkew = const Duration(minutes: 5),
}) async {
  final clock = (now ?? DateTime.now()).toUtc();
  if (proof.timestamp.isBefore(clock.subtract(maxClockSkew)) ||
      proof.timestamp.isAfter(clock.add(maxClockSkew))) {
    return false;
  }
  try {
    final key = base64Decode(publicKeyBase64);
    final signature = base64Decode(proof.signature);
    if (key.length != 32 || signature.length != 64) return false;
    final bytes = loomFederationRequestSigningBytes(
      method: method,
      path: path,
      timestamp: proof.timestamp,
      nonce: proof.nonce,
      body: body,
    );
    return await Ed25519().verify(
      bytes,
      signature: Signature(
        signature,
        publicKey: SimplePublicKey(key, type: KeyPairType.ed25519),
      ),
    );
  } on FormatException {
    return false;
  }
}

abstract interface class LoomFederationRequestReplayStore {
  Future<bool> rememberRequestNonce({
    required String nodeId,
    required String nonce,
    required DateTime expiresAt,
  });
}

class LoomFederationRequestVerifier {
  LoomFederationRequestVerifier({
    required this.replayStore,
    this.maxClockSkew = const Duration(minutes: 5),
  });

  final LoomFederationRequestReplayStore replayStore;
  final Duration maxClockSkew;

  Future<bool> verify({
    required LoomFederationRequestProof proof,
    required String method,
    required String path,
    required Object? body,
    required String publicKeyBase64,
    DateTime? now,
  }) async {
    final clock = (now ?? DateTime.now()).toUtc();
    final signatureValid = await loomVerifyFederationRequest(
      proof: proof,
      method: method,
      path: path,
      body: body,
      publicKeyBase64: publicKeyBase64,
      now: clock,
      maxClockSkew: maxClockSkew,
    );
    if (!signatureValid) return false;
    return replayStore.rememberRequestNonce(
      nodeId: proof.nodeId,
      nonce: proof.nonce,
      expiresAt: proof.timestamp.add(maxClockSkew),
    );
  }
}

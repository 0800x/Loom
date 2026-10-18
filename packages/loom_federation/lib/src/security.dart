import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import 'event.dart';
import 'policy.dart';

abstract interface class LoomFederationReplayStore {
  /// Returns true only when [eventId] was not previously recorded and has now
  /// been recorded atomically.
  Future<bool> remember(String eventId, DateTime expiresAt);
}

class LoomFederationLimits {
  const LoomFederationLimits({
    this.maxEncodedBytes = 1024 * 1024,
    this.maxClockSkew = const Duration(minutes: 5),
    this.maxLifetime = const Duration(days: 7),
    this.maxHops = 8,
  });

  final int maxEncodedBytes;
  final Duration maxClockSkew;
  final Duration maxLifetime;
  final int maxHops;
}

class LoomFederationValidationException implements Exception {
  const LoomFederationValidationException(this.message);
  final String message;
  @override
  String toString() => 'LoomFederationValidationException: $message';
}

class LoomFederationVerifier {
  LoomFederationVerifier({
    required this.replayStore,
    this.limits = const LoomFederationLimits(),
  });

  final LoomFederationReplayStore replayStore;
  final LoomFederationLimits limits;

  Future<void> validateIncoming({
    required LoomFederationEvent event,
    required LoomFederationPeer authenticatedPeer,
    required String originPublicKeyBase64,
    required LoomFederationPolicy policy,
    required String localDomain,
    DateTime? now,
  }) async {
    final clock = (now ?? DateTime.now()).toUtc();
    if (!policy.allowsPeer(authenticatedPeer)) {
      throw const LoomFederationValidationException(
        'Federation policy rejected peer',
      );
    }
    if (event.hopCount == 0 && event.originNodeId != authenticatedPeer.nodeId) {
      throw const LoomFederationValidationException(
        'Direct event origin does not match authenticated peer',
      );
    }
    if (event.destinationDomain.toLowerCase() != localDomain.toLowerCase()) {
      throw const LoomFederationValidationException(
        'Federation event is addressed to another domain',
      );
    }
    if (event.hopCount < 0 ||
        event.maxHops < 1 ||
        event.maxHops > limits.maxHops ||
        event.hopCount > event.maxHops) {
      throw const LoomFederationValidationException(
        'Invalid federation hop bounds',
      );
    }
    if (event.expiresAt.isBefore(event.createdAt) ||
        event.expiresAt.difference(event.createdAt) > limits.maxLifetime) {
      throw const LoomFederationValidationException(
        'Invalid federation event lifetime',
      );
    }
    if (event.expiresAt.isBefore(clock)) {
      throw const LoomFederationValidationException('Federation event expired');
    }
    if (event.createdAt.isAfter(clock.add(limits.maxClockSkew)) ||
        event.createdAt.isBefore(
          clock.subtract(limits.maxLifetime + limits.maxClockSkew),
        )) {
      throw const LoomFederationValidationException(
        'Federation event timestamp outside accepted window',
      );
    }
    final encodedLength = utf8.encode(jsonEncode(event.toJson())).length;
    if (encodedLength > limits.maxEncodedBytes) {
      throw const LoomFederationValidationException(
        'Federation event exceeds maximum size',
      );
    }
    await _verifySignature(event, originPublicKeyBase64);
    final fresh = await replayStore.remember(event.eventId, event.expiresAt);
    if (!fresh) {
      throw const LoomFederationValidationException(
        'Duplicate or replayed federation event',
      );
    }
  }

  Future<void> _verifySignature(
    LoomFederationEvent event,
    String publicKeyBase64,
  ) async {
    try {
      final publicKeyBytes = base64Decode(publicKeyBase64);
      final signatureBytes = base64Decode(event.signature);
      if (publicKeyBytes.length != 32 || signatureBytes.length != 64) {
        throw const FormatException('Invalid Ed25519 material length');
      }
      final valid = await Ed25519().verify(
        event.signingBytes(),
        signature: Signature(
          signatureBytes,
          publicKey: SimplePublicKey(publicKeyBytes, type: KeyPairType.ed25519),
        ),
      );
      if (!valid) {
        throw const LoomFederationValidationException(
          'Invalid federation event signature',
        );
      }
    } on FormatException {
      throw const LoomFederationValidationException(
        'Malformed federation signing material',
      );
    }
  }
}

Future<LoomFederationEvent> loomSignFederationEvent({
  required LoomFederationEvent unsignedEvent,
  required KeyPair keyPair,
}) async {
  final signature = await Ed25519().sign(
    unsignedEvent.signingBytes(),
    keyPair: keyPair,
  );
  return LoomFederationEvent(
    version: unsignedEvent.version,
    eventId: unsignedEvent.eventId,
    originNodeId: unsignedEvent.originNodeId,
    destinationDomain: unsignedEvent.destinationDomain,
    conversationId: unsignedEvent.conversationId,
    type: unsignedEvent.type,
    createdAt: unsignedEvent.createdAt,
    expiresAt: unsignedEvent.expiresAt,
    hopCount: unsignedEvent.hopCount,
    maxHops: unsignedEvent.maxHops,
    nonce: unsignedEvent.nonce,
    body: unsignedEvent.body,
    signature: base64Encode(signature.bytes),
  );
}

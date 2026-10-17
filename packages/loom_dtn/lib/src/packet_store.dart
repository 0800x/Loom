import 'dart:typed_data';

import 'package:loom_protocol/loom_protocol.dart';

enum LoomDtnPacketOrigin {
  localOutbound,
  carriedReplica,
}

enum LoomDtnPacketState {
  queued,
  gatewayAccepted,
  relayAccepted,
  recipientConfirmed,
  expired,
  cancelledLocal,
}

/// Raised when a stable PacketId is reused with different immutable packet data.
final class LoomDtnPacketConflict implements Exception {
  const LoomDtnPacketConflict(this.message);

  final String message;

  @override
  String toString() => 'LoomDtnPacketConflict: $message';
}

/// A packet that is known to have reached durable local DTN custody.
///
/// [wireBytes] are the exact encoded source OuterEnvelopeV2 bytes stored before
/// any transport is allowed to send them. [initialCopiesRemaining] is therefore
/// immutable and must match those bytes. [copiesRemaining] is the local runtime
/// Spray-and-Wait budget after successful forwarding revisions and may decrease
/// without rewriting the original source envelope.
final class LoomStoredDtnPacket {
  LoomStoredDtnPacket({
    required this.packetId,
    required this.origin,
    required this.operationId,
    required this.messageId,
    required Uint8List wireBytes,
    required this.routingScope,
    required Uint8List mailboxToken,
    required this.expiresAt,
    required this.priority,
    required this.initialHopLimit,
    required this.hopsUsed,
    required this.initialCopiesRemaining,
    required this.copiesRemaining,
    required this.storedAt,
    required this.state,
    required this.attemptCount,
    required this.nextAttemptAt,
    required this.lastErrorCode,
    required this.gatewayAcceptedAt,
    required this.relayAcceptedAt,
    required this.recipientConfirmedAt,
    required this.terminalAt,
  })  : _wireBytes = Uint8List.fromList(wireBytes),
        _mailboxToken = Uint8List.fromList(mailboxToken);

  final String packetId;
  final LoomDtnPacketOrigin origin;

  /// Local application correlation only. Never serialized into OuterEnvelopeV2.
  final String? operationId;

  /// Local application correlation only. Never serialized into OuterEnvelopeV2.
  final String? messageId;

  final Uint8List _wireBytes;
  final LoomRoutingScopeV2 routingScope;
  final Uint8List _mailboxToken;
  final DateTime expiresAt;
  final LoomPriorityClassV2 priority;
  final int initialHopLimit;
  final int hopsUsed;

  /// Copy budget encoded in the immutable source OuterEnvelopeV2.
  final int initialCopiesRemaining;

  /// Current local forwarding budget after accepted replication transfers.
  /// Zero means custody was handed off and local automatic forwarding is paused.
  final int copiesRemaining;

  final DateTime storedAt;
  final LoomDtnPacketState state;
  final int attemptCount;
  final DateTime nextAttemptAt;
  final String? lastErrorCode;
  final DateTime? gatewayAcceptedAt;
  final DateTime? relayAcceptedAt;
  final DateTime? recipientConfirmedAt;
  final DateTime? terminalAt;

  Uint8List get wireBytes => Uint8List.fromList(_wireBytes);

  Uint8List get mailboxToken => Uint8List.fromList(_mailboxToken);

  bool get isTerminal => switch (state) {
        LoomDtnPacketState.recipientConfirmed ||
        LoomDtnPacketState.expired ||
        LoomDtnPacketState.cancelledLocal =>
          true,
        _ => false,
      };

  /// Whether the local router may still schedule a transmission attempt.
  ///
  /// A relay acceptance means the delivery service has taken custody, so the
  /// local packet is retained as a tombstone/status record but is no longer
  /// automatically retransmitted. A recipient-confirmed receipt is stronger
  /// and is terminal. A zero local copy budget represents an outstanding
  /// single-copy custody handoff and also blocks new forwarding plans.
  bool get isEligibleForForwarding =>
      copiesRemaining > 0 &&
      (switch (state) {
        LoomDtnPacketState.queued || LoomDtnPacketState.gatewayAccepted => true,
        _ => false,
      });
}

/// Durable packet-custody boundary between messaging/session security and DTN.
///
/// Implementations must not expose a newly assembled packet to transports until
/// [putLocalOutbound] has committed successfully. Repeating the same operation
/// with byte-identical data must be idempotent. Reusing a PacketId with different
/// encoded bytes or local immutable correlation data must fail closed.
abstract interface class LoomPacketStore {
  LoomStoredDtnPacket putLocalOutbound({
    required String operationId,
    required String messageId,
    required String packetId,
    required Uint8List exactOuterEnvelopeBytes,
    required DateTime now,
  });

  LoomStoredDtnPacket? read(String packetId);

  List<LoomStoredDtnPacket> listEligible(
    DateTime now, {
    int limit = 50,
  });

  LoomStoredDtnPacket recordAttempt(
    String packetId, {
    required DateTime attemptedAt,
    required DateTime nextAttemptAt,
    String? errorCode,
  });

  LoomStoredDtnPacket markGatewayAccepted(
    String packetId,
    DateTime acceptedAt,
  );

  LoomStoredDtnPacket markRelayAccepted(
    String packetId,
    DateTime acceptedAt,
  );

  LoomStoredDtnPacket markRecipientConfirmed(
    String packetId,
    DateTime confirmedAt,
  );

  LoomStoredDtnPacket cancelLocal(String packetId, DateTime cancelledAt);

  int expireDue(DateTime now);

  /// Deletes old terminal records only after both packet expiry and the
  /// configured tombstone-retention window have elapsed.
  int pruneTerminal(
    DateTime now, {
    Duration tombstoneRetention = const Duration(days: 30),
  });

  void close();
}

/// Nearby scheduling is independent of an Internet-route retry delay.
/// Includes retained ciphertext that may only be offered to the sealed recipient
/// after relay tokens are spent; callers must still enforce forwarding budgets.
abstract interface class LoomNearbyPacketSource {
  List<LoomStoredDtnPacket> listNearbyCandidates(DateTime now,
      {int limit = 50});
}

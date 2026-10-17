import 'dart:typed_data';

import 'package:loom_protocol/loom_protocol.dart';
import 'package:loom_storage/loom_storage.dart';

/// Routing metadata selected after session encryption has committed.
///
/// This object contains no plaintext, account id, device id, conversation id,
/// or message content. The mailbox token is opaque rotating routing material.
final class LoomV2PacketAssemblyPlan {
  const LoomV2PacketAssemblyPlan({
    required this.routingHint,
    required this.expiresAtBucket,
    required this.priority,
    required this.initialHopLimit,
    required this.copiesRemaining,
  });

  final LoomRoutingHintV2 routingHint;
  final DateTime expiresAtBucket;
  final LoomPriorityClassV2 priority;
  final int initialHopLimit;
  final int copiesRemaining;

  void validate(DateTime now) {
    routingHint.validate();
    if (initialHopLimit < 1 || initialHopLimit > 8) {
      throw const FormatException('Invalid initial hop limit');
    }
    if (copiesRemaining < 1 || copiesRemaining > 8) {
      throw const FormatException('Invalid initial copy budget');
    }

    final expiry = expiresAtBucket.toUtc();
    final current = now.toUtc();
    if (!expiry.isAfter(current)) {
      throw const FormatException('Packet expiry must be in the future');
    }
    if (expiry.isAfter(current.add(const Duration(days: 7)))) {
      throw const FormatException('Packet expiry exceeds seven-day DTN limit');
    }
    if (expiry.minute != 0 ||
        expiry.second != 0 ||
        expiry.millisecond != 0 ||
        expiry.microsecond != 0) {
      throw const FormatException('Packet expiry must use an hourly bucket');
    }
  }
}

/// A fully encoded v2 packet derived from already-committed session state.
///
/// This value is intentionally called a draft because the DTN packet store
/// must durably persist [wireBytes] before any transport is allowed to send it.
/// The assembler itself has no TransportAdapter dependency and cannot transmit.
final class LoomV2CommittedPacketDraft {
  LoomV2CommittedPacketDraft({
    required this.packetId,
    required this.messageId,
    required this.operationId,
    required Uint8List wireBytes,
  }) : wireBytes = Uint8List.fromList(wireBytes);

  final String packetId;
  final String messageId;
  final String operationId;
  final Uint8List wireBytes;
}

/// Converts committed crypto-outbox records into opaque routable v2 packets.
///
/// Security boundary:
///
/// 1. the session provider must already have committed session advancement,
///    stable PacketId and exact session ciphertext in LoomCryptoStateStore;
/// 2. this assembler wraps that committed result in SessionCiphertextV2 and
///    OuterEnvelopeV2;
/// 3. a future DTN PacketStore must durably persist the exact outer bytes;
/// 4. only then may a transport receive them.
final class LoomV2CommittedPacketAssembler {
  const LoomV2CommittedPacketAssembler();

  LoomV2CommittedPacketDraft assemblePending({
    required LoomStoredCryptoOutboxRecord stored,
    required LoomV2PacketAssemblyPlan plan,
    required DateTime now,
  }) {
    if (stored.state != LoomCryptoOutboxState.pending) {
      throw StateError(
        'Only pending committed crypto outbox rows may be assembled',
      );
    }
    final record = stored.record;
    record.validate();
    plan.validate(now);

    final sessionWire = LoomSessionCiphertextWireV2(
      protocolVersion: record.ciphertext.protocolVersion,
      sessionLocator: record.ciphertext.sessionLocator,
      ciphertext: record.ciphertext.bytes,
    );
    final sessionPayload = LoomEnvelopeV2Codec.encodeSessionCiphertext(
      sessionWire,
    );
    if (sessionPayload.length > 1024 * 1024) {
      throw const FormatException(
        'Wrapped session ciphertext exceeds packet limit',
      );
    }

    final outer = LoomOuterEnvelopeV2(
      packetId: record.packetId,
      routingHint: plan.routingHint,
      expiresAtBucket: plan.expiresAtBucket,
      priority: plan.priority,
      initialHopLimit: plan.initialHopLimit,
      forwardingState: LoomForwardingStateV2(
        hopsUsed: 0,
        copiesRemaining: plan.copiesRemaining,
      ),
      encryptedPayload: sessionPayload,
    );
    final wireBytes = LoomEnvelopeV2Codec.encodeOuter(outer);

    return LoomV2CommittedPacketDraft(
      packetId: record.packetId,
      messageId: record.messageId,
      operationId: record.operationId,
      wireBytes: wireBytes,
    );
  }
}

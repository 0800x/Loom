import 'package:loom_dtn/loom_dtn.dart';
import 'package:loom_storage/loom_storage.dart';

import 'v2_committed_packet_assembler.dart';

/// Durable handoff from committed session ciphertext into DTN custody.
///
/// This service deliberately performs no network operation. It returns only a
/// [LoomStoredDtnPacket], which means the exact encoded OuterEnvelopeV2 bytes
/// have already committed to [packetStore]. A process crash before that commit
/// simply leaves the crypto outbox pending; retrying the same committed row and
/// assembly plan is idempotent.
final class LoomV2PacketCustodyService {
  const LoomV2PacketCustodyService({
    required this.packetStore,
    this.assembler = const LoomV2CommittedPacketAssembler(),
  });

  final LoomPacketStore packetStore;
  final LoomV2CommittedPacketAssembler assembler;

  LoomStoredDtnPacket persistPending({
    required LoomStoredCryptoOutboxRecord stored,
    required LoomV2PacketAssemblyPlan plan,
    required DateTime now,
  }) {
    final draft = assembler.assemblePending(
      stored: stored,
      plan: plan,
      now: now,
    );

    final durable = packetStore.putLocalOutbound(
      operationId: draft.operationId,
      messageId: draft.messageId,
      packetId: draft.packetId,
      exactOuterEnvelopeBytes: draft.wireBytes,
      now: now,
    );

    if (durable.operationId != draft.operationId ||
        durable.messageId != draft.messageId ||
        durable.packetId != draft.packetId) {
      throw const LoomDtnPacketConflict(
        'Durable packet correlation does not match committed crypto outbox',
      );
    }
    return durable;
  }

  /// Persists DTN custody and the local-only MessageId/PacketId/device mapping
  /// required to validate a future E2EE delivery receipt.
  ///
  /// The two SQLite domains cannot share one transaction, so this operation is
  /// intentionally retryable rather than pretending to be cross-database
  /// atomic. DTN custody commits first. If the process dies before correlation
  /// registration, replaying the same committed crypto outbox row returns the
  /// same PacketId/bytes and idempotently completes this second write.
  LoomStoredDtnPacket persistPendingForRecipient({
    required LoomStoredCryptoOutboxRecord stored,
    required LoomV2PacketAssemblyPlan plan,
    required LoomV2MessageStateStore messageStateStore,
    required String recipientDeviceId,
    required DateTime now,
  }) {
    final durable = persistPending(stored: stored, plan: plan, now: now);
    messageStateStore.registerOutboundPacket(
      messageId: durable.messageId ?? stored.record.messageId,
      packetId: durable.packetId,
      recipientDeviceId: recipientDeviceId,
      createdAt: durable.storedAt,
      expiresAt: durable.expiresAt,
    );
    return durable;
  }
}

import 'package:loom_dtn/loom_dtn.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:loom_storage/loom_storage.dart';

/// Trust boundary supplied by the authenticated session/decryption layer.
///
/// A transport, relay, gateway, or hop ACK cannot satisfy this contract merely
/// by passing a boolean. The implementation must resolve [sessionContextId] to
/// an already-authenticated remote device from the E2EE session that produced
/// the protected delivery receipt.
abstract interface class LoomDeliveryReceiptTrustGate {
  bool isVerifiedRemoteDevice({
    required String sessionContextId,
    required String remoteDeviceId,
  });
}

enum LoomDeliveryReceiptApplyStatus {
  confirmed,
  alreadyConfirmed,
  unknownLogicalDeviceSend,
  pendingPacketRecovery,
  lateEvidenceAfterTerminalPacket,
}

final class LoomDeliveryReceiptApplyResult {
  const LoomDeliveryReceiptApplyResult({
    required this.status,
    required this.messageId,
    required this.recipientDeviceId,
    required this.packetId,
    required this.packet,
  });

  final LoomDeliveryReceiptApplyStatus status;
  final String messageId;
  final String recipientDeviceId;
  final String? packetId;
  final LoomStoredDtnPacket? packet;

  bool get recipientDeliveryConfirmed =>
      status == LoomDeliveryReceiptApplyStatus.confirmed ||
      status == LoomDeliveryReceiptApplyStatus.alreadyConfirmed;
}

/// Applies authenticated, end-to-end protected delivery receipts to DTN state.
///
/// Crash invariant across the independent message-state and DTN databases:
///
/// 1. verify the remote device against the authenticated session context;
/// 2. resolve durable (MessageId, recipientDeviceId) -> PacketId correlation;
/// 3. durably stage the receipt in [messageStateStore];
/// 4. mark the packet recipient-confirmed in [packetStore];
/// 5. mark the staged receipt applied.
///
/// A crash between steps 3 and 5 leaves a pending receipt that [recoverPending]
/// can replay. Hop/gateway/relay ACKs never enter this API and therefore cannot
/// create the user-facing Delivered state.
final class LoomV2DeliveryReceiptProcessor {
  const LoomV2DeliveryReceiptProcessor({
    required this.messageStateStore,
    required this.packetStore,
    required this.trustGate,
  });

  final LoomV2MessageStateStore messageStateStore;
  final LoomPacketStore packetStore;
  final LoomDeliveryReceiptTrustGate trustGate;

  /// Registers receipt correlation after exact packet bytes are already under
  /// durable local DTN custody.
  LoomOutboundMessagePacketRecord trackCustodiedOutbound({
    required LoomStoredDtnPacket packet,
    required String messageId,
    required String recipientDeviceId,
  }) {
    if (packet.origin != LoomDtnPacketOrigin.localOutbound ||
        packet.messageId != messageId ||
        packet.operationId == null) {
      throw const LoomDtnPacketConflict(
        'Only correlated local outbound custody may be tracked for receipts',
      );
    }
    return messageStateStore.registerOutboundPacket(
      messageId: messageId,
      packetId: packet.packetId,
      recipientDeviceId: recipientDeviceId,
      createdAt: packet.storedAt,
      expiresAt: packet.expiresAt,
    );
  }

  LoomDeliveryReceiptApplyResult processVerified({
    required LoomDeliveryReceiptV2 receipt,
    required String sessionContextId,
    required DateTime observedAt,
  }) {
    receipt.validate();
    _validateContextId(sessionContextId);
    final observed = observedAt.toUtc();

    if (!trustGate.isVerifiedRemoteDevice(
      sessionContextId: sessionContextId,
      remoteDeviceId: receipt.recipientDeviceId,
    )) {
      throw StateError(
        'Delivery receipt remote device is not verified by the session context',
      );
    }

    final correlation = messageStateStore.readOutboundPacket(
      messageId: receipt.forMessageId,
      recipientDeviceId: receipt.recipientDeviceId,
    );
    if (correlation == null) {
      // Old/pruned/foreign receipts are authenticated but have no active local
      // logical-device send to confirm. Do not invent a PacketId or Delivered.
      return LoomDeliveryReceiptApplyResult(
        status: LoomDeliveryReceiptApplyStatus.unknownLogicalDeviceSend,
        messageId: receipt.forMessageId,
        recipientDeviceId: receipt.recipientDeviceId,
        packetId: null,
        packet: null,
      );
    }

    final staged = messageStateStore.stageDeliveryReceipt(
      messageId: correlation.messageId,
      packetId: correlation.packetId,
      recipientDeviceId: correlation.recipientDeviceId,
      observedAt: observed,
    );

    return _applyStaged(staged, observed);
  }

  /// Replays receipts that were durably staged before a crash but not fully
  /// applied to the independent DTN database.
  List<LoomDeliveryReceiptApplyResult> recoverPending({
    required DateTime observedAt,
    int limit = 100,
  }) {
    final observed = observedAt.toUtc();
    final pending = messageStateStore.listPendingDeliveryReceipts(limit: limit);
    return pending
        .map((receipt) => _applyStaged(receipt, observed))
        .toList(growable: false);
  }

  LoomDeliveryReceiptApplyResult _applyStaged(
    LoomPendingDeliveryReceiptRecord staged,
    DateTime observed,
  ) {
    if (staged.state == LoomPendingDeliveryReceiptState.applied) {
      final packet = packetStore.read(staged.packetId);
      return LoomDeliveryReceiptApplyResult(
        status: LoomDeliveryReceiptApplyStatus.alreadyConfirmed,
        messageId: staged.messageId,
        recipientDeviceId: staged.recipientDeviceId,
        packetId: staged.packetId,
        packet: packet,
      );
    }

    final packet = packetStore.read(staged.packetId);
    if (packet == null) {
      // Keep the receipt pending. Packet custody may be restored/recovered from
      // another durable domain before the next replay pass.
      return LoomDeliveryReceiptApplyResult(
        status: LoomDeliveryReceiptApplyStatus.pendingPacketRecovery,
        messageId: staged.messageId,
        recipientDeviceId: staged.recipientDeviceId,
        packetId: staged.packetId,
        packet: null,
      );
    }

    if (packet.state == LoomDtnPacketState.recipientConfirmed) {
      messageStateStore.markDeliveryReceiptApplied(
        messageId: staged.messageId,
        recipientDeviceId: staged.recipientDeviceId,
        appliedAt: observed,
      );
      return LoomDeliveryReceiptApplyResult(
        status: LoomDeliveryReceiptApplyStatus.alreadyConfirmed,
        messageId: staged.messageId,
        recipientDeviceId: staged.recipientDeviceId,
        packetId: staged.packetId,
        packet: packet,
      );
    }

    // EXPIRED/CANCELLED remain terminal routing states in the current v2
    // lifecycle. A late authenticated receipt is retained as applied evidence
    // instead of resurrecting routing/copy state or looping recovery forever.
    if (packet.state == LoomDtnPacketState.expired ||
        packet.state == LoomDtnPacketState.cancelledLocal) {
      messageStateStore.markDeliveryReceiptApplied(
        messageId: staged.messageId,
        recipientDeviceId: staged.recipientDeviceId,
        appliedAt: observed,
      );
      return LoomDeliveryReceiptApplyResult(
        status: LoomDeliveryReceiptApplyStatus.lateEvidenceAfterTerminalPacket,
        messageId: staged.messageId,
        recipientDeviceId: staged.recipientDeviceId,
        packetId: staged.packetId,
        packet: packet,
      );
    }

    final confirmed = packetStore.markRecipientConfirmed(
      staged.packetId,
      observed,
    );
    messageStateStore.markDeliveryReceiptApplied(
      messageId: staged.messageId,
      recipientDeviceId: staged.recipientDeviceId,
      appliedAt: observed,
    );

    return LoomDeliveryReceiptApplyResult(
      status: LoomDeliveryReceiptApplyStatus.confirmed,
      messageId: staged.messageId,
      recipientDeviceId: staged.recipientDeviceId,
      packetId: staged.packetId,
      packet: confirmed,
    );
  }

  static void _validateContextId(String value) {
    if (value.trim() != value ||
        value.length < 8 ||
        value.length > 256 ||
        value.contains('\r') ||
        value.contains('\n')) {
      throw const FormatException('Invalid authenticated session context id');
    }
  }
}

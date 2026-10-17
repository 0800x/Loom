import 'packet_store.dart';
import 'router.dart';
import 'transfer_store.dart';

/// Hop-local acknowledgement for one durable prepared transfer.
///
/// This proves only that the next authenticated hop has durable custody for the
/// PacketId. It is never an end-to-end recipient delivery confirmation.
/// [acceptedAt] is peer-provided informational time; local custody/retry state
/// must use the sender's own observation clock instead.
final class LoomDtnHopAck {
  const LoomDtnHopAck({
    required this.transmissionId,
    required this.packetId,
    required this.acceptedAt,
    required this.duplicate,
  });

  final String transmissionId;
  final String packetId;
  final DateTime acceptedAt;
  final bool duplicate;

  bool get recipientDeliveryConfirmed => false;
}

sealed class LoomDtnSendResult {
  const LoomDtnSendResult();
}

final class LoomDtnSendAccepted extends LoomDtnSendResult {
  const LoomDtnSendAccepted(this.ack);

  final LoomDtnHopAck ack;
}

final class LoomDtnSendFailed extends LoomDtnSendResult {
  const LoomDtnSendFailed({
    required this.completedAt,
    required this.errorCode,
  });

  /// Transport-provided informational time. The executor does not trust it for
  /// local state transitions; it records its own observation time.
  final DateTime completedAt;
  final String errorCode;
}

/// Low-level transport port implemented by Internet/LAN/Nearby adapters.
///
/// The adapter receives only a durably prepared opaque transfer. It has no
/// access to message plaintext, session keys, ratchet state or crypto outbox.
abstract interface class LoomDtnTransferSender {
  Future<LoomDtnSendResult> sendPrepared(LoomStoredDtnTransfer transfer);
}

enum LoomDtnExecutionStatus {
  accepted,
  failed,
  alreadyAccepted,
}

final class LoomDtnExecutionResult {
  const LoomDtnExecutionResult({
    required this.status,
    required this.transfer,
    required this.packet,
  });

  final LoomDtnExecutionStatus status;
  final LoomStoredDtnTransfer transfer;
  final LoomStoredDtnPacket packet;
}

/// Coordinates pure routing, durable transfer preparation and transport IO.
///
/// Preparation and execution are intentionally separate. Recovery code can
/// call [listPreparedTransfers] on the store and resume the exact transfer after
/// process death rather than planning a new replica or spending copy budget
/// twice.
final class LoomDtnTransferExecutor {
  LoomDtnTransferExecutor({
    required this.packetStore,
    required this.transferStore,
    this.router = const LoomMessageRouter(),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final LoomPacketStore packetStore;
  final LoomTransferStore transferStore;
  final LoomMessageRouter router;
  final DateTime Function() _clock;

  LoomStoredDtnTransfer? prepareNext({
    required String packetId,
    required Iterable<LoomDtnOpportunity> opportunities,
    required String transmissionId,
    required DateTime now,
  }) {
    final packet = packetStore.read(packetId);
    if (packet == null) throw StateError('DTN packet $packetId does not exist');
    final plan = router.planNext(
      packet: packet,
      opportunities: opportunities.where((opportunity) =>
          opportunity.directRecipient ||
          !transferStore.hasAcceptedTransfer(
              packetId, opportunity.opportunityId)),
      now: now,
    );
    if (plan == null) return null;
    return transferStore.prepareTransfer(
      transmissionId: transmissionId,
      plan: plan,
      now: now,
    );
  }

  Future<LoomDtnExecutionResult> executePrepared({
    required String transmissionId,
    required LoomDtnTransferSender sender,
    Duration retryDelay = const Duration(minutes: 2),
    Duration directRecipientReceiptGrace = const Duration(minutes: 5),
  }) async {
    if (retryDelay.isNegative || directRecipientReceiptGrace.isNegative) {
      throw ArgumentError('DTN retry/grace durations must be non-negative');
    }
    final initial = transferStore.readTransfer(transmissionId);
    if (initial == null) {
      throw StateError('DTN transfer $transmissionId does not exist');
    }

    if (initial.state == LoomDtnTransferState.accepted ||
        initial.state == LoomDtnTransferState.custodyReleased) {
      final packet = packetStore.read(initial.packetId);
      if (packet == null) {
        throw StateError('DTN packet ${initial.packetId} disappeared');
      }
      return LoomDtnExecutionResult(
        status: LoomDtnExecutionStatus.alreadyAccepted,
        transfer: initial,
        packet: packet,
      );
    }
    if (initial.state != LoomDtnTransferState.prepared) {
      throw LoomDtnPacketConflict(
        'Transfer $transmissionId is ${initial.state.name}; prepare a new transmission',
      );
    }

    LoomDtnSendResult result;
    try {
      result = await sender.sendPrepared(initial);
    } catch (_) {
      result = LoomDtnSendFailed(
        completedAt: _clock().toUtc(),
        errorCode: 'transport_exception',
      );
    }

    // Remote/adapter timestamps are not authority for local retry state. Clamp
    // a backwards-moving local wall clock to the durable preparation time.
    final observedAt = _localObservationNotBefore(initial.preparedAt);

    if (result case LoomDtnSendAccepted(:final ack)) {
      _validateAck(initial, ack);
      final accepted = transferStore.markTransferAccepted(
        transmissionId,
        observedAt,
      );
      var packet = packetStore.read(initial.packetId);
      if (packet == null) {
        throw StateError('DTN packet ${initial.packetId} disappeared');
      }

      // An online node cannot deliver to an offline handset. Keep retained
      // copies eligible for Nearby; accepted-transfer history prevents another
      // upload to this node from consuming that remaining copy budget.
      if (initial.reason == LoomDtnTransferReason.destinationNode &&
          packet.state != LoomDtnPacketState.recipientConfirmed) {
        packet = packetStore.markGatewayAccepted(packet.packetId, observedAt);
      }

      // A direct-recipient hop ACK means the recipient device has durable packet
      // custody, not that session decryption succeeded. Avoid an immediate resend
      // storm while retaining the packet until an E2EE delivery receipt arrives.
      if (initial.reason == LoomDtnTransferReason.directRecipient &&
          packet.isEligibleForForwarding) {
        packet = packetStore.recordAttempt(
          packet.packetId,
          attemptedAt: observedAt,
          nextAttemptAt: observedAt.add(directRecipientReceiptGrace),
        );
      }

      return LoomDtnExecutionResult(
        status: LoomDtnExecutionStatus.accepted,
        transfer: accepted,
        packet: packet,
      );
    }

    final failed = result as LoomDtnSendFailed;
    _validateErrorCode(failed.errorCode);
    final terminal = transferStore.markTransferFailed(
      transmissionId,
      observedAt,
      errorCode: failed.errorCode,
    );

    var packet = packetStore.read(initial.packetId);
    if (packet == null) {
      throw StateError('DTN packet ${initial.packetId} disappeared');
    }
    if (packet.isEligibleForForwarding) {
      packet = packetStore.recordAttempt(
        packet.packetId,
        attemptedAt: observedAt,
        nextAttemptAt: observedAt.add(retryDelay),
        errorCode: failed.errorCode,
      );
    }

    return LoomDtnExecutionResult(
      status: LoomDtnExecutionStatus.failed,
      transfer: terminal,
      packet: packet,
    );
  }

  DateTime _localObservationNotBefore(DateTime preparedAt) {
    final observed = _clock().toUtc();
    final prepared = preparedAt.toUtc();
    return observed.isBefore(prepared) ? prepared : observed;
  }

  static void _validateAck(
    LoomStoredDtnTransfer transfer,
    LoomDtnHopAck ack,
  ) {
    if (ack.transmissionId != transfer.transmissionId ||
        ack.packetId != transfer.packetId) {
      throw const LoomDtnPacketConflict(
        'Hop ACK does not match prepared transmission and PacketId',
      );
    }
  }

  static void _validateErrorCode(String value) {
    if (!RegExp(r'^[a-z0-9][a-z0-9_.-]{0,63}$').hasMatch(value)) {
      throw const FormatException('Invalid structured DTN error code');
    }
  }
}

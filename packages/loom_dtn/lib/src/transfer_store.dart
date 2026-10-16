import 'dart:typed_data';

import 'router.dart';

enum LoomDtnTransferState {
  prepared,
  accepted,
  failed,
  custodyReleased,
  cancelled,
}

/// Exact, durably prepared next-hop packet revision.
///
/// A transport may send [wireBytes] only after obtaining this object from a
/// [LoomTransferStore]. It uses the same logical PacketId as its source packet
/// but contains forwarding-state values specific to this next-hop operation.
final class LoomStoredDtnTransfer {
  LoomStoredDtnTransfer({
    required this.transmissionId,
    required this.packetId,
    required this.opportunityId,
    required this.reason,
    required Uint8List wireBytes,
    required this.copiesBefore,
    required this.copiesGranted,
    required this.copiesRetainedAfterSuccess,
    required this.requiresSingleCopyCustodyHandoff,
    required this.preparedAt,
    required this.state,
    required this.completedAt,
    required this.errorCode,
  }) : _wireBytes = Uint8List.fromList(wireBytes);

  final String transmissionId;
  final String packetId;
  final String opportunityId;
  final LoomDtnTransferReason reason;
  final Uint8List _wireBytes;
  final int copiesBefore;
  final int copiesGranted;
  final int copiesRetainedAfterSuccess;
  final bool requiresSingleCopyCustodyHandoff;
  final DateTime preparedAt;
  final LoomDtnTransferState state;
  final DateTime? completedAt;
  final String? errorCode;

  Uint8List get wireBytes => Uint8List.fromList(_wireBytes);

  bool get isTerminal => state != LoomDtnTransferState.prepared;
}

/// Durable execution boundary for a pure [LoomDtnTransferPlan].
///
/// Implementations must commit the exact next-hop bytes before returning from
/// [prepareTransfer]. Only one prepared transfer may exist for a packet at a
/// time so concurrent bearers cannot overspend the Spray-and-Wait copy budget.
abstract interface class LoomTransferStore {
  LoomStoredDtnTransfer prepareTransfer({
    required String transmissionId,
    required LoomDtnTransferPlan plan,
    required DateTime now,
  });

  LoomStoredDtnTransfer? readTransfer(String transmissionId);

  /// Persisted encounter history prevents spending another copy on the same
  /// authenticated custodian after reconnecting or restarting the app.
  bool hasAcceptedTransfer(String packetId, String opportunityId);

  List<LoomStoredDtnTransfer> listPreparedTransfers({int limit = 50});

  LoomStoredDtnTransfer markTransferAccepted(
    String transmissionId,
    DateTime acceptedAt,
  );

  LoomStoredDtnTransfer markTransferFailed(
    String transmissionId,
    DateTime failedAt, {
    required String errorCode,
  });

  LoomStoredDtnTransfer cancelPreparedTransfer(
    String transmissionId,
    DateTime cancelledAt,
  );

  /// Restores the one local forwarding token after a previously accepted
  /// single-copy gateway custody handoff is explicitly abandoned.
  ///
  /// This is valid only before the packet reaches relay-accepted or recipient-
  /// confirmed state. It exists so a dead gateway cannot permanently strand a
  /// single-copy packet.
  LoomStoredDtnTransfer releaseSingleCopyHandoff(
    String transmissionId,
    DateTime releasedAt, {
    required String errorCode,
  });
}

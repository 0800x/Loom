import 'dart:async';
import 'dart:typed_data';

import 'package:loom_dtn/loom_dtn.dart';
import 'package:loom_protocol/loom_protocol.dart';

import 'nearby_transport.dart';

typedef LoomNearbyDtnDestinationRoute = String? Function(String packetId);

typedef LoomNearbyDtnRoutedDurableAccept = FutureOr<LoomDtnHopAck> Function({
  required String transmissionId,
  required Uint8List exactOuterEnvelopeBytes,
  required String? destinationNodeDomain,
});

/// Sends one durably prepared DTN transfer over an already authenticated nearby
/// secure connection.
///
/// Construction of [connection] belongs to the peer-authentication layer. This
/// adapter owns no identity/session keys and never receives message plaintext.
final class LoomNearbyDtnTransferSender implements LoomDtnTransferSender {
  LoomNearbyDtnTransferSender({
    required this.connection,
    this.destinationRoute,
    this.ackTimeout = const Duration(seconds: 20),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final LoomNearbySecureConnection connection;
  final LoomNearbyDtnDestinationRoute? destinationRoute;
  final Duration ackTimeout;
  final DateTime Function() _clock;

  @override
  Future<LoomDtnSendResult> sendPrepared(LoomStoredDtnTransfer transfer) async {
    if (transfer.state != LoomDtnTransferState.prepared) {
      return LoomDtnSendFailed(
        completedAt: _clock().toUtc(),
        errorCode: 'transfer_not_prepared',
      );
    }
    if (ackTimeout <= Duration.zero) {
      return LoomDtnSendFailed(
        completedAt: _clock().toUtc(),
        errorCode: 'invalid_ack_timeout',
      );
    }

    try {
      final frame = LoomDtnPeerFrameV2Codec.encode(
        LoomDtnPacketTransferFrameV2(
          transmissionId: transfer.transmissionId,
          outerEnvelopeBytes: transfer.wireBytes,
          destinationNodeDomain: destinationRoute?.call(transfer.packetId),
        ),
      );
      await connection.send(frame);
      final responseBytes = await connection.receive(timeout: ackTimeout);
      final response = LoomDtnPeerFrameV2Codec.decode(
        Uint8List.fromList(responseBytes),
      );
      if (response is! LoomDtnHopAckFrameV2) {
        return LoomDtnSendFailed(
          completedAt: _clock().toUtc(),
          errorCode: 'unexpected_peer_frame',
        );
      }
      return LoomDtnSendAccepted(
        LoomDtnHopAck(
          transmissionId: response.transmissionId,
          packetId: response.packetId,
          acceptedAt: response.acceptedAt,
          duplicate: response.duplicate,
        ),
      );
    } on TimeoutException {
      return LoomDtnSendFailed(
        completedAt: _clock().toUtc(),
        errorCode: 'nearby_timeout',
      );
    } on FormatException {
      return LoomDtnSendFailed(
        completedAt: _clock().toUtc(),
        errorCode: 'invalid_peer_frame',
      );
    } on ArgumentError {
      return LoomDtnSendFailed(
        completedAt: _clock().toUtc(),
        errorCode: 'nearby_frame_too_large',
      );
    } catch (_) {
      return LoomDtnSendFailed(
        completedAt: _clock().toUtc(),
        errorCode: 'nearby_io_error',
      );
    }
  }
}

/// Receive-side handler for a single DTN packet-transfer frame on an already
/// authenticated nearby secure connection.
///
/// [durablyAccept] must return only after the packet has entered durable DTN
/// custody. The ACK is serialized and sent strictly after that future resolves.
/// This keeps transport from acknowledging parse-only/volatile state.
final class LoomNearbyDtnTransferReceiver {
  const LoomNearbyDtnTransferReceiver({
    required this.connection,
    required this.durablyAccept,
    this.durablyAcceptRouted,
  });

  final LoomNearbySecureConnection connection;

  /// Application/messaging-owned durable custody callback.
  ///
  /// The callback is expected to perform peer-session trust validation in the
  /// composition layer before returning the hop ACK.
  final FutureOr<LoomDtnHopAck> Function({
    required String transmissionId,
    required Uint8List exactOuterEnvelopeBytes,
  })
  durablyAccept;

  /// Optional route-aware durable boundary. New product runtimes use this to
  /// commit the destination Node sidecar with replica custody. Keeping the
  /// original callback required preserves compatibility for existing callers
  /// and route-less peer frames.
  final LoomNearbyDtnRoutedDurableAccept? durablyAcceptRouted;

  Future<LoomDtnHopAck> receiveAndAcknowledge({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final bytes = await connection.receive(timeout: timeout);
    return acknowledgeFrame(bytes);
  }

  Future<LoomDtnHopAck> acknowledgeFrame(List<int> bytes) async {
    final frame = LoomDtnPeerFrameV2Codec.decode(Uint8List.fromList(bytes));
    if (frame is! LoomDtnPacketTransferFrameV2) {
      throw const FormatException('Expected DTN packet-transfer peer frame');
    }

    final routedAccept = durablyAcceptRouted;
    final ack = routedAccept == null
        ? await durablyAccept(
            transmissionId: frame.transmissionId,
            exactOuterEnvelopeBytes: frame.outerEnvelopeBytes,
          )
        : await routedAccept(
            transmissionId: frame.transmissionId,
            exactOuterEnvelopeBytes: frame.outerEnvelopeBytes,
            destinationNodeDomain: frame.destinationNodeDomain,
          );
    if (ack.transmissionId != frame.transmissionId) {
      throw const FormatException(
        'Durable intake returned ACK for a different transmission',
      );
    }

    final ackFrame = LoomDtnHopAckFrameV2(
      transmissionId: ack.transmissionId,
      packetId: ack.packetId,
      acceptedAt: ack.acceptedAt,
      duplicate: ack.duplicate,
    );
    await connection.send(LoomDtnPeerFrameV2Codec.encode(ackFrame));
    return ack;
  }
}

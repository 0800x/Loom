import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:loom_dtn/loom_dtn.dart';
import 'package:loom_protocol/loom_protocol.dart';

import 'direct_node_delivery.dart';
import 'nearby_dtn_peer_bootstrap.dart';
import 'nearby_transport.dart';

const _probeKind = 'nearby.internet-gateway.probe.v1';
const _capabilityKind = 'nearby.internet-gateway.capability.v1';
const _packetKind = 'nearby.internet-gateway.packet.v1';
const _ackKind = 'nearby.internet-gateway.ack.v1';
const _doneKind = 'nearby.internet-gateway.done.v1';

final class LoomNearbyInternetGatewayForwardResult {
  const LoomNearbyInternetGatewayForwardResult({
    required this.gatewayOffered,
    required this.attempted,
    required this.accepted,
    required this.failed,
  });

  final bool gatewayOffered;
  final int attempted;
  final int accepted;
  final int failed;
}

typedef LoomNearbyGatewayDurableAccept = FutureOr<LoomDtnHopAck> Function({
  required String transmissionId,
  required Uint8List exactOuterEnvelopeBytes,
  required String destinationNodeDomain,
});

/// Authenticated Nearby handoff to a peer that claims it can reach Internet
/// destination Nodes.
///
/// The destination route travels as a sidecar inside the already authenticated
/// and encrypted Nearby channel. It is deliberately not trusted by the gateway:
/// the receiving phone must independently verify the Node before using direct
/// ingress. A self-claimed Internet gateway is only a `claimedGateway` routing
/// opportunity, so Spray-and-Wait never gives it the final packet copy.
final class LoomNearbyInternetGatewayEncounter {
  LoomNearbyInternetGatewayEncounter({
    required this.packetStore,
    required this.routeStore,
    required this.transferExecutor,
    required this.durablyAccept,
    LoomNearbyDtnPeerBootstrap? bootstrap,
    DateTime Function()? clock,
  }) : bootstrap = bootstrap ?? LoomNearbyDtnPeerBootstrap(),
       _clock = clock ?? DateTime.now;

  final LoomPacketStore packetStore;
  final LoomPacketRouteStore routeStore;
  final LoomDtnTransferExecutor transferExecutor;
  final LoomNearbyGatewayDurableAccept durablyAccept;
  final LoomNearbyDtnPeerBootstrap bootstrap;
  final DateTime Function() _clock;
  int _transmissionSequence = 0;

  Future<LoomNearbyInternetGatewayForwardResult> forwardOverLink({
    required LoomNearbyLink link,
    required LoomDirectTransportSigner signer,
    int maxPackets = 8,
  }) async {
    _validateMaxPackets(maxPackets);
    LoomNearbyDtnPeerSession? session;
    try {
      session = await bootstrap.establishAsInitiator(
        link: link,
        signer: signer,
        canStoreCarry: true,
      );
      await _sendJson(session.connection, const <String, Object?>{
        'kind': _probeKind,
        'version': 1,
      });
      final capability = await _receiveJson(session.connection);
      if (capability['kind'] != _capabilityKind ||
          capability['version'] != 1 ||
          capability['available'] is! bool) {
        throw const FormatException(
          'Invalid Nearby Internet gateway capability',
        );
      }
      final offered = capability['available'] as bool;
      if (!offered) {
        await _sendJson(session.connection, const <String, Object?>{
          'kind': _doneKind,
          'version': 1,
        });
        return const LoomNearbyInternetGatewayForwardResult(
          gatewayOffered: false,
          attempted: 0,
          accepted: 0,
          failed: 0,
        );
      }

      final opportunity = LoomDtnOpportunity(
        opportunityId: 'internet-gateway:${session.remoteFingerprint}',
        authenticated: true,
        destinationNode: false,
        directRecipient: false,
        gatewayClaim: LoomGatewayClaimState.claimed,
        supportedRelayScopes: Set<LoomRoutingScopeV2>.unmodifiable(
          LoomRoutingScopeV2.values,
        ),
        canStoreCarry: true,
        linkQualityPercent: 80,
        congestionPercent: 0,
        batteryConstrained: false,
        recentSuccessfulTransfers: 0,
        recentFailedTransfers: 0,
      );
      final sender = _NearbyInternetGatewayTransferSender(
        connection: session.connection,
        routeStore: routeStore,
        clock: _clock,
      );
      var attempted = 0;
      var accepted = 0;
      var failed = 0;
      final attemptedPackets = <String>{};

      final prepared = transferExecutor.transferStore
          .listPreparedTransfers(limit: maxPackets)
          .where(
            (transfer) => transfer.opportunityId == opportunity.opportunityId,
          )
          .toList(growable: false);
      for (final transfer in prepared) {
        if (attempted >= maxPackets) break;
        if (routeStore.readDestinationRoute(transfer.packetId) == null)
          continue;
        attemptedPackets.add(transfer.packetId);
        final result = await transferExecutor.executePrepared(
          transmissionId: transfer.transmissionId,
          sender: sender,
        );
        attempted++;
        if (result.status == LoomDtnExecutionStatus.accepted ||
            result.status == LoomDtnExecutionStatus.alreadyAccepted) {
          accepted++;
        } else {
          failed++;
        }
      }

      if (attempted < maxPackets) {
        final now = _clock().toUtc();
        for (final packet in packetStore.listEligible(
          now,
          limit: maxPackets * 2,
        )) {
          if (attempted >= maxPackets) break;
          if (!attemptedPackets.add(packet.packetId)) continue;
          if (routeStore.readDestinationRoute(packet.packetId) == null)
            continue;
          final preparedTransfer = transferExecutor.prepareNext(
            packetId: packet.packetId,
            opportunities: <LoomDtnOpportunity>[opportunity],
            transmissionId: _nextTransmissionId(now),
            now: now,
          );
          if (preparedTransfer == null) continue;
          final result = await transferExecutor.executePrepared(
            transmissionId: preparedTransfer.transmissionId,
            sender: sender,
          );
          attempted++;
          if (result.status == LoomDtnExecutionStatus.accepted ||
              result.status == LoomDtnExecutionStatus.alreadyAccepted) {
            accepted++;
          } else {
            failed++;
          }
        }
      }

      await _sendJson(session.connection, const <String, Object?>{
        'kind': _doneKind,
        'version': 1,
      });
      return LoomNearbyInternetGatewayForwardResult(
        gatewayOffered: true,
        attempted: attempted,
        accepted: accepted,
        failed: failed,
      );
    } finally {
      if (session != null) {
        await session.connection.close();
      } else {
        try {
          await link.close();
        } catch (_) {}
      }
    }
  }

  Future<int> acceptOverLink({
    required LoomNearbyLink link,
    required LoomDirectTransportSigner signer,
    required bool internetGatewayAvailable,
    int maxPackets = 8,
    Duration idleTimeout = const Duration(seconds: 20),
  }) async {
    _validateMaxPackets(maxPackets);
    if (idleTimeout <= Duration.zero) {
      throw ArgumentError.value(idleTimeout, 'idleTimeout');
    }
    LoomNearbyDtnPeerSession? session;
    try {
      session = await bootstrap.establishAsResponder(
        link: link,
        signer: signer,
        canStoreCarry: true,
      );
      final probe = await _receiveJson(
        session.connection,
        timeout: idleTimeout,
      );
      if (probe['kind'] != _probeKind || probe['version'] != 1) {
        throw const FormatException('Invalid Nearby Internet gateway probe');
      }
      await _sendJson(session.connection, <String, Object?>{
        'kind': _capabilityKind,
        'version': 1,
        'available': internetGatewayAvailable,
      });
      if (!internetGatewayAvailable) {
        final done = await _receiveJson(
          session.connection,
          timeout: idleTimeout,
        );
        if (done['kind'] != _doneKind || done['version'] != 1) {
          throw const FormatException(
            'Invalid Nearby Internet gateway completion',
          );
        }
        return 0;
      }

      var accepted = 0;
      for (var index = 0; index < maxPackets; index++) {
        Map<String, Object?> body;
        try {
          body = await _receiveJson(session.connection, timeout: idleTimeout);
        } on TimeoutException {
          break;
        }
        if (body['kind'] == _doneKind && body['version'] == 1) break;
        if (body['kind'] != _packetKind ||
            body['version'] != 1 ||
            body['frameBase64'] is! String ||
            body['destinationNodeDomain'] is! String) {
          throw const FormatException('Invalid Nearby Internet gateway packet');
        }
        final domain = LoomAddress.normalizeHomeNode(
          body['destinationNodeDomain'] as String,
        );
        final frameBytes = _decodeBase64(
          body['frameBase64'] as String,
          LoomDtnPeerFrameV2Codec.maxFrameBytes,
        );
        final frame = LoomDtnPeerFrameV2Codec.decode(frameBytes);
        if (frame is! LoomDtnPacketTransferFrameV2) {
          throw const FormatException(
            'Gateway frame did not contain a DTN transfer',
          );
        }
        final ack = await durablyAccept(
          transmissionId: frame.transmissionId,
          exactOuterEnvelopeBytes: frame.outerEnvelopeBytes,
          destinationNodeDomain: domain,
        );
        if (ack.transmissionId != frame.transmissionId ||
            ack.packetId != frame.packetId) {
          throw const LoomDtnPacketConflict(
            'Gateway durable custody ACK does not match the transfer',
          );
        }
        await _sendJson(session.connection, <String, Object?>{
          'kind': _ackKind,
          'version': 1,
          'frameBase64': base64UrlEncode(
            LoomDtnPeerFrameV2Codec.encode(
              LoomDtnHopAckFrameV2(
                transmissionId: ack.transmissionId,
                packetId: ack.packetId,
                acceptedAt: ack.acceptedAt,
                duplicate: ack.duplicate,
              ),
            ),
          ).replaceAll('=', ''),
        });
        accepted++;
      }
      return accepted;
    } finally {
      if (session != null) {
        await session.connection.close();
      } else {
        try {
          await link.close();
        } catch (_) {}
      }
    }
  }

  String _nextTransmissionId(DateTime now) =>
      'nearby-gateway-${now.microsecondsSinceEpoch}-${_transmissionSequence++}';

  static void _validateMaxPackets(int value) {
    if (value < 1 || value > 50) throw ArgumentError.value(value, 'maxPackets');
  }
}

final class _NearbyInternetGatewayTransferSender
    implements LoomDtnTransferSender {
  _NearbyInternetGatewayTransferSender({
    required this.connection,
    required this.routeStore,
    required this.clock,
  });

  final LoomNearbySecureConnection connection;
  final LoomPacketRouteStore routeStore;
  final DateTime Function() clock;

  @override
  Future<LoomDtnSendResult> sendPrepared(LoomStoredDtnTransfer transfer) async {
    final route = routeStore.readDestinationRoute(transfer.packetId);
    if (route == null) {
      return LoomDtnSendFailed(
        completedAt: clock().toUtc(),
        errorCode: 'gateway-route-missing',
      );
    }
    try {
      final frame = LoomDtnPeerFrameV2Codec.encode(
        LoomDtnPacketTransferFrameV2(
          transmissionId: transfer.transmissionId,
          outerEnvelopeBytes: transfer.wireBytes,
        ),
      );
      await _sendJson(connection, <String, Object?>{
        'kind': _packetKind,
        'version': 1,
        'destinationNodeDomain': route.destinationNodeDomain,
        'frameBase64': base64UrlEncode(frame).replaceAll('=', ''),
      });
      final body = await _receiveJson(connection);
      if (body['kind'] != _ackKind ||
          body['version'] != 1 ||
          body['frameBase64'] is! String) {
        return LoomDtnSendFailed(
          completedAt: clock().toUtc(),
          errorCode: 'gateway-ack-invalid',
        );
      }
      final ackFrame = LoomDtnPeerFrameV2Codec.decode(
        _decodeBase64(
          body['frameBase64'] as String,
          LoomDtnPeerFrameV2Codec.maxFrameBytes,
        ),
      );
      if (ackFrame is! LoomDtnHopAckFrameV2 ||
          ackFrame.transmissionId != transfer.transmissionId ||
          ackFrame.packetId != transfer.packetId) {
        return LoomDtnSendFailed(
          completedAt: clock().toUtc(),
          errorCode: 'gateway-ack-mismatch',
        );
      }
      return LoomDtnSendAccepted(
        LoomDtnHopAck(
          transmissionId: ackFrame.transmissionId,
          packetId: ackFrame.packetId,
          acceptedAt: ackFrame.acceptedAt,
          duplicate: ackFrame.duplicate,
        ),
      );
    } catch (_) {
      return LoomDtnSendFailed(
        completedAt: clock().toUtc(),
        errorCode: 'gateway-nearby-failed',
      );
    }
  }
}

Future<void> _sendJson(
  LoomNearbySecureConnection connection,
  Map<String, Object?> value,
) => connection.send(utf8.encode(jsonEncode(value)));

Future<Map<String, Object?>> _receiveJson(
  LoomNearbySecureConnection connection, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final bytes = await connection.receive(timeout: timeout);
  final decoded = jsonDecode(utf8.decode(bytes));
  if (decoded is! Map) {
    throw const FormatException(
      'Nearby Internet gateway frame must be an object',
    );
  }
  return decoded.map(
    (key, value) => MapEntry(key.toString(), value as Object?),
  );
}

Uint8List _decodeBase64(String value, int maxBytes) {
  if (value.isEmpty || !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value)) {
    throw const FormatException('Invalid Nearby Internet gateway base64');
  }
  final bytes = base64Url.decode(base64Url.normalize(value));
  if (bytes.isEmpty ||
      bytes.length > maxBytes ||
      base64UrlEncode(bytes).replaceAll('=', '') != value) {
    throw const FormatException('Invalid Nearby Internet gateway base64');
  }
  return Uint8List.fromList(bytes);
}

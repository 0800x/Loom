import 'package:loom_dtn/loom_dtn.dart';
import 'package:loom_models/loom_models.dart';
import 'package:loom_protocol/loom_protocol.dart';

import 'direct_node_delivery.dart';

typedef LoomDestinationNodeDiscovery = Future<LoomWellKnownNode> Function(
  String domain,
);

final class LoomDestinationNodeUplinkResult {
  const LoomDestinationNodeUplinkResult({
    required this.attempted,
    required this.accepted,
    required this.failed,
    required this.deferred,
    required this.resumed,
  });

  final int attempted;
  final int accepted;
  final int failed;
  final int deferred;
  final int resumed;
}

/// Drains durable DTN custody directly into each packet's verified destination
/// node.
///
/// Destination route sidecars are hints only. Every network upload first
/// re-verifies the advertised Node through signed well-known discovery. Exact
/// prepared transfers are resumed before any new planning so process death
/// cannot spend the Spray-and-Wait copy budget twice.
final class LoomDestinationNodeUplink {
  LoomDestinationNodeUplink({
    required this.packetStore,
    required this.routeStore,
    required this.transferExecutor,
    required this.signer,
    LoomDestinationNodeDiscovery? discoverNode,
    LoomDirectHttpPoster? poster,
    DateTime Function()? clock,
  }) : _discoverNode = discoverNode ?? LoomNodeClient().discoverDomain,
       poster = poster ?? LoomIoDirectHttpPoster(),
       _clock = clock ?? DateTime.now;

  final LoomPacketStore packetStore;
  final LoomPacketRouteStore routeStore;
  final LoomDtnTransferExecutor transferExecutor;
  final LoomDirectTransportSigner signer;
  final LoomDirectHttpPoster poster;
  final LoomDestinationNodeDiscovery _discoverNode;
  final DateTime Function() _clock;
  int _sequence = 0;

  Future<LoomDestinationNodeUplinkResult> drain({
    int maxPackets = 8,
    Duration retryDelay = const Duration(minutes: 2),
  }) async {
    if (maxPackets < 1 || maxPackets > 50) {
      throw RangeError.range(maxPackets, 1, 50, 'maxPackets');
    }
    if (retryDelay.isNegative) {
      throw ArgumentError.value(retryDelay, 'retryDelay');
    }

    final now = _clock().toUtc();
    packetStore.expireDue(now);

    var attempted = 0;
    var accepted = 0;
    var failed = 0;
    var deferred = 0;
    var resumed = 0;

    final prepared = transferExecutor.transferStore
        .listPreparedTransfers(limit: maxPackets * 4)
        .where(
          (transfer) =>
              transfer.reason == LoomDtnTransferReason.destinationNode,
        )
        .take(maxPackets)
        .toList(growable: false);

    for (final transfer in prepared) {
      resumed += 1;
      attempted += 1;
      final result = await _resumePrepared(transfer, retryDelay: retryDelay);
      if (_isAccepted(result)) {
        accepted += 1;
      } else {
        failed += 1;
      }
    }

    if (attempted < maxPackets) {
      final eligible = packetStore.listEligible(now, limit: 500);
      for (final packet in eligible) {
        if (attempted >= maxPackets) break;
        final route = routeStore.readDestinationRoute(packet.packetId);
        if (route == null) continue;

        LoomWellKnownNode node;
        try {
          node = await _discoverNode(route.destinationNodeDomain);
        } catch (_) {
          packetStore.recordAttempt(
            packet.packetId,
            attemptedAt: now,
            nextAttemptAt: now.add(retryDelay),
            errorCode: 'destination-node-unverified',
          );
          deferred += 1;
          continue;
        }

        final transmissionId = _nextTransmissionId(now);
        final transfer = transferExecutor.prepareNext(
          packetId: packet.packetId,
          opportunities: <LoomDtnOpportunity>[
            _verifiedDestinationOpportunity(node.nodeId),
          ],
          transmissionId: transmissionId,
          now: now,
        );
        if (transfer == null) continue;

        attempted += 1;
        final result = await _executeVerified(
          transfer,
          node,
          retryDelay: retryDelay,
        );
        if (_isAccepted(result)) {
          accepted += 1;
        } else {
          failed += 1;
        }
      }
    }

    return LoomDestinationNodeUplinkResult(
      attempted: attempted,
      accepted: accepted,
      failed: failed,
      deferred: deferred,
      resumed: resumed,
    );
  }

  Future<LoomDtnExecutionResult> _resumePrepared(
    LoomStoredDtnTransfer transfer, {
    required Duration retryDelay,
  }) async {
    final route = routeStore.readDestinationRoute(transfer.packetId);
    if (route == null) {
      return _failPrepared(
        transfer,
        'destination-route-missing',
        retryDelay: retryDelay,
      );
    }

    LoomWellKnownNode node;
    try {
      node = await _discoverNode(route.destinationNodeDomain);
    } catch (_) {
      return _failPrepared(
        transfer,
        'destination-node-unverified',
        retryDelay: retryDelay,
      );
    }

    if (transfer.opportunityId != _destinationOpportunityId(node.nodeId)) {
      return _failPrepared(
        transfer,
        'destination-node-identity-changed',
        retryDelay: retryDelay,
      );
    }

    return _executeVerified(transfer, node, retryDelay: retryDelay);
  }

  Future<LoomDtnExecutionResult> _executeVerified(
    LoomStoredDtnTransfer transfer,
    LoomWellKnownNode node, {
    required Duration retryDelay,
  }) async {
    final packet = packetStore.read(transfer.packetId);
    if (packet == null) {
      return _failPrepared(
        transfer,
        'destination-packet-missing',
        retryDelay: retryDelay,
      );
    }

    final sender = LoomDirectNodeTransferSender(
      packetStore: packetStore,
      target: LoomDirectNodeTarget(
        nodeId: node.nodeId,
        endpoint: node.endpoint,
        mailboxToken: packet.mailboxToken,
        identityVerified: true,
      ),
      signer: signer,
      poster: poster,
      clock: _clock,
    );
    return transferExecutor.executePrepared(
      transmissionId: transfer.transmissionId,
      sender: sender,
      retryDelay: retryDelay,
    );
  }

  Future<LoomDtnExecutionResult> _failPrepared(
    LoomStoredDtnTransfer transfer,
    String errorCode, {
    required Duration retryDelay,
  }) => transferExecutor.executePrepared(
    transmissionId: transfer.transmissionId,
    sender: _LoomFailedDestinationSender(clock: _clock, errorCode: errorCode),
    retryDelay: retryDelay,
  );

  String _nextTransmissionId(DateTime now) {
    _sequence += 1;
    return 'destination-${now.microsecondsSinceEpoch}-$_sequence';
  }

  static bool _isAccepted(LoomDtnExecutionResult result) =>
      result.status == LoomDtnExecutionStatus.accepted ||
      result.status == LoomDtnExecutionStatus.alreadyAccepted;

  static String _destinationOpportunityId(String nodeId) =>
      'destination-node:$nodeId';

  static LoomDtnOpportunity _verifiedDestinationOpportunity(String nodeId) =>
      LoomDtnOpportunity(
        opportunityId: _destinationOpportunityId(nodeId),
        authenticated: true,
        destinationNode: true,
        directRecipient: false,
        gatewayClaim: LoomGatewayClaimState.none,
        supportedRelayScopes: const <LoomRoutingScopeV2>{},
        canStoreCarry: false,
        linkQualityPercent: 100,
        congestionPercent: 0,
        batteryConstrained: false,
        recentSuccessfulTransfers: 0,
        recentFailedTransfers: 0,
      );
}

final class _LoomFailedDestinationSender implements LoomDtnTransferSender {
  const _LoomFailedDestinationSender({
    required DateTime Function() clock,
    required this.errorCode,
  }) : _clock = clock;

  final DateTime Function() _clock;
  final String errorCode;

  @override
  Future<LoomDtnSendResult> sendPrepared(
    LoomStoredDtnTransfer transfer,
  ) async =>
      LoomDtnSendFailed(completedAt: _clock().toUtc(), errorCode: errorCode);
}

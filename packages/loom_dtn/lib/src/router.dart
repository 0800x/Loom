import 'packet_store.dart';

import 'package:loom_protocol/loom_protocol.dart';

enum LoomGatewayClaimState { none, claimed, verifiedRecently }

enum LoomDtnTransferReason {
  directRecipient,
  destinationNode,
  verifiedGateway,
  claimedGateway,
  storeCarryPeer,
}

/// Authenticated routing opportunity presented to the pure DTN router.
///
/// Transport-specific handles, MAC addresses, IP addresses, usernames and
/// session keys do not belong here. [opportunityId] is an opaque local handle
/// valid only for the current routing snapshot.
final class LoomDtnOpportunity {
  LoomDtnOpportunity({
    required this.opportunityId,
    required this.authenticated,
    this.destinationNode = false,
    required this.directRecipient,
    required this.gatewayClaim,
    required Set<LoomRoutingScopeV2> supportedRelayScopes,
    required this.canStoreCarry,
    required this.linkQualityPercent,
    required this.congestionPercent,
    required this.batteryConstrained,
    required this.recentSuccessfulTransfers,
    required this.recentFailedTransfers,
  }) : supportedRelayScopes = Set.unmodifiable(supportedRelayScopes) {
    validate();
  }

  final String opportunityId;
  final bool authenticated;

  /// True when this authenticated opportunity is the recipient device's
  /// advertised destination node. It is preferred over generic gateways but is
  /// still only a custody hop; it is not an end-to-end delivery confirmation.
  final bool destinationNode;
  final bool directRecipient;
  final LoomGatewayClaimState gatewayClaim;
  final Set<LoomRoutingScopeV2> supportedRelayScopes;
  final bool canStoreCarry;
  final int linkQualityPercent;
  final int congestionPercent;
  final bool batteryConstrained;
  final int recentSuccessfulTransfers;
  final int recentFailedTransfers;

  void validate() {
    if (opportunityId.trim() != opportunityId ||
        opportunityId.length < 4 ||
        opportunityId.length > 256) {
      throw const FormatException('Invalid DTN opportunity id');
    }
    if (linkQualityPercent < 0 || linkQualityPercent > 100) {
      throw const FormatException('Invalid DTN link quality');
    }
    if (congestionPercent < 0 || congestionPercent > 100) {
      throw const FormatException('Invalid DTN congestion value');
    }
    if (recentSuccessfulTransfers < 0 ||
        recentSuccessfulTransfers > 1000 ||
        recentFailedTransfers < 0 ||
        recentFailedTransfers > 1000) {
      throw const FormatException('Invalid DTN transfer history');
    }
    if (directRecipient && destinationNode) {
      throw const FormatException(
        'A routing opportunity cannot be both recipient and destination node',
      );
    }
    if (directRecipient && gatewayClaim != LoomGatewayClaimState.none) {
      throw const FormatException(
        'A direct recipient opportunity cannot also be a gateway claim',
      );
    }
    if (destinationNode && gatewayClaim != LoomGatewayClaimState.none) {
      throw const FormatException(
        'A destination node opportunity cannot also be a generic gateway claim',
      );
    }
    if (gatewayClaim != LoomGatewayClaimState.none &&
        supportedRelayScopes.isEmpty) {
      throw const FormatException('Gateway opportunity has no relay scope');
    }
  }
}

/// One proposed next-hop transfer. The executor must durably persist any
/// forwarding/custody revision before transmitting bytes derived from it.
final class LoomDtnTransferPlan {
  const LoomDtnTransferPlan({
    required this.packetId,
    required this.opportunityId,
    required this.reason,
    required this.score,
    required this.copiesBefore,
    required this.copiesGranted,
    required this.copiesRetainedAfterSuccess,
    required this.requiresSingleCopyCustodyHandoff,
  });

  final String packetId;
  final String opportunityId;
  final LoomDtnTransferReason reason;
  final int score;
  final int copiesBefore;

  /// Forwarding-copy budget encoded for the next custodian.
  ///
  /// For a direct final-recipient transmission this is zero because no new DTN
  /// relay replica is created. For peer/gateway/destination-node forwarding it
  /// is at least one.
  final int copiesGranted;

  /// Local forwarding-copy budget after a successful custody operation.
  ///
  /// Zero is allowed only for an explicit single-copy handoff to a strongly
  /// authenticated destination/gateway. The durable executor must represent
  /// that handoff before it stops forwarding locally.
  final int copiesRetainedAfterSuccess;

  final bool requiresSingleCopyCustodyHandoff;
}

/// Deterministic, transport-independent routing policy for one durable packet.
///
/// This planner is intentionally pure: it scores authenticated opportunities
/// and computes a bounded Spray-and-Wait split, but performs no radio, storage,
/// encryption or network operation.
final class LoomMessageRouter {
  const LoomMessageRouter();

  LoomDtnTransferPlan? planNext({
    required LoomStoredDtnPacket packet,
    required Iterable<LoomDtnOpportunity> opportunities,
    required DateTime now,
  }) {
    if (!packet.isEligibleForForwarding ||
        packet.hopsUsed >= packet.initialHopLimit ||
        !packet.expiresAt.isAfter(now.toUtc())) {
      return null;
    }

    final candidates = <_ScoredOpportunity>[];
    for (final opportunity in opportunities) {
      opportunity.validate();
      final scored = _score(packet, opportunity);
      if (scored != null) candidates.add(scored);
    }
    if (candidates.isEmpty) return null;

    candidates.sort((left, right) {
      final score = right.score.compareTo(left.score);
      if (score != 0) return score;
      return left.opportunity.opportunityId.compareTo(
        right.opportunity.opportunityId,
      );
    });

    final best = candidates.first;
    final copies = packet.copiesRemaining;

    if (best.reason == LoomDtnTransferReason.directRecipient) {
      return LoomDtnTransferPlan(
        packetId: packet.packetId,
        opportunityId: best.opportunity.opportunityId,
        reason: best.reason,
        score: best.score,
        copiesBefore: copies,
        copiesGranted: 0,
        copiesRetainedAfterSuccess: copies,
        requiresSingleCopyCustodyHandoff: false,
      );
    }

    if (copies == 1) {
      // Spray-and-Wait enters the wait phase. A verified destination node has
      // the same durable-custody semantics as a recently verified gateway and
      // may receive the single forwarding token.
      if (best.reason != LoomDtnTransferReason.destinationNode &&
          best.reason != LoomDtnTransferReason.verifiedGateway) {
        return null;
      }
      return LoomDtnTransferPlan(
        packetId: packet.packetId,
        opportunityId: best.opportunity.opportunityId,
        reason: best.reason,
        score: best.score,
        copiesBefore: 1,
        copiesGranted: 1,
        copiesRetainedAfterSuccess: 0,
        requiresSingleCopyCustodyHandoff: true,
      );
    }

    final granted = copies ~/ 2;
    final retained = copies - granted;
    return LoomDtnTransferPlan(
      packetId: packet.packetId,
      opportunityId: best.opportunity.opportunityId,
      reason: best.reason,
      score: best.score,
      copiesBefore: copies,
      copiesGranted: granted,
      copiesRetainedAfterSuccess: retained,
      requiresSingleCopyCustodyHandoff: false,
    );
  }

  _ScoredOpportunity? _score(
    LoomStoredDtnPacket packet,
    LoomDtnOpportunity opportunity,
  ) {
    if (!opportunity.authenticated) return null;

    late final LoomDtnTransferReason reason;
    var score = 0;

    if (opportunity.directRecipient) {
      reason = LoomDtnTransferReason.directRecipient;
      score = 1000;
    } else if (opportunity.destinationNode) {
      reason = LoomDtnTransferReason.destinationNode;
      score = 900;
    } else if (opportunity.gatewayClaim ==
        LoomGatewayClaimState.verifiedRecently) {
      if (!_gatewaySupportsPacket(packet, opportunity)) return null;
      reason = LoomDtnTransferReason.verifiedGateway;
      score = 600;
    } else if (opportunity.gatewayClaim == LoomGatewayClaimState.claimed) {
      if (packet.copiesRemaining <= 1 ||
          !_gatewaySupportsPacket(packet, opportunity)) {
        return null;
      }
      reason = LoomDtnTransferReason.claimedGateway;
      score = 300;
    } else {
      if (packet.copiesRemaining <= 1 || !opportunity.canStoreCarry)
        return null;
      reason = LoomDtnTransferReason.storeCarryPeer;
      score = 120;
    }

    if (opportunity.gatewayClaim != LoomGatewayClaimState.none &&
        opportunity.supportedRelayScopes.contains(packet.routingScope)) {
      score += 100;
    }

    score += (opportunity.recentSuccessfulTransfers.clamp(0, 5)) * 15;
    score -= (opportunity.recentFailedTransfers.clamp(0, 5)) * 20;
    score += opportunity.linkQualityPercent ~/ 5;
    score -= opportunity.congestionPercent ~/ 5;
    if (opportunity.batteryConstrained) score -= 25;

    return _ScoredOpportunity(opportunity, reason, score);
  }

  static bool _gatewaySupportsPacket(
    LoomStoredDtnPacket packet,
    LoomDtnOpportunity opportunity,
  ) {
    if (packet.routingScope == LoomRoutingScopeV2.localDevice) return false;
    return opportunity.supportedRelayScopes.contains(packet.routingScope);
  }
}

final class _ScoredOpportunity {
  const _ScoredOpportunity(this.opportunity, this.reason, this.score);

  final LoomDtnOpportunity opportunity;
  final LoomDtnTransferReason reason;
  final int score;
}

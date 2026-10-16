import 'nearby_transport.dart';

enum LoomConnectivityState {
  online,
  localNetwork,
  nearby,
  relaying,
  queued,
  syncing,
  nodeUnreachable,
}

enum LoomRouteKind { homeNode, destinationNode, localNetwork }

enum LoomExecutionPolicy {
  foregroundInteractive,
  foregroundService,
  backgroundRestricted,
  suspended,
}

/// Authoritative Architecture-v2 connectivity input.
///
/// Routing must reason about independently changing capabilities rather than a
/// single online/offline enum. Human-facing labels may still be derived from
/// this snapshot for compatibility UI.
final class LoomConnectivityCapabilities {
  LoomConnectivityCapabilities({
    required this.observedAt,
    this.internetReachable = false,
    this.homeNodeReachable = false,
    this.destinationNodeReachable = false,
    this.domesticRelayReachable = false,
    this.globalRelayReachable = false,
    this.lanAvailable = false,
    Set<LoomNearbyBearer> nearbyBearers = const <LoomNearbyBearer>{},
    this.authenticatedNearbyPeerCount = 0,
    this.verifiedGatewayCount = 0,
    this.executionPolicy = LoomExecutionPolicy.foregroundInteractive,
    this.storagePressure = false,
    this.batterySaver = false,
  }) : nearbyBearers = Set.unmodifiable(nearbyBearers) {
    if (authenticatedNearbyPeerCount < 0 ||
        authenticatedNearbyPeerCount > 4096 ||
        verifiedGatewayCount < 0 ||
        verifiedGatewayCount > 4096) {
      throw const FormatException('Invalid connectivity capability counts');
    }
    final time = observedAt.toUtc();
    if (time.year < 2020 || time.year >= 2200) {
      throw const FormatException('Invalid connectivity observation time');
    }
  }

  final DateTime observedAt;
  final bool internetReachable;
  final bool homeNodeReachable;

  /// Reachability of the current recipient device's verified destination node.
  /// This is intentionally independent from Home Node reachability so routing
  /// can bypass a broken node-to-node path.
  final bool destinationNodeReachable;
  final bool domesticRelayReachable;
  final bool globalRelayReachable;
  final bool lanAvailable;
  final Set<LoomNearbyBearer> nearbyBearers;
  final int authenticatedNearbyPeerCount;
  final int verifiedGatewayCount;
  final LoomExecutionPolicy executionPolicy;
  final bool storagePressure;
  final bool batterySaver;

  bool get hasAuthenticatedNearbyPath => authenticatedNearbyPeerCount > 0;
  bool get hasVerifiedGatewayPath => verifiedGatewayCount > 0;
  bool get canRunActiveDiscovery =>
      executionPolicy == LoomExecutionPolicy.foregroundInteractive ||
      executionPolicy == LoomExecutionPolicy.foregroundService;
  bool get hasAnyPath =>
      internetReachable ||
      homeNodeReachable ||
      destinationNodeReachable ||
      domesticRelayReachable ||
      globalRelayReachable ||
      lanAvailable ||
      hasAuthenticatedNearbyPath ||
      hasVerifiedGatewayPath;

  LoomConnectivityState get legacyDisplayState {
    if (destinationNodeReachable ||
        homeNodeReachable ||
        internetReachable ||
        globalRelayReachable) {
      return LoomConnectivityState.online;
    }
    if (lanAvailable) return LoomConnectivityState.localNetwork;
    if (hasVerifiedGatewayPath) return LoomConnectivityState.relaying;
    if (hasAuthenticatedNearbyPath) return LoomConnectivityState.nearby;
    return LoomConnectivityState.queued;
  }

  LoomConnectivityCapabilities copyWith({
    DateTime? observedAt,
    bool? internetReachable,
    bool? homeNodeReachable,
    bool? destinationNodeReachable,
    bool? domesticRelayReachable,
    bool? globalRelayReachable,
    bool? lanAvailable,
    Set<LoomNearbyBearer>? nearbyBearers,
    int? authenticatedNearbyPeerCount,
    int? verifiedGatewayCount,
    LoomExecutionPolicy? executionPolicy,
    bool? storagePressure,
    bool? batterySaver,
  }) => LoomConnectivityCapabilities(
    observedAt: observedAt ?? this.observedAt,
    internetReachable: internetReachable ?? this.internetReachable,
    homeNodeReachable: homeNodeReachable ?? this.homeNodeReachable,
    destinationNodeReachable:
        destinationNodeReachable ?? this.destinationNodeReachable,
    domesticRelayReachable:
        domesticRelayReachable ?? this.domesticRelayReachable,
    globalRelayReachable: globalRelayReachable ?? this.globalRelayReachable,
    lanAvailable: lanAvailable ?? this.lanAvailable,
    nearbyBearers: nearbyBearers ?? this.nearbyBearers,
    authenticatedNearbyPeerCount:
        authenticatedNearbyPeerCount ?? this.authenticatedNearbyPeerCount,
    verifiedGatewayCount: verifiedGatewayCount ?? this.verifiedGatewayCount,
    executionPolicy: executionPolicy ?? this.executionPolicy,
    storagePressure: storagePressure ?? this.storagePressure,
    batterySaver: batterySaver ?? this.batterySaver,
  );
}

class LoomRouteCandidate {
  const LoomRouteCandidate({
    required this.id,
    required this.kind,
    required this.nodeId,
    required this.endpoint,
    required this.identityVerified,
    this.latency,
    this.reachable = true,
  });

  final String id;
  final LoomRouteKind kind;
  final String nodeId;
  final Uri endpoint;
  final bool identityVerified;
  final Duration? latency;
  final bool reachable;

  LoomRouteCandidate copyWith({bool? reachable, Duration? latency}) =>
      LoomRouteCandidate(
        id: id,
        kind: kind,
        nodeId: nodeId,
        endpoint: endpoint,
        identityVerified: identityVerified,
        latency: latency ?? this.latency,
        reachable: reachable ?? this.reachable,
      );
}

/// Legacy compatibility result. New v2 routing should consume
/// [LoomConnectivityCapabilities] directly.
class LoomRouteSelection {
  const LoomRouteSelection({required this.ordered, required this.state});
  final List<LoomRouteCandidate> ordered;
  final LoomConnectivityState state;
}

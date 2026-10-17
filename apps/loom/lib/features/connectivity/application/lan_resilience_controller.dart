import 'package:loom_models/loom_models.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:loom_transport/loom_transport.dart';

class LoomLanResilienceController {
  LoomLanResilienceController({LoomLanDiscoveryClient? discovery})
    : discovery = discovery ?? LoomLanDiscoveryClient();

  final LoomLanDiscoveryClient discovery;

  Future<List<LoomMessagingRoute>> routesForHomeNode({
    required LoomNodeDescriptor trustedNode,
    required Uri homeEndpoint,
    required LoomAccessTokenProvider accessTokenProvider,
    required LoomDeviceRequestProofProvider deviceProofProvider,
    Future<bool> Function(String rejectedToken)? refreshRejectedToken,
  }) async {
    Future<List<LoomMessagingRoute>> refresh() => routesForHomeNode(
      trustedNode: trustedNode,
      homeEndpoint: homeEndpoint,
      accessTokenProvider: accessTokenProvider,
      deviceProofProvider: deviceProofProvider,
      refreshRejectedToken: refreshRejectedToken,
    );

    LoomMessagingApi clientFor(Uri endpoint) =>
        LoomGenerationAwareMessagingClient(
          baseUri: endpoint,
          accessTokenProvider: accessTokenProvider,
          deviceProofProvider: deviceProofProvider,
          refreshRejectedToken: refreshRejectedToken,
        );

    final routes = <LoomMessagingRoute>[
      LoomMessagingRoute(
        candidate: LoomRouteCandidate(
          id: 'home:${trustedNode.nodeId}',
          kind: LoomRouteKind.homeNode,
          nodeId: trustedNode.nodeId,
          endpoint: homeEndpoint,
          identityVerified: true,
        ),
        api: clientFor(homeEndpoint),
        refreshOnNetworkChange: refresh,
      ),
    ];
    try {
      final discovered = await discovery.discover(
        expectedNodeId: trustedNode.nodeId,
        expectedPublicKey: trustedNode.publicKey,
        timeout: const Duration(milliseconds: 900),
      );
      for (final result in discovered) {
        final endpoint = result.announcement.endpoint;
        if (routes.any((route) => route.candidate.endpoint == endpoint)) {
          continue;
        }
        routes.add(
          LoomMessagingRoute(
            candidate: LoomRouteCandidate(
              id: 'lan:${trustedNode.nodeId}:${endpoint.authority}',
              kind: LoomRouteKind.localNetwork,
              nodeId: trustedNode.nodeId,
              endpoint: endpoint,
              identityVerified: true,
            ),
            api: clientFor(endpoint),
          ),
        );
      }
    } catch (_) {
      // Local discovery is opportunistic. The Home Node route remains usable.
    }
    return routes;
  }
}

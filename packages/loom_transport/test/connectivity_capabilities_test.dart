import 'package:loom_transport/loom_transport.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 9, 6);

  test(
      'capability snapshot derives legacy display without collapsing router state',
      () {
    final snapshot = LoomConnectivityCapabilities(
      observedAt: now,
      nearbyBearers: const <LoomNearbyBearer>{
        LoomNearbyBearer.bluetoothLowEnergy,
      },
      authenticatedNearbyPeerCount: 2,
      verifiedGatewayCount: 1,
      executionPolicy: LoomExecutionPolicy.foregroundService,
    );
    expect(snapshot.hasAnyPath, isTrue);
    expect(snapshot.hasAuthenticatedNearbyPath, isTrue);
    expect(snapshot.hasVerifiedGatewayPath, isTrue);
    expect(snapshot.canRunActiveDiscovery, isTrue);
    expect(snapshot.legacyDisplayState, LoomConnectivityState.relaying);
  });

  test(
    'background restriction disables active discovery without erasing paths',
    () {
      final snapshot = LoomConnectivityCapabilities(
        observedAt: now,
        lanAvailable: true,
        executionPolicy: LoomExecutionPolicy.backgroundRestricted,
      );
      expect(snapshot.canRunActiveDiscovery, isFalse);
      expect(snapshot.hasAnyPath, isTrue);
      expect(snapshot.legacyDisplayState, LoomConnectivityState.localNetwork);
    },
  );
}

import 'package:loom_transport/loom_transport.dart';
import 'package:test/test.dart';

void main() {
  test('destination node reachability is an independent online path', () {
    final snapshot = LoomConnectivityCapabilities(
      observedAt: DateTime.utc(2026, 9, 7, 8),
      internetReachable: false,
      homeNodeReachable: false,
      destinationNodeReachable: true,
    );

    expect(snapshot.hasAnyPath, isTrue);
    expect(snapshot.legacyDisplayState, LoomConnectivityState.online);
  });

  test(
    'copyWith can flip destination node without changing Home Node state',
    () {
      final initial = LoomConnectivityCapabilities(
        observedAt: DateTime.utc(2026, 9, 7, 8),
        homeNodeReachable: true,
        destinationNodeReachable: false,
      );
      final changed = initial.copyWith(destinationNodeReachable: true);

      expect(changed.homeNodeReachable, isTrue);
      expect(changed.destinationNodeReachable, isTrue);
    },
  );
}

import 'dart:io';
import 'dart:typed_data';

import 'package:loom_dtn/loom_dtn.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:loom_next/features/messaging/application/v2_messaging_runtime.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('V2 runtime shares one durable DTN database with Nearby intake', () {
    final root = Directory.systemTemp.createTempSync('loom-v2-runtime-dtn-');
    addTearDown(() => root.deleteSync(recursive: true));
    final runtime = LoomV2MessagingRuntime.open(
      applicationSupportPath: root.path,
    );
    addTearDown(runtime.close);

    final now = DateTime.utc(2026, 9, 10, 12);
    const packetId = 'packet-runtime-nearby-intake-0001';
    final exact = LoomEnvelopeV2Codec.encodeOuter(
      LoomOuterEnvelopeV2(
        packetId: packetId,
        routingHint: LoomRoutingHintV2(
          scope: LoomRoutingScopeV2.globalRelay,
          mailboxToken: Uint8List.fromList(List<int>.filled(32, 45)),
        ),
        expiresAtBucket: now.add(const Duration(days: 1)),
        priority: LoomPriorityClassV2.normal,
        initialHopLimit: 4,
        forwardingState: const LoomForwardingStateV2(
          hopsUsed: 1,
          copiesRemaining: 2,
        ),
        encryptedPayload: Uint8List.fromList(<int>[7, 8, 9]),
      ),
    );

    final intake = runtime.replicaIntakeStore.acceptReplica(
      exactOuterEnvelopeBytes: exact,
      now: now,
    );

    expect(intake.packetId, packetId);
    expect(runtime.packetStore.read(packetId), isNotNull);
    expect(
      runtime.packetStore.read(packetId)!.origin,
      LoomDtnPacketOrigin.carriedReplica,
    );
    expect(
      identical(runtime.nearbyDtnEncounters.packetStore, runtime.packetStore),
      isTrue,
    );
    expect(
      identical(
        runtime.nearbyDtnEncounters.transferExecutor,
        runtime.transferExecutor,
      ),
      isTrue,
    );
    expect(
      identical(
        runtime.nearbyDtnEncounters.routeStore,
        runtime.packetRouteStore,
      ),
      isTrue,
    );
  });

  test(
    'generic Nearby custody durably preserves destination Node route',
    () async {
      final root = Directory.systemTemp.createTempSync(
        'loom-v2-runtime-route-',
      );
      addTearDown(() => root.deleteSync(recursive: true));
      final runtime = LoomV2MessagingRuntime.open(
        applicationSupportPath: root.path,
      );
      addTearDown(runtime.close);

      // Unlike the direct store test above, this path uses the runtime clock.
      final now = DateTime.now().toUtc();
      const packetId = 'packet-runtime-nearby-route-0001';
      final exact = LoomEnvelopeV2Codec.encodeOuter(
        LoomOuterEnvelopeV2(
          packetId: packetId,
          routingHint: LoomRoutingHintV2(
            scope: LoomRoutingScopeV2.globalRelay,
            mailboxToken: Uint8List.fromList(List<int>.filled(32, 46)),
          ),
          expiresAtBucket: now.add(const Duration(days: 1)),
          priority: LoomPriorityClassV2.normal,
          initialHopLimit: 4,
          forwardingState: const LoomForwardingStateV2(
            hopsUsed: 1,
            copiesRemaining: 2,
          ),
          encryptedPayload: Uint8List.fromList(<int>[10, 11, 12]),
        ),
      );

      final routedAccept = runtime.nearbyDtnEncounters.durablyAcceptRouted;
      expect(routedAccept, isNotNull);
      final ack = await routedAccept!(
        transmissionId: 'transmission-runtime-nearby-route-0001',
        exactOuterEnvelopeBytes: exact,
        destinationNodeDomain: 'Recipient.Example.',
      );

      expect(ack.packetId, packetId);
      expect(runtime.packetStore.read(packetId), isNotNull);
      expect(
        runtime.packetRouteStore
            .readDestinationRoute(packetId)
            ?.destinationNodeDomain,
        'recipient.example',
      );
    },
  );
}

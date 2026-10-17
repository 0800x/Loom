import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:loom_protocol/loom_protocol.dart';
import 'package:loom_transport/loom_transport.dart';
import 'package:loom_next/features/messaging/application/v2_messaging_runtime.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'gateway custody ACK does not wait for Destination Node uplink',
    () async {
      final root = Directory.systemTemp.createTempSync(
        'loom-v2-uplink-runtime-',
      );
      addTearDown(() => root.deleteSync(recursive: true));
      final discoveryStarted = Completer<void>();
      final releaseDiscovery = Completer<void>();
      final runtime = LoomV2MessagingRuntime.open(
        applicationSupportPath: root.path,
        destinationNodeDiscovery: (domain) async {
          if (!discoveryStarted.isCompleted) {
            discoveryStarted.complete();
          }
          await releaseDiscovery.future;
          throw StateError('offline discovery');
        },
      );
      addTearDown(runtime.close);

      // The runtime intake and uplink use the wall clock. Keep this integration
      // fixture live rather than expiring it on a fixed calendar date.
      final now = DateTime.now().toUtc();
      const packetId = 'packet-runtime-gateway-uplink-0001';
      final exact = LoomEnvelopeV2Codec.encodeOuter(
        LoomOuterEnvelopeV2(
          packetId: packetId,
          routingHint: LoomRoutingHintV2(
            scope: LoomRoutingScopeV2.globalRelay,
            mailboxToken: Uint8List.fromList(List<int>.filled(32, 51)),
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

      final ack = await runtime
          .acceptNearbyInternetGatewayReplica(
            transmissionId: 'transmission-runtime-gateway-uplink-0001',
            exactOuterEnvelopeBytes: exact,
            destinationNodeDomain: 'recipient.example',
            signer: const _Signer(),
          )
          .timeout(const Duration(seconds: 1));

      expect(ack.packetId, packetId);
      expect(
        runtime.packetRouteStore
            .readDestinationRoute(packetId)!
            .destinationNodeDomain,
        'recipient.example',
      );
      await discoveryStarted.future.timeout(const Duration(seconds: 1));

      releaseDiscovery.complete();
      await runtime.waitForDestinationNodeUplinkIdle();

      final stored = runtime.packetStore.read(packetId)!;
      expect(stored.lastErrorCode, 'destination-node-unverified');
      expect(stored.copiesRemaining, 2);
    },
  );
}

final class _Signer implements LoomDirectTransportSigner {
  const _Signer();

  @override
  Future<Uint8List> ed25519PublicKey() async =>
      Uint8List.fromList(List<int>.filled(32, 61));

  @override
  Future<Uint8List> sign(Uint8List canonicalBytes) async =>
      Uint8List.fromList(List<int>.filled(64, 62));
}

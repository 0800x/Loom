import 'dart:io';
import 'dart:typed_data';

import 'package:loom_dtn/loom_dtn.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('packet received at hop limit is durable but never replanned', () {
    final now = DateTime.utc(2026, 9, 5, 12);
    final directory = Directory.systemTemp.createTempSync('loom-dtn-hoplimit-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final path = '${directory.path}${Platform.pathSeparator}dtn.sqlite3';
    final packetStore = LoomSqlitePacketStore.openFile(path);
    final intake = LoomSqliteReplicaIntakeStore.openExistingFile(path);
    addTearDown(packetStore.close);
    addTearDown(intake.close);

    final outer = LoomOuterEnvelopeV2(
      packetId: 'packet-hoplimit-000001',
      routingHint: LoomRoutingHintV2(
        scope: LoomRoutingScopeV2.globalRelay,
        mailboxToken: Uint8List.fromList(List<int>.filled(32, 42)),
      ),
      expiresAtBucket: DateTime.utc(2026, 9, 6, 12),
      priority: LoomPriorityClassV2.normal,
      initialHopLimit: 4,
      forwardingState: const LoomForwardingStateV2(
        hopsUsed: 4,
        copiesRemaining: 2,
      ),
      encryptedPayload: Uint8List.fromList(<int>[1, 2, 3, 4]),
    );

    intake.acceptReplica(
      exactOuterEnvelopeBytes: LoomEnvelopeV2Codec.encodeOuter(outer),
      now: now,
    );
    final packet = packetStore.read('packet-hoplimit-000001')!;
    expect(packet.hopsUsed, packet.initialHopLimit);

    final plan = const LoomMessageRouter().planNext(
      packet: packet,
      now: now,
      opportunities: <LoomDtnOpportunity>[
        LoomDtnOpportunity(
          opportunityId: 'peer-after-hop-limit',
          authenticated: true,
          directRecipient: true,
          gatewayClaim: LoomGatewayClaimState.none,
          supportedRelayScopes: const <LoomRoutingScopeV2>{},
          canStoreCarry: false,
          linkQualityPercent: 100,
          congestionPercent: 0,
          batteryConstrained: false,
          recentSuccessfulTransfers: 0,
          recentFailedTransfers: 0,
        ),
      ],
    );

    expect(plan, isNull);
  });
}

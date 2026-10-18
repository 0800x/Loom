import 'dart:io';
import 'dart:typed_data';

import 'package:loom_dtn/loom_dtn.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 9, 5, 12);

  test(
    'durably carried replica can be planned and prepared for the next hop',
    () {
      final directory = Directory.systemTemp.createTempSync('loom-dtn-carry-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final path = '${directory.path}${Platform.pathSeparator}dtn.sqlite3';
      final packetStore = LoomSqlitePacketStore.openFile(path);
      final intake = LoomSqliteReplicaIntakeStore.openExistingFile(path);
      addTearDown(packetStore.close);
      addTearDown(intake.close);

      intake.acceptReplica(
        exactOuterEnvelopeBytes: _wire(
          packetId: 'packet-carry-forward-0001',
          hopsUsed: 2,
          copiesRemaining: 4,
          hopLimit: 4,
        ),
        now: now,
      );
      final packet = packetStore.read('packet-carry-forward-0001')!;
      expect(packet.origin, LoomDtnPacketOrigin.carriedReplica);

      final plan = const LoomMessageRouter().planNext(
        packet: packet,
        now: now,
        opportunities: <LoomDtnOpportunity>[
          LoomDtnOpportunity(
            opportunityId: 'next-authenticated-peer',
            authenticated: true,
            directRecipient: false,
            gatewayClaim: LoomGatewayClaimState.none,
            supportedRelayScopes: const <LoomRoutingScopeV2>{},
            canStoreCarry: true,
            linkQualityPercent: 80,
            congestionPercent: 5,
            batteryConstrained: false,
            recentSuccessfulTransfers: 0,
            recentFailedTransfers: 0,
          ),
        ],
      );
      expect(plan, isNotNull);
      expect(plan!.copiesGranted, 2);

      final transfer = packetStore.prepareTransfer(
        transmissionId: 'transmission-carry-forward-0001',
        plan: plan,
        now: now,
      );
      final forwarded = LoomEnvelopeV2Codec.decodeOuter(transfer.wireBytes);
      expect(forwarded.forwardingState.hopsUsed, 3);
      expect(forwarded.forwardingState.copiesRemaining, 2);
      expect(
        forwarded.encryptedPayload,
        LoomEnvelopeV2Codec.decodeOuter(packet.wireBytes).encryptedPayload,
      );
    },
  );

  test(
    'packet at hop limit may enter custody but router will not forward it',
    () {
      final directory = Directory.systemTemp.createTempSync(
        'loom-dtn-hop-limit-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final path = '${directory.path}${Platform.pathSeparator}dtn.sqlite3';
      final packetStore = LoomSqlitePacketStore.openFile(path);
      final intake = LoomSqliteReplicaIntakeStore.openExistingFile(path);
      addTearDown(packetStore.close);
      addTearDown(intake.close);

      intake.acceptReplica(
        exactOuterEnvelopeBytes: _wire(
          packetId: 'packet-carry-forward-0002',
          hopsUsed: 4,
          copiesRemaining: 2,
          hopLimit: 4,
        ),
        now: now,
      );
      final packet = packetStore.read('packet-carry-forward-0002')!;
      final plan = const LoomMessageRouter().planNext(
        packet: packet,
        now: now,
        opportunities: <LoomDtnOpportunity>[
          LoomDtnOpportunity(
            opportunityId: 'peer-beyond-hop-limit',
            authenticated: true,
            directRecipient: false,
            gatewayClaim: LoomGatewayClaimState.none,
            supportedRelayScopes: const <LoomRoutingScopeV2>{},
            canStoreCarry: true,
            linkQualityPercent: 80,
            congestionPercent: 5,
            batteryConstrained: false,
            recentSuccessfulTransfers: 0,
            recentFailedTransfers: 0,
          ),
        ],
      );

      expect(
        plan,
        isNull,
        reason:
            'the pure router has enough durable metadata to enforce hop budget',
      );
    },
  );
}

Uint8List _wire({
  required String packetId,
  required int hopsUsed,
  required int copiesRemaining,
  required int hopLimit,
}) {
  return LoomEnvelopeV2Codec.encodeOuter(
    LoomOuterEnvelopeV2(
      packetId: packetId,
      routingHint: LoomRoutingHintV2(
        scope: LoomRoutingScopeV2.globalRelay,
        mailboxToken: Uint8List.fromList(List<int>.filled(32, 37)),
      ),
      expiresAtBucket: DateTime.utc(2026, 9, 6, 12),
      priority: LoomPriorityClassV2.normal,
      initialHopLimit: hopLimit,
      forwardingState: LoomForwardingStateV2(
        hopsUsed: hopsUsed,
        copiesRemaining: copiesRemaining,
      ),
      encryptedPayload: Uint8List.fromList(<int>[61, 62, 63]),
    ),
  );
}

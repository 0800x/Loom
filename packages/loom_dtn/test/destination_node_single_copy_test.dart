import 'dart:typed_data';

import 'package:loom_dtn/loom_dtn.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('single remaining copy can be handed to the destination node', () {
    final now = DateTime.utc(2026, 9, 10, 14);
    final store = LoomSqlitePacketStore.openInMemory();
    addTearDown(store.close);

    const packetId = 'packet-single-copy-destination-0001';
    store.putLocalOutbound(
      operationId: 'operation-single-copy-destination-0001',
      messageId: 'message-single-copy-destination-0001',
      packetId: packetId,
      exactOuterEnvelopeBytes: LoomEnvelopeV2Codec.encodeOuter(
        LoomOuterEnvelopeV2(
          packetId: packetId,
          routingHint: LoomRoutingHintV2(
            scope: LoomRoutingScopeV2.globalRelay,
            mailboxToken: Uint8List.fromList(List<int>.filled(32, 19)),
          ),
          expiresAtBucket: now.add(const Duration(days: 1)),
          priority: LoomPriorityClassV2.normal,
          initialHopLimit: 4,
          forwardingState: const LoomForwardingStateV2(
            hopsUsed: 0,
            copiesRemaining: 1,
          ),
          encryptedPayload: Uint8List.fromList(<int>[4, 5, 6]),
        ),
      ),
      now: now,
    );

    final executor = LoomDtnTransferExecutor(
      packetStore: store,
      transferStore: store,
    );
    final prepared = executor.prepareNext(
      packetId: packetId,
      opportunities: <LoomDtnOpportunity>[
        LoomDtnOpportunity(
          opportunityId: 'destination-node:single-copy-0001',
          authenticated: true,
          destinationNode: true,
          directRecipient: false,
          gatewayClaim: LoomGatewayClaimState.none,
          supportedRelayScopes: Set<LoomRoutingScopeV2>.unmodifiable(
            LoomRoutingScopeV2.values,
          ),
          canStoreCarry: false,
          linkQualityPercent: 100,
          congestionPercent: 0,
          batteryConstrained: false,
          recentSuccessfulTransfers: 1,
          recentFailedTransfers: 0,
        ),
      ],
      transmissionId: 'transmission-single-copy-destination-0001',
      now: now,
    );

    expect(prepared, isNotNull);
    expect(prepared!.reason, LoomDtnTransferReason.destinationNode);
    expect(prepared.copiesBefore, 1);
    expect(prepared.copiesGranted, 1);
    expect(prepared.copiesRetainedAfterSuccess, 0);
    expect(prepared.requiresSingleCopyCustodyHandoff, isTrue);
  });
}

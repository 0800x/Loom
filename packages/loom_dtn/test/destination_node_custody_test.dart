import 'dart:typed_data';

import 'package:loom_dtn/loom_dtn.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:test/test.dart';

void main() {
  test(
      'destination-node custody retains Nearby forwarding without claiming delivery',
      () async {
    final now = DateTime.utc(2026, 9, 10, 13);
    final store = LoomSqlitePacketStore.openInMemory();
    addTearDown(store.close);
    const packetId = 'packet-destination-custody-0001';
    store.putLocalOutbound(
      operationId: 'operation-destination-custody-0001',
      messageId: 'message-destination-custody-0001',
      packetId: packetId,
      exactOuterEnvelopeBytes: LoomEnvelopeV2Codec.encodeOuter(
        LoomOuterEnvelopeV2(
          packetId: packetId,
          routingHint: LoomRoutingHintV2(
            scope: LoomRoutingScopeV2.globalRelay,
            mailboxToken: Uint8List.fromList(List<int>.filled(32, 71)),
          ),
          expiresAtBucket: now.add(const Duration(days: 1)),
          priority: LoomPriorityClassV2.normal,
          initialHopLimit: 4,
          forwardingState: const LoomForwardingStateV2(
            hopsUsed: 0,
            copiesRemaining: 4,
          ),
          encryptedPayload: Uint8List.fromList(<int>[1, 2, 3]),
        ),
      ),
      now: now,
    );
    final executor = LoomDtnTransferExecutor(
      packetStore: store,
      transferStore: store,
      clock: () => now.add(const Duration(seconds: 2)),
    );
    final prepared = executor.prepareNext(
      packetId: packetId,
      opportunities: <LoomDtnOpportunity>[
        LoomDtnOpportunity(
          opportunityId: 'destination-node:node-verified-0001',
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
      transmissionId: 'transmission-destination-custody-0001',
      now: now,
    )!;
    expect(prepared.reason, LoomDtnTransferReason.destinationNode);

    final result = await executor.executePrepared(
      transmissionId: prepared.transmissionId,
      sender: _AcceptedSender(
        LoomDtnHopAck(
          transmissionId: prepared.transmissionId,
          packetId: packetId,
          acceptedAt: now.add(const Duration(days: 5)),
          duplicate: false,
        ),
      ),
    );

    expect(result.status, LoomDtnExecutionStatus.accepted);
    expect(result.packet.state, LoomDtnPacketState.gatewayAccepted);
    expect(
      result.packet.gatewayAcceptedAt,
      now.add(const Duration(seconds: 2)),
    );
    expect(result.packet.recipientConfirmedAt, isNull);
    expect(result.packet.isTerminal, isFalse);
    expect(
      store.listEligible(now.add(const Duration(seconds: 3))),
      hasLength(1),
    );
    expect(result.packet.copiesRemaining, 2);
    expect(store.hasAcceptedTransfer(packetId, prepared.opportunityId), isTrue);
    final duplicate = executor.prepareNext(
      packetId: packetId,
      opportunities: [
        LoomDtnOpportunity(
          opportunityId: prepared.opportunityId,
          authenticated: true,
          destinationNode: true,
          directRecipient: false,
          gatewayClaim: LoomGatewayClaimState.none,
          supportedRelayScopes: {},
          canStoreCarry: false,
          linkQualityPercent: 100,
          congestionPercent: 0,
          batteryConstrained: false,
          recentSuccessfulTransfers: 1,
          recentFailedTransfers: 0,
        ),
      ],
      transmissionId: 'transmission-destination-duplicate',
      now: now.add(const Duration(seconds: 3)),
    );
    expect(
      duplicate,
      isNull,
      reason: 'Reconnect cannot spend more copies on the same node',
    );
  });
}

final class _AcceptedSender implements LoomDtnTransferSender {
  const _AcceptedSender(this.ack);

  final LoomDtnHopAck ack;

  @override
  Future<LoomDtnSendResult> sendPrepared(
    LoomStoredDtnTransfer transfer,
  ) async =>
      LoomDtnSendAccepted(ack);
}

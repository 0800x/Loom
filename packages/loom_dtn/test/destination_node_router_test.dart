import 'dart:typed_data';

import 'package:loom_dtn/loom_dtn.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 9, 7, 8);
  const router = LoomMessageRouter();

  test('verified destination node outranks generic gateways and carriers', () {
    final store = LoomSqlitePacketStore.openInMemory();
    addTearDown(store.close);
    final packet = _packet(store, now: now, copies: 4);

    final plan = router.planNext(
      packet: packet,
      now: now,
      opportunities: <LoomDtnOpportunity>[
        _opportunity(
          id: 'verified-gateway',
          gateway: LoomGatewayClaimState.verifiedRecently,
          link: 100,
        ),
        _opportunity(id: 'carrier', canCarry: true, link: 100),
        _opportunity(id: 'destination-node', destinationNode: true, link: 10),
      ],
    );

    expect(plan, isNotNull);
    expect(plan!.reason, LoomDtnTransferReason.destinationNode);
    expect(plan.opportunityId, 'destination-node');
  });

  test('single-copy wait phase may hand custody to verified destination node',
      () {
    final store = LoomSqlitePacketStore.openInMemory();
    addTearDown(store.close);
    final packet = _packet(store, now: now, copies: 1);

    final plan = router.planNext(
      packet: packet,
      now: now,
      opportunities: <LoomDtnOpportunity>[
        _opportunity(id: 'destination-node', destinationNode: true),
      ],
    );

    expect(plan, isNotNull);
    expect(plan!.reason, LoomDtnTransferReason.destinationNode);
    expect(plan.copiesGranted, 1);
    expect(plan.copiesRetainedAfterSuccess, 0);
    expect(plan.requiresSingleCopyCustodyHandoff, isTrue);
  });

  test('unauthenticated destination node is never a routing candidate', () {
    final store = LoomSqlitePacketStore.openInMemory();
    addTearDown(store.close);
    final packet = _packet(store, now: now, copies: 4);

    final plan = router.planNext(
      packet: packet,
      now: now,
      opportunities: <LoomDtnOpportunity>[
        _opportunity(
          id: 'fake-destination',
          authenticated: false,
          destinationNode: true,
        ),
      ],
    );

    expect(plan, isNull);
  });
}

LoomStoredDtnPacket _packet(
  LoomSqlitePacketStore store, {
  required DateTime now,
  required int copies,
}) {
  final packetId = 'packet-destination-$copies';
  final outer = LoomOuterEnvelopeV2(
    packetId: packetId,
    routingHint: LoomRoutingHintV2(
      scope: LoomRoutingScopeV2.globalRelay,
      mailboxToken: Uint8List.fromList(List<int>.filled(32, 12)),
    ),
    expiresAtBucket: now.add(const Duration(days: 1)),
    priority: LoomPriorityClassV2.normal,
    initialHopLimit: 4,
    forwardingState: LoomForwardingStateV2(
      hopsUsed: 0,
      copiesRemaining: copies,
    ),
    encryptedPayload: Uint8List.fromList(<int>[1, 2, 3, copies]),
  );
  return store.putLocalOutbound(
    operationId: 'operation-destination-$copies',
    messageId: 'message-destination-$copies',
    packetId: packetId,
    exactOuterEnvelopeBytes: LoomEnvelopeV2Codec.encodeOuter(outer),
    now: now,
  );
}

LoomDtnOpportunity _opportunity({
  required String id,
  bool authenticated = true,
  bool destinationNode = false,
  LoomGatewayClaimState gateway = LoomGatewayClaimState.none,
  bool canCarry = false,
  int link = 60,
}) =>
    LoomDtnOpportunity(
      opportunityId: id,
      authenticated: authenticated,
      destinationNode: destinationNode,
      directRecipient: false,
      gatewayClaim: gateway,
      supportedRelayScopes: gateway == LoomGatewayClaimState.none
          ? const <LoomRoutingScopeV2>{}
          : const <LoomRoutingScopeV2>{LoomRoutingScopeV2.globalRelay},
      canStoreCarry: canCarry,
      linkQualityPercent: link,
      congestionPercent: 10,
      batteryConstrained: false,
      recentSuccessfulTransfers: 0,
      recentFailedTransfers: 0,
    );

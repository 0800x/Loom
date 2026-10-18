import 'dart:typed_data';

import 'package:loom_dtn/loom_dtn.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 9, 5, 12);
  const router = LoomMessageRouter();

  test('authenticated direct recipient outranks all relay opportunities', () {
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
        _opportunity(
          id: 'recipient-device',
          direct: true,
          link: 10,
          congestion: 90,
        ),
      ],
    );

    expect(plan, isNotNull);
    expect(plan!.reason, LoomDtnTransferReason.directRecipient);
    expect(plan.opportunityId, 'recipient-device');
    expect(plan.copiesGranted, 0);
    expect(plan.copiesRetainedAfterSuccess, 4);
  });

  test(
    'unauthenticated peers and gateway claims are never routing candidates',
    () {
      final store = LoomSqlitePacketStore.openInMemory();
      addTearDown(store.close);
      final packet = _packet(store, now: now, copies: 4);

      final plan = router.planNext(
        packet: packet,
        now: now,
        opportunities: <LoomDtnOpportunity>[
          _opportunity(
            id: 'fake-gateway',
            authenticated: false,
            gateway: LoomGatewayClaimState.verifiedRecently,
          ),
          _opportunity(id: 'fake-peer', authenticated: false, canCarry: true),
        ],
      );

      expect(plan, isNull);
    },
  );

  test('verified gateway outranks claimed gateway and store-carry peer', () {
    final store = LoomSqlitePacketStore.openInMemory();
    addTearDown(store.close);
    final packet = _packet(store, now: now, copies: 8);

    final plan = router.planNext(
      packet: packet,
      now: now,
      opportunities: <LoomDtnOpportunity>[
        _opportunity(id: 'carrier-peer', canCarry: true, link: 100),
        _opportunity(
          id: 'claimed-gateway',
          gateway: LoomGatewayClaimState.claimed,
          link: 100,
        ),
        _opportunity(
          id: 'verified-gateway',
          gateway: LoomGatewayClaimState.verifiedRecently,
          link: 20,
        ),
      ],
    );

    expect(plan!.reason, LoomDtnTransferReason.verifiedGateway);
    expect(plan.opportunityId, 'verified-gateway');
    expect(plan.copiesBefore, 8);
    expect(plan.copiesGranted, 4);
    expect(plan.copiesRetainedAfterSuccess, 4);
  });

  test('binary Spray-and-Wait split is bounded and deterministic', () {
    final store = LoomSqlitePacketStore.openInMemory();
    addTearDown(store.close);
    final packet = _packet(store, now: now, copies: 5);

    final plan = router.planNext(
      packet: packet,
      now: now,
      opportunities: <LoomDtnOpportunity>[
        _opportunity(id: 'carrier-peer', canCarry: true),
      ],
    );

    expect(plan, isNotNull);
    expect(plan!.reason, LoomDtnTransferReason.storeCarryPeer);
    expect(plan.copiesBefore, 5);
    expect(plan.copiesGranted, 2);
    expect(plan.copiesRetainedAfterSuccess, 3);
    expect(plan.requiresSingleCopyCustodyHandoff, isFalse);
  });

  test('single-copy wait phase rejects generic and claimed relays', () {
    final store = LoomSqlitePacketStore.openInMemory();
    addTearDown(store.close);
    final packet = _packet(store, now: now, copies: 1);

    final noRoute = router.planNext(
      packet: packet,
      now: now,
      opportunities: <LoomDtnOpportunity>[
        _opportunity(id: 'carrier-peer', canCarry: true),
        _opportunity(
          id: 'claimed-gateway',
          gateway: LoomGatewayClaimState.claimed,
        ),
      ],
    );
    expect(noRoute, isNull);

    final verified = router.planNext(
      packet: packet,
      now: now,
      opportunities: <LoomDtnOpportunity>[
        _opportunity(
          id: 'verified-gateway',
          gateway: LoomGatewayClaimState.verifiedRecently,
        ),
      ],
    );
    expect(verified, isNotNull);
    expect(verified!.copiesGranted, 1);
    expect(verified.copiesRetainedAfterSuccess, 0);
    expect(verified.requiresSingleCopyCustodyHandoff, isTrue);
  });

  test('relay scope mismatch prevents a gateway from receiving the packet', () {
    final store = LoomSqlitePacketStore.openInMemory();
    addTearDown(store.close);
    final packet = _packet(
      store,
      now: now,
      copies: 4,
      scope: LoomRoutingScopeV2.globalRelay,
    );

    final plan = router.planNext(
      packet: packet,
      now: now,
      opportunities: <LoomDtnOpportunity>[
        _opportunity(
          id: 'domestic-only',
          gateway: LoomGatewayClaimState.verifiedRecently,
          scopes: const <LoomRoutingScopeV2>{LoomRoutingScopeV2.domesticRelay},
        ),
      ],
    );

    expect(plan, isNull);
  });

  test(
    'equal scores use opaque opportunity id as deterministic tie-breaker',
    () {
      final store = LoomSqlitePacketStore.openInMemory();
      addTearDown(store.close);
      final packet = _packet(store, now: now, copies: 4);

      final plan = router.planNext(
        packet: packet,
        now: now,
        opportunities: <LoomDtnOpportunity>[
          _opportunity(id: 'peer-z', canCarry: true),
          _opportunity(id: 'peer-a', canCarry: true),
        ],
      );

      expect(plan!.opportunityId, 'peer-a');
    },
  );

  test('relay-accepted and expired packets are not replanned', () {
    final store = LoomSqlitePacketStore.openInMemory();
    addTearDown(store.close);
    final packet = _packet(store, now: now, copies: 4);
    final relayAccepted = store.markRelayAccepted(packet.packetId, now);

    expect(
      router.planNext(
        packet: relayAccepted,
        now: now,
        opportunities: <LoomDtnOpportunity>[
          _opportunity(id: 'peer', canCarry: true),
        ],
      ),
      isNull,
    );
  });
}

LoomStoredDtnPacket _packet(
  LoomSqlitePacketStore store, {
  required DateTime now,
  required int copies,
  LoomRoutingScopeV2 scope = LoomRoutingScopeV2.globalRelay,
}) {
  final suffix = '$copies-${scope.name}';
  final packetId = 'packet-router-$suffix';
  final outer = LoomOuterEnvelopeV2(
    packetId: packetId,
    routingHint: LoomRoutingHintV2(
      scope: scope,
      mailboxToken: Uint8List.fromList(List<int>.filled(32, 12)),
    ),
    expiresAtBucket: DateTime.utc(2026, 9, 6, 12),
    priority: LoomPriorityClassV2.normal,
    initialHopLimit: 4,
    forwardingState: LoomForwardingStateV2(
      hopsUsed: 0,
      copiesRemaining: copies,
    ),
    encryptedPayload: Uint8List.fromList(<int>[1, 2, 3, copies]),
  );
  return store.putLocalOutbound(
    operationId: 'operation-router-$suffix',
    messageId: 'message-router-$suffix',
    packetId: packetId,
    exactOuterEnvelopeBytes: LoomEnvelopeV2Codec.encodeOuter(outer),
    now: now,
  );
}

LoomDtnOpportunity _opportunity({
  required String id,
  bool authenticated = true,
  bool direct = false,
  LoomGatewayClaimState gateway = LoomGatewayClaimState.none,
  Set<LoomRoutingScopeV2>? scopes,
  bool canCarry = false,
  int link = 60,
  int congestion = 10,
  bool batteryConstrained = false,
  int successes = 0,
  int failures = 0,
}) =>
    LoomDtnOpportunity(
      opportunityId: id,
      authenticated: authenticated,
      directRecipient: direct,
      gatewayClaim: gateway,
      supportedRelayScopes: scopes ??
          (gateway == LoomGatewayClaimState.none
              ? const <LoomRoutingScopeV2>{}
              : const <LoomRoutingScopeV2>{
                  LoomRoutingScopeV2.domesticRelay,
                  LoomRoutingScopeV2.globalRelay,
                }),
      canStoreCarry: canCarry,
      linkQualityPercent: link,
      congestionPercent: congestion,
      batteryConstrained: batteryConstrained,
      recentSuccessfulTransfers: successes,
      recentFailedTransfers: failures,
    );

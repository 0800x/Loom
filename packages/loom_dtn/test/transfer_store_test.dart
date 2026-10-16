import 'dart:io';
import 'dart:typed_data';

import 'package:loom_dtn/loom_dtn.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 9, 5, 12);

  test('prepared transfer persists exact next-hop revision before send', () {
    final store = LoomSqlitePacketStore.openInMemory();
    addTearDown(store.close);
    final packet = _putPacket(store, now: now, copies: 4);
    final plan = const LoomMessageRouter().planNext(
      packet: packet,
      now: now,
      opportunities: <LoomDtnOpportunity>[
        _peer('peer-alpha'),
      ],
    )!;

    final transfer = store.prepareTransfer(
      transmissionId: 'transmission-00000001',
      plan: plan,
      now: now,
    );

    expect(transfer.state, LoomDtnTransferState.prepared);
    expect(transfer.copiesBefore, 4);
    expect(transfer.copiesGranted, 2);
    expect(transfer.copiesRetainedAfterSuccess, 2);

    final forwarded = LoomEnvelopeV2Codec.decodeOuter(transfer.wireBytes);
    final source = LoomEnvelopeV2Codec.decodeOuter(packet.wireBytes);
    expect(forwarded.packetId, source.packetId);
    expect(forwarded.encryptedPayload, source.encryptedPayload);
    expect(forwarded.forwardingState.hopsUsed, 1);
    expect(forwarded.forwardingState.copiesRemaining, 2);

    expect(store.listEligible(now), isEmpty,
        reason: 'a prepared transfer owns the packet forwarding lease');
    expect(store.listPreparedTransfers(), hasLength(1));
  });

  test('only one prepared transfer may reserve a packet copy budget', () {
    final store = LoomSqlitePacketStore.openInMemory();
    addTearDown(store.close);
    final packet = _putPacket(store, now: now, copies: 4);
    const router = LoomMessageRouter();
    final first = router.planNext(
      packet: packet,
      now: now,
      opportunities: <LoomDtnOpportunity>[_peer('peer-a')],
    )!;
    final second = router.planNext(
      packet: packet,
      now: now,
      opportunities: <LoomDtnOpportunity>[_peer('peer-b')],
    )!;

    store.prepareTransfer(
      transmissionId: 'transmission-00000002',
      plan: first,
      now: now,
    );

    expect(
      () => store.prepareTransfer(
        transmissionId: 'transmission-00000003',
        plan: second,
        now: now,
      ),
      throwsA(isA<LoomDtnPacketConflict>()),
    );
  });

  test('accepted Spray-and-Wait split reduces only runtime local copies', () {
    final store = LoomSqlitePacketStore.openInMemory();
    addTearDown(store.close);
    final packet = _putPacket(store, now: now, copies: 5);
    final plan = const LoomMessageRouter().planNext(
      packet: packet,
      now: now,
      opportunities: <LoomDtnOpportunity>[_peer('peer-split')],
    )!;
    final sourceBytes = packet.wireBytes;

    final transfer = store.prepareTransfer(
      transmissionId: 'transmission-00000004',
      plan: plan,
      now: now,
    );
    store.markTransferAccepted(
      transfer.transmissionId,
      now.add(const Duration(seconds: 1)),
    );

    final updated = store.read(packet.packetId)!;
    expect(updated.initialCopiesRemaining, 5);
    expect(updated.copiesRemaining, 3);
    expect(updated.wireBytes, sourceBytes,
        reason: 'source custody bytes must never be rewritten');
    expect(
      LoomEnvelopeV2Codec.decodeOuter(updated.wireBytes)
          .forwardingState
          .copiesRemaining,
      5,
    );
    expect(store.readTransfer(transfer.transmissionId)!.state,
        LoomDtnTransferState.accepted);
  });

  test('failed prepared transfer releases reservation without spending copies',
      () {
    final store = LoomSqlitePacketStore.openInMemory();
    addTearDown(store.close);
    final packet = _putPacket(store, now: now, copies: 4);
    final plan = const LoomMessageRouter().planNext(
      packet: packet,
      now: now,
      opportunities: <LoomDtnOpportunity>[_peer('peer-fail')],
    )!;
    final transfer = store.prepareTransfer(
      transmissionId: 'transmission-00000005',
      plan: plan,
      now: now,
    );

    final failed = store.markTransferFailed(
      transfer.transmissionId,
      now.add(const Duration(seconds: 2)),
      errorCode: 'link_timeout',
    );

    expect(failed.state, LoomDtnTransferState.failed);
    expect(failed.errorCode, 'link_timeout');
    expect(store.read(packet.packetId)!.copiesRemaining, 4);
    expect(store.listEligible(now), hasLength(1));
  });

  test('single-copy verified gateway handoff can be explicitly recovered', () {
    final store = LoomSqlitePacketStore.openInMemory();
    addTearDown(store.close);
    final packet = _putPacket(store, now: now, copies: 1);
    final plan = const LoomMessageRouter().planNext(
      packet: packet,
      now: now,
      opportunities: <LoomDtnOpportunity>[
        _gateway('verified-gateway'),
      ],
    )!;
    expect(plan.requiresSingleCopyCustodyHandoff, isTrue);

    final prepared = store.prepareTransfer(
      transmissionId: 'transmission-00000006',
      plan: plan,
      now: now,
    );
    final accepted = store.markTransferAccepted(
      prepared.transmissionId,
      now.add(const Duration(seconds: 1)),
    );
    expect(accepted.state, LoomDtnTransferState.accepted);

    final handedOff = store.read(packet.packetId)!;
    expect(handedOff.state, LoomDtnPacketState.gatewayAccepted);
    expect(handedOff.copiesRemaining, 0);
    expect(handedOff.isEligibleForForwarding, isFalse);

    final released = store.releaseSingleCopyHandoff(
      prepared.transmissionId,
      now.add(const Duration(minutes: 5)),
      errorCode: 'gateway_lost',
    );
    expect(released.state, LoomDtnTransferState.custodyReleased);

    final recovered = store.read(packet.packetId)!;
    expect(recovered.state, LoomDtnPacketState.queued);
    expect(recovered.copiesRemaining, 1);
    expect(recovered.lastErrorCode, 'gateway_lost');
    expect(recovered.isEligibleForForwarding, isTrue);
  });

  test('relay acceptance prevents reclaiming a single-copy gateway handoff',
      () {
    final store = LoomSqlitePacketStore.openInMemory();
    addTearDown(store.close);
    final packet = _putPacket(store, now: now, copies: 1);
    final plan = const LoomMessageRouter().planNext(
      packet: packet,
      now: now,
      opportunities: <LoomDtnOpportunity>[_gateway('relay-gateway')],
    )!;
    final transfer = store.prepareTransfer(
      transmissionId: 'transmission-00000007',
      plan: plan,
      now: now,
    );
    store.markTransferAccepted(
      transfer.transmissionId,
      now.add(const Duration(seconds: 1)),
    );
    store.markRelayAccepted(
      packet.packetId,
      now.add(const Duration(seconds: 2)),
    );

    expect(
      () => store.releaseSingleCopyHandoff(
        transfer.transmissionId,
        now.add(const Duration(minutes: 1)),
        errorCode: 'gateway_lost',
      ),
      throwsA(isA<LoomDtnPacketConflict>()),
    );
    expect(
        store.read(packet.packetId)!.state, LoomDtnPacketState.relayAccepted);
  });

  test('prepared transfer and exact bytes survive process restart', () {
    final directory = Directory.systemTemp.createTempSync('loom-dtn-xfer-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final path = '${directory.path}${Platform.pathSeparator}dtn.sqlite3';

    final first = LoomSqlitePacketStore.openFile(path);
    final packet = _putPacket(first, now: now, copies: 4);
    final plan = const LoomMessageRouter().planNext(
      packet: packet,
      now: now,
      opportunities: <LoomDtnOpportunity>[_peer('restart-peer')],
    )!;
    final prepared = first.prepareTransfer(
      transmissionId: 'transmission-00000008',
      plan: plan,
      now: now,
    );
    final expectedBytes = prepared.wireBytes;
    first.close();

    final reopened = LoomSqlitePacketStore.openFile(path);
    addTearDown(reopened.close);
    final recovered = reopened.readTransfer('transmission-00000008');
    expect(recovered, isNotNull);
    expect(recovered!.state, LoomDtnTransferState.prepared);
    expect(recovered.wireBytes, expectedBytes);
    expect(reopened.listEligible(now), isEmpty);
  });

  test(
      'direct recipient transfer ACK does not consume copy budget or mark delivered',
      () {
    final store = LoomSqlitePacketStore.openInMemory();
    addTearDown(store.close);
    final packet = _putPacket(store, now: now, copies: 2);
    final plan = const LoomMessageRouter().planNext(
      packet: packet,
      now: now,
      opportunities: <LoomDtnOpportunity>[_recipient('recipient-device')],
    )!;
    final transfer = store.prepareTransfer(
      transmissionId: 'transmission-00000009',
      plan: plan,
      now: now,
    );
    final forwarded = LoomEnvelopeV2Codec.decodeOuter(transfer.wireBytes);
    expect(forwarded.forwardingState.copiesRemaining, 1);

    store.markTransferAccepted(
      transfer.transmissionId,
      now.add(const Duration(seconds: 1)),
    );
    final updated = store.read(packet.packetId)!;
    expect(updated.copiesRemaining, 2);
    expect(updated.state, LoomDtnPacketState.queued);
    expect(updated.recipientConfirmedAt, isNull);
  });
}

LoomStoredDtnPacket _putPacket(
  LoomSqlitePacketStore store, {
  required DateTime now,
  required int copies,
}) {
  final packetId = 'packet-transfer-$copies';
  final outer = LoomOuterEnvelopeV2(
    packetId: packetId,
    routingHint: LoomRoutingHintV2(
      scope: LoomRoutingScopeV2.globalRelay,
      mailboxToken: Uint8List.fromList(List<int>.filled(32, 17)),
    ),
    expiresAtBucket: DateTime.utc(2026, 9, 6, 12),
    priority: LoomPriorityClassV2.normal,
    initialHopLimit: 4,
    forwardingState: LoomForwardingStateV2(
      hopsUsed: 0,
      copiesRemaining: copies,
    ),
    encryptedPayload: Uint8List.fromList(<int>[31, 32, 33, copies]),
  );
  return store.putLocalOutbound(
    operationId: 'operation-transfer-$copies',
    messageId: 'message-transfer-$copies',
    packetId: packetId,
    exactOuterEnvelopeBytes: LoomEnvelopeV2Codec.encodeOuter(outer),
    now: now,
  );
}

LoomDtnOpportunity _peer(String id) => LoomDtnOpportunity(
      opportunityId: id,
      authenticated: true,
      directRecipient: false,
      gatewayClaim: LoomGatewayClaimState.none,
      supportedRelayScopes: const <LoomRoutingScopeV2>{},
      canStoreCarry: true,
      linkQualityPercent: 70,
      congestionPercent: 10,
      batteryConstrained: false,
      recentSuccessfulTransfers: 0,
      recentFailedTransfers: 0,
    );

LoomDtnOpportunity _gateway(String id) => LoomDtnOpportunity(
      opportunityId: id,
      authenticated: true,
      directRecipient: false,
      gatewayClaim: LoomGatewayClaimState.verifiedRecently,
      supportedRelayScopes: const <LoomRoutingScopeV2>{
        LoomRoutingScopeV2.globalRelay,
      },
      canStoreCarry: true,
      linkQualityPercent: 70,
      congestionPercent: 10,
      batteryConstrained: false,
      recentSuccessfulTransfers: 0,
      recentFailedTransfers: 0,
    );

LoomDtnOpportunity _recipient(String id) => LoomDtnOpportunity(
      opportunityId: id,
      authenticated: true,
      directRecipient: true,
      gatewayClaim: LoomGatewayClaimState.none,
      supportedRelayScopes: const <LoomRoutingScopeV2>{},
      canStoreCarry: false,
      linkQualityPercent: 70,
      congestionPercent: 10,
      batteryConstrained: false,
      recentSuccessfulTransfers: 0,
      recentFailedTransfers: 0,
    );

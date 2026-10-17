import 'dart:typed_data';

import 'package:loom_dtn/loom_dtn.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 9, 5, 12);

  test('store-carry transfer is prepared before IO and spends copies on ACK',
      () async {
    final store = LoomSqlitePacketStore.openInMemory();
    addTearDown(store.close);
    _putPacket(store, now: now, packetId: 'packet-exec-000001', copies: 4);
    final executor = LoomDtnTransferExecutor(
      packetStore: store,
      transferStore: store,
      clock: () => now,
    );

    final prepared = executor.prepareNext(
      packetId: 'packet-exec-000001',
      opportunities: <LoomDtnOpportunity>[_carrier('peer-exec-0001')],
      transmissionId: 'transmission-exec-0001',
      now: now,
    );
    expect(prepared, isNotNull);
    expect(prepared!.state, LoomDtnTransferState.prepared);
    final forwarded = LoomEnvelopeV2Codec.decodeOuter(prepared.wireBytes);
    expect(forwarded.forwardingState.hopsUsed, 1);
    expect(forwarded.forwardingState.copiesRemaining, 2);
    expect(store.read('packet-exec-000001')!.copiesRemaining, 4);

    final sender = _AcceptedSender(
      LoomDtnHopAck(
        transmissionId: prepared.transmissionId,
        packetId: prepared.packetId,
        acceptedAt: now.add(const Duration(seconds: 1)),
        duplicate: false,
      ),
    );
    final result = await executor.executePrepared(
      transmissionId: prepared.transmissionId,
      sender: sender,
    );

    expect(sender.calls, 1);
    expect(result.status, LoomDtnExecutionStatus.accepted);
    expect(result.transfer.state, LoomDtnTransferState.accepted);
    expect(result.packet.copiesRemaining, 2);
    expect(result.packet.state, LoomDtnPacketState.queued);
  });

  test('already accepted transmission is not sent again', () async {
    final store = LoomSqlitePacketStore.openInMemory();
    addTearDown(store.close);
    _putPacket(store, now: now, packetId: 'packet-exec-000002', copies: 4);
    final executor = LoomDtnTransferExecutor(
      packetStore: store,
      transferStore: store,
      clock: () => now,
    );
    final prepared = executor.prepareNext(
      packetId: 'packet-exec-000002',
      opportunities: <LoomDtnOpportunity>[_carrier('peer-exec-0002')],
      transmissionId: 'transmission-exec-0002',
      now: now,
    )!;
    final firstSender = _AcceptedSender(
      LoomDtnHopAck(
        transmissionId: prepared.transmissionId,
        packetId: prepared.packetId,
        acceptedAt: now.add(const Duration(seconds: 1)),
        duplicate: false,
      ),
    );
    await executor.executePrepared(
      transmissionId: prepared.transmissionId,
      sender: firstSender,
    );

    final shouldNotRun = _ThrowingSender();
    final second = await executor.executePrepared(
      transmissionId: prepared.transmissionId,
      sender: shouldNotRun,
    );
    expect(second.status, LoomDtnExecutionStatus.alreadyAccepted);
    expect(shouldNotRun.calls, 0);
  });

  test('mismatched hop ACK cannot mutate prepared transfer or copy budget',
      () async {
    final store = LoomSqlitePacketStore.openInMemory();
    addTearDown(store.close);
    _putPacket(store, now: now, packetId: 'packet-exec-000003', copies: 4);
    final executor = LoomDtnTransferExecutor(
      packetStore: store,
      transferStore: store,
      clock: () => now,
    );
    final prepared = executor.prepareNext(
      packetId: 'packet-exec-000003',
      opportunities: <LoomDtnOpportunity>[_carrier('peer-exec-0003')],
      transmissionId: 'transmission-exec-0003',
      now: now,
    )!;

    expect(
      () => executor.executePrepared(
        transmissionId: prepared.transmissionId,
        sender: _AcceptedSender(
          LoomDtnHopAck(
            transmissionId: 'transmission-wrong-0003',
            packetId: prepared.packetId,
            acceptedAt: now.add(const Duration(seconds: 1)),
            duplicate: false,
          ),
        ),
      ),
      throwsA(isA<LoomDtnPacketConflict>()),
    );

    expect(
      store.readTransfer(prepared.transmissionId)!.state,
      LoomDtnTransferState.prepared,
    );
    expect(store.read(prepared.packetId)!.copiesRemaining, 4);
  });

  test(
      'direct recipient hop ACK pauses retry but never marks recipient delivered',
      () async {
    final store = LoomSqlitePacketStore.openInMemory();
    addTearDown(store.close);
    _putPacket(store, now: now, packetId: 'packet-exec-000004', copies: 4);
    final localObservedAt = now.add(const Duration(seconds: 3));
    final executor = LoomDtnTransferExecutor(
      packetStore: store,
      transferStore: store,
      clock: () => localObservedAt,
    );
    final prepared = executor.prepareNext(
      packetId: 'packet-exec-000004',
      opportunities: <LoomDtnOpportunity>[_directRecipient('recipient-peer')],
      transmissionId: 'transmission-exec-0004',
      now: now,
    )!;
    expect(prepared.reason, LoomDtnTransferReason.directRecipient);

    // Deliberately absurd peer timestamp: local retry state must ignore it.
    final remoteAcceptedAt = now.add(const Duration(days: 30));
    final result = await executor.executePrepared(
      transmissionId: prepared.transmissionId,
      sender: _AcceptedSender(
        LoomDtnHopAck(
          transmissionId: prepared.transmissionId,
          packetId: prepared.packetId,
          acceptedAt: remoteAcceptedAt,
          duplicate: false,
        ),
      ),
      directRecipientReceiptGrace: const Duration(minutes: 5),
    );

    expect(result.packet.state, LoomDtnPacketState.queued);
    expect(result.packet.recipientConfirmedAt, isNull);
    expect(result.packet.isTerminal, isFalse);
    expect(
      result.packet.nextAttemptAt,
      localObservedAt.add(const Duration(minutes: 5)),
    );
    expect(result.packet.attemptCount, 1);
  });

  test('structured send failure releases prepared lock and reschedules packet',
      () async {
    final store = LoomSqlitePacketStore.openInMemory();
    addTearDown(store.close);
    _putPacket(store, now: now, packetId: 'packet-exec-000005', copies: 4);
    final localFailureAt = now.add(const Duration(seconds: 3));
    final executor = LoomDtnTransferExecutor(
      packetStore: store,
      transferStore: store,
      clock: () => localFailureAt,
    );
    final prepared = executor.prepareNext(
      packetId: 'packet-exec-000005',
      opportunities: <LoomDtnOpportunity>[_carrier('peer-exec-0005')],
      transmissionId: 'transmission-exec-0005',
      now: now,
    )!;

    final result = await executor.executePrepared(
      transmissionId: prepared.transmissionId,
      sender: _FailedSender(
        LoomDtnSendFailed(
          // Adapter time is intentionally wrong and must not control state.
          completedAt: now.add(const Duration(days: 20)),
          errorCode: 'link_timeout',
        ),
      ),
      retryDelay: const Duration(minutes: 3),
    );

    expect(result.status, LoomDtnExecutionStatus.failed);
    expect(result.transfer.state, LoomDtnTransferState.failed);
    expect(result.transfer.errorCode, 'link_timeout');
    expect(result.packet.copiesRemaining, 4);
    expect(result.packet.attemptCount, 1);
    expect(result.packet.lastErrorCode, 'link_timeout');
    expect(
      result.packet.nextAttemptAt,
      localFailureAt.add(const Duration(minutes: 3)),
    );
    expect(store.listPreparedTransfers(), isEmpty);
  });

  test('unexpected transport exception is sanitized to structured code',
      () async {
    final store = LoomSqlitePacketStore.openInMemory();
    addTearDown(store.close);
    _putPacket(store, now: now, packetId: 'packet-exec-000006', copies: 4);
    final failureTime = now.add(const Duration(seconds: 7));
    final executor = LoomDtnTransferExecutor(
      packetStore: store,
      transferStore: store,
      clock: () => failureTime,
    );
    final prepared = executor.prepareNext(
      packetId: 'packet-exec-000006',
      opportunities: <LoomDtnOpportunity>[_carrier('peer-exec-0006')],
      transmissionId: 'transmission-exec-0006',
      now: now,
    )!;

    final sender = _ThrowingSender();
    final result = await executor.executePrepared(
      transmissionId: prepared.transmissionId,
      sender: sender,
    );

    expect(sender.calls, 1);
    expect(result.status, LoomDtnExecutionStatus.failed);
    expect(result.transfer.errorCode, 'transport_exception');
    expect(result.packet.lastErrorCode, 'transport_exception');
    expect(
      result.packet.nextAttemptAt,
      failureTime.add(const Duration(minutes: 2)),
    );
  });

  test('backwards local wall clock is clamped to durable preparation time',
      () async {
    final store = LoomSqlitePacketStore.openInMemory();
    addTearDown(store.close);
    _putPacket(store, now: now, packetId: 'packet-exec-000007', copies: 4);
    final executor = LoomDtnTransferExecutor(
      packetStore: store,
      transferStore: store,
      clock: () => now.subtract(const Duration(hours: 1)),
    );
    final prepared = executor.prepareNext(
      packetId: 'packet-exec-000007',
      opportunities: <LoomDtnOpportunity>[_directRecipient('recipient-peer-7')],
      transmissionId: 'transmission-exec-0007',
      now: now,
    )!;

    final result = await executor.executePrepared(
      transmissionId: prepared.transmissionId,
      sender: _AcceptedSender(
        LoomDtnHopAck(
          transmissionId: prepared.transmissionId,
          packetId: prepared.packetId,
          acceptedAt: now,
          duplicate: false,
        ),
      ),
      directRecipientReceiptGrace: const Duration(minutes: 1),
    );

    expect(
      result.packet.nextAttemptAt,
      prepared.preparedAt.add(const Duration(minutes: 1)),
    );
  });
}

void _putPacket(
  LoomSqlitePacketStore store, {
  required DateTime now,
  required String packetId,
  required int copies,
}) {
  final outer = LoomOuterEnvelopeV2(
    packetId: packetId,
    routingHint: LoomRoutingHintV2(
      scope: LoomRoutingScopeV2.globalRelay,
      mailboxToken: Uint8List.fromList(List<int>.filled(32, 23)),
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
  store.putLocalOutbound(
    operationId: 'operation-$packetId',
    messageId: 'message-$packetId',
    packetId: packetId,
    exactOuterEnvelopeBytes: LoomEnvelopeV2Codec.encodeOuter(outer),
    now: now,
  );
}

LoomDtnOpportunity _carrier(String id) => LoomDtnOpportunity(
      opportunityId: id,
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
    );

LoomDtnOpportunity _directRecipient(String id) => LoomDtnOpportunity(
      opportunityId: id,
      authenticated: true,
      directRecipient: true,
      gatewayClaim: LoomGatewayClaimState.none,
      supportedRelayScopes: const <LoomRoutingScopeV2>{},
      canStoreCarry: false,
      linkQualityPercent: 80,
      congestionPercent: 5,
      batteryConstrained: false,
      recentSuccessfulTransfers: 0,
      recentFailedTransfers: 0,
    );

final class _AcceptedSender implements LoomDtnTransferSender {
  _AcceptedSender(this.ack);

  final LoomDtnHopAck ack;
  int calls = 0;

  @override
  Future<LoomDtnSendResult> sendPrepared(LoomStoredDtnTransfer transfer) async {
    calls += 1;
    expect(transfer.state, LoomDtnTransferState.prepared);
    return LoomDtnSendAccepted(ack);
  }
}

final class _FailedSender implements LoomDtnTransferSender {
  _FailedSender(this.result);

  final LoomDtnSendFailed result;

  @override
  Future<LoomDtnSendResult> sendPrepared(
          LoomStoredDtnTransfer transfer) async =>
      result;
}

final class _ThrowingSender implements LoomDtnTransferSender {
  int calls = 0;

  @override
  Future<LoomDtnSendResult> sendPrepared(LoomStoredDtnTransfer transfer) async {
    calls += 1;
    throw StateError(
        'secret host detail should never reach durable error state');
  }
}

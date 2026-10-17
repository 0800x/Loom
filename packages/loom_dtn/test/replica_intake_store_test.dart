import 'dart:io';
import 'dart:typed_data';

import 'package:loom_dtn/loom_dtn.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 9, 5, 12);

  test('accepts exact prepared peer transfer into durable carried custody', () {
    final senderDir = Directory.systemTemp.createTempSync('loom-dtn-sender-');
    final receiverDir =
        Directory.systemTemp.createTempSync('loom-dtn-receiver-');
    addTearDown(() => senderDir.deleteSync(recursive: true));
    addTearDown(() => receiverDir.deleteSync(recursive: true));

    final senderPath = '${senderDir.path}${Platform.pathSeparator}dtn.sqlite3';
    final receiverPath =
        '${receiverDir.path}${Platform.pathSeparator}dtn.sqlite3';
    final sender = LoomSqlitePacketStore.openFile(senderPath);
    final receiver = LoomSqlitePacketStore.openFile(receiverPath);
    final intake = LoomSqliteReplicaIntakeStore.openExistingFile(receiverPath);
    addTearDown(sender.close);
    addTearDown(receiver.close);
    addTearDown(intake.close);

    sender.putLocalOutbound(
      operationId: 'operation-replica-0001',
      messageId: 'message-replica-0001',
      packetId: 'packet-replica-000001',
      exactOuterEnvelopeBytes: _outerWire(
        packetId: 'packet-replica-000001',
        expiresAt: DateTime.utc(2026, 9, 6, 12),
        hopsUsed: 0,
        copiesRemaining: 4,
      ),
      now: now,
    );

    final packet = sender.read('packet-replica-000001')!;
    final plan = const LoomMessageRouter().planNext(
      packet: packet,
      opportunities: <LoomDtnOpportunity>[
        LoomDtnOpportunity(
          opportunityId: 'peer-session-0001',
          authenticated: true,
          directRecipient: false,
          gatewayClaim: LoomGatewayClaimState.none,
          supportedRelayScopes: const <LoomRoutingScopeV2>{},
          canStoreCarry: true,
          linkQualityPercent: 80,
          congestionPercent: 10,
          batteryConstrained: false,
          recentSuccessfulTransfers: 1,
          recentFailedTransfers: 0,
        ),
      ],
      now: now,
    );
    expect(plan, isNotNull);
    expect(plan!.copiesGranted, 2);

    final transfer = sender.prepareTransfer(
      transmissionId: 'transmission-00000001',
      plan: plan,
      now: now,
    );
    final forwarded = LoomEnvelopeV2Codec.decodeOuter(transfer.wireBytes);
    expect(forwarded.forwardingState.hopsUsed, 1);
    expect(forwarded.forwardingState.copiesRemaining, 2);

    final result = intake.acceptReplica(
      exactOuterEnvelopeBytes: transfer.wireBytes,
      now: now.add(const Duration(seconds: 1)),
    );

    expect(result.disposition, LoomReplicaIntakeDisposition.accepted);
    expect(result.shouldAcknowledgeTransfer, isTrue);
    expect(result.effectiveCopiesRemaining, 2);

    final stored = receiver.read('packet-replica-000001');
    expect(stored, isNotNull);
    expect(stored!.origin, LoomDtnPacketOrigin.carriedReplica);
    expect(stored.operationId, isNull);
    expect(stored.messageId, isNull);
    expect(stored.wireBytes, transfer.wireBytes);
    expect(stored.hopsUsed, 1);
    expect(stored.initialCopiesRemaining, 2);
    expect(stored.copiesRemaining, 2);
  });

  test('duplicate forwarding revision is ACKable and never inflates copies',
      () {
    final directory =
        Directory.systemTemp.createTempSync('loom-dtn-duplicate-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final path = '${directory.path}${Platform.pathSeparator}dtn.sqlite3';
    final packetStore = LoomSqlitePacketStore.openFile(path);
    final intake = LoomSqliteReplicaIntakeStore.openExistingFile(path);
    addTearDown(packetStore.close);
    addTearDown(intake.close);

    final firstWire = _outerWire(
      packetId: 'packet-replica-000002',
      expiresAt: DateTime.utc(2026, 9, 6, 12),
      hopsUsed: 1,
      copiesRemaining: 2,
    );
    final first = intake.acceptReplica(
      exactOuterEnvelopeBytes: firstWire,
      now: now,
    );
    expect(first.disposition, LoomReplicaIntakeDisposition.accepted);
    expect(first.effectiveCopiesRemaining, 2);

    // Same logical packet and encrypted payload, but a different forwarding
    // revision claims a larger copy budget. It is a duplicate, not authority to
    // mint six more local forwarding tokens.
    final duplicateWire = _outerWire(
      packetId: 'packet-replica-000002',
      expiresAt: DateTime.utc(2026, 9, 6, 12),
      hopsUsed: 2,
      copiesRemaining: 8,
    );
    final duplicate = intake.acceptReplica(
      exactOuterEnvelopeBytes: duplicateWire,
      now: now.add(const Duration(minutes: 1)),
    );
    expect(duplicate.disposition, LoomReplicaIntakeDisposition.duplicate);
    expect(duplicate.shouldAcknowledgeTransfer, isTrue);
    expect(duplicate.effectiveCopiesRemaining, 2);

    final persisted = packetStore.read('packet-replica-000002')!;
    expect(persisted.wireBytes, firstWire);
    expect(persisted.copiesRemaining, 2);
    expect(persisted.hopsUsed, 1);
  });

  test('PacketId collision with different encrypted payload fails closed', () {
    final directory = Directory.systemTemp.createTempSync('loom-dtn-conflict-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final path = '${directory.path}${Platform.pathSeparator}dtn.sqlite3';
    final packetStore = LoomSqlitePacketStore.openFile(path);
    final intake = LoomSqliteReplicaIntakeStore.openExistingFile(path);
    addTearDown(packetStore.close);
    addTearDown(intake.close);

    intake.acceptReplica(
      exactOuterEnvelopeBytes: _outerWire(
        packetId: 'packet-replica-000003',
        expiresAt: DateTime.utc(2026, 9, 6, 12),
        hopsUsed: 1,
        copiesRemaining: 2,
        payloadByte: 7,
      ),
      now: now,
    );

    expect(
      () => intake.acceptReplica(
        exactOuterEnvelopeBytes: _outerWire(
          packetId: 'packet-replica-000003',
          expiresAt: DateTime.utc(2026, 9, 6, 12),
          hopsUsed: 2,
          copiesRemaining: 1,
          payloadByte: 99,
        ),
        now: now.add(const Duration(minutes: 1)),
      ),
      throwsA(isA<LoomReplicaConflict>()),
    );
  });

  test(
      'looped copy of local packet is duplicate without overwriting correlation',
      () {
    final directory = Directory.systemTemp.createTempSync('loom-dtn-loop-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final path = '${directory.path}${Platform.pathSeparator}dtn.sqlite3';
    final packetStore = LoomSqlitePacketStore.openFile(path);
    final intake = LoomSqliteReplicaIntakeStore.openExistingFile(path);
    addTearDown(packetStore.close);
    addTearDown(intake.close);

    packetStore.putLocalOutbound(
      operationId: 'operation-replica-0004',
      messageId: 'message-replica-0004',
      packetId: 'packet-replica-000004',
      exactOuterEnvelopeBytes: _outerWire(
        packetId: 'packet-replica-000004',
        expiresAt: DateTime.utc(2026, 9, 6, 12),
        hopsUsed: 0,
        copiesRemaining: 4,
      ),
      now: now,
    );

    final result = intake.acceptReplica(
      exactOuterEnvelopeBytes: _outerWire(
        packetId: 'packet-replica-000004',
        expiresAt: DateTime.utc(2026, 9, 6, 12),
        hopsUsed: 2,
        copiesRemaining: 1,
      ),
      now: now.add(const Duration(minutes: 1)),
    );
    expect(result.disposition, LoomReplicaIntakeDisposition.duplicate);

    final persisted = packetStore.read('packet-replica-000004')!;
    expect(persisted.origin, LoomDtnPacketOrigin.localOutbound);
    expect(persisted.operationId, 'operation-replica-0004');
    expect(persisted.messageId, 'message-replica-0004');
    expect(persisted.copiesRemaining, 4);
  });

  test('untrusted forwarding copy budget is clamped locally', () {
    final directory = Directory.systemTemp.createTempSync('loom-dtn-clamp-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final path = '${directory.path}${Platform.pathSeparator}dtn.sqlite3';
    final packetStore = LoomSqlitePacketStore.openFile(path);
    final intake = LoomSqliteReplicaIntakeStore.openExistingFile(path);
    addTearDown(packetStore.close);
    addTearDown(intake.close);

    final wire = _outerWire(
      packetId: 'packet-replica-000005',
      expiresAt: DateTime.utc(2026, 9, 6, 12),
      hopsUsed: 1,
      copiesRemaining: 16,
    );
    final result = intake.acceptReplica(
      exactOuterEnvelopeBytes: wire,
      now: now,
    );
    expect(result.effectiveCopiesRemaining, 8);

    final persisted = packetStore.read('packet-replica-000005')!;
    expect(persisted.initialCopiesRemaining, 16);
    expect(persisted.copiesRemaining, 8);
    expect(persisted.wireBytes, wire);
  });

  test('rejects hop-zero, expired, and overlong-lifetime peer packets', () {
    final directory = Directory.systemTemp.createTempSync('loom-dtn-invalid-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final path = '${directory.path}${Platform.pathSeparator}dtn.sqlite3';
    final packetStore = LoomSqlitePacketStore.openFile(path);
    final intake = LoomSqliteReplicaIntakeStore.openExistingFile(path);
    addTearDown(packetStore.close);
    addTearDown(intake.close);

    expect(
      () => intake.acceptReplica(
        exactOuterEnvelopeBytes: _outerWire(
          packetId: 'packet-replica-invalid1',
          expiresAt: DateTime.utc(2026, 9, 6, 12),
          hopsUsed: 0,
          copiesRemaining: 2,
        ),
        now: now,
      ),
      throwsFormatException,
    );

    expect(
      () => intake.acceptReplica(
        exactOuterEnvelopeBytes: _outerWire(
          packetId: 'packet-replica-invalid2',
          expiresAt: now,
          hopsUsed: 1,
          copiesRemaining: 2,
        ),
        now: now,
      ),
      throwsFormatException,
    );

    expect(
      () => intake.acceptReplica(
        exactOuterEnvelopeBytes: _outerWire(
          packetId: 'packet-replica-invalid3',
          expiresAt: now.add(const Duration(days: 8)),
          hopsUsed: 1,
          copiesRemaining: 2,
        ),
        now: now,
      ),
      throwsFormatException,
    );
  });
}

Uint8List _outerWire({
  required String packetId,
  required DateTime expiresAt,
  required int hopsUsed,
  required int copiesRemaining,
  int payloadByte = 7,
}) {
  final outer = LoomOuterEnvelopeV2(
    packetId: packetId,
    routingHint: LoomRoutingHintV2(
      scope: LoomRoutingScopeV2.globalRelay,
      mailboxToken: Uint8List.fromList(
        List<int>.generate(32, (index) => index + 1),
      ),
    ),
    expiresAtBucket: expiresAt,
    priority: LoomPriorityClassV2.normal,
    initialHopLimit: 4,
    forwardingState: LoomForwardingStateV2(
      hopsUsed: hopsUsed,
      copiesRemaining: copiesRemaining,
    ),
    encryptedPayload: Uint8List.fromList(<int>[payloadByte, 2, 3, 4]),
  );
  return LoomEnvelopeV2Codec.encodeOuter(outer);
}

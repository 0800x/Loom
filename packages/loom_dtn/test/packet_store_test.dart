import 'dart:io';
import 'dart:typed_data';

import 'package:loom_dtn/loom_dtn.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 9, 5, 12);

  test('persists exact OuterEnvelope bytes before exposing packet', () {
    final store = LoomSqlitePacketStore.openInMemory();
    addTearDown(store.close);
    final wire = _outerWire(
      packetId: 'packet-000000000001',
      expiresAt: DateTime.utc(2026, 9, 6, 12),
    );

    final stored = store.putLocalOutbound(
      operationId: 'operation-00000001',
      messageId: 'message-00000001',
      packetId: 'packet-000000000001',
      exactOuterEnvelopeBytes: wire,
      now: now,
    );

    expect(stored.state, LoomDtnPacketState.queued);
    expect(stored.wireBytes, wire);
    expect(stored.routingScope, LoomRoutingScopeV2.globalRelay);
    expect(stored.attemptCount, 0);

    final mutableCopy = stored.wireBytes;
    mutableCopy[mutableCopy.length - 1] ^= 0xff;
    expect(store.read(stored.packetId)!.wireBytes, wire);
  });

  test(
    'same local packet put is idempotent but PacketId collision fails closed',
    () {
      final store = LoomSqlitePacketStore.openInMemory();
      addTearDown(store.close);
      final wire = _outerWire(
        packetId: 'packet-000000000002',
        expiresAt: DateTime.utc(2026, 9, 6, 12),
      );

      final first = store.putLocalOutbound(
        operationId: 'operation-00000002',
        messageId: 'message-00000002',
        packetId: 'packet-000000000002',
        exactOuterEnvelopeBytes: wire,
        now: now,
      );
      final retry = store.putLocalOutbound(
        operationId: 'operation-00000002',
        messageId: 'message-00000002',
        packetId: 'packet-000000000002',
        exactOuterEnvelopeBytes: wire,
        now: now.add(const Duration(minutes: 1)),
      );

      expect(retry.storedAt, first.storedAt);
      expect(retry.wireBytes, first.wireBytes);

      final conflicting = _outerWire(
        packetId: 'packet-000000000002',
        expiresAt: DateTime.utc(2026, 9, 6, 12),
        payloadByte: 9,
      );
      expect(
        () => store.putLocalOutbound(
          operationId: 'operation-00000002',
          messageId: 'message-00000002',
          packetId: 'packet-000000000002',
          exactOuterEnvelopeBytes: conflicting,
          now: now,
        ),
        throwsA(isA<LoomDtnPacketConflict>()),
      );
    },
  );

  test(
    'file-backed packet custody survives close and reopen byte-for-byte',
    () {
      final directory = Directory.systemTemp.createTempSync('loom-dtn-test-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final path = '${directory.path}${Platform.pathSeparator}dtn.sqlite3';
      final wire = _outerWire(
        packetId: 'packet-000000000003',
        expiresAt: DateTime.utc(2026, 9, 6, 12),
      );

      final first = LoomSqlitePacketStore.openFile(path);
      first.putLocalOutbound(
        operationId: 'operation-00000003',
        messageId: 'message-00000003',
        packetId: 'packet-000000000003',
        exactOuterEnvelopeBytes: wire,
        now: now,
      );
      first.close();

      final reopened = LoomSqlitePacketStore.openFile(path);
      addTearDown(reopened.close);
      final recovered = reopened.read('packet-000000000003');
      expect(recovered, isNotNull);
      expect(recovered!.wireBytes, wire);
      expect(recovered.operationId, 'operation-00000003');
      expect(recovered.messageId, 'message-00000003');
    },
  );

  test('relay acceptance is not recipient delivery confirmation', () {
    final store = LoomSqlitePacketStore.openInMemory();
    addTearDown(store.close);
    final wire = _outerWire(
      packetId: 'packet-000000000004',
      expiresAt: DateTime.utc(2026, 9, 6, 12),
    );
    store.putLocalOutbound(
      operationId: 'operation-00000004',
      messageId: 'message-00000004',
      packetId: 'packet-000000000004',
      exactOuterEnvelopeBytes: wire,
      now: now,
    );

    final attempted = store.recordAttempt(
      'packet-000000000004',
      attemptedAt: now,
      nextAttemptAt: now.add(const Duration(minutes: 5)),
      errorCode: 'link_timeout',
    );
    expect(attempted.attemptCount, 1);
    expect(attempted.lastErrorCode, 'link_timeout');

    final gateway = store.markGatewayAccepted(
      'packet-000000000004',
      now.add(const Duration(minutes: 1)),
    );
    expect(gateway.state, LoomDtnPacketState.gatewayAccepted);
    expect(gateway.isEligibleForForwarding, isTrue);

    final relay = store.markRelayAccepted(
      'packet-000000000004',
      now.add(const Duration(minutes: 2)),
    );
    expect(relay.state, LoomDtnPacketState.relayAccepted);
    expect(relay.recipientConfirmedAt, isNull);
    expect(relay.isTerminal, isFalse);
    expect(relay.isEligibleForForwarding, isFalse);

    final delivered = store.markRecipientConfirmed(
      'packet-000000000004',
      now.add(const Duration(minutes: 3)),
    );
    expect(delivered.state, LoomDtnPacketState.recipientConfirmed);
    expect(delivered.recipientConfirmedAt, isNotNull);
    expect(delivered.isTerminal, isTrue);
  });

  test(
    'eligible queue is bounded by retry time, state, priority, and expiry',
    () {
      final store = LoomSqlitePacketStore.openInMemory();
      addTearDown(store.close);
      final normal = _outerWire(
        packetId: 'packet-000000000005',
        expiresAt: DateTime.utc(2026, 9, 6, 12),
      );
      final urgent = _outerWire(
        packetId: 'packet-000000000006',
        expiresAt: DateTime.utc(2026, 9, 6, 12),
        priority: LoomPriorityClassV2.urgent,
      );
      store.putLocalOutbound(
        operationId: 'operation-00000005',
        messageId: 'message-00000005',
        packetId: 'packet-000000000005',
        exactOuterEnvelopeBytes: normal,
        now: now,
      );
      store.putLocalOutbound(
        operationId: 'operation-00000006',
        messageId: 'message-00000006',
        packetId: 'packet-000000000006',
        exactOuterEnvelopeBytes: urgent,
        now: now,
      );

      expect(
        store.listEligible(now).map((packet) => packet.packetId).toList(),
        <String>['packet-000000000006', 'packet-000000000005'],
      );

      store.recordAttempt(
        'packet-000000000006',
        attemptedAt: now,
        nextAttemptAt: now.add(const Duration(hours: 1)),
      );
      expect(
        store.listEligible(now).map((packet) => packet.packetId).toList(),
        <String>['packet-000000000005'],
      );

      store.markRelayAccepted('packet-000000000005', now);
      expect(store.listEligible(now), isEmpty);
    },
  );

  test(
    'terminal PacketId tombstones survive expiry until retention elapses',
    () {
      final store = LoomSqlitePacketStore.openInMemory();
      addTearDown(store.close);
      final expiry = DateTime.utc(2026, 9, 6, 12);
      final wire = _outerWire(
        packetId: 'packet-000000000007',
        expiresAt: expiry,
      );
      store.putLocalOutbound(
        operationId: 'operation-00000007',
        messageId: 'message-00000007',
        packetId: 'packet-000000000007',
        exactOuterEnvelopeBytes: wire,
        now: now,
      );
      store.markRecipientConfirmed(
        'packet-000000000007',
        now.add(const Duration(minutes: 2)),
      );

      expect(store.pruneTerminal(expiry.add(const Duration(days: 20))), 0);
      expect(store.read('packet-000000000007'), isNotNull);
      expect(store.pruneTerminal(expiry.add(const Duration(days: 40))), 1);
      expect(store.read('packet-000000000007'), isNull);
    },
  );

  test('local custody rejects forwarded bytes and mismatched PacketId', () {
    final store = LoomSqlitePacketStore.openInMemory();
    addTearDown(store.close);
    final forwarded = _outerWire(
      packetId: 'packet-000000000008',
      expiresAt: DateTime.utc(2026, 9, 6, 12),
      hopsUsed: 1,
    );

    expect(
      () => store.putLocalOutbound(
        operationId: 'operation-00000008',
        messageId: 'message-00000008',
        packetId: 'packet-000000000008',
        exactOuterEnvelopeBytes: forwarded,
        now: now,
      ),
      throwsFormatException,
    );

    final valid = _outerWire(
      packetId: 'packet-000000000009',
      expiresAt: DateTime.utc(2026, 9, 6, 12),
    );
    expect(
      () => store.putLocalOutbound(
        operationId: 'operation-00000009',
        messageId: 'message-00000009',
        packetId: 'packet-000000000099',
        exactOuterEnvelopeBytes: valid,
        now: now,
      ),
      throwsA(isA<LoomDtnPacketConflict>()),
    );
  });
}

Uint8List _outerWire({
  required String packetId,
  required DateTime expiresAt,
  int payloadByte = 7,
  int hopsUsed = 0,
  LoomPriorityClassV2 priority = LoomPriorityClassV2.normal,
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
    priority: priority,
    initialHopLimit: 4,
    forwardingState: LoomForwardingStateV2(
      hopsUsed: hopsUsed,
      copiesRemaining: 4,
    ),
    encryptedPayload: Uint8List.fromList(<int>[payloadByte, 2, 3, 4]),
  );
  return LoomEnvelopeV2Codec.encodeOuter(outer);
}

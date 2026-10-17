import 'dart:typed_data';

import 'package:loom_dtn/loom_dtn.dart';
import 'package:loom_messaging/loom_messaging.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:loom_sessions/loom_sessions.dart';
import 'package:loom_storage/loom_storage.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 9, 5, 12, 30);

  test('crypto outbox becomes routable only after durable DTN custody', () {
    final packetStore = LoomSqlitePacketStore.openInMemory();
    addTearDown(packetStore.close);
    final service = LoomV2PacketCustodyService(packetStore: packetStore);
    final stored = _stored(now);
    final plan = _plan(scope: LoomRoutingScopeV2.globalRelay);

    final durable = service.persistPending(
      stored: stored,
      plan: plan,
      now: now,
    );

    expect(durable.packetId, stored.record.packetId);
    expect(durable.operationId, stored.record.operationId);
    expect(durable.messageId, stored.record.messageId);
    expect(durable.state, LoomDtnPacketState.queued);

    final recovered = packetStore.read(stored.record.packetId);
    expect(recovered, isNotNull);
    expect(recovered!.wireBytes, durable.wireBytes);

    final outer = LoomEnvelopeV2Codec.decodeOuter(recovered.wireBytes);
    expect(outer.packetId, stored.record.packetId);
    final session = LoomEnvelopeV2Codec.decodeSessionCiphertext(
      outer.encryptedPayload,
    );
    expect(session.ciphertext, stored.record.ciphertext.bytes);
  });

  test(
    'crash-style replay of the same committed outbox and plan is idempotent',
    () {
      final packetStore = LoomSqlitePacketStore.openInMemory();
      addTearDown(packetStore.close);
      final service = LoomV2PacketCustodyService(packetStore: packetStore);
      final stored = _stored(now);
      final plan = _plan(scope: LoomRoutingScopeV2.domesticRelay);

      final first = service.persistPending(
        stored: stored,
        plan: plan,
        now: now,
      );
      final replay = service.persistPending(
        stored: stored,
        plan: plan,
        now: now.add(const Duration(minutes: 2)),
      );

      expect(replay.packetId, first.packetId);
      expect(replay.storedAt, first.storedAt);
      expect(replay.wireBytes, first.wireBytes);
    },
  );

  test('a PacketId cannot silently acquire different routing metadata after custody', () {
    final packetStore = LoomSqlitePacketStore.openInMemory();
    addTearDown(packetStore.close);
    final service = LoomV2PacketCustodyService(packetStore: packetStore);
    final stored = _stored(now);

    service.persistPending(
      stored: stored,
      plan: _plan(scope: LoomRoutingScopeV2.domesticRelay),
      now: now,
    );

    expect(
      () => service.persistPending(
        stored: stored,
        plan: _plan(scope: LoomRoutingScopeV2.globalRelay),
        now: now.add(const Duration(minutes: 1)),
      ),
      throwsA(isA<LoomDtnPacketConflict>()),
    );
  });
}

LoomStoredCryptoOutboxRecord _stored(DateTime now) {
  final record = LoomCryptoOutboxRecord(
    operationId: 'operation-00000011',
    sessionId: 'session-00000011',
    sessionRevision: 5,
    messageId: 'message-00000011',
    packetId: 'packet-000000000011',
    ciphertext: LoomSessionCiphertext(
      protocolVersion: 'Loom-Session-v2',
      sessionLocator: 'opaque-session-locator-11',
      bytes: Uint8List.fromList(<int>[21, 22, 23, 24]),
    ),
    createdAt: now,
  );
  return LoomStoredCryptoOutboxRecord(
    record: record,
    state: LoomCryptoOutboxState.pending,
    attemptCount: 0,
    nextAttemptAt: now,
    acknowledgedAt: null,
  );
}

LoomV2PacketAssemblyPlan _plan({required LoomRoutingScopeV2 scope}) =>
    LoomV2PacketAssemblyPlan(
      routingHint: LoomRoutingHintV2(
        scope: scope,
        mailboxToken: Uint8List.fromList(List<int>.filled(32, 11)),
      ),
      expiresAtBucket: DateTime.utc(2026, 9, 6, 12),
      priority: LoomPriorityClassV2.normal,
      initialHopLimit: 4,
      copiesRemaining: 4,
    );

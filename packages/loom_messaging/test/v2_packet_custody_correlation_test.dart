import 'dart:typed_data';

import 'package:loom_dtn/loom_dtn.dart';
import 'package:loom_messaging/loom_messaging.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:loom_sessions/loom_sessions.dart';
import 'package:loom_storage/loom_storage.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 9, 5, 12, 30);

  test(
    'durable custody registers local MessageId/PacketId/device correlation',
    () {
      final packetStore = LoomSqlitePacketStore.openInMemory();
      final stateStore = LoomV2MessageStateStore.openInMemory();
      addTearDown(packetStore.close);
      addTearDown(stateStore.close);
      final service = LoomV2PacketCustodyService(packetStore: packetStore);
      final stored = _stored(now);
      const recipientDeviceId = 'recipient-device-correlation-01';

      final durable = service.persistPendingForRecipient(
        stored: stored,
        plan: _plan(),
        messageStateStore: stateStore,
        recipientDeviceId: recipientDeviceId,
        now: now,
      );

      final correlation = stateStore.readOutboundPacket(
        messageId: stored.record.messageId,
        recipientDeviceId: recipientDeviceId,
      );
      expect(correlation, isNotNull);
      expect(correlation!.messageId, stored.record.messageId);
      expect(correlation.packetId, durable.packetId);
      expect(correlation.recipientDeviceId, recipientDeviceId);
      expect(correlation.createdAt, durable.storedAt);
      expect(correlation.expiresAt, durable.expiresAt);
    },
  );

  test(
    'replay after a crash between custody and correlation is idempotent',
    () {
      final packetStore = LoomSqlitePacketStore.openInMemory();
      final stateStore = LoomV2MessageStateStore.openInMemory();
      addTearDown(packetStore.close);
      addTearDown(stateStore.close);
      final service = LoomV2PacketCustodyService(packetStore: packetStore);
      final stored = _stored(now);
      final plan = _plan();
      const recipientDeviceId = 'recipient-device-correlation-02';

      // Simulate the first database commit succeeding while the process dies
      // before the message-state correlation write.
      final first = service.persistPending(
        stored: stored,
        plan: plan,
        now: now,
      );
      expect(
        stateStore.readOutboundPacket(
          messageId: stored.record.messageId,
          recipientDeviceId: recipientDeviceId,
        ),
        isNull,
      );

      final recovered = service.persistPendingForRecipient(
        stored: stored,
        plan: plan,
        messageStateStore: stateStore,
        recipientDeviceId: recipientDeviceId,
        now: now.add(const Duration(minutes: 3)),
      );

      expect(recovered.packetId, first.packetId);
      expect(recovered.storedAt, first.storedAt);
      expect(recovered.wireBytes, first.wireBytes);
      final correlation = stateStore.readOutboundPacket(
        messageId: stored.record.messageId,
        recipientDeviceId: recipientDeviceId,
      );
      expect(correlation, isNotNull);
      expect(correlation!.packetId, first.packetId);
      expect(correlation.recipientDeviceId, recipientDeviceId);

      // A second recovery pass converges on exactly the same mapping.
      final replay = service.persistPendingForRecipient(
        stored: stored,
        plan: plan,
        messageStateStore: stateStore,
        recipientDeviceId: recipientDeviceId,
        now: now.add(const Duration(minutes: 5)),
      );
      expect(replay.packetId, first.packetId);
      expect(
        stateStore
            .readOutboundPacket(
              messageId: stored.record.messageId,
              recipientDeviceId: recipientDeviceId,
            )!
            .packetId,
        first.packetId,
      );
    },
  );
}

LoomStoredCryptoOutboxRecord _stored(DateTime now) {
  final record = LoomCryptoOutboxRecord(
    operationId: 'operation-correlation-0001',
    sessionId: 'session-correlation-0001',
    sessionRevision: 8,
    messageId: 'message-correlation-0001',
    packetId: 'packet-correlation-000001',
    ciphertext: LoomSessionCiphertext(
      protocolVersion: 'Loom-Session-v2',
      sessionLocator: 'opaque-session-correlation-01',
      bytes: Uint8List.fromList(<int>[31, 32, 33, 34]),
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

LoomV2PacketAssemblyPlan _plan() => LoomV2PacketAssemblyPlan(
  routingHint: LoomRoutingHintV2(
    scope: LoomRoutingScopeV2.globalRelay,
    mailboxToken: Uint8List.fromList(List<int>.filled(32, 71)),
  ),
  expiresAtBucket: DateTime.utc(2026, 9, 6, 12),
  priority: LoomPriorityClassV2.normal,
  initialHopLimit: 4,
  copiesRemaining: 4,
);

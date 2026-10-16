import 'dart:typed_data';

import 'package:loom_messaging/loom_messaging.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:loom_sessions/loom_sessions.dart';
import 'package:loom_storage/loom_storage.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 9, 5, 12, 30);

  test(
    'assembler wraps only committed ciphertext into routable outer packet',
    () {
      final stored = _stored(state: LoomCryptoOutboxState.pending, now: now);
      final plan = LoomV2PacketAssemblyPlan(
        routingHint: LoomRoutingHintV2(
          scope: LoomRoutingScopeV2.globalRelay,
          mailboxToken: Uint8List.fromList(List<int>.filled(32, 7)),
        ),
        expiresAtBucket: DateTime.utc(2026, 9, 6, 12),
        priority: LoomPriorityClassV2.normal,
        initialHopLimit: 4,
        copiesRemaining: 4,
      );

      final draft = const LoomV2CommittedPacketAssembler().assemblePending(
        stored: stored,
        plan: plan,
        now: now,
      );

      expect(draft.packetId, stored.record.packetId);
      expect(draft.messageId, stored.record.messageId);
      expect(draft.operationId, stored.record.operationId);

      final outer = LoomEnvelopeV2Codec.decodeOuter(draft.wireBytes);
      expect(outer.packetId, stored.record.packetId);
      expect(outer.routingHint.scope, LoomRoutingScopeV2.globalRelay);
      expect(outer.forwardingState.hopsUsed, 0);
      expect(outer.forwardingState.copiesRemaining, 4);

      final session = LoomEnvelopeV2Codec.decodeSessionCiphertext(
        outer.encryptedPayload,
      );
      expect(session.protocolVersion, 'Loom-Session-v2');
      expect(session.sessionLocator, 'opaque-session-locator');
      expect(session.ciphertext, <int>[11, 12, 13]);
    },
  );

  test('acknowledged crypto outbox rows are never assembled for sending', () {
    final stored = _stored(state: LoomCryptoOutboxState.acknowledged, now: now);
    final plan = _plan(now);

    expect(
      () => const LoomV2CommittedPacketAssembler().assemblePending(
        stored: stored,
        plan: plan,
        now: now,
      ),
      throwsStateError,
    );
  });

  test(
    'packet assembly enforces seven-day lifetime and coarse expiry bucket',
    () {
      final stored = _stored(state: LoomCryptoOutboxState.pending, now: now);

      expect(
        () => const LoomV2CommittedPacketAssembler().assemblePending(
          stored: stored,
          plan: LoomV2PacketAssemblyPlan(
            routingHint: _plan(now).routingHint,
            expiresAtBucket: now.add(const Duration(days: 8)),
            priority: LoomPriorityClassV2.normal,
            initialHopLimit: 4,
            copiesRemaining: 4,
          ),
          now: now,
        ),
        throwsFormatException,
      );

      expect(
        () => const LoomV2CommittedPacketAssembler().assemblePending(
          stored: stored,
          plan: LoomV2PacketAssemblyPlan(
            routingHint: _plan(now).routingHint,
            expiresAtBucket: DateTime.utc(2026, 9, 6, 12, 15),
            priority: LoomPriorityClassV2.normal,
            initialHopLimit: 4,
            copiesRemaining: 4,
          ),
          now: now,
        ),
        throwsFormatException,
      );
    },
  );
}

LoomStoredCryptoOutboxRecord _stored({
  required LoomCryptoOutboxState state,
  required DateTime now,
}) {
  final record = LoomCryptoOutboxRecord(
    operationId: 'operation-00000001',
    sessionId: 'session-00000001',
    sessionRevision: 3,
    messageId: 'message-00000001',
    packetId: 'packet-000000000001',
    ciphertext: LoomSessionCiphertext(
      protocolVersion: 'Loom-Session-v2',
      sessionLocator: 'opaque-session-locator',
      bytes: Uint8List.fromList(<int>[11, 12, 13]),
    ),
    createdAt: now,
  );
  return LoomStoredCryptoOutboxRecord(
    record: record,
    state: state,
    attemptCount: 0,
    nextAttemptAt: now,
    acknowledgedAt: state == LoomCryptoOutboxState.acknowledged
        ? now.add(const Duration(minutes: 1))
        : null,
  );
}

LoomV2PacketAssemblyPlan _plan(DateTime now) => LoomV2PacketAssemblyPlan(
  routingHint: LoomRoutingHintV2(
    scope: LoomRoutingScopeV2.domesticRelay,
    mailboxToken: Uint8List.fromList(List<int>.filled(32, 9)),
  ),
  expiresAtBucket: DateTime.utc(2026, 9, 6, 12),
  priority: LoomPriorityClassV2.normal,
  initialHopLimit: 4,
  copiesRemaining: 4,
);

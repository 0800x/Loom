import 'dart:typed_data';

import 'package:loom_dtn/loom_dtn.dart';
import 'package:loom_messaging/loom_messaging.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:loom_storage/loom_storage.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 9, 5, 12);

  test(
    'verified E2EE receipt is the event that confirms recipient delivery',
    () {
      final packetStore = LoomSqlitePacketStore.openInMemory();
      final stateStore = LoomV2MessageStateStore.openInMemory();
      addTearDown(packetStore.close);
      addTearDown(stateStore.close);

      _putPacket(
        packetStore,
        packetId: 'packet-receipt-000001',
        messageId: 'message-receipt-000001',
        now: now,
      );
      final processor = LoomV2DeliveryReceiptProcessor(
        messageStateStore: stateStore,
        packetStore: packetStore,
        trustGate: const _TrustGate(<String>{'recipient-device-0001'}),
      );
      processor.trackCustodiedOutbound(
        packet: packetStore.read('packet-receipt-000001')!,
        messageId: 'message-receipt-000001',
        recipientDeviceId: 'recipient-device-0001',
      );

      final result = processor.processVerified(
        receipt: LoomDeliveryReceiptV2(
          forMessageId: 'message-receipt-000001',
          recipientDeviceId: 'recipient-device-0001',
          receivedAt: now.add(const Duration(days: 20)),
        ),
        sessionContextId: 'session-context-0001',
        observedAt: now.add(const Duration(seconds: 3)),
      );

      expect(result.status, LoomDeliveryReceiptApplyStatus.confirmed);
      expect(result.recipientDeliveryConfirmed, isTrue);
      expect(result.packetId, 'packet-receipt-000001');
      expect(result.packet!.state, LoomDtnPacketState.recipientConfirmed);
      expect(
        result.packet!.recipientConfirmedAt,
        now.add(const Duration(seconds: 3)),
        reason: 'local observation time is authoritative for local DTN state',
      );
      expect(stateStore.listPendingDeliveryReceipts(), isEmpty);
    },
  );

  test('unverified session context cannot create delivery state', () {
    final packetStore = LoomSqlitePacketStore.openInMemory();
    final stateStore = LoomV2MessageStateStore.openInMemory();
    addTearDown(packetStore.close);
    addTearDown(stateStore.close);
    _putPacket(
      packetStore,
      packetId: 'packet-receipt-000002',
      messageId: 'message-receipt-000002',
      now: now,
    );
    stateStore.registerOutboundPacket(
      messageId: 'message-receipt-000002',
      packetId: 'packet-receipt-000002',
      recipientDeviceId: 'recipient-device-0002',
      createdAt: now,
      expiresAt: now.add(const Duration(days: 1)),
    );
    final processor = LoomV2DeliveryReceiptProcessor(
      messageStateStore: stateStore,
      packetStore: packetStore,
      trustGate: const _TrustGate(<String>{}),
    );

    expect(
      () => processor.processVerified(
        receipt: const LoomDeliveryReceiptV2(
          forMessageId: 'message-receipt-000002',
          recipientDeviceId: 'recipient-device-0002',
        ),
        sessionContextId: 'session-context-0002',
        observedAt: now,
      ),
      throwsStateError,
    );
    expect(
      packetStore.read('packet-receipt-000002')!.recipientConfirmedAt,
      isNull,
    );
    expect(stateStore.listPendingDeliveryReceipts(), isEmpty);
  });

  test(
    'same logical message is confirmed independently per recipient device',
    () {
      final packetStore = LoomSqlitePacketStore.openInMemory();
      final stateStore = LoomV2MessageStateStore.openInMemory();
      addTearDown(packetStore.close);
      addTearDown(stateStore.close);

      _putPacket(
        packetStore,
        packetId: 'packet-receipt-phone01',
        messageId: 'message-receipt-multi1',
        now: now,
      );
      _putPacket(
        packetStore,
        packetId: 'packet-receipt-laptop1',
        messageId: 'message-receipt-multi1',
        now: now,
      );
      stateStore.registerOutboundPacket(
        messageId: 'message-receipt-multi1',
        packetId: 'packet-receipt-phone01',
        recipientDeviceId: 'recipient-device-phone1',
        createdAt: now,
        expiresAt: now.add(const Duration(days: 1)),
      );
      stateStore.registerOutboundPacket(
        messageId: 'message-receipt-multi1',
        packetId: 'packet-receipt-laptop1',
        recipientDeviceId: 'recipient-device-laptop',
        createdAt: now,
        expiresAt: now.add(const Duration(days: 1)),
      );
      final processor = LoomV2DeliveryReceiptProcessor(
        messageStateStore: stateStore,
        packetStore: packetStore,
        trustGate: const _TrustGate(<String>{
          'recipient-device-phone1',
          'recipient-device-laptop',
        }),
      );

      final phone = processor.processVerified(
        receipt: const LoomDeliveryReceiptV2(
          forMessageId: 'message-receipt-multi1',
          recipientDeviceId: 'recipient-device-phone1',
        ),
        sessionContextId: 'session-context-phone1',
        observedAt: now.add(const Duration(seconds: 1)),
      );
      expect(phone.packetId, 'packet-receipt-phone01');
      expect(
        packetStore.read('packet-receipt-phone01')!.state,
        LoomDtnPacketState.recipientConfirmed,
      );
      expect(
        packetStore.read('packet-receipt-laptop1')!.state,
        LoomDtnPacketState.queued,
      );

      final laptop = processor.processVerified(
        receipt: const LoomDeliveryReceiptV2(
          forMessageId: 'message-receipt-multi1',
          recipientDeviceId: 'recipient-device-laptop',
        ),
        sessionContextId: 'session-context-laptop',
        observedAt: now.add(const Duration(seconds: 2)),
      );
      expect(laptop.packetId, 'packet-receipt-laptop1');
      expect(
        packetStore.read('packet-receipt-laptop1')!.state,
        LoomDtnPacketState.recipientConfirmed,
      );
    },
  );

  test('verified receipt with no logical/device correlation cannot invent Delivered', () {
    final packetStore = LoomSqlitePacketStore.openInMemory();
    final stateStore = LoomV2MessageStateStore.openInMemory();
    addTearDown(packetStore.close);
    addTearDown(stateStore.close);
    final processor = LoomV2DeliveryReceiptProcessor(
      messageStateStore: stateStore,
      packetStore: packetStore,
      trustGate: const _TrustGate(<String>{'recipient-device-unknown'}),
    );

    final result = processor.processVerified(
      receipt: const LoomDeliveryReceiptV2(
        forMessageId: 'message-receipt-unknown',
        recipientDeviceId: 'recipient-device-unknown',
      ),
      sessionContextId: 'session-context-unknown',
      observedAt: now,
    );
    expect(
      result.status,
      LoomDeliveryReceiptApplyStatus.unknownLogicalDeviceSend,
    );
    expect(result.recipientDeliveryConfirmed, isFalse);
    expect(result.packetId, isNull);
    expect(stateStore.listPendingDeliveryReceipts(), isEmpty);
  });

  test(
    'staged receipt survives missing packet and recovery later confirms it',
    () {
      final packetStore = LoomSqlitePacketStore.openInMemory();
      final stateStore = LoomV2MessageStateStore.openInMemory();
      addTearDown(packetStore.close);
      addTearDown(stateStore.close);
      stateStore.registerOutboundPacket(
        messageId: 'message-receipt-000004',
        packetId: 'packet-receipt-000004',
        recipientDeviceId: 'recipient-device-0004',
        createdAt: now,
        expiresAt: now.add(const Duration(days: 1)),
      );
      final processor = LoomV2DeliveryReceiptProcessor(
        messageStateStore: stateStore,
        packetStore: packetStore,
        trustGate: const _TrustGate(<String>{'recipient-device-0004'}),
      );

      final first = processor.processVerified(
        receipt: const LoomDeliveryReceiptV2(
          forMessageId: 'message-receipt-000004',
          recipientDeviceId: 'recipient-device-0004',
        ),
        sessionContextId: 'session-context-0004',
        observedAt: now,
      );
      expect(
        first.status,
        LoomDeliveryReceiptApplyStatus.pendingPacketRecovery,
      );
      expect(stateStore.listPendingDeliveryReceipts(), hasLength(1));

      _putPacket(
        packetStore,
        packetId: 'packet-receipt-000004',
        messageId: 'message-receipt-000004',
        now: now,
      );
      final recovered = processor.recoverPending(
        observedAt: now.add(const Duration(minutes: 1)),
      );
      expect(recovered, hasLength(1));
      expect(recovered.single.status, LoomDeliveryReceiptApplyStatus.confirmed);
      expect(
        packetStore.read('packet-receipt-000004')!.state,
        LoomDtnPacketState.recipientConfirmed,
      );
      expect(stateStore.listPendingDeliveryReceipts(), isEmpty);
    },
  );

  test('late authenticated receipt after packet expiry is evidence but does not resurrect routing', () {
    final packetStore = LoomSqlitePacketStore.openInMemory();
    final stateStore = LoomV2MessageStateStore.openInMemory();
    addTearDown(packetStore.close);
    addTearDown(stateStore.close);
    _putPacket(
      packetStore,
      packetId: 'packet-receipt-expire1',
      messageId: 'message-receipt-expire1',
      now: now,
    );
    stateStore.registerOutboundPacket(
      messageId: 'message-receipt-expire1',
      packetId: 'packet-receipt-expire1',
      recipientDeviceId: 'recipient-device-expire',
      createdAt: now,
      expiresAt: now.add(const Duration(days: 1)),
    );
    packetStore.expireDue(now.add(const Duration(days: 2)));
    final processor = LoomV2DeliveryReceiptProcessor(
      messageStateStore: stateStore,
      packetStore: packetStore,
      trustGate: const _TrustGate(<String>{'recipient-device-expire'}),
    );

    final result = processor.processVerified(
      receipt: const LoomDeliveryReceiptV2(
        forMessageId: 'message-receipt-expire1',
        recipientDeviceId: 'recipient-device-expire',
      ),
      sessionContextId: 'session-context-expire',
      observedAt: now.add(const Duration(days: 2, minutes: 1)),
    );
    expect(
      result.status,
      LoomDeliveryReceiptApplyStatus.lateEvidenceAfterTerminalPacket,
    );
    expect(result.recipientDeliveryConfirmed, isFalse);
    expect(result.packet!.state, LoomDtnPacketState.expired);
    expect(stateStore.listPendingDeliveryReceipts(), isEmpty);
  });
}

void _putPacket(
  LoomSqlitePacketStore store, {
  required String packetId,
  required String messageId,
  required DateTime now,
}) {
  final outer = LoomOuterEnvelopeV2(
    packetId: packetId,
    routingHint: LoomRoutingHintV2(
      scope: LoomRoutingScopeV2.globalRelay,
      mailboxToken: Uint8List.fromList(List<int>.filled(32, 63)),
    ),
    expiresAtBucket: now.add(const Duration(days: 1)),
    priority: LoomPriorityClassV2.normal,
    initialHopLimit: 4,
    forwardingState: const LoomForwardingStateV2(
      hopsUsed: 0,
      copiesRemaining: 4,
    ),
    encryptedPayload: Uint8List.fromList(<int>[1, 3, 5, 7]),
  );
  store.putLocalOutbound(
    operationId: 'operation-$packetId',
    messageId: messageId,
    packetId: packetId,
    exactOuterEnvelopeBytes: LoomEnvelopeV2Codec.encodeOuter(outer),
    now: now,
  );
}

final class _TrustGate implements LoomDeliveryReceiptTrustGate {
  const _TrustGate(this.verifiedDeviceIds);

  final Set<String> verifiedDeviceIds;

  @override
  bool isVerifiedRemoteDevice({
    required String sessionContextId,
    required String remoteDeviceId,
  }) =>
      sessionContextId.startsWith('session-context-') &&
      verifiedDeviceIds.contains(remoteDeviceId);
}

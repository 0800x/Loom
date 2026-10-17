import 'dart:typed_data';

import 'package:loom_messaging/loom_messaging.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:loom_storage/loom_storage.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 9, 5, 12);
  const localAccount = 'account-local-0001';
  const localDevice = 'device-local-000001';
  const remoteAccount = 'account-remote-0001';
  const remoteDevice = 'device-remote-000001';

  test('first authenticated logical message displays, duplicate does not', () {
    final store = LoomV2MessageStateStore.openInMemory();
    addTearDown(store.close);
    final dedup = LoomV2InboundMessageDeduplicator(
      messageStateStore: store,
      trustGate: const _TrustGate(
        accountId: remoteAccount,
        deviceId: remoteDevice,
      ),
      localAccountId: localAccount,
      localDeviceId: localDevice,
    );
    final envelope = _inner(
      messageId: 'message-logical-0001',
      senderAccountId: remoteAccount,
      senderDeviceId: remoteDevice,
      recipientAccountId: localAccount,
      recipientDeviceId: localDevice,
    );

    final first = dedup.recordDecrypted(
      envelope: envelope,
      sessionContextId: 'session-context-logical1',
      observedAt: now,
    );
    final duplicate = dedup.recordDecrypted(
      envelope: envelope,
      sessionContextId: 'session-context-logical1',
      observedAt: now.add(const Duration(seconds: 2)),
    );

    expect(
      first.disposition,
      LoomInboundLogicalMessageDisposition.firstDelivery,
    );
    expect(first.shouldDisplay, isTrue);
    expect(
      duplicate.disposition,
      LoomInboundLogicalMessageDisposition.duplicate,
    );
    expect(duplicate.shouldDisplay, isFalse);
  });

  test('same MessageId from different PacketIds still displays once', () {
    // PacketId is intentionally absent from InnerEnvelope; logical dedup is
    // therefore independent from which DTN replica/path produced the decrypt.
    final store = LoomV2MessageStateStore.openInMemory();
    addTearDown(store.close);
    final dedup = LoomV2InboundMessageDeduplicator(
      messageStateStore: store,
      trustGate: const _TrustGate(
        accountId: remoteAccount,
        deviceId: remoteDevice,
      ),
      localAccountId: localAccount,
      localDeviceId: localDevice,
    );
    final envelope = _inner(
      messageId: 'message-logical-0002',
      senderAccountId: remoteAccount,
      senderDeviceId: remoteDevice,
      recipientAccountId: localAccount,
      recipientDeviceId: localDevice,
    );

    expect(
      dedup
          .recordDecrypted(
            envelope: envelope,
            sessionContextId: 'session-context-path-a',
            observedAt: now,
          )
          .shouldDisplay,
      isTrue,
    );
    expect(
      dedup
          .recordDecrypted(
            envelope: envelope,
            sessionContextId: 'session-context-path-b',
            observedAt: now.add(const Duration(seconds: 1)),
          )
          .shouldDisplay,
      isFalse,
    );
  });

  test('inner sender not bound to authenticated session is rejected before seen state', () {
    final store = LoomV2MessageStateStore.openInMemory();
    addTearDown(store.close);
    final dedup = LoomV2InboundMessageDeduplicator(
      messageStateStore: store,
      trustGate: const _TrustGate(
        accountId: remoteAccount,
        deviceId: remoteDevice,
      ),
      localAccountId: localAccount,
      localDeviceId: localDevice,
    );
    final envelope = _inner(
      messageId: 'message-logical-0003',
      senderAccountId: 'account-attacker-001',
      senderDeviceId: 'device-attacker-0001',
      recipientAccountId: localAccount,
      recipientDeviceId: localDevice,
    );

    expect(
      () => dedup.recordDecrypted(
        envelope: envelope,
        sessionContextId: 'session-context-logical3',
        observedAt: now,
      ),
      throwsStateError,
    );
    expect(store.readSeenMessage('message-logical-0003'), isNull);
  });

  test('inner envelope addressed to another local device is rejected', () {
    final store = LoomV2MessageStateStore.openInMemory();
    addTearDown(store.close);
    final dedup = LoomV2InboundMessageDeduplicator(
      messageStateStore: store,
      trustGate: const _TrustGate(
        accountId: remoteAccount,
        deviceId: remoteDevice,
      ),
      localAccountId: localAccount,
      localDeviceId: localDevice,
    );
    final envelope = _inner(
      messageId: 'message-logical-0004',
      senderAccountId: remoteAccount,
      senderDeviceId: remoteDevice,
      recipientAccountId: localAccount,
      recipientDeviceId: 'device-local-other01',
    );

    expect(
      () => dedup.recordDecrypted(
        envelope: envelope,
        sessionContextId: 'session-context-logical4',
        observedAt: now,
      ),
      throwsA(isA<LoomSeenMessageConflict>()),
    );
    expect(store.readSeenMessage('message-logical-0004'), isNull);
  });

  test(
    'MessageId collision under a different authenticated sender fails closed',
    () {
      final store = LoomV2MessageStateStore.openInMemory();
      addTearDown(store.close);
      store.markMessageSeen(
        messageId: 'message-logical-0005',
        senderAccountId: 'account-old-sender01',
        senderDeviceId: 'device-old-sender001',
        now: now,
      );
      final dedup = LoomV2InboundMessageDeduplicator(
        messageStateStore: store,
        trustGate: const _TrustGate(
          accountId: remoteAccount,
          deviceId: remoteDevice,
        ),
        localAccountId: localAccount,
        localDeviceId: localDevice,
      );

      expect(
        () => dedup.recordDecrypted(
          envelope: _inner(
            messageId: 'message-logical-0005',
            senderAccountId: remoteAccount,
            senderDeviceId: remoteDevice,
            recipientAccountId: localAccount,
            recipientDeviceId: localDevice,
          ),
          sessionContextId: 'session-context-logical5',
          observedAt: now.add(const Duration(seconds: 1)),
        ),
        throwsA(isA<LoomSeenMessageConflict>()),
      );
    },
  );
}

LoomInnerEnvelopeV2 _inner({
  required String messageId,
  required String senderAccountId,
  required String senderDeviceId,
  required String recipientAccountId,
  required String recipientDeviceId,
}) => LoomInnerEnvelopeV2(
  messageId: messageId,
  conversationRef: 'conversation-logical-01',
  senderAccountId: senderAccountId,
  senderDeviceId: senderDeviceId,
  recipientAccountId: recipientAccountId,
  recipientDeviceId: recipientDeviceId,
  contentKind: LoomInnerContentKindV2.text,
  contentPayload: Uint8List.fromList(<int>[1, 2, 3]),
  createdAt: DateTime.utc(2026, 9, 5, 12),
);

final class _TrustGate implements LoomInboundMessageTrustGate {
  const _TrustGate({required this.accountId, required this.deviceId});

  final String accountId;
  final String deviceId;

  @override
  bool isVerifiedRemoteSender({
    required String sessionContextId,
    required String senderAccountId,
    required String senderDeviceId,
  }) =>
      sessionContextId.startsWith('session-context-') &&
      senderAccountId == accountId &&
      senderDeviceId == deviceId;
}

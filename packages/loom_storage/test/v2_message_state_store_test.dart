import 'dart:io';

import 'package:loom_storage/loom_storage.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 9, 5, 12);

  test('logical MessageId dedup is sender-bound and survives restart', () {
    final directory = Directory.systemTemp.createTempSync('loom-msg-state-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final path =
        '${directory.path}${Platform.pathSeparator}messages-v2.sqlite3';

    final first = LoomV2MessageStateStore.openFile(path);
    expect(
      first.markMessageSeen(
        messageId: 'message-seen-000001',
        senderAccountId: 'account-sender-0001',
        senderDeviceId: 'device-sender-0001',
        now: now,
      ),
      isTrue,
    );
    expect(
      first.markMessageSeen(
        messageId: 'message-seen-000001',
        senderAccountId: 'account-sender-0001',
        senderDeviceId: 'device-sender-0001',
        now: now.add(const Duration(minutes: 1)),
      ),
      isFalse,
    );
    first.close();

    final reopened = LoomV2MessageStateStore.openFile(path);
    addTearDown(reopened.close);
    final stored = reopened.readSeenMessage('message-seen-000001');
    expect(stored, isNotNull);
    expect(stored!.senderAccountId, 'account-sender-0001');
    expect(stored.senderDeviceId, 'device-sender-0001');
    expect(stored.firstSeenAt, now);
  });

  test('same MessageId from a different authenticated sender fails closed', () {
    final store = LoomV2MessageStateStore.openInMemory();
    addTearDown(store.close);
    store.markMessageSeen(
      messageId: 'message-seen-000002',
      senderAccountId: 'account-sender-0002',
      senderDeviceId: 'device-sender-0002',
      now: now,
    );

    expect(
      () => store.markMessageSeen(
        messageId: 'message-seen-000002',
        senderAccountId: 'account-other-0002',
        senderDeviceId: 'device-other-0002',
        now: now.add(const Duration(seconds: 1)),
      ),
      throwsA(isA<LoomSeenMessageConflict>()),
    );
  });

  test('same logical MessageId may map independently to multiple recipient devices', () {
    final store = LoomV2MessageStateStore.openInMemory();
    addTearDown(store.close);
    final expiry = now.add(const Duration(days: 2));

    final phone = store.registerOutboundPacket(
      messageId: 'message-multidevice-0001',
      packetId: 'packet-multidevice-phone1',
      recipientDeviceId: 'device-recipient-phone1',
      createdAt: now,
      expiresAt: expiry,
    );
    final laptop = store.registerOutboundPacket(
      messageId: 'message-multidevice-0001',
      packetId: 'packet-multidevice-laptop',
      recipientDeviceId: 'device-recipient-laptop',
      createdAt: now,
      expiresAt: expiry,
    );

    expect(phone.packetId, isNot(laptop.packetId));
    expect(
      store
          .readOutboundPacket(
            messageId: 'message-multidevice-0001',
            recipientDeviceId: 'device-recipient-phone1',
          )!
          .packetId,
      'packet-multidevice-phone1',
    );
    expect(
      store
          .readOutboundPacket(
            messageId: 'message-multidevice-0001',
            recipientDeviceId: 'device-recipient-laptop',
          )!
          .packetId,
      'packet-multidevice-laptop',
    );
  });

  test(
    'outbound logical/device mapping is immutable and PacketId is unique',
    () {
      final store = LoomV2MessageStateStore.openInMemory();
      addTearDown(store.close);
      final expiry = now.add(const Duration(days: 2));

      final first = store.registerOutboundPacket(
        messageId: 'message-outbound-0001',
        packetId: 'packet-outbound-00001',
        recipientDeviceId: 'device-recipient-0001',
        createdAt: now,
        expiresAt: expiry,
      );
      final retry = store.registerOutboundPacket(
        messageId: 'message-outbound-0001',
        packetId: 'packet-outbound-00001',
        recipientDeviceId: 'device-recipient-0001',
        createdAt: now,
        expiresAt: expiry,
      );
      expect(retry.packetId, first.packetId);

      expect(
        () => store.registerOutboundPacket(
          messageId: 'message-outbound-0001',
          packetId: 'packet-outbound-other1',
          recipientDeviceId: 'device-recipient-0001',
          createdAt: now,
          expiresAt: expiry,
        ),
        throwsA(isA<LoomSeenMessageConflict>()),
      );
      expect(
        () => store.registerOutboundPacket(
          messageId: 'message-outbound-other1',
          packetId: 'packet-outbound-00001',
          recipientDeviceId: 'device-recipient-other',
          createdAt: now,
          expiresAt: expiry,
        ),
        throwsA(isA<LoomSeenMessageConflict>()),
      );
    },
  );

  test(
    'delivery receipt staging is durable and replayable across crash boundary',
    () {
      final directory = Directory.systemTemp.createTempSync(
        'loom-receipt-state-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final path =
          '${directory.path}${Platform.pathSeparator}messages-v2.sqlite3';

      final first = LoomV2MessageStateStore.openFile(path);
      first.registerOutboundPacket(
        messageId: 'message-receipt-0001',
        packetId: 'packet-receipt-00001',
        recipientDeviceId: 'device-recipient-0002',
        createdAt: now,
        expiresAt: now.add(const Duration(days: 2)),
      );
      final staged = first.stageDeliveryReceipt(
        messageId: 'message-receipt-0001',
        packetId: 'packet-receipt-00001',
        recipientDeviceId: 'device-recipient-0002',
        observedAt: now.add(const Duration(minutes: 5)),
      );
      expect(staged.state, LoomPendingDeliveryReceiptState.pending);
      first.close();

      final reopened = LoomV2MessageStateStore.openFile(path);
      addTearDown(reopened.close);
      final pending = reopened.listPendingDeliveryReceipts();
      expect(pending, hasLength(1));
      expect(pending.single.messageId, 'message-receipt-0001');
      expect(pending.single.packetId, 'packet-receipt-00001');

      final applied = reopened.markDeliveryReceiptApplied(
        messageId: 'message-receipt-0001',
        recipientDeviceId: 'device-recipient-0002',
        appliedAt: now.add(const Duration(minutes: 6)),
      );
      expect(applied.state, LoomPendingDeliveryReceiptState.applied);
      expect(reopened.listPendingDeliveryReceipts(), isEmpty);
    },
  );

  test('same logical message can stage independent receipts per device', () {
    final store = LoomV2MessageStateStore.openInMemory();
    addTearDown(store.close);
    store.stageDeliveryReceipt(
      messageId: 'message-receipt-multi1',
      packetId: 'packet-receipt-phone1',
      recipientDeviceId: 'device-receipt-phone1',
      observedAt: now,
    );
    store.stageDeliveryReceipt(
      messageId: 'message-receipt-multi1',
      packetId: 'packet-receipt-laptop',
      recipientDeviceId: 'device-receipt-laptop',
      observedAt: now.add(const Duration(seconds: 1)),
    );

    expect(store.listPendingDeliveryReceipts(), hasLength(2));
    store.markDeliveryReceiptApplied(
      messageId: 'message-receipt-multi1',
      recipientDeviceId: 'device-receipt-phone1',
      appliedAt: now.add(const Duration(seconds: 2)),
    );
    final pending = store.listPendingDeliveryReceipts();
    expect(pending, hasLength(1));
    expect(pending.single.recipientDeviceId, 'device-receipt-laptop');
  });

  test(
    'conflicting receipt packet cannot replace staged logical/device receipt',
    () {
      final store = LoomV2MessageStateStore.openInMemory();
      addTearDown(store.close);
      store.stageDeliveryReceipt(
        messageId: 'message-receipt-0002',
        packetId: 'packet-receipt-00002',
        recipientDeviceId: 'device-recipient-0003',
        observedAt: now,
      );

      expect(
        () => store.stageDeliveryReceipt(
          messageId: 'message-receipt-0002',
          packetId: 'packet-receipt-other2',
          recipientDeviceId: 'device-recipient-0003',
          observedAt: now.add(const Duration(seconds: 1)),
        ),
        throwsA(isA<LoomSeenMessageConflict>()),
      );
    },
  );

  test('prune removes expired seen/correlation state but preserves pending receipt mapping', () {
    final store = LoomV2MessageStateStore.openInMemory();
    addTearDown(store.close);
    store.markMessageSeen(
      messageId: 'message-prune-seen1',
      senderAccountId: 'account-prune-0001',
      senderDeviceId: 'device-prune-00001',
      now: now,
      retention: const Duration(days: 1),
    );
    store.registerOutboundPacket(
      messageId: 'message-prune-out1',
      packetId: 'packet-prune-out001',
      recipientDeviceId: 'device-prune-rec01',
      createdAt: now,
      expiresAt: now.add(const Duration(days: 1)),
    );
    store.registerOutboundPacket(
      messageId: 'message-prune-pend',
      packetId: 'packet-prune-pend01',
      recipientDeviceId: 'device-prune-rec02',
      createdAt: now,
      expiresAt: now.add(const Duration(days: 1)),
    );
    store.stageDeliveryReceipt(
      messageId: 'message-prune-pend',
      packetId: 'packet-prune-pend01',
      recipientDeviceId: 'device-prune-rec02',
      observedAt: now.add(const Duration(hours: 1)),
    );

    final deleted = store.prune(now.add(const Duration(days: 2)));
    expect(deleted, 2);
    expect(store.readSeenMessage('message-prune-seen1'), isNull);
    expect(
      store.readOutboundPacket(
        messageId: 'message-prune-out1',
        recipientDeviceId: 'device-prune-rec01',
      ),
      isNull,
    );
    expect(
      store.readOutboundPacket(
        messageId: 'message-prune-pend',
        recipientDeviceId: 'device-prune-rec02',
      ),
      isNotNull,
    );
    expect(store.listPendingDeliveryReceipts(), hasLength(1));
  });
}

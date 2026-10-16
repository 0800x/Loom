import 'package:loom_models/loom_models.dart';
import 'package:loom_next/features/notifications/application/message_notifications.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final start = DateTime.utc(2026, 10, 8, 12);
  LoomMessageRecord message(
    String id, {
    String sender = '@bob:home',
    DateTime? at,
    LoomDeliveryState state = LoomDeliveryState.delivered,
  }) => LoomMessageRecord(
    id: id,
    clientId: id,
    conversationId: 'chat',
    senderAddress: sender,
    type: LoomMessageType.text,
    ciphertext: 'opaque',
    protocolVersion: 'test',
    createdOrder: 1,
    createdAt: at ?? start.add(const Duration(seconds: 1)),
    deliveryState: state,
  );
  bool notify(
    LoomMessageNotificationPolicy p,
    LoomMessageRecord m, {
    bool muted = false,
    bool visible = false,
  }) => p.shouldNotify(
    m,
    ownAddress: '@alice:home',
    muted: muted,
    visible: visible,
  );
  test(
    'new incoming messages ring once; loading history and refreshing never rings',
    () {
      final policy = LoomMessageNotificationPolicy(startedAt: start);
      expect(notify(policy, message('new')), isTrue);
      expect(notify(policy, message('new')), isFalse);
      expect(
        notify(
          policy,
          message('old', at: start.subtract(const Duration(days: 1))),
        ),
        isFalse,
      );
      expect(
        notify(policy, message('read', state: LoomDeliveryState.read)),
        isFalse,
      );
      expect(notify(policy, message('own', sender: '@ALICE:home')), isFalse);
    },
  );
  test(
    'muted and currently visible messages stay silent after switching chats',
    () {
      final policy = LoomMessageNotificationPolicy(startedAt: start);
      expect(notify(policy, message('muted'), muted: true), isFalse);
      expect(notify(policy, message('visible'), visible: true), isFalse);
      expect(notify(policy, message('muted')), isFalse);
      expect(notify(policy, message('visible')), isFalse);
      expect(notify(policy, message('other')), isTrue);
    },
  );
  test(
    'native notification bridge uses a generic body and restores the pending conversation',
    () async {
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        LoomMessageNotificationBridge.channel,
        (call) async {
          calls.add(call);
          return call.method == 'prepare' ? 'invited-group' : null;
        },
      );
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          LoomMessageNotificationBridge.channel,
          null,
        ),
      );
      final opened = <String>[];
      final bridge = LoomMessageNotificationBridge();
      await bridge.initialize(opened.add);
      await bridge.show('invited-group', 'Friends');
      await bridge.clear('invited-group');
      expect(opened, ['invited-group']);
      expect(calls[1].arguments, {
        'conversationId': 'invited-group',
        'title': 'Friends',
        'body': 'New encrypted message',
      });
      expect(calls.last.method, 'clearMessage');
    },
  );
}

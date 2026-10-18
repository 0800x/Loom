import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loom_models/loom_models.dart' as models;
import 'package:loom_next/features/home/presentation/messenger_shell.dart';
import 'package:loom_next/features/messaging/application/message_content.dart';
import 'package:loom_next/features/messaging/application/messaging_session_controller.dart';
import 'package:loom_next/features/nodes/application/node_directory_controller.dart';
import 'package:loom_next/features/onboarding/application/onboarding_controller.dart';
import 'widget_smoke_test.dart' show host;

class _GroupMessaging extends LoomMessagingSessionController {
  _GroupMessaging({required super.onboarding}) {
    status = LoomMessagingSessionStatus.ready;
    conversations = const [
      models.LoomConversation(
        id: 'group',
        kind: models.LoomConversationKind.group,
        updatedOrder: 1,
        unreadCount: 0,
        isMuted: false,
        isPinned: false,
      ),
    ];
  }
  final sent = Completer<bool>();
  @override
  Future<void> open() async {}
  @override
  bool canSendToGroup(String id) => id == 'group';
  @override
  Future<bool> sendText(
    String conversationId,
    String plaintext, {
    String? replyToMessageId,
    LoomVisibleMessage? reply,
    LoomMessageContent? content,
  }) => sent.future;
}

void main() {
  for (final scenario in ['selection', 'new text', 'failed']) {
    testWidgets('group composer retains the correct draft after $scenario', (
      tester,
    ) async {
      final nodes = LoomNodeDirectoryController();
      final onboarding = LoomOnboardingController(nodes: nodes)
        ..receipt = const models.LoomRegistrationReceipt(
          accountId: 'test',
          deviceId: 'test',
          address: '@test:home.example',
          homeNode: 'home.example',
        );
      final messaging = _GroupMessaging(onboarding: onboarding);
      await tester.pumpWidget(
        host(
          Scaffold(
            body: LoomMessagingSessionScope(
              controller: messaging,
              child: const LoomConversationSurface(conversationId: 'group'),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 350));
      final field = find.byType(TextField).first;
      await tester.enterText(field, 'hello group');
      await tester.pump();
      await tester.tap(find.byTooltip('Send').last);
      await tester.pump();
      final controller = tester.widget<TextField>(field).controller!;
      if (scenario == 'selection') {
        controller.selection = const TextSelection.collapsed(offset: 2);
      } else if (scenario == 'new text') {
        controller.text = 'next message';
      }
      messaging.sent.complete(scenario != 'failed');
      await tester.pump(const Duration(milliseconds: 350));
      expect(
        controller.text,
        scenario == 'selection'
            ? ''
            : scenario == 'new text'
            ? 'next message'
            : 'hello group',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      messaging.dispose();
      onboarding.dispose();
      nodes.dispose();
    });
  }
}

import 'dart:async';

import 'package:loom_design/loom_design.dart';
import 'package:loom_models/loom_models.dart' as models;
import 'package:loom_next/features/home/presentation/messenger_shell.dart';
import 'package:loom_next/features/messaging/application/messaging_session_controller.dart';
import 'package:loom_next/features/messaging/application/message_content.dart';
import 'package:loom_next/features/nodes/application/node_directory_controller.dart';
import 'package:loom_next/features/onboarding/application/onboarding_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'widget_smoke_test.dart' show host, usePhoneViewport;

class _DelayedMessaging extends LoomMessagingSessionController {
  _DelayedMessaging({required super.onboarding}) {
    status = LoomMessagingSessionStatus.ready;
    conversations = const [
      models.LoomConversation(
        id: 'sara',
        kind: models.LoomConversationKind.direct,
        title: 'Sara',
        peerAddress: '@maya:example.org',
        updatedOrder: 2,
        unreadCount: 0,
        isMuted: false,
        isPinned: false,
      ),
      models.LoomConversation(
        id: 'nima',
        kind: models.LoomConversationKind.direct,
        title: 'Nima',
        peerAddress: '@nima:example.org',
        updatedOrder: 1,
        unreadCount: 0,
        isMuted: false,
        isPinned: false,
      ),
    ];
  }

  final queued = Completer<bool>();
  String? sentReplyId;
  final sentTexts = <String>[];

  String? deletedClientId;
  String? deletedConversationId;
  @override
  Future<void> deleteLocalMessage(
    String conversationId,
    String clientId,
  ) async {
    deletedClientId = clientId;
    visibleMessages[conversationId] = visibleMessagesFor(
      conversationId,
    ).where((m) => m.record.clientId != clientId).toList();
    notifyListeners();
  }

  @override
  Future<void> deleteLocalConversation(String conversationId) async {
    deletedConversationId = conversationId;
    conversations = conversations.where((c) => c.id != conversationId).toList();
    visibleMessages.remove(conversationId);
    notifyListeners();
  }

  @override
  Future<void> open() async {}

  @override
  Future<bool> sendText(
    String conversationId,
    String plaintext, {
    String? replyToMessageId,
    LoomVisibleMessage? reply,
    LoomMessageContent? content,
  }) {
    sentReplyId = replyToMessageId;
    sentTexts.add(plaintext);
    return queued.future;
  }
}

Widget _surface(Widget child, {Locale locale = const Locale('en')}) => host(
  LoomGlassScope(quality: LoomGlassQuality.disabled, child: child),
  locale: locale,
);

void main() {
  testWidgets(
    'device deletion requires confirmation and calls the selected message or chat',
    (tester) async {
      usePhoneViewport(tester);
      final nodes = LoomNodeDirectoryController();
      final onboarding = LoomOnboardingController(nodes: nodes);
      final messaging = _DelayedMessaging(onboarding: onboarding);
      addTearDown(nodes.dispose);
      addTearDown(onboarding.dispose);
      addTearDown(messaging.dispose);
      messaging.visibleMessages = {
        'sara': [
          LoomVisibleMessage(
            record: models.LoomMessageRecord(
              id: 'server-delete',
              clientId: 'delete-client',
              conversationId: 'sara',
              senderAddress: '@maya:example.org',
              type: models.LoomMessageType.text,
              ciphertext: 'opaque',
              protocolVersion: 'test',
              createdOrder: 1,
              createdAt: DateTime.utc(2026),
              deliveryState: models.LoomDeliveryState.sent,
            ),
            text: 'Delete this message',
            readable: true,
          ),
        ],
      };
      await tester.pumpWidget(
        _surface(
          LoomMessagingSessionScope(
            controller: messaging,
            child: const MessengerShell(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sara').first);
      await tester.pumpAndSettle();
      await tester.longPress(find.text('Delete this message'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete from this device'));
      await tester.pumpAndSettle();
      expect(find.text('Delete message?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(messaging.deletedClientId, isNull);
      await tester.longPress(find.text('Delete this message'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete from this device'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(messaging.deletedClientId, 'delete-client');
      expect(find.text('Delete this message'), findsNothing);
      await tester.tap(find.byTooltip('Conversation menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete chat from this device'));
      await tester.pumpAndSettle();
      expect(find.text('Delete chat?'), findsOneWidget);
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(messaging.deletedConversationId, 'sara');
      expect(find.byType(LoomGlassComposer), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('system back preserves the draft and message search filters', (
    tester,
  ) async {
    usePhoneViewport(tester);
    await tester.pumpWidget(_surface(const MessengerShell(preview: true)));
    await tester.tap(find.text('Maya Brooks').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'unsent draft');

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(LoomGlassComposer), findsNothing);
    await tester.tap(find.text('Maya Brooks').first);
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'unsent draft',
    );

    await tester.tap(find.byTooltip('Conversation menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Search messages'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('message-search-preview')),
      'house Node',
    );
    await tester.pump();
    expect(
      tester
          .widgetList<LoomMessageBubble>(find.byType(LoomMessageBubble))
          .map((bubble) => bubble.text),
      ['I can reach the house Node again.'],
    );
    await tester.enterText(
      find.byKey(const ValueKey('message-search-preview')),
      'unfindable-123',
    );
    await tester.pump();
    expect(find.text('No matching messages'), findsOneWidget);
  });

  testWidgets('late send completion preserves a different conversation draft', (
    tester,
  ) async {
    usePhoneViewport(tester);
    final nodes = LoomNodeDirectoryController();
    final onboarding = LoomOnboardingController(nodes: nodes);
    final messaging = _DelayedMessaging(onboarding: onboarding);
    addTearDown(nodes.dispose);
    addTearDown(onboarding.dispose);
    addTearDown(messaging.dispose);
    await tester.pumpWidget(
      _surface(
        LoomMessagingSessionScope(
          controller: messaging,
          child: const MessengerShell(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sara').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'send to Sara');
    await tester.pump();
    await tester.tap(find.byTooltip('Send'));
    await tester.pump();
    await tester.tap(find.byIcon(LoomIcons.arrow_back_rounded));
    // Even while the old chat fades out, the inbox must accept a new tap.
    await tester.pump();
    expect(find.text('Nima').first.hitTestable(), findsOneWidget);
    await tester.tap(find.text('Nima').first);
    await tester.pumpAndSettle();
    expect(find.text('Nima'), findsOneWidget);
    expect(find.byType(LoomChatBackdrop), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'keep Nima draft');

    messaging.queued.complete(true);
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'keep Nima draft',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'message reply survives navigation and forwards the server message ID',
    (tester) async {
      usePhoneViewport(tester);
      final nodes = LoomNodeDirectoryController();
      final onboarding = LoomOnboardingController(nodes: nodes);
      final messaging = _DelayedMessaging(onboarding: onboarding);
      messaging.visibleMessages = {
        'sara': [
          LoomVisibleMessage(
            record: models.LoomMessageRecord(
              id: 'server-message-1',
              clientId: 'message-client-1',
              conversationId: 'sara',
              senderAddress: '@maya:example.org',
              type: models.LoomMessageType.text,
              ciphertext: 'opaque',
              protocolVersion: 'test',
              createdOrder: 1,
              createdAt: DateTime.utc(2026, 9, 20, 12),
              deliveryState: models.LoomDeliveryState.delivered,
            ),
            text: 'Hello from Sara',
            readable: true,
          ),
        ],
      };
      addTearDown(nodes.dispose);
      addTearDown(onboarding.dispose);
      addTearDown(messaging.dispose);
      await tester.pumpWidget(
        _surface(
          LoomMessagingSessionScope(
            controller: messaging,
            child: const MessengerShell(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sara').first);
      await tester.pumpAndSettle();
      await tester.longPress(find.text('Hello from Sara'));
      await tester.pumpAndSettle();
      // Long-press anywhere on the text opens message actions, while partial
      // selection remains available through an explicit action.
      expect(find.text('Reply'), findsOneWidget);
      await tester.tap(find.text('Select text'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<SelectableText>(find.byType(SelectableText)).data,
        'Hello from Sara',
      );
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      await tester.longPress(find.text('Hello from Sara'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reply').first);
      await tester.pumpAndSettle();
      expect(find.text('Replying to'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Hello back');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sara').first);
      await tester.pumpAndSettle();
      expect(find.text('Replying to'), findsOneWidget);
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      expect(messaging.sentTexts, ['Hello back']);
      expect(messaging.sentReplyId, 'server-message-1');
      messaging.queued.complete(true);
      await tester.pumpAndSettle();
      expect(find.text('Replying to'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'attachment paste stays a draft and supported GIF controls remain available',
    (tester) async {
      usePhoneViewport(tester);
      var reads = 0;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.getData') {
            reads++;
            return {'text': 'clipboard text'};
          }
          if (call.method == 'Clipboard.hasStrings') {
            return {'value': true};
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      const photos = MethodChannel('com.fluttercandies/photo_manager');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        photos,
        (call) async => call.method == 'requestPermissionExtend' ? 2 : true,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          photos,
          null,
        ),
      );
      await tester.pumpWidget(_surface(const MessengerShell(preview: true)));
      await tester.tap(find.text('Maya Brooks').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Attach'));
      await tester.pumpAndSettle();
      expect(find.text('Gallery'), findsNWidgets(2));
      expect(
        find.text('File'),
        findsOneWidget,
      ); // encrypted generic files are supported
      expect(find.text('GIF'), findsOneWidget); // GIF sending is supported
      await tester.ensureVisible(find.text('Paste text'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Paste text'));
      await tester.pumpAndSettle();
      expect(reads, 1);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'clipboard text',
      );
      expect(find.byType(LoomActionTile), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('switching tabs preserves chat search and its clear action', (
    tester,
  ) async {
    usePhoneViewport(tester);
    await tester.pumpWidget(_surface(const MessengerShell(preview: true)));
    await tester.tap(find.byTooltip('Search'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Sara');
    await tester.pump();
    await tester.tap(find.text('Calls').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Chats').last);
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'Sara',
    );
    await tester.tap(find.byTooltip('Close search'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.byTooltip('Search'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });

  for (final width in [320.0, 700.0]) {
    testWidgets('RTL conversation uses the available width at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        _surface(
          const MessengerShell(preview: true),
          locale: const Locale('fa'),
        ),
      );
      await tester.tap(find.text('Maya Brooks').first);
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byType(LoomGlassComposer)).width,
        greaterThan(width - 30),
      );
      expect(tester.takeException(), isNull);
    });
  }
}

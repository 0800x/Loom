import 'package:loom_crypto_bridge/loom_crypto_bridge.dart';
import 'package:loom_design/loom_design.dart';
import 'package:loom_models/loom_models.dart';
import 'package:loom_next/features/chat_folders/application/chat_folder_controller.dart';
import 'package:loom_next/features/groups/application/groups_controller.dart';
import 'package:loom_next/features/groups/presentation/group_join_screen.dart';
import 'package:loom_next/features/groups/presentation/groups_screen.dart';
import 'package:loom_next/features/home/presentation/messenger_shell.dart';
import 'package:loom_next/features/messaging/application/message_content.dart';
import 'package:loom_next/features/messaging/application/messaging_session_controller.dart';
import 'package:loom_next/features/nodes/application/node_directory_controller.dart';
import 'package:loom_next/features/onboarding/application/onboarding_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Groups extends LoomGroupsController {
  _Groups(LoomOnboardingController onboarding)
    : super(
        onboarding: onboarding,
        trustedDevice: (_) async => throw StateError('unused'),
        devicesForContact: (_) async => [],
      );
  LoomMessageContent? sent;
  int previews = 0;
  List<String>? createdPeers;
  @override
  Future<String?> create(String title, List<String> peers) async {
    createdPeers = peers;
    groups = [
      ...groups,
      LoomGroupState(
        id: 'g-created',
        title: title,
        epoch: 1,
        revision: 1,
        sequence: 1,
        members: group.members,
      ),
    ];
    messages = {...messages, 'g-created': const <LoomGroupMessage>[]};
    notifyListeners();
    return 'g-created';
  }

  @override
  Future<String?> joinInvite(String token) async => 'g';
  @override
  Future<Map<String, Object?>?> previewInvite(String token) async {
    previews++;
    return {
      'groupId': 'g',
      'title': 'Friends',
      'memberCount': 2,
      'mode': 'open',
      'status': 'none',
    };
  }

  @override
  Future<bool> open() async => true;
  @override
  Future<bool> sendContent(String id, LoomMessageContent content) async {
    sent = content;
    return true;
  }
}

class _Messaging extends LoomMessagingSessionController {
  _Messaging(LoomOnboardingController onboarding)
    : super(onboarding: onboarding);
  @override
  Future<void> open() async {}
}

const group = LoomGroupState(
  id: 'g',
  title: 'Friends',
  epoch: 1,
  revision: 1,
  sequence: 10,
  members: [
    LoomGroupMember(
      accountId: 'a',
      deviceId: 'd',
      identityId: 'i',
      role: 'owner',
      mlsSignatureKey: '',
      mlsSignature: '',
    ),
    LoomGroupMember(
      accountId: 'b',
      deviceId: 'b',
      identityId: 'j',
      role: 'member',
      mlsSignatureKey: '',
      mlsSignature: '',
    ),
  ],
);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => LoomAppLock.instance.initialize());
  late LoomNodeDirectoryController nodes;
  late LoomOnboardingController onboarding;
  late _Groups groups;
  late _Messaging messaging;
  setUp(() {
    nodes = LoomNodeDirectoryController()
      ..selectedEndpoint = Uri.parse('https://home.test');
    onboarding = LoomOnboardingController(nodes: nodes)
      ..receipt = const LoomRegistrationReceipt(
        accountId: 'a',
        deviceId: 'd',
        address: '@alice:home.test',
        homeNode: 'home.test',
      );
    groups = _Groups(onboarding)
      ..ready = true
      ..groups = [group]
      ..messages = {
        'g': [
          LoomGroupMessage(
            10,
            'm',
            'd',
            'Group history',
            createdAt: DateTime.utc(2026, 10, 11),
          ),
        ],
      }
      ..unreadCounts['g'] = 2;
    messaging = _Messaging(onboarding)..attachGroups(groups);
  });
  tearDown(() {
    messaging.dispose();
    groups.dispose();
    onboarding.dispose();
    nodes.dispose();
  });
  test(
    'MLS catalogue enters group and unread folders without legacy records',
    () {
      final entry = messaging.conversations.single;
      expect(entry.kind, LoomConversationKind.group);
      expect(
        const LoomChatFolderDefinition(
          id: 'groups',
          name: 'Groups',
          includeGroups: true,
        ).matches(entry),
        isTrue,
      );
      expect(
        const LoomChatFolderDefinition(
          id: 'unread',
          name: 'Unread',
          unreadOnly: true,
        ).matches(entry),
        isTrue,
      );
      final row = messaging.visibleMessagesFor('g').single;
      expect(row.text, 'Group history');
      expect(row.record.ciphertext, isEmpty);
      expect(row.record.senderAddress, '@alice:home.test');
      final before = messaging.visibleMessagesFor('g');
      groups.messages = {
        'g': [
          LoomGroupMessage(
            10,
            'm',
            'd',
            'Group history',
            createdAt: DateTime.utc(2026, 10, 11),
          ),
        ],
      };
      groups.notifyListeners();
      expect(
        identical(before, messaging.visibleMessagesFor('g')),
        isTrue,
        reason: 'Unchanged sync does not recreate media rows',
      );
      messaging.clearReadableState();
      expect(messaging.visibleMessages, isEmpty);
    },
  );
  test(
    'a live group card refreshes its content without changing its message key',
    () {
      void update(int at, double lat) {
        groups.messages = {
          'g': [
            LoomGroupMessage(
              10,
              'live',
              'd',
              '',
              createdAt: DateTime.utc(2026),
              location: {
                'lat': lat,
                'lon': 51.0,
                'at': at,
                'until': 1000,
                'session': 'sharing',
                'stopped': false,
              },
            ),
          ],
        };
        groups.notifyListeners();
      }

      update(1, 35);
      final key = messaging.visibleMessagesFor('g').single.record.id;
      update(2, 35.1);
      final message = messaging.visibleMessagesFor('g').single;
      expect(message.record.id, key);
      expect(message.content.location!['lat'], 35.1);
      expect(message.content.location!['at'], 2);
    },
  );

  test('shared send routes text, reply and location through MLS', () async {
    final reply = messaging.visibleMessagesFor('g').single;
    expect(await messaging.sendText('g', 'Hello group', reply: reply), isTrue);
    expect(groups.sent!.text, 'Hello group');
    expect(groups.sent!.reply!['clientId'], 'm');
    const content = LoomMessageContent(location: {'lat': 35.0, 'lon': 51.0});
    expect(await messaging.sendText('g', '', content: content), isTrue);
    expect(groups.sent, same(content));
  });
  test('combined catalogue keeps pinned chats ahead of active groups', () {
    messaging.conversations = [
      ...messaging.conversations,
      const LoomConversation(
        id: 'direct',
        kind: LoomConversationKind.direct,
        title: 'Pinned',
        updatedOrder: 1,
        unreadCount: 0,
        isMuted: false,
        isPinned: true,
      ),
    ];
    groups.notifyListeners();
    expect(messaging.conversations.first.id, 'direct');
  });
  testWidgets(
    'tapping an invitation in chat opens its preview inside the app',
    (tester) async {
      final link = 'https://home.test/g/${'a' * 43}';
      groups.messages = {
        'g': [
          LoomGroupMessage(
            11,
            'invite',
            'b',
            link,
            createdAt: DateTime.utc(2026, 10, 11),
          ),
        ],
      };
      groups.notifyListeners();
      await tester.pumpWidget(
        LoomMessagingSessionScope(
          controller: messaging,
          child: LoomGroupsScope(
            controller: groups,
            child: MaterialApp(
              theme: LoomTheme.light(),
              home: const Scaffold(
                body: LoomConversationSurface(conversationId: 'g'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      tester
          .widget<LoomMessageBubble>(find.byType(LoomMessageBubble))
          .onLinkTap!(Uri.parse(link));
      await tester.pumpAndSettle();
      expect(find.byType(LoomGroupJoinScreen), findsOneWidget);
      expect(groups.previews, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'New group creates directly from Chats without a group catalogue',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        LoomMessagingSessionScope(
          controller: messaging,
          child: LoomGroupsScope(
            controller: groups,
            child: MaterialApp(
              theme: LoomTheme.light(),
              home: const MessengerShell(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('create-dial-toggle')));
      await tester.pumpAndSettle();
      expect(find.text('Encrypted groups'), findsNothing);
      expect(find.text('Join with link'), findsNothing);
      await tester.tap(find.text('New group'));
      await tester.pumpAndSettle();
      expect(find.byType(LoomGroupsScreen), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('group-name')),
        'Weekend',
      );
      await tester.tap(find.byKey(const ValueKey('create-group-submit')));
      await tester.pumpAndSettle();
      expect(
        groups.createdPeers,
        isEmpty,
        reason: 'Members are optional; selection has dedicated flow coverage',
      );
      expect(find.text('Weekend'), findsWidgets);
      expect(find.byTooltip('Conversation menu'), findsOneWidget);
      expect(find.byType(LoomGroupsScreen), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'joining from a chat invitation opens the ordinary messenger route',
    (tester) async {
      await tester.pumpWidget(
        LoomMessagingSessionScope(
          controller: messaging,
          child: LoomGroupsScope(
            controller: groups,
            child: MaterialApp(
              theme: LoomTheme.light(),
              home: LoomGroupJoinScreen(
                initialLink: 'https://home.test/g/${'a' * 43}',
              ),
              routes: {'/messenger': (_) => const MessengerShell()},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byType(TextField),
        findsNothing,
        reason: 'Tapped links open a group preview, not a paste-link form',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Join group'));
      await tester.pumpAndSettle();
      expect(find.byType(LoomGroupJoinScreen), findsNothing);
      expect(find.byType(LoomGroupsScreen), findsNothing);
      expect(find.byType(LoomMessageBubble), findsOneWidget);
      expect(find.text('Group history'), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final width in [320.0, 1280.0]) {
    testWidgets('group opens the ordinary chat and composer at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        LoomMessagingSessionScope(
          controller: messaging,
          child: LoomGroupsScope(
            controller: groups,
            child: MaterialApp(
              theme: LoomTheme.light(),
              home: const MessengerShell(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      if (width < 1000) {
        await tester.tap(find.text('Friends').first);
        await tester.pumpAndSettle();
      }
      expect(find.byType(LoomMessageBubble), findsOneWidget);
      expect(find.text('Group history'), findsWidgets);
      await tester.enterText(find.byType(TextField).last, 'Unified composer');
      await tester.pump();
      await tester.tap(find.byTooltip('Send'));
      await tester.pumpAndSettle();
      expect(groups.sent!.text, 'Unified composer');
      expect(find.byTooltip('Conversation menu'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}

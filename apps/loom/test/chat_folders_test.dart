import 'dart:io';

import 'package:loom_design/loom_design.dart';
import 'package:loom_models/loom_models.dart';
import 'package:loom_next/features/chat_folders/application/chat_folder_controller.dart';
import 'package:loom_next/features/chat_folders/presentation/chat_folders_settings_screen.dart';
import 'package:loom_next/features/home/presentation/messenger_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(
  LoomChatFolderController controller,
  Widget child, {
  Locale locale = const Locale('en'),
}) => LoomChatFoldersScope(
  controller: controller,
  child: MaterialApp(
    theme: LoomTheme.light(),
    locale: locale,
    supportedLocales: const [Locale('en'), Locale('fa')],
    localizationsDelegates: const [
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: child,
  ),
);

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

LoomConversation _conversation({
  required String id,
  required LoomConversationKind kind,
  int unread = 0,
  bool pinned = false,
  bool muted = false,
}) => LoomConversation(
  id: id,
  kind: kind,
  title: id,
  peerAddress: kind == LoomConversationKind.direct ? '@$id:node.test' : null,
  updatedOrder: 1,
  unreadCount: unread,
  isMuted: muted,
  isPinned: pinned,
);

void main() {
  test('folder rules filter real conversation metadata', () {
    const unreadPersonal = LoomChatFolderDefinition(
      id: 'custom-unread-personal',
      name: 'Unread personal',
      includeDirect: true,
      includeSelf: true,
      unreadOnly: true,
    );

    expect(
      unreadPersonal.matches(
        _conversation(
          id: 'alice',
          kind: LoomConversationKind.direct,
          unread: 3,
        ),
      ),
      isTrue,
    );
    expect(
      unreadPersonal.matches(
        _conversation(id: 'read-direct', kind: LoomConversationKind.direct),
      ),
      isFalse,
    );
    expect(
      unreadPersonal.matches(
        _conversation(id: 'group', kind: LoomConversationKind.group, unread: 4),
      ),
      isFalse,
    );
  });

  test('new folder setup starts with no category folders', () {
    final controller = LoomChatFolderController(identityIdProvider: () => null);
    addTearDown(controller.dispose);
    expect(controller.folders.map((folder) => folder.id).toList(), <String>[
      loomAllChatsFolderId,
    ]);
  });

  test('folder definitions persist per identity with order', () async {
    final directory = await Directory.systemTemp.createTemp(
      'loom-folders-test-',
    );
    addTearDown(() async {
      await directory.delete(recursive: true);
    });

    final first = LoomChatFolderController(
      identityIdProvider: () => 'identity-test',
      supportDirectoryProvider: () async => directory,
    );
    await first.open();
    expect(first.folders.map((folder) => folder.id).toList(), <String>[
      loomAllChatsFolderId,
    ]);

    await first.createCustom(
      name: 'Work',
      includeDirect: true,
      includeGroups: true,
      includeSelf: false,
      unreadOnly: true,
      pinnedOnly: false,
      mutedOnly: false,
    );
    final workIndex = first.folders.indexWhere(
      (folder) => folder.name == 'Work',
    );
    await first.reorder(workIndex, 1);
    expect(first.folders.first.id, loomAllChatsFolderId);
    expect(first.folders[1].name, 'Work');
    first.dispose();

    final reopened = LoomChatFolderController(
      identityIdProvider: () => 'identity-test',
      supportDirectoryProvider: () async => directory,
    );
    addTearDown(reopened.dispose);
    await reopened.open();
    expect(reopened.folders.first.id, loomAllChatsFolderId);
    expect(reopened.folders[1].name, 'Work');
    expect(reopened.folders.length, 2);
  });

  testWidgets(
    'settings exposes recommended and custom folder controls without defaults',
    (tester) async {
      _phone(tester);
      final controller = LoomChatFolderController(
        identityIdProvider: () => null,
      );
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        _host(controller, const LoomChatFoldersSettingsScreen()),
      );
      await tester.pump();

      expect(find.text('Chat Folders'), findsWidgets);
      expect(find.text('Recommended Folders'), findsOneWidget);
      expect(find.text('Muted'), findsOneWidget);
      expect(find.text('All Chats'), findsNothing);
      expect(find.textContaining('No folders added'), findsOneWidget);

      await tester.drag(find.byType(ListView).first, const Offset(0, -420));
      await tester.pumpAndSettle();
      expect(find.text('Create New Folder'), findsOneWidget);
    },
  );

  testWidgets('settings reorders down and up without moving All Chats', (
    tester,
  ) async {
    _phone(tester);
    final controller = LoomChatFolderController(identityIdProvider: () => null);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _host(controller, const LoomChatFoldersSettingsScreen()),
    );
    await tester.pumpAndSettle();
    for (final name in ['First', 'Second', 'Third']) {
      await controller.createCustom(
        name: name,
        includeDirect: true,
        includeGroups: false,
        includeSelf: false,
        unreadOnly: false,
        pinnedOnly: false,
        mutedOnly: false,
      );
    }
    await tester.pumpAndSettle();
    var list = tester.widget<ReorderableListView>(
      find.byType(ReorderableListView),
    );
    list.onReorderItem!(0, 2);
    await tester.pumpAndSettle();
    expect(controller.folders.skip(1).map((f) => f.name), [
      'Second',
      'Third',
      'First',
    ]);
    list = tester.widget<ReorderableListView>(find.byType(ReorderableListView));
    list.onReorderItem!(2, 0);
    await tester.pumpAndSettle();
    expect(controller.folders.skip(1).map((f) => f.name), [
      'First',
      'Second',
      'Third',
    ]);
    expect(controller.folders.first.id, loomAllChatsFolderId);
    expect(tester.takeException(), isNull);
  });

  testWidgets('chat folder strip supports tap and horizontal page swipe', (
    tester,
  ) async {
    _phone(tester);
    final controller = LoomChatFolderController(identityIdProvider: () => null);
    addTearDown(controller.dispose);
    await controller.addPreset(loomPersonalFolderId);
    await controller.addPreset(loomGroupsFolderId);

    await tester.pumpWidget(
      _host(controller, const MessengerShell(preview: true)),
    );
    await tester.pumpAndSettle();

    ChoiceChip chip(String text) =>
        tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, text));

    expect(chip('All').selected, isTrue);
    await tester.tap(find.text('Personal').first);
    await tester.pumpAndSettle();
    expect(chip('Personal').selected, isTrue);

    final swipePager = find.byWidgetPredicate(
      (widget) =>
          widget is PageView && widget.physics is! NeverScrollableScrollPhysics,
    );
    expect(swipePager, findsOneWidget);
    await tester.drag(swipePager, const Offset(-300, 0));
    await tester.pumpAndSettle();

    expect(chip('Groups').selected, isTrue);
  });
}

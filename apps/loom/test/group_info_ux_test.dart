import 'package:loom_crypto_bridge/loom_crypto_bridge.dart';
import 'package:loom_design/loom_design.dart';
import 'package:loom_models/loom_models.dart';
import 'package:loom_next/features/groups/application/groups_controller.dart';
import 'package:loom_next/features/groups/presentation/group_info_surface.dart';
import 'package:loom_next/features/groups/presentation/group_requests_screen.dart';
import 'package:loom_next/features/nodes/application/node_directory_controller.dart';
import 'package:loom_next/features/onboarding/application/onboarding_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

LoomGroupMember member(String account, String device, String role) =>
    LoomGroupMember(
      accountId: account,
      deviceId: device,
      identityId: 'identity-$account',
      role: role,
      mlsSignatureKey: '',
      mlsSignature: '',
    );

class _Groups extends LoomGroupsController {
  _Groups(LoomOnboardingController onboarding)
    : super(
        onboarding: onboarding,
        trustedDevice: (_) async => throw StateError('unused'),
        devicesForContact: (_) async => [],
      );
  final decisions = <(String, bool)>[];
  @override
  String memberLabel(LoomGroupMember member) => switch (member.accountId) {
    'a' => 'Alice',
    'b' => 'Bob',
    'c' => 'Carol',
    _ => 'Dora',
  };
  @override
  String? memberCachedAddress(LoomGroupMember member) =>
      '@${memberLabel(member).toLowerCase()}:home.test';
  @override
  Future<void> loadMemberProfiles(
    List<LoomGroupMember> members, {
    bool force = false,
  }) async {}
  @override
  Future<bool> synchronize() async => true;
  @override
  Future<bool> decideJoin(String id, String deviceId, bool approve) async {
    decisions.add((deviceId, approve));
    joinRequests[id] = joinRequests[id]!
        .where((r) => (r['member'] as Map)['deviceId'] != deviceId)
        .toList();
    notifyListeners();
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => LoomAppLock.instance.initialize());
  late LoomNodeDirectoryController nodes;
  late LoomOnboardingController onboarding;
  late _Groups groups;
  setUp(() {
    nodes = LoomNodeDirectoryController();
    onboarding = LoomOnboardingController(nodes: nodes)
      ..receipt = const LoomRegistrationReceipt(
        accountId: 'a',
        deviceId: 'a-one',
        address: '@alice:home.test',
        homeNode: 'home.test',
      );
    groups = _Groups(onboarding)
      ..ready = true
      ..groups = [
        LoomGroupState(
          id: 'g',
          title: 'Friends · دوستان',
          epoch: 1,
          revision: 1,
          sequence: 1,
          members: [
            member('a', 'a-one', 'owner'),
            member('a', 'a-two', 'owner'),
            member('b', 'b-one', 'admin'),
            member('b', 'b-two', 'admin'),
            member('c', 'c-one', 'member'),
          ],
        ),
      ];
  });
  tearDown(() {
    groups.dispose();
    onboarding.dispose();
    nodes.dispose();
  });

  Widget host(Widget Function(BuildContext) builder, Locale locale) =>
      LoomGroupsScope(
        controller: groups,
        child: MaterialApp(
          theme: LoomTheme.dark(),
          locale: locale,
          supportedLocales: const [Locale('en'), Locale('fa')],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.5)),
            child: child!,
          ),
          home: Builder(builder: builder),
        ),
      );

  for (final locale in const [Locale('en'), Locale('fa')]) {
    for (final width in [320.0, 1280.0]) {
      testWidgets(
        'group info: accounts, admin tab, search and private chat at ${locale.languageCode}/$width',
        (tester) async {
          tester.view.physicalSize = Size(width, 780);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          String? opened;
          await tester.pumpWidget(
            host((context) {
              final controller = LoomGroupsScope.of(context);
              return LoomGroupInfoSurface(
                groups: controller,
                group: controller.groups.single,
                onOpenMember: (m) => opened = m.accountId,
                onMemberAction: (_, _) {},
                onAddMember: () {},
                onInvite: () {},
                onRequests: () {},
                onRename: () {},
              );
            }, locale),
          );
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog), findsNothing);
          expect(
            find.text('3 ${locale.languageCode == 'fa' ? 'عضو' : 'members'}'),
            findsOneWidget,
          );
          await Scrollable.ensureVisible(
            tester.element(find.byKey(const ValueKey('group-admins-tab'))),
            alignment: .5,
          );
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('group-admins-tab')).hitTestable(),
            findsOneWidget,
          );
          await tester.tap(find.byKey(const ValueKey('group-admins-tab')));
          await tester.pumpAndSettle();
          expect(find.byKey(const ValueKey('group-member-c')), findsNothing);
          expect(find.byKey(const ValueKey('group-member-b')), findsOneWidget);
          await tester.tap(find.byKey(const ValueKey('group-members-tab')));
          await tester.pumpAndSettle();
          await tester.enterText(
            find.byKey(const ValueKey('group-member-search')),
            'carol',
          );
          await tester.pumpAndSettle();
          expect(find.byKey(const ValueKey('group-member-b')), findsNothing);
          await tester.ensureVisible(
            find.byKey(const ValueKey('group-member-c')),
          );
          await tester.tap(find.byKey(const ValueKey('group-member-c')));
          await tester.pumpAndSettle();
          expect(
            opened,
            'c',
            reason: 'Opening private chat does not require a saved contact',
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }

  testWidgets(
    'ordinary members can message people but cannot manage roles or invitations',
    (tester) async {
      final old = groups.groups.single;
      groups.groups = [
        LoomGroupState(
          id: old.id,
          title: old.title,
          epoch: 1,
          revision: 2,
          sequence: 1,
          members: [
            member('a', 'a-one', 'member'),
            member('b', 'b-one', 'owner'),
          ],
        ),
      ];
      await tester.pumpWidget(
        host(
          (context) => LoomGroupInfoSurface(
            groups: groups,
            group: groups.groups.single,
            onOpenMember: (_) {},
            onMemberAction: (_, _) {},
            onAddMember: () {},
            onInvite: () {},
            onRequests: () {},
            onRename: () {},
          ),
          const Locale('en'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Invite link'), findsNothing);
      expect(find.text('Add members'), findsNothing);
      expect(find.byTooltip('Edit group name'), findsNothing);
      await tester.ensureVisible(find.byKey(const ValueKey('group-member-b')));
      await tester.tap(find.byTooltip('Member options'));
      await tester.pumpAndSettle();
      expect(find.text('Send message'), findsOneWidget);
      expect(find.text('Make admin'), findsNothing);
      expect(find.text('Remove member'), findsNothing);
      expect(find.text('Transfer ownership'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'admins can remove ordinary members but only the owner can change roles',
    (tester) async {
      groups.groups = [
        LoomGroupState(
          id: 'g',
          title: 'Friends',
          epoch: 1,
          revision: 1,
          sequence: 1,
          members: [
            member('a', 'a-one', 'admin'),
            member('b', 'b-one', 'owner'),
            member('c', 'c-one', 'admin'),
            member('d', 'd-one', 'member'),
          ],
        ),
      ];
      await tester.pumpWidget(
        host(
          (context) => LoomGroupInfoSurface(
            groups: groups,
            group: groups.groups.single,
            onOpenMember: (_) {},
            onMemberAction: (_, _) {},
            onAddMember: () {},
            onInvite: () {},
            onRequests: () {},
            onRename: () {},
          ),
          const Locale('en'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('group-member-search')),
      );
      await tester.enterText(
        find.byKey(const ValueKey('group-member-search')),
        'carol',
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('group-member-c')));
      await tester.tap(find.byTooltip('Member options'));
      await tester.pumpAndSettle();
      expect(find.text('Send message'), findsOneWidget);
      expect(find.text('Remove admin role'), findsNothing);
      expect(find.text('Remove member'), findsNothing);
      expect(find.text('Transfer ownership'), findsNothing);
      await tester.tapAt(const Offset(8, 8));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('group-member-search')),
        'dora',
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('group-member-d')));
      await tester.tap(find.byTooltip('Member options'));
      await tester.pumpAndSettle();
      expect(find.text('Remove member'), findsOneWidget);
      expect(find.text('Make admin'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'join requests show one person and approve all requesting devices without reopening dialogs',
    (tester) async {
      groups.joinRequests['g'] = [
        {
          'status': 'pending',
          'member': member('d', 'd-one', 'member').toJson(),
        },
        {
          'status': 'pending',
          'member': member('d', 'd-two', 'member').toJson(),
        },
      ];
      await tester.pumpWidget(
        host(
          (_) => const LoomGroupRequestsScreen(groupId: 'g'),
          const Locale('en'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Dora'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Approve'));
      await tester.pumpAndSettle();
      expect(groups.decisions, [('d-one', true), ('d-two', true)]);
      expect(find.text('No pending requests'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

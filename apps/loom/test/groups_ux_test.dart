import 'package:loom_crypto_bridge/loom_crypto_bridge.dart';
import 'package:loom_design/loom_design.dart';
import 'package:loom_models/loom_models.dart';
import 'package:loom_next/features/groups/application/groups_controller.dart';
import 'package:loom_next/features/groups/presentation/groups_screen.dart';
import 'package:loom_next/features/nodes/application/node_directory_controller.dart';
import 'package:loom_next/features/onboarding/application/onboarding_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

class _Groups extends LoomGroupsController {
  _Groups(LoomOnboardingController onboarding)
    : super(
        onboarding: onboarding,
        trustedDevice: (_) async => throw StateError('No lookup in UI test'),
        devicesForContact: (_) async => [],
        identityLabel: (id) => id == 'i-b' ? 'Bob' : 'Alice',
      );
  @override
  Future<bool> open() async => true;
  @override
  void setActiveGroup(String? id) {
    activeGroupId = id;
  }

  @override
  Future<bool> send(String id, String text) async => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => LoomAppLock.instance.initialize());
  for (final locale in const [Locale('en'), Locale('fa')]) {
    for (final width in [320.0, 700.0, 1280.0]) {
      testWidgets(
        'MLS group fits ${locale.languageCode} at $width and preserves a failed draft',
        (tester) async {
          tester.view.physicalSize = Size(width, 780);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final nodes = LoomNodeDirectoryController();
          final onboarding = LoomOnboardingController(nodes: nodes)
            ..receipt = const LoomRegistrationReceipt(
              accountId: 'a',
              deviceId: 'd',
              address: '@alice:home',
              homeNode: 'home',
            );
          final groups = _Groups(onboarding)..ready = true;
          groups.groups = [
            const LoomGroupState(
              id: 'g',
              title: 'Friends · دوستان',
              epoch: 1,
              revision: 1,
              sequence: 1,
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
                  accountId: 'a',
                  deviceId: 'd-two',
                  identityId: 'i',
                  role: 'owner',
                  mlsSignatureKey: '',
                  mlsSignature: '',
                ),
                LoomGroupMember(
                  accountId: 'b',
                  deviceId: 'b-one',
                  identityId: 'i-b',
                  role: 'member',
                  mlsSignatureKey: '',
                  mlsSignature: '',
                ),
                LoomGroupMember(
                  accountId: 'b',
                  deviceId: 'b-two',
                  identityId: 'i-b',
                  role: 'member',
                  mlsSignatureKey: '',
                  mlsSignature: '',
                ),
              ],
            ),
          ];
          groups.messages = {
            'g': [
              const LoomGroupMessage(
                1,
                'm',
                'd',
                'Private message · پیام خصوصی',
              ),
            ],
          };
          await tester.pumpWidget(
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
                home: const LoomGroupsScreen(initialGroupId: 'g'),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.enterText(find.byType(TextField), 'keep draft');
          await tester.tap(
            find.byTooltip(locale.languageCode == 'fa' ? 'ارسال' : 'Send'),
          );
          await tester.pumpAndSettle();
          expect(find.text('keep draft'), findsOneWidget);
          expect(groups.draft('g'), 'keep draft');
          if (width < 900) {
            await tester.tap(find.byType(BackButton));
            await tester.pumpAndSettle();
            expect(find.byType(TextField), findsNothing);
            await tester.tap(find.text('Friends · دوستان').last);
            await tester.pumpAndSettle();
            expect(find.text('keep draft'), findsOneWidget);
          }
          await tester.tap(
            find.byTooltip(locale.languageCode == 'fa' ? 'اعضا' : 'Members'),
          );
          await tester.pumpAndSettle();
          await tester.scrollUntilVisible(
            find.byKey(const ValueKey('group-member-b')),
            100,
            scrollable: find
                .descendant(
                  of: find.byType(CustomScrollView),
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          expect(
            find.text('Bob'),
            findsOneWidget,
            reason: 'One row per account, regardless of device count',
          );
          expect(
            find.text(locale.languageCode == 'fa' ? 'شما' : 'You'),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
          await tester.tap(find.byType(BackButton));
          await tester.pumpAndSettle();
          await tester.tap(
            find.byTooltip(
              locale.languageCode == 'fa' ? 'گروه جدید' : 'New group',
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          await tester.pump(const Duration(milliseconds: 300));
          groups.dispose();
          onboarding.dispose();
          nodes.dispose();
        },
      );
    }
  }
}

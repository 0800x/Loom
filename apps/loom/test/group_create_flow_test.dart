import 'dart:async';
import 'dart:typed_data';
import 'package:image/image.dart' as img;

import 'package:loom_crypto_bridge/loom_crypto_bridge.dart';
import 'package:loom_design/loom_design.dart';
import 'package:loom_models/loom_models.dart';
import 'package:loom_next/features/groups/application/groups_controller.dart';
import 'package:loom_next/features/groups/presentation/group_create_screen.dart';
import 'package:loom_next/features/nodes/application/node_directory_controller.dart';
import 'package:loom_next/features/onboarding/application/onboarding_controller.dart';
import 'package:loom_next/features/people/application/people_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/ux_evidence.dart';

class Groups extends LoomGroupsController {
  Groups(LoomOnboardingController onboarding)
    : super(
        onboarding: onboarding,
        trustedDevice: (_) async => throw StateError('No network in UI test'),
        devicesForContact: (_) async => [],
      );
  int submissions = 0, photoSubmissions = 0;
  bool photoSuccess = false;
  @override
  Future<bool> setGroupPhoto(String id, Uint8List? png) async {
    photoSubmissions++;
    return photoSuccess;
  }

  String? submittedName;
  List<String>? submittedMembers;
  Completer<String?>? pending;
  @override
  Future<String?> create(String title, List<String> addresses) {
    submissions++;
    submittedName = title;
    submittedMembers = addresses;
    return (pending = Completer<String?>()).future;
  }
}

class People extends LoomPeopleController {
  People()
    : super(
        homeNodeProvider: () => 'home.test',
        endpointProvider: () => Uri.parse('https://home.test'),
        accessTokenProvider: () async => 'unused',
        deviceProofProvider: () async => throw StateError('unused'),
      ) {
    final now = DateTime.utc(2026);
    contacts = [
      for (final address in ['@bob:home.test', '@remote:other.test'])
        LoomContact(
          identityId: address,
          username: address,
          displayName: address.startsWith('@bob')
              ? 'Bob · بابک با نام طولانی'
              : 'Remote',
          canonicalAddress: address,
          homeNode: address.split(':').last,
          securityState: LoomContactSecurityState.verified,
          createdAt: now,
          updatedAt: now,
          lastResolvedAt: now,
        ),
    ];
  }
  @override
  Future<void> open() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await LoomAppLock.instance.initialize();
    await loadUxFonts();
  });
  for (final locale in const [Locale('en'), Locale('fa')]) {
    for (final theme in [
      LoomTheme.light(fontFamily: 'Vazirmatn'),
      LoomTheme.dark(fontFamily: 'Vazirmatn'),
      LoomTheme.oled(fontFamily: 'Vazirmatn'),
    ]) {
      testWidgets(
        'create retains selections after failure, blocks duplicates and opens only on success: $locale ${theme.scaffoldBackgroundColor}',
        (tester) async {
          tester.view.physicalSize = const Size(320, 780);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final nodes = LoomNodeDirectoryController();
          final onboarding = LoomOnboardingController(nodes: nodes)
            ..receipt = const LoomRegistrationReceipt(
              accountId: 'a',
              deviceId: 'd',
              address: '@alice:home.test',
              homeNode: 'home.test',
            );
          final groups = Groups(onboarding)..photoSuccess = true;
          final people = People();
          String? created;
          await tester.pumpWidget(
            MaterialApp(
              theme: theme,
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
                child: RepaintBoundary(child: child!),
              ),
              home: Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () async {
                      created = await Navigator.push<String>(
                        context,
                        MaterialPageRoute(
                          builder: (_) => LoomGroupCreateScreen(
                            groups: groups,
                            people: people,
                            pickPhoto: () async => img.encodePng(
                              img.Image(width: 32, height: 32)
                                ..clear(img.ColorRgb8(66, 112, 218)),
                            ),
                          ),
                        ),
                      );
                    },
                    child: const Text('Launch'),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('Launch'));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('create-group-submit')));
          await tester.pumpAndSettle();
          expect(groups.submissions, 0, reason: 'Name is required');
          await tester.tap(
            find.text(
              locale.languageCode == 'fa' ? 'افزودن تصویر' : 'Add photo',
            ),
          );
          await tester.pumpAndSettle();
          await tester.enterText(
            find.byKey(const ValueKey('group-name')),
            'Study group · گروه مطالعه',
          );
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.byType(Image).first);
          await tester.runAsync(
            () => precacheImage(
              tester.widget<Image>(find.byType(Image).first).image,
              tester.element(find.byType(Image).first),
            ),
          );
          await tester.pumpAndSettle();
          await captureUxEvidence(
            tester,
            'group-create-photo-${locale.languageCode}-${theme.scaffoldBackgroundColor.toARGB32()}',
          );
          final member = find.byKey(
            const ValueKey('create-member-@bob:home.test'),
          );
          await tester.ensureVisible(member);
          await tester.tap(member);
          await tester.pumpAndSettle();
          await tester.ensureVisible(
            find.byKey(const ValueKey('create-member-@remote:other.test')),
          );
          final foreign = tester.widget<CheckboxListTile>(
            find.descendant(
              of: find.byKey(
                const ValueKey('create-member-@remote:other.test'),
              ),
              matching: find.byType(CheckboxListTile),
            ),
          );
          expect(
            foreign.onChanged,
            isNull,
            reason: 'Group federation is not supported',
          );
          await tester.tap(find.byKey(const ValueKey('create-group-submit')));
          await tester.pump();
          await tester.tap(find.byKey(const ValueKey('create-group-submit')));
          await tester.pump();
          expect(groups.submissions, 1);
          expect(groups.submittedMembers, ['@bob:home.test']);
          groups.pending!.complete(null);
          await tester.pumpAndSettle();
          expect(created, isNull);
          expect(find.byType(LoomGroupCreateScreen), findsOneWidget);
          final scrollable = find
              .descendant(
                of: find.byType(ListView),
                matching: find.byType(Scrollable),
              )
              .first;
          await tester.scrollUntilVisible(
            find.byKey(const ValueKey('group-name')),
            -200,
            scrollable: scrollable,
          );
          expect(find.text('Study group · گروه مطالعه'), findsOneWidget);
          expect(find.byType(InputChip), findsOneWidget);
          await tester.scrollUntilVisible(
            find.byType(LoomFeedbackSurface),
            200,
            scrollable: scrollable,
          );
          expect(find.byType(LoomFeedbackSurface), findsOneWidget);
          await tester.pumpAndSettle();
          await captureUxEvidence(
            tester,
            'group-create-${locale.languageCode}-${theme.scaffoldBackgroundColor.toARGB32()}-failure',
          );
          await tester.tap(find.byKey(const ValueKey('create-group-submit')));
          await tester.pump();
          expect(groups.submissions, 2);
          groups.pending!.complete('new-group');
          await tester.pumpAndSettle();
          expect(created, 'new-group');
          expect(find.byType(LoomGroupCreateScreen), findsNothing);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          groups.dispose();
          people.dispose();
          onboarding.dispose();
          nodes.dispose();
        },
      );
    }
  }
  testWidgets('back keeps a meaningful draft until discard is chosen', (
    tester,
  ) async {
    final nodes = LoomNodeDirectoryController();
    final onboarding = LoomOnboardingController(nodes: nodes);
    final groups = Groups(onboarding), people = People();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.push<void>(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      LoomGroupCreateScreen(groups: groups, people: people),
                ),
              ),
              child: const Text('Launch'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Launch'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('group-name')), 'Draft');
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Keep editing'));
    await tester.pumpAndSettle();
    expect(find.text('Draft'), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    expect(find.text('Launch'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    groups.dispose();
    people.dispose();
    onboarding.dispose();
    nodes.dispose();
  });
  testWidgets(
    'photo retry preserves the created group and never duplicates it',
    (tester) async {
      tester.view.physicalSize = const Size(320, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final nodes = LoomNodeDirectoryController();
      final onboarding = LoomOnboardingController(nodes: nodes);
      final groups = Groups(onboarding), people = People();
      final photo = img.encodePng(
        img.Image(width: 32, height: 32)..clear(img.ColorRgb8(66, 112, 218)),
      );
      String? result;
      await tester.pumpWidget(
        MaterialApp(
          theme: LoomTheme.dark(fontFamily: 'Vazirmatn'),
          builder: (_, child) => RepaintBoundary(child: child!),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  result = await Navigator.push<String>(
                    context,
                    MaterialPageRoute(
                      builder: (_) => LoomGroupCreateScreen(
                        groups: groups,
                        people: people,
                        pickPhoto: () async => Uint8List.fromList(photo),
                      ),
                    ),
                  );
                },
                child: const Text('Launch'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Launch'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add photo'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('group-name')),
        'Design team · گروه طراحی',
      );
      await tester.pumpAndSettle();
      await captureUxEvidence(tester, 'group-create-photo-dark-en');
      await tester.tap(find.byKey(const ValueKey('create-group-submit')));
      await tester.pump();
      groups.pending!.complete('created-once');
      await tester.pumpAndSettle();
      expect(groups.submissions, 1);
      expect(groups.photoSubmissions, 1);
      expect(find.text('Retry photo sync'), findsOneWidget);
      expect(find.text('Open group'), findsOneWidget);
      await captureUxEvidence(tester, 'group-create-photo-retry-dark-en');
      groups.photoSuccess = true;
      await tester.tap(find.text('Retry photo sync'));
      await tester.pumpAndSettle();
      expect(groups.submissions, 1);
      expect(groups.photoSubmissions, 2);
      expect(result, 'created-once');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      groups.dispose();
      people.dispose();
      onboarding.dispose();
      nodes.dispose();
    },
  );
}

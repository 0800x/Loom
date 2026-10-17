import 'package:loom_design/loom_design.dart';
import 'package:loom_next/features/groups/application/group_call_models.dart';
import 'package:loom_next/features/groups/presentation/group_call_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/ux_evidence.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadUxFonts);
  for (final locale in const [Locale('en'), Locale('fa')]) {
    for (final width in [320.0, 1280.0]) {
      for (final mode in LoomThemeMode.values) {
        testWidgets(
          'call controls keep their slots when permission and capture change: $locale $width $mode',
          (tester) async {
            tester.view.physicalSize = Size(width, 780);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            final camera = ValueNotifier(false),
                permission = ValueNotifier(false);
            final changes = Listenable.merge([camera, permission]);
            final actions = <String>[];
            final theme = switch (mode) {
              LoomThemeMode.light => LoomTheme.light(
                fontFamily: 'Vazirmatn',
              ),
              LoomThemeMode.dark => LoomTheme.dark(fontFamily: 'Vazirmatn'),
              LoomThemeMode.oled => LoomTheme.oled(fontFamily: 'Vazirmatn'),
            };
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
                  data: MediaQuery.of(context).copyWith(
                    textScaler: TextScaler.linear(width < 400 ? 1.5 : 1),
                  ),
                  child: RepaintBoundary(child: child!),
                ),
                home: Scaffold(
                  appBar: LoomGlassAppBar(
                    title: const Text('Study group · گروه مطالعه'),
                  ),
                  body: SafeArea(
                    child: ListenableBuilder(
                      listenable: changes,
                      builder: (context, _) => LoomGroupCallSurface(
                        call: LoomGroupCallSnapshot(
                          id: 'call',
                          groupId: 'group',
                          epoch: 1,
                          revision: 1,
                          phase: 'active',
                          kind: 'video',
                          mode: 'approval',
                          joinLocked: false,
                          participants: [
                            LoomGroupCallParticipant(
                              id: 'own',
                              accountId: 'a',
                              deviceId: 'd',
                              name: 'Maya Brooks · مایا بروکس',
                              role: 'owner',
                              state: 'connected',
                              subscribe: true,
                              microphone: permission.value,
                              camera: permission.value,
                            ),
                            const LoomGroupCallParticipant(
                              id: 'peer',
                              accountId: 'b',
                              deviceId: 'db',
                              name:
                                  'Iris Lane · آیریس با نام خانوادگی بسیار طولانی',
                              role: 'member',
                              state: 'connected',
                              subscribe: true,
                              microphone: false,
                              camera: false,
                              handRaisedAt: 1,
                            ),
                          ],
                        ),
                        ownId: 'own',
                        admin: true,
                        owner: true,
                        joining: false,
                        busy: false,
                        microphone: false,
                        camera: camera.value,
                        speaker: true,
                        speakers: const {'peer'},
                        video: (_) => null,
                        onMicrophone: () => actions.add('microphone'),
                        onCamera: () => actions.add('camera'),
                        onSwitchCamera: () => actions.add('switch'),
                        onSpeaker: () => actions.add('speaker'),
                        onLeave: () => actions.add('leave'),
                        onControl: (a, _) => actions.add(a),
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            final leave = find.byKey(const ValueKey('group-call-leave'));
            final switchCamera = find.byKey(
              const ValueKey('group-call-switch-camera'),
            );
            final leaveBefore = tester.getTopLeft(leave),
                switchBefore = tester.getTopLeft(switchCamera);
            expect(actions, isEmpty, reason: 'Permission never starts capture');
            permission.value = true;
            await tester.pumpAndSettle();
            expect(actions, isEmpty);
            expect(tester.getTopLeft(leave), leaveBefore);
            camera.value = true;
            await tester.pumpAndSettle();
            expect(tester.getTopLeft(leave), leaveBefore);
            expect(tester.getTopLeft(switchCamera), switchBefore);
            expect(tester.takeException(), isNull);
            await captureUxEvidence(
              tester,
              'group-call-${locale.languageCode}-${mode.name}-${width.toInt()}',
            );
            await tester.tap(
              find.descendant(of: leave, matching: find.byType(IconButton)),
            );
            expect(actions, ['leave']);
            await tester.pumpWidget(const SizedBox());
            camera.dispose();
            permission.dispose();
          },
        );
      }
    }
  }
}

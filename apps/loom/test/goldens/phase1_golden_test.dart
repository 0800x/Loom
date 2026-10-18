import 'package:loom_design/loom_design.dart';
import 'package:loom_next/features/home/presentation/messenger_shell.dart';
import 'package:loom_next/features/nodes/presentation/node_selection_screen.dart';
import 'package:loom_next/features/profile/presentation/profile_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

const bool runGoldens = bool.fromEnvironment('LOOM_GOLDENS');

class _GoldenState {
  const _GoldenState(this.name, this.theme, this.locale);
  final String name;
  final ThemeData theme;
  final Locale locale;
}

Widget _host(Widget child, _GoldenState state) => MaterialApp(
  theme: state.theme,
  locale: state.locale,
  supportedLocales: const [Locale('en'), Locale('fa')],
  localizationsDelegates: const [
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  home: child,
);

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(430, 932);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void _desktop(WidgetTester tester) {
  tester.view.physicalSize = const Size(1600, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  final states = <_GoldenState>[
    _GoldenState('light', LoomTheme.light(), const Locale('en')),
    _GoldenState('dark', LoomTheme.dark(), const Locale('en')),
    _GoldenState('oled', LoomTheme.oled(), const Locale('en')),
    _GoldenState('fa_rtl', LoomTheme.dark(), const Locale('fa')),
  ];

  for (final state in states) {
    testWidgets('Node Selection ${state.name}', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_host(const NodeSelectionScreen(), state));
      await expectLater(
        find.byType(NodeSelectionScreen),
        matchesGoldenFile('node_selection_${state.name}.png'),
      );
    }, skip: !runGoldens);

    testWidgets('Chat List ${state.name}', (tester) async {
      _phone(tester);
      await tester.pumpWidget(
        _host(const MessengerShell(preview: true), state),
      );
      await expectLater(
        find.byType(MessengerShell),
        matchesGoldenFile('chat_list_${state.name}.png'),
      );
    }, skip: !runGoldens);

    testWidgets('Profile ${state.name}', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_host(const ProfileScreen(preview: true), state));
      await expectLater(
        find.byType(ProfileScreen),
        matchesGoldenFile('profile_${state.name}.png'),
      );
    }, skip: !runGoldens);

    testWidgets('Settings ${state.name}', (tester) async {
      _phone(tester);
      await tester.pumpWidget(
        _host(const MessengerShell(preview: true), state),
      );
      final settingsLabel = state.locale.languageCode == 'fa'
          ? 'تنظیمات'
          : 'Settings';
      await tester.tap(find.text(settingsLabel).last);
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(MessengerShell),
        matchesGoldenFile('settings_${state.name}.png'),
      );
    }, skip: !runGoldens);

    testWidgets('Desktop Shell ${state.name}', (tester) async {
      _desktop(tester);
      await tester.pumpWidget(
        _host(const MessengerShell(preview: true), state),
      );
      await expectLater(
        find.byType(MessengerShell),
        matchesGoldenFile('desktop_shell_${state.name}.png'),
      );
    }, skip: !runGoldens);

    testWidgets('Glass Components ${state.name}', (tester) async {
      _phone(tester);
      await tester.pumpWidget(
        _host(
          const Scaffold(
            body: Padding(
              padding: EdgeInsets.all(LoomSpacing.ml),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LoomGlassSurface(
                    strength: LoomGlassStrength.strong,
                    padding: EdgeInsets.all(LoomSpacing.md),
                    child: Text('Glass surface'),
                  ),
                  SizedBox(height: LoomSpacing.sm),
                  LoomGlassComposer(
                    hintText: 'Message',
                    attachTooltip: 'Attach',
                    voiceTooltip: 'Voice message',
                    sendTooltip: 'Send',
                  ),
                  SizedBox(height: LoomSpacing.sm),
                  LoomConnectivityPill(
                    state: LoomConnectivity.online,
                    label: 'Online',
                  ),
                ],
              ),
            ),
          ),
          state,
        ),
      );
      await expectLater(
        find.byType(Scaffold),
        matchesGoldenFile('glass_components_${state.name}.png'),
      );
    }, skip: !runGoldens);
  }
}

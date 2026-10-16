import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loom_design/loom_design.dart';
import 'package:loom_next/features/home/presentation/messenger_shell.dart';
import 'package:loom_next/features/onboarding/presentation/welcome_screen.dart';
import 'package:loom_next/features/media/application/playback_controller.dart';
import 'package:loom_next/features/media/presentation/playback_host.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'support/ux_evidence.dart';
import 'widget_smoke_test.dart' show host;

// Real production widgets with explicit fictional fixtures. No account/network.
void main() {
  setUpAll(loadUxFonts);
  for (final mode in LoomThemeMode.values) {
    for (final size in const [Size(390, 844), Size(1440, 960)]) {
      final platform = size.width < 600 ? 'mobile' : 'desktop';
      testWidgets('English product capture $platform ${mode.name}', (
        tester,
      ) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final theme = switch (mode) {
          LoomThemeMode.light => LoomTheme.light(fontFamily: 'Vazirmatn'),
          LoomThemeMode.dark => LoomTheme.dark(fontFamily: 'Vazirmatn'),
          LoomThemeMode.oled => LoomTheme.oled(fontFamily: 'Vazirmatn'),
        };
        await tester.pumpWidget(
          host(
            const RepaintBoundary(
              child: LoomGlassScope(
                quality: LoomGlassQuality.disabled,
                child: MessengerShell(preview: true),
              ),
            ),
            locale: const Locale('en'),
            theme: theme,
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await captureUxEvidence(tester, '$platform-${mode.name}-chats-en');
        await tester.tap(find.text('Maya Brooks').first);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await captureUxEvidence(
          tester,
          '$platform-${mode.name}-conversation-en',
        );
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
  for (final mode in LoomThemeMode.values) {
    testWidgets('English settings and onboarding capture ${mode.name}', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final theme = switch (mode) {
        LoomThemeMode.light => LoomTheme.light(fontFamily: 'Vazirmatn'),
        LoomThemeMode.dark => LoomTheme.dark(fontFamily: 'Vazirmatn'),
        LoomThemeMode.oled => LoomTheme.oled(fontFamily: 'Vazirmatn'),
      };
      await tester.pumpWidget(
        host(
          const RepaintBoundary(child: MessengerShell(preview: true)),
          theme: theme,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Settings').last);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await captureUxEvidence(tester, 'mobile-${mode.name}-settings-en');
      await tester.pumpWidget(
        host(
          RepaintBoundary(
            child: WelcomeScreen(
              onThemeChanged: (_) {},
              onLocaleChanged: (_) {},
            ),
          ),
          theme: theme,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await captureUxEvidence(tester, 'mobile-${mode.name}-onboarding-en');
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
  testWidgets('Desktop production music surface with mocked playback state', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1440, 960);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final playback = LoomPlaybackController.instance;
    // Visual fixture only: no decoder, audible playback or native integration.
    playback.sourcePath = '/fixture/synthetic-audio.wav';
    playback.title = 'Evening Walk';
    playback.subtitle = 'Iris Lane • Fictional audio';
    playback.music = true;
    playback.playing = true;
    playback.duration = const Duration(minutes: 3, seconds: 24);
    playback.position = const Duration(seconds: 48);
    addTearDown(() {
      playback.sourcePath = null;
      playback.playing = false;
      playback.music = false;
      playback.setExpanded(false);
    });
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        theme: LoomTheme.light(fontFamily: 'Vazirmatn'),
        locale: const Locale('en'),
        supportedLocales: const [Locale('en'), Locale('fa')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        builder: (context, child) => RepaintBoundary(
          child: LoomPlaybackHost(navigatorKey: navigator, child: child!),
        ),
        home: const MessengerShell(preview: true),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
    await captureUxEvidence(tester, 'desktop-light-music-mini-en');
    await tester.tap(find.text('Evening Walk').first);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Music player'), findsOneWidget);
    expect(
      tester
          .getSize(find.byKey(const ValueKey('full-player-transport')))
          .height,
      greaterThan(40),
    );
    expect(tester.takeException(), isNull);
    await captureUxEvidence(tester, 'desktop-light-music-player-en');
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}

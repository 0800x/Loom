import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loom_design/loom_design.dart';
import 'package:loom_next/features/home/presentation/messenger_shell.dart';
import 'package:loom_next/features/media/application/playback_controller.dart';
import 'package:loom_next/features/media/presentation/playback_host.dart';
import 'package:photo_manager/photo_manager.dart';

// Production surfaces with mocked playing state and denied photo permission.
// Does not claim audible playback, device permissions or native media coverage.
void main() {
  for (final locale in const [Locale('en'), Locale('fa')]) {
    for (final mode in LoomThemeMode.values) {
      testWidgets(
        'attachment sheet above music with large text $locale $mode',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = const Size(320, 780);
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          const channel = MethodChannel('com.fluttercandies/photo_manager');
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            (call) async => call.method == 'requestPermissionExtend'
                ? PermissionState.denied.index
                : true,
          );
          addTearDown(
            () => tester.binding.defaultBinaryMessenger
                .setMockMethodCallHandler(channel, null),
          );
          final p = LoomPlaybackController.instance;
          p.sourcePath = '/fixture/music';
          p.title = 'Evening Walk';
          p.subtitle = 'Iris Lane';
          p.music = p.playing = true;
          addTearDown(() {
            p.sourcePath = null;
            p.music = p.playing = false;
            p.setExpanded(false);
          });
          final navigator = GlobalKey<NavigatorState>();
          await tester.pumpWidget(
            MaterialApp(
              navigatorKey: navigator,
              locale: locale,
              supportedLocales: const [Locale('en'), Locale('fa')],
              localizationsDelegates: const [
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              theme: switch (mode) {
                LoomThemeMode.light => LoomTheme.light(),
                LoomThemeMode.dark => LoomTheme.dark(),
                LoomThemeMode.oled => LoomTheme.oled(),
              },
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: const TextScaler.linear(1.5),
                  disableAnimations: true,
                ),
                child: LoomPlaybackHost(navigatorKey: navigator, child: child!),
              ),
              home: const MessengerShell(preview: true),
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 500));
          await tester.tap(find.text('Maya Brooks').first);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 500));
          await tester.tap(find.byIcon(LoomIcons.attach_file_rounded).first);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 500));
          final file = find.text(locale.languageCode == 'fa' ? 'فایل' : 'File');
          expect(file, findsOneWidget);
          await Scrollable.ensureVisible(tester.element(file), alignment: .5);
          await tester.pump();
          expect(file.hitTestable(), findsOneWidget);
          expect(tester.getRect(file).bottom, lessThan(780));
          expect(p.playing, isTrue);
          expect(p.sourcePath, '/fixture/music');
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
        variant: TargetPlatformVariant.only(TargetPlatform.android),
      );
    }
  }
}

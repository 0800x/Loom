import 'package:loom_crypto_bridge/loom_crypto_bridge.dart';
import 'package:loom_design/loom_design.dart';
import 'package:loom_next/features/settings/presentation/settings_detail_screen.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

Widget host(Widget child, LoomThemeMode mode, Locale locale) => MaterialApp(
  theme: switch (mode) {
    LoomThemeMode.light => LoomTheme.light(),
    LoomThemeMode.dark => LoomTheme.dark(),
    LoomThemeMode.oled => LoomTheme.oled(),
  },
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
  home: child,
);

LoomSettingsDetailScreen page(
  LoomSettingsSection section,
  Locale locale, {
  ValueChanged<LoomThemeMode>? onTheme,
}) => LoomSettingsDetailScreen(
  section: section,
  themeMode: LoomThemeMode.dark,
  glassQuality: LoomGlassQuality.high,
  locale: locale,
  localePreference: locale.languageCode,
  onThemeChanged: onTheme ?? (_) {},
  onGlassQualityChanged: (_) {},
  onLocaleChanged: (_) {},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await LoomAppLock.instance.initialize();
    PackageInfo.setMockInitialValues(
      appName: 'Loom',
      packageName: 'app.loom.messenger',
      version: '0.0.9',
      buildNumber: '15',
      buildSignature: '',
    );
  });

  for (final mode in LoomThemeMode.values) {
    for (final locale in const [Locale('en'), Locale('fa')]) {
      for (final section in LoomSettingsSection.values) {
        testWidgets(
          '${section.name} fits ${locale.languageCode} ${mode.name} with large text',
          (tester) async {
            tester.view.physicalSize = const Size(320, 780);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            await tester.pumpWidget(host(page(section, locale), mode, locale));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            await tester.drag(
              find.byType(ListView).first,
              const Offset(0, -1000),
            );
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }

  testWidgets('theme choices still apply immediately', (tester) async {
    LoomThemeMode? selected;
    await tester.pumpWidget(
      host(
        page(
          LoomSettingsSection.appearance,
          const Locale('en'),
          onTheme: (value) => selected = value,
        ),
        LoomThemeMode.dark,
        const Locale('en'),
      ),
    );
    await tester.tap(find.text('Theme'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Light'));
    await tester.pumpAndSettle();
    expect(selected, LoomThemeMode.light);
  });

  testWidgets(
    'incoming notification settings open the native channel controls',
    (tester) async {
      final previousPlatform = debugDefaultTargetPlatformOverride;
      try {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        const channel = MethodChannel('loom/calls');
        final methods = <String>[];
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(channel, (call) async {
          methods.add(call.method);
          return null;
        });
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        await tester.pumpWidget(
          host(
            page(LoomSettingsSection.notifications, const Locale('en')),
            LoomThemeMode.dark,
            const Locale('en'),
          ),
        );
        await tester.tap(find.text('Incoming call notifications'));
        await tester.pumpAndSettle();
        expect(methods, ['openIncomingSettings']);
        expect(find.textContaining('not active yet'), findsNothing);
      } finally {
        // Flutter checks this invariant before addTearDown callbacks run.
        debugDefaultTargetPlatformOverride = previousPlatform;
      }
    },
  );
}

import 'package:loom_design/loom_design.dart';
import 'package:loom_next/app/appearance_preferences.dart';
import 'package:loom_next/features/home/presentation/messenger_shell.dart';
import 'package:loom_next/features/settings/presentation/settings_detail_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'widget_smoke_test.dart' show host;

void main() {
  for (final locale in [const Locale('en'), const Locale('fa')]) {
    testWidgets('large-text search reverses during expansion: $locale', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        host(
          const MediaQuery(
            data: MediaQueryData(
              size: Size(320, 700),
              textScaler: TextScaler.linear(2),
            ),
            child: MessengerShell(preview: true),
          ),
          locale: locale,
        ),
      );
      await tester.pumpAndSettle();
      final open = locale.languageCode == 'fa' ? 'جستجو' : 'Search';
      final close = locale.languageCode == 'fa' ? 'بستن جستجو' : 'Close search';
      await tester.tap(find.byTooltip(open));
      await tester.pump(const Duration(milliseconds: 80));
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.byTooltip(open));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
      await tester.tap(find.byTooltip(close));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets(
    'compact header clears search and opens the real appearance editor',
    (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      LoomThemeMode? requestedTheme;
      await tester.pumpWidget(
        MaterialApp(
          theme: LoomTheme.dark(),
          routes: {
            '/settings/appearance': (_) => LoomSettingsDetailScreen(
              section: LoomSettingsSection.appearance,
              themeMode: LoomThemeMode.dark,
              glassQuality: LoomGlassQuality.disabled,
              locale: const Locale('en'),
              onThemeChanged: (value) => requestedTheme = value,
              onGlassQualityChanged: (_) {},
              onLocaleChanged: (_) {},
            ),
          },
          home: LoomAppearanceScope(
            mode: LoomThemeMode.dark,
            onChanged: (value) => requestedTheme = value,
            child: const MessengerShell(preview: true),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Loom'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      final searchOrigin = tester.getRect(find.byTooltip('Search'));
      await tester.tap(find.byTooltip('Search'));
      await tester.pump();
      final searchTransform = tester.widget<LoomContainerTransform>(
        find.byType(LoomContainerTransform).first,
      );
      expect(searchTransform.origin.size, searchOrigin.size);
      expect(
        searchTransform.destination.width,
        greaterThan(searchOrigin.width),
      );
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'temporary search');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      expect(find.text('Loom'), findsOneWidget);
      await tester.tap(find.byTooltip('Search'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
      await tester.tap(find.byTooltip('Close search'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('More options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Appearance'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Theme'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Light'));
      await tester.pumpAndSettle();
      expect(requestedTheme, LoomThemeMode.light);
      expect(tester.takeException(), isNull);
    },
  );
}

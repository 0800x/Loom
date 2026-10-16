import 'package:loom_design/loom_design.dart';
import 'package:loom_next/app/appearance_preferences.dart';
import 'package:loom_next/app/chat_wallpaper.dart';
import 'package:loom_next/features/settings/presentation/chat_wallpaper_editor.dart';
import 'package:loom_next/features/settings/presentation/settings_detail_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(
  Widget child,
  Locale locale,
  LoomThemeMode mode, {
  Widget Function(BuildContext, Widget)? wrap,
}) => MaterialApp(
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
    child: wrap?.call(context, child!) ?? child!,
  ),
  home: child,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => LoomWallpaperStore.instance.load());
  for (final locale in const [Locale('en'), Locale('fa')]) {
    for (final mode in LoomThemeMode.values) {
      testWidgets(
        'wallpaper editor fits large ${locale.languageCode} text in ${mode.name}',
        (tester) async {
          tester.view.physicalSize = const Size(320, 780);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await tester.pumpWidget(
            _host(const LoomWallpaperEditor(), locale, mode),
          );
          await tester.runAsync(() async {
            await Future<void>.delayed(Duration.zero);
          });
          await tester.pumpAndSettle();
          expect(find.byType(LoomAppearancePreviewMessages), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.drag(find.byType(ListView).first, const Offset(0, -500));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets(
      'layout choice updates real preview and keeps text scale: ${locale.languageCode}',
      (tester) async {
        tester.view.physicalSize = const Size(320, 780);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var density = LoomChatDensity.comfortable;
        await tester.pumpWidget(
          StatefulBuilder(
            builder: (_, refresh) => _host(
              LoomSettingsDetailScreen(
                section: LoomSettingsSection.appearance,
                themeMode: LoomThemeMode.light,
                glassQuality: LoomGlassQuality.high,
                locale: locale,
                onThemeChanged: (_) {},
                onGlassQualityChanged: (_) {},
                onLocaleChanged: (_) {},
              ),
              locale,
              LoomThemeMode.light,
              wrap: (_, child) => LoomAppearanceScope(
                mode: LoomThemeMode.light,
                onChanged: (_) {},
                chatDensity: density,
                onChatDensityChanged: (value) => refresh(() => density = value),
                child: LoomChatLayoutScope(density: density, child: child),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final bubble = find.byType(LoomMessageBubble).first;
        final originalHeight = tester.getSize(bubble).height;
        final row = find.text(
          locale.languageCode == 'fa' ? 'چیدمان گفتگو' : 'Chat layout',
        );
        await tester.scrollUntilVisible(
          row,
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.text(locale.languageCode == 'fa' ? 'فشرده' : 'Compact'),
        );
        await tester.pumpAndSettle();
        expect(density, LoomChatDensity.compact);
        await tester.scrollUntilVisible(
          find.byType(LoomAppearancePreviewMessages),
          -200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        expect(tester.getSize(bubble).height, lessThan(originalHeight));
        expect(MediaQuery.textScalerOf(tester.element(bubble)).scale(16), 24);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('compact interactive bubbles retain a 48-pixel target', (
    tester,
  ) async {
    var replies = 0;
    await tester.pumpWidget(
      _host(
        LoomChatLayoutScope(
          density: LoomChatDensity.compact,
          child: Scaffold(
            body: LoomMessageBubble(
              text: 'Hi',
              time: '12:40',
              mine: false,
              onReply: () => replies++,
            ),
          ),
        ),
        const Locale('en'),
        LoomThemeMode.light,
      ),
    );
    final bubble = find.byType(LoomMessageBubble);
    final target = find.descendant(
      of: bubble,
      matching: find.byType(LoomSwipeToReply),
    );
    expect(tester.getSize(target).height, greaterThanOrEqualTo(48));
    await tester.drag(find.text('Hi'), const Offset(100, 0));
    await tester.pumpAndSettle();
    expect(replies, 1);
  });
}

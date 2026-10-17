import 'package:loom_next/app/appearance_preferences.dart';
import 'package:loom_design/loom_design.dart';
import 'package:loom_next/features/settings/presentation/settings_detail_screen.dart';
import 'package:loom_next/features/nodes/application/node_directory_controller.dart';
import 'package:loom_next/features/onboarding/application/onboarding_controller.dart';
import 'package:loom_next/features/onboarding/presentation/identity_creation_screen.dart';
import 'package:loom_next/features/onboarding/presentation/welcome_screen.dart';
import 'package:loom_next/features/home/presentation/messenger_shell.dart';
import 'package:loom_next/features/messaging/presentation/location_status.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'widget_smoke_test.dart' show host;
import 'support/ux_evidence.dart';

void main() {
  setUpAll(loadUxFonts);
  for (final locale in const [Locale('en'), Locale('fa')]) {
    for (final mode in LoomThemeMode.values) {
      for (final width in [320.0, 1280.0]) {
        testWidgets('appearance ${locale.languageCode} ${mode.name} $width', (
          tester,
        ) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = Size(width, 900);
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final theme = switch (mode) {
            LoomThemeMode.light => LoomTheme.light(fontFamily: 'Vazirmatn'),
            LoomThemeMode.dark => LoomTheme.dark(fontFamily: 'Vazirmatn'),
            LoomThemeMode.oled => LoomTheme.oled(fontFamily: 'Vazirmatn'),
          };
          await tester.pumpWidget(
            host(
              RepaintBoundary(
                child: LoomAppearanceScope(
                  mode: mode,
                  onChanged: (_) {},
                  onAccentChanged: (_) {},
                  onMotionChanged: (_) {},
                  onChatDensityChanged: (_) {},
                  child: LoomSettingsDetailScreen(
                    section: LoomSettingsSection.appearance,
                    themeMode: mode,
                    glassQuality: LoomGlassQuality.high,
                    locale: locale,
                    onThemeChanged: (_) {},
                    onGlassQualityChanged: (_) {},
                    onLocaleChanged: (_) {},
                  ),
                ),
              ),
              theme: theme,
              locale: locale,
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await captureUxEvidence(
            tester,
            'appearance-${locale.languageCode}-${mode.name}-${width.toInt()}',
          );
        });
      }
    }
    testWidgets(
      'setup fits and keeps actions above keyboard ${locale.languageCode}',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(360, 640);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetViewInsets);
        final nodes = LoomNodeDirectoryController();
        final onboarding = LoomOnboardingController(nodes: nodes);
        addTearDown(nodes.dispose);
        addTearDown(onboarding.dispose);
        Widget page(Widget child, {double scale = 1, double keyboard = 0}) =>
            host(
              RepaintBoundary(
                child: LoomNodeDirectoryScope(
                  controller: nodes,
                  child: LoomOnboardingScope(
                    controller: onboarding,
                    child: Builder(
                      builder: (context) => MediaQuery(
                        data: MediaQuery.of(context).copyWith(
                          textScaler: TextScaler.linear(scale),
                          viewInsets: EdgeInsets.only(bottom: keyboard),
                        ),
                        child: child,
                      ),
                    ),
                  ),
                ),
              ),
              locale: locale,
              theme: LoomTheme.dark(fontFamily: 'Vazirmatn'),
            );
        await tester.pumpWidget(
          page(WelcomeScreen(onThemeChanged: (_) {}, onLocaleChanged: (_) {})),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await captureUxEvidence(tester, 'welcome-${locale.languageCode}-360');
        await tester.pumpWidget(page(const IdentityCreationScreen()));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final button = find.widgetWithText(
          FilledButton,
          locale.languageCode == 'fa' ? 'ادامه' : 'Continue',
        );
        expect(tester.getRect(button).bottom, lessThanOrEqualTo(640));
        final scroll = tester.state<ScrollableState>(
          find.byType(Scrollable).first,
        );
        expect(
          scroll.position.maxScrollExtent,
          0,
          reason: 'The ordinary form should fit without scrolling',
        );
        await captureUxEvidence(tester, 'identity-${locale.languageCode}-360');
        await tester.enterText(
          find.byType(TextFormField).first,
          'Maya Brooks · سارا رحیمی',
        );
        tester.view.physicalSize = const Size(320, 780);
        tester.view.viewInsets = const FakeViewPadding(bottom: 280);
        await tester.pumpWidget(
          page(const IdentityCreationScreen(), scale: 1.5, keyboard: 280),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(tester.getRect(button).bottom, lessThanOrEqualTo(500));
        expect(
          find.text(
            locale.languageCode == 'fa'
                ? 'نامی انتخاب کنید که دوستانتان شما را با آن پیدا کنند. مرحلهٔ بعد، پشتیبان‌گیری حساب است.'
                : 'Choose how people find you. Next, we’ll help you back up your account.',
          ),
          findsNothing,
        );
        await captureUxEvidence(
          tester,
          'identity-keyboard-large-${locale.languageCode}-320',
        );
      },
    );
    testWidgets(
      'mobile menu stays bounded above keyboard ${locale.languageCode}',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(320, 780);
        tester.view.viewInsets = const FakeViewPadding(bottom: 280);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetViewInsets);
        await tester.pumpWidget(
          RepaintBoundary(
            child: host(
              Builder(
                builder: (context) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: const TextScaler.linear(1.5)),
                  child: const MessengerShell(preview: true),
                ),
              ),
              locale: locale,
              theme: LoomTheme.dark(fontFamily: 'Vazirmatn'),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Maya Brooks').first);
        await tester.pumpAndSettle();
        await tester.tap(
          find.byTooltip(
            locale.languageCode == 'fa' ? 'منوی گفتگو' : 'Conversation menu',
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final item = find.byType(MenuItemButton).first;
        expect(tester.getRect(item).left, greaterThanOrEqualTo(0));
        expect(tester.getRect(item).right, lessThanOrEqualTo(320));
        expect(tester.getRect(item).top, greaterThanOrEqualTo(0));
        final last = find.byType(MenuItemButton).last;
        await tester.ensureVisible(last);
        await tester.pumpAndSettle();
        expect(tester.getRect(last).bottom, lessThanOrEqualTo(500));
        await captureUxEvidence(
          tester,
          'chat-menu-keyboard-large-${locale.languageCode}-320',
        );
      },
    );
    testWidgets('chat menu real overlay ${locale.languageCode}', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1200, 800);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        RepaintBoundary(
          child: host(
            const MessengerShell(preview: true),
            locale: locale,
            theme: LoomTheme.dark(fontFamily: 'Vazirmatn'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Maya Brooks').first);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byTooltip(
          locale.languageCode == 'fa' ? 'منوی گفتگو' : 'Conversation menu',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(MenuItemButton), findsWidgets);
      expect(tester.takeException(), isNull);
      await captureUxEvidence(tester, 'chat-menu-${locale.languageCode}-1200');
    });
  }
  testWidgets('stale location exposes freshness without capture or playback', (
    tester,
  ) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await tester.pumpWidget(
      host(
        LoomLocationStatus(
          location: {
            'at': now - 90000,
            'until': now + 600000,
            'stopped': false,
          },
          foreground: Colors.black,
        ),
      ),
    );
    expect(find.text('No recent update'), findsOneWidget);
    expect(find.text('Updated 1 min ago'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 30));
    expect(tester.takeException(), isNull);
  });
}

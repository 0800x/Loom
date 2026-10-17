import 'package:loom_design/loom_design.dart';
import 'package:loom_next/features/calls/application/call_session_controller.dart';
import 'package:loom_next/features/home/presentation/messenger_shell.dart';
import 'package:loom_next/features/messaging/application/messaging_session_controller.dart';
import 'package:loom_next/features/nodes/application/node_directory_controller.dart';
import 'package:loom_next/features/nodes/presentation/node_detail_screen.dart';
import 'package:loom_next/features/nodes/presentation/node_selection_screen.dart';
import 'package:loom_next/features/onboarding/application/onboarding_controller.dart';
import 'package:loom_next/features/onboarding/presentation/link_device_screen.dart';
import 'package:loom_next/features/onboarding/presentation/recovery_screen.dart';
import 'package:loom_next/features/onboarding/presentation/restore_identity_screen.dart';
import 'package:loom_next/features/profile/presentation/profile_screen.dart';
import 'package:loom_next/features/settings/presentation/settings_detail_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

Widget host(
  Widget child, {
  ThemeData? theme,
  Locale locale = const Locale('en'),
  Map<String, WidgetBuilder> routes = const {},
}) => MaterialApp(
  theme: theme ?? LoomTheme.light(),
  locale: locale,
  supportedLocales: const [Locale('en'), Locale('fa')],
  localizationsDelegates: const [
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  routes: routes,
  home: child,
);

void usePhoneViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void useDesktopViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1600, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets('Node selection renders non-live state', (tester) async {
    final controller = LoomNodeDirectoryController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      host(
        LoomNodeDirectoryScope(
          controller: controller,
          child: const NodeSelectionScreen(),
        ),
      ),
    );
    await tester.pump();
    expect(
      find.text('Choose where your Loom identity lives'),
      findsOneWidget,
    );
    expect(find.text('Public directory is not configured'), findsOneWidget);
  });

  testWidgets('Node detail without a selection returns to discovery', (
    tester,
  ) async {
    final controller = LoomNodeDirectoryController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      host(
        LoomNodeDirectoryScope(
          controller: controller,
          child: const NodeDetailScreen(),
        ),
      ),
    );
    expect(find.text('Choose a Node'), findsOneWidget);
  });

  testWidgets('Profile preview renders explicit preview identity', (
    tester,
  ) async {
    await tester.pumpWidget(host(const ProfileScreen(preview: true)));
    expect(find.text('Maya Brooks'), findsWidgets);
    expect(find.textContaining('Design preview only'), findsOneWidget);
  });

  testWidgets('Messenger compact shell renders primary navigation', (
    tester,
  ) async {
    usePhoneViewport(tester);
    await tester.pumpWidget(host(const MessengerShell()));
    expect(find.text('Chats'), findsWidgets);
    expect(find.text('People'), findsWidgets);
    expect(find.text('Calls'), findsWidgets);
    expect(find.text('Settings'), findsWidgets);
  });

  testWidgets('Messenger production shell excludes preview fixtures', (
    tester,
  ) async {
    usePhoneViewport(tester);
    await tester.pumpWidget(host(const MessengerShell()));
    expect(find.text('Maya Brooks'), findsNothing);
    expect(find.text('Project Cedar'), findsNothing);
    expect(find.text('No conversations yet.'), findsOneWidget);
  });

  testWidgets('Messenger settings rows open dedicated pages', (tester) async {
    usePhoneViewport(tester);
    final nodes = LoomNodeDirectoryController();
    final onboarding = LoomOnboardingController(nodes: nodes);
    final messaging = LoomMessagingSessionController(onboarding: onboarding);
    final calls = LoomCallSessionController(
      onboarding: onboarding,
      messaging: messaging,
    );
    addTearDown(calls.dispose);
    addTearDown(messaging.dispose);
    addTearDown(onboarding.dispose);
    addTearDown(nodes.dispose);

    await tester.pumpWidget(
      host(
        LoomCallSessionScope(
          controller: calls,
          child: const MessengerShell(),
        ),
        routes: {
          '/settings/privacy': (_) => const Scaffold(
            body: Center(child: Text('Privacy settings route')),
          ),
        },
      ),
    );
    await tester.tap(find.text('Settings').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Privacy'));
    await tester.pumpAndSettle();
    expect(find.text('Privacy settings route'), findsOneWidget);
  });

  testWidgets(
    'Appearance controls change theme and glass without nested sheets',
    (tester) async {
      var selectedTheme = LoomThemeMode.dark;
      var selectedGlass = LoomGlassQuality.high;
      await tester.pumpWidget(
        host(
          LoomSettingsDetailScreen(
            section: LoomSettingsSection.appearance,
            themeMode: selectedTheme,
            glassQuality: selectedGlass,
            locale: const Locale('en'),
            onThemeChanged: (value) => selectedTheme = value,
            onGlassQualityChanged: (value) => selectedGlass = value,
            onLocaleChanged: (_) {},
          ),
        ),
      );
      await tester.tap(find.text('OLED'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Off'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Off'));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      expect(selectedTheme, LoomThemeMode.oled);
      expect(selectedGlass, LoomGlassQuality.disabled);
    },
  );

  testWidgets('Messenger compact shell opens and closes a conversation', (
    tester,
  ) async {
    usePhoneViewport(tester);
    await tester.pumpWidget(host(const MessengerShell(preview: true)));
    await tester.tap(find.text('Maya Brooks').first);
    await tester.pumpAndSettle();
    expect(find.byType(LoomGlassComposer), findsOneWidget);
    expect(find.byIcon(LoomIcons.arrow_back_rounded), findsOneWidget);

    await tester.tap(find.byIcon(LoomIcons.arrow_back_rounded));
    await tester.pumpAndSettle();
    expect(find.text('Chats'), findsWidgets);
  });

  testWidgets('Persian shell establishes RTL labels', (tester) async {
    usePhoneViewport(tester);
    await tester.pumpWidget(
      host(const MessengerShell(), locale: const Locale('fa')),
    );
    expect(find.text('گفتگوها'), findsWidgets);
    expect(
      Directionality.of(tester.element(find.byType(MessengerShell))),
      TextDirection.rtl,
    );
  });

  testWidgets('Desktop shell uses conversation and details panes', (
    tester,
  ) async {
    useDesktopViewport(tester);
    await tester.pumpWidget(host(const MessengerShell(preview: true)));
    expect(find.text('Maya Brooks'), findsWidgets);
    expect(find.text('Verify identity'), findsOneWidget);
    expect(find.byType(LoomGlassComposer), findsOneWidget);
  });

  for (final theme in <ThemeData>[
    LoomTheme.light(),
    LoomTheme.dark(),
    LoomTheme.oled(),
  ]) {
    testWidgets('Messenger shell renders a configured theme', (tester) async {
      usePhoneViewport(tester);
      await tester.pumpWidget(
        host(const MessengerShell(preview: true), theme: theme),
      );
      expect(find.byType(MessengerShell), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Restore identity contains no generated secret', (tester) async {
    final nodes = LoomNodeDirectoryController();
    final onboarding = LoomOnboardingController(nodes: nodes);
    addTearDown(onboarding.dispose);
    addTearDown(nodes.dispose);
    await tester.pumpWidget(
      host(
        LoomNodeDirectoryScope(
          controller: nodes,
          child: LoomOnboardingScope(
            controller: onboarding,
            child: const RestoreIdentityScreen(),
          ),
        ),
      ),
    );
    expect(find.text('Bring your account back'), findsOneWidget);
    expect(find.text('24 recovery words'), findsOneWidget);
    expect(find.text('Encrypted Recovery File'), findsNothing);
    expect(find.text('Recovery QR'), findsNothing);
  });

  testWidgets('Link device uses encrypted QR visual contract', (tester) async {
    final nodes = LoomNodeDirectoryController();
    final onboarding = LoomOnboardingController(nodes: nodes);
    addTearDown(onboarding.dispose);
    addTearDown(nodes.dispose);

    await tester.pumpWidget(
      host(
        LoomNodeDirectoryScope(
          controller: nodes,
          child: LoomOnboardingScope(
            controller: onboarding,
            child: const LinkDeviceScreen(),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Link a new device'), findsOneWidget);
    expect(
      find.textContaining(
        'The QR never contains your password or recovery words in plaintext.',
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining('QR payload intentionally absent'),
      findsNothing,
    );
  });

  testWidgets('Recovery screen exposes no material without an identity', (
    tester,
  ) async {
    final nodes = LoomNodeDirectoryController();
    final onboarding = LoomOnboardingController(nodes: nodes);
    addTearDown(onboarding.dispose);
    addTearDown(nodes.dispose);
    await tester.pumpWidget(
      host(
        LoomNodeDirectoryScope(
          controller: nodes,
          child: LoomOnboardingScope(
            controller: onboarding,
            child: const RecoveryScreen(),
          ),
        ),
      ),
    );
    expect(find.text('Create profile'), findsOneWidget);
    expect(find.textContaining('word01'), findsNothing);
  });
}

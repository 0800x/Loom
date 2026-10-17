import 'package:loom_design/loom_design.dart';
import 'package:loom_next/features/onboarding/presentation/welcome_screen.dart';
import 'package:loom_next/features/onboarding/presentation/onboarding_flow.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final locale in [const Locale('en'), const Locale('fa')]) {
    testWidgets('welcome remains usable on small screen with large text: $locale', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Object? purpose;
      await tester.pumpWidget(MaterialApp(
        theme: LoomTheme.light(), locale: locale,
        supportedLocales: const [Locale('en'), Locale('fa')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate, GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.8), disableAnimations: true),
          child: child!,
        ),
        onGenerateRoute: (settings) {
          if (settings.name != '/nodes') return null;
          purpose = settings.arguments;
          return MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('Server step')));
        },
        home: WelcomeScreen(onThemeChanged: (_) {}, onLocaleChanged: (_) {}),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final start = find.text(locale.languageCode == 'fa' ? 'بزن بریم' : 'Let’s get started');
      await tester.ensureVisible(start);
      await tester.tap(start);
      await tester.pumpAndSettle();
      expect(purpose, LoomNodeSelectionPurpose.register);
      expect(find.text('Server step'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}

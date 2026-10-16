import 'package:loom_design/loom_design.dart';
import 'package:loom_next/app/loom_app.dart';
import 'package:loom_next/features/home/presentation/messenger_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const routes = <String>[
    '/nodes',
    '/node-detail',
    '/identity',
    '/restore',
    '/sign-in',
    '/link-device',
    '/recovery',
    '/recovery-verify',
    '/ready',
    '/messenger',
    '/profile',
    '/profile-qr',
    '/security',
  ];

  testWidgets('Application startup and declared routes build', (tester) async {
    for (final route in routes) {
      await tester.pumpWidget(LoomApp(key: ValueKey(route)));
      await tester.pump();

      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      navigator.pushNamed(route);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(tester.takeException(), isNull, reason: 'Route failed: $route');
    }
  });

  testWidgets(
    'production messenger route keeps glass chrome and a clean list',
    (tester) async {
      await tester.pumpWidget(const LoomApp());
      await tester.pump();

      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      navigator.pushNamed('/messenger');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byType(MessengerShell), findsOneWidget);
      // The patterned backdrop belongs to an open conversation, not the inbox.
      expect(find.byType(LoomChatBackdrop), findsNothing);
      expect(find.byKey(const ValueKey('create-dial-toggle')), findsOneWidget);
      expect(find.byType(LoomGlassSurface), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('production routes never expose design preview fixtures', (
    tester,
  ) async {
    await tester.pumpWidget(const LoomApp());
    await tester.pump();

    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.pushNamed('/profile');
    await tester.pumpAndSettle();

    expect(find.text('Maya Brooks'), findsNothing);
    expect(find.textContaining('Design preview only'), findsNothing);

    navigator.pushReplacementNamed('/messenger');
    await tester.pumpAndSettle();

    expect(find.text('Maya Brooks'), findsNothing);
    expect(find.textContaining('Design preview only'), findsNothing);

    navigator.pushReplacementNamed('/settings/privacy');
    await tester.pumpAndSettle();

    expect(find.text('Alice'), findsNothing);
    expect(find.textContaining('Design preview only'), findsNothing);
  });
}

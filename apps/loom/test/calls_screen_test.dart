import 'package:loom_design/loom_design.dart';
import 'package:loom_next/features/calls/application/call_session_controller.dart';
import 'package:loom_next/features/calls/presentation/calls_screen.dart';
import 'package:loom_next/features/messaging/application/messaging_session_controller.dart';
import 'package:loom_next/features/nodes/application/node_directory_controller.dart';
import 'package:loom_next/features/onboarding/application/onboarding_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('calls screen has honest empty state without preview data', (
    tester,
  ) async {
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
      LoomCallSessionScope(
        controller: calls,
        child: MaterialApp(
          theme: LoomTheme.light(),
          home: const LoomCallsScreen(),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('No call history yet'), findsOneWidget);
    expect(find.text('All'), findsOneWidget);
    expect(find.text('Missed'), findsOneWidget);
    expect(find.text('Maya Brooks'), findsNothing);
    expect(find.text('Ethan Cole'), findsNothing);
  });
}

import 'package:loom_next/features/messaging/presentation/messaging_sync_heartbeat.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('resuming the app immediately wakes messaging sync', (
    tester,
  ) async {
    var calls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: LoomMessagingSyncHeartbeat(
          interval: const Duration(hours: 1),
          shouldSync: () => true,
          synchronize: () async {
            calls++;
          },
          child: const SizedBox(),
        ),
      ),
    );
    expect(calls, 0);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(calls, 0);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(calls, 1);
  });
}

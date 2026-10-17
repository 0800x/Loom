import 'dart:async';

import 'package:loom_next/features/messaging/presentation/messaging_sync_heartbeat.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('heartbeat syncs only when enabled and never overlaps',
      (tester) async {
    var enabled = false;
    var calls = 0;
    var concurrent = 0;
    var maxConcurrent = 0;
    final completions = <Completer<void>>[];

    await tester.pumpWidget(
      MaterialApp(
        home: LoomMessagingSyncHeartbeat(
          interval: const Duration(milliseconds: 100),
          shouldSync: () => enabled,
          synchronize: () {
            calls++;
            concurrent++;
            if (concurrent > maxConcurrent) maxConcurrent = concurrent;
            final completer = Completer<void>();
            completions.add(completer);
            return completer.future.whenComplete(() => concurrent--);
          },
          child: const SizedBox(),
        ),
      ),
    );

    await tester.pump(const Duration(milliseconds: 250));
    expect(calls, 0);

    enabled = true;
    await tester.pump(const Duration(milliseconds: 120));
    expect(calls, 1);
    await tester.pump(const Duration(milliseconds: 300));
    expect(calls, 1, reason: 'a slow sync must not overlap with another tick');
    expect(maxConcurrent, 1);

    completions.single.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(calls, 2);
    expect(maxConcurrent, 1);

    completions.last.complete();
    await tester.pump();
  });
}

import 'dart:async';
import 'dart:io';
import 'package:loom_next/features/media/application/voice_draft_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:loom_next/features/media/presentation/hold_record_action.dart';

class Backend implements VoiceRecorderBackend {
  final permissionResult = Completer<bool>();
  int starts = 0, cancels = 0;
  @override
  Future<bool> permission() => permissionResult.future;
  @override
  Future<void> start() async {
    starts++;
  }

  @override
  Stream<double> get amplitudes => const Stream.empty();
  @override
  Future<File?> stop() async => null;
  @override
  Future<void> cancel() async {
    cancels++;
  }

  @override
  Future<void> dispose() async {}
}

void main() {
  testWidgets('hold survives the transition from microphone to recording UI', (
    tester,
  ) async {
    var started = false, ended = false, moved = false;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) => Center(
            child: LoomHoldRecordAction(
              onStart: (_) => setState(() => started = true),
              onMove: (_) => moved = true,
              onEnd: (_) => ended = true,
              onCancel: () {},
              child: SizedBox.square(
                dimension: 48,
                child: Icon(started ? Icons.stop : Icons.mic),
              ),
            ),
          ),
        ),
      ),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(LoomHoldRecordAction)),
    );
    await tester.pump(const Duration(milliseconds: 210));
    expect(started, true);
    await gesture.moveBy(const Offset(0, -80));
    await tester.pump();
    await gesture.up();
    expect(moved, true);
    expect(ended, true);
    expect(tester.takeException(), isNull);
  });
  test(
    'release before permission resolves never starts a late recording',
    () async {
      final b = Backend();
      final c = VoiceDraftController(b);
      final start = c.start();
      await Future<void>.delayed(Duration.zero);
      final release = c.release();
      b.permissionResult.complete(true);
      await start;
      await release;
      expect(b.starts, 0);
      expect(c.phase, VoicePhase.idle);
      c.dispose();
    },
  );
  test(
    'lock requested during camera initialization survives finger release',
    () async {
      final b = Backend();
      final c = VoiceDraftController(
        b,
        maxDuration: const Duration(seconds: 60),
      );
      final start = c.start();
      c.lock();
      await c.release();
      b.permissionResult.complete(true);
      await start;
      expect(b.starts, 1);
      expect(c.phase, VoicePhase.locked);
      await c.cancel();
      expect(c.phase, VoicePhase.idle);
      c.dispose();
    },
  );
}

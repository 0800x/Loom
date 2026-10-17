import 'package:loom_calls/loom_calls.dart';
import 'package:loom_design/loom_design.dart';
import 'package:loom_models/loom_models.dart';
import 'package:loom_next/features/calls/presentation/active_call_screen.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'widget_smoke_test.dart' show host;

class _UnusedApi implements LoomCallApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected network call');
}

class _UnusedSignaling implements LoomCallSignalingConnection {
  @override
  Future<void> dispose() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected signaling');
}

class _Engine extends LoomCallEngine {
  _Engine(this.snapshot)
    : super(
        api: _UnusedApi(),
        signaling: _UnusedSignaling(),
        localIdentityId: 'self',
      );
  LoomCallSnapshot snapshot;
  @override
  LoomCallSnapshot get state => snapshot;
  void finish() {
    snapshot = snapshot.copyWith(
      lifecycle: LoomCallLifecycle.ended,
      endedAt: DateTime.now().toUtc(),
    );
    notifyListeners();
  }
}

void main() {
  for (final kind in [LoomCallKind.audio, LoomCallKind.video]) {
    testWidgets(
      'Persian $kind controls fit a narrow phone in light app theme',
      (tester) async {
        tester.view.physicalSize = const Size(320, 740);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final engine = _Engine(
          LoomCallSnapshot(
            kind: kind,
            lifecycle: LoomCallLifecycle.connected,
          ),
        );
        addTearDown(engine.dispose);
        await tester.pumpWidget(
          host(
            LoomGlassScope(
              quality: LoomGlassQuality.disabled,
              child: MediaQuery(
                data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
                child: LoomActiveCallScreen(
                  engine: engine,
                  peerLabel: 'نام مخاطب برای آزمایش چیدمان',
                ),
              ),
            ),
            locale: const Locale('fa'),
          ),
        );
        await tester.pump(const Duration(milliseconds: 400));
        expect(tester.takeException(), isNull);
        expect(find.byTooltip('پایان تماس'), findsOneWidget);
        expect(find.byTooltip('قطع تصویر'), findsNothing);
        if (kind == LoomCallKind.audio) {
          expect(find.byIcon(LoomIcons.cameraswitch_rounded), findsNothing);
        }
        final buttonContext = tester.element(find.byTooltip('پایان تماس'));
        expect(Theme.of(buttonContext).brightness, Brightness.dark);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'ending a video call always reveals Close after hiding controls',
    (tester) async {
      final engine = _Engine(
        const LoomCallSnapshot(
          kind: LoomCallKind.video,
          lifecycle: LoomCallLifecycle.connected,
        ),
      );
      addTearDown(engine.dispose);
      await tester.pumpWidget(
        host(
          LoomGlassScope(
            quality: LoomGlassQuality.disabled,
            child: LoomActiveCallScreen(engine: engine, peerLabel: 'Alice'),
          ),
        ),
      );
      await tester.tapAt(const Offset(400, 350));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byTooltip('End call').hitTestable(), findsNothing);
      engine.finish();
      await tester.pumpAndSettle();
      expect(find.text('Close').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

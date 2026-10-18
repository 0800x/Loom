import 'dart:ui';

import 'package:loom_design/loom_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'automatic glass degrades on sustained raster cost and recovers with hysteresis',
    (tester) async {
      LoomGlassQuality? observed;
      await tester.pumpWidget(
        LoomGlassScope(
          quality: LoomGlassQuality.high,
          child: MaterialApp(
            home: Builder(
              builder: (context) {
                observed = LoomGlassScope.qualityOf(context);
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      void report(int cost) =>
          tester.binding.platformDispatcher.onReportTimings!(
            List.generate(
              60,
              (_) => FrameTiming(
                vsyncStart: 0,
                buildStart: 0,
                buildFinish: 1000,
                rasterStart: 1000,
                rasterFinish: 1000 + cost,
                rasterFinishWallTime: 1000 + cost,
              ),
            ),
          );
      expect(observed, LoomGlassQuality.high);
      report(40000);
      await tester.pump();
      expect(observed, LoomGlassQuality.reduced);
      for (var i = 0; i < 7; i++) {
        report(1000);
        await tester.pump();
      }
      expect(observed, LoomGlassQuality.reduced);
      report(1000);
      await tester.pump();
      expect(observed, LoomGlassQuality.high);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      report(40000);
      await tester.pump();
      expect(observed, LoomGlassQuality.high);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    },
  );
}

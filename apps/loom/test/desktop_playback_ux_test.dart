import 'package:loom_design/loom_design.dart';
import 'package:loom_next/features/media/application/playback_controller.dart';
import 'package:loom_next/features/media/presentation/playback_host.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'Windows player fits desktop resize and retains gain across reopen',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1200, 800);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final player = LoomPlaybackController.instance;
      player.sourcePath = '/fixture/song';
      player.sourceId = 'fixture';
      player.title = 'Desktop track';
      player.subtitle = 'Artist';
      player.music = true;
      await player.volume.set(35);
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          theme: LoomTheme.dark(),
          navigatorKey: navigator,
          builder: (_, child) =>
              LoomPlaybackHost(navigatorKey: navigator, child: child!),
          home: const Scaffold(body: Text('Chat draft remains')),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Desktop track'));
      await tester.pumpAndSettle();
      expect(find.text('Music player'), findsOneWidget);
      expect(find.text('Up next'), findsOneWidget);
      expect(find.text('35%'), findsOneWidget);
      await tester.tap(find.byTooltip('Mute'));
      await tester.pumpAndSettle();
      expect(player.volume.muted, isTrue);
      await tester.tap(find.byTooltip('Unmute'));
      await tester.pumpAndSettle();
      expect(player.volume.value, 35);
      final sliders = find.byType(Slider);
      await tester.drag(sliders.last, const Offset(40, 0));
      await tester.pumpAndSettle();
      expect(player.volume.value, greaterThan(35));
      final retainedGain = player.volume.value;
      tester.view.physicalSize = const Size(480, 480);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      tester.view.physicalSize = const Size(1200, 800);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Desktop track'));
      await tester.pumpAndSettle();
      expect(player.volume.value, retainedGain);
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      await player.close();
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}

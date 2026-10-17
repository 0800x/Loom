import 'package:loom_design/loom_design.dart';
import 'package:loom_next/features/media/application/playback_controller.dart';
import 'package:loom_next/features/media/presentation/playback_host.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'timeline ticks rebuild progress only and preserve miniplayer controls',
    (tester) async {
      final playback = LoomPlaybackController.instance;
      playback.sourcePath = '/fixture/music';
      playback.sourceId = 'fixture';
      playback.title = 'Playing track';
      playback.music = true;
      playback.duration = const Duration(minutes: 4);
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          theme: LoomTheme.light(),
          navigatorKey: navigator,
          builder: (_, child) =>
              LoomPlaybackHost(navigatorKey: navigator, child: child!),
          home: const Scaffold(body: Text('Chat')),
        ),
      );
      await tester.pumpAndSettle();
      final title = tester.widget(find.text('Playing track'));
      for (var tick = 1; tick <= 100; tick++) {
        playback.position = Duration(milliseconds: tick * 100);
        await tester.pump();
        expect(
          identical(tester.widget(find.text('Playing track')), title),
          isTrue,
          reason:
              'Progress must not reconstruct the title/artwork/transport subtree',
        );
      }
      expect(find.textContaining('0:10'), findsOneWidget);
      await playback.close();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

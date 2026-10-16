import 'package:loom_next/features/media/application/playback_controller.dart';
import 'package:loom_next/features/media/presentation/playback_host.dart';
import 'package:loom_design/loom_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'music mini player opens queue and playlists without losing chat state',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final p = LoomPlaybackController.instance;
      p.sourcePath = '/test/song';
      p.sourceId = 'chat:song';
      p.title = 'A track';
      p.subtitle = 'An artist';
      p.music = true;
      final navigator = GlobalKey<NavigatorState>();
      final input = TextEditingController(text: 'Unsent draft');
      await tester.pumpWidget(
        MaterialApp(
          theme: LoomTheme.light(),
          navigatorKey: navigator,
          builder: (context, child) =>
              LoomPlaybackHost(navigatorKey: navigator, child: child!),
          home: Scaffold(body: TextField(controller: input)),
        ),
      );
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('A track'), findsOneWidget);
      expect(find.text('Unsent draft'), findsOneWidget);
      await tester.tap(find.text('A track'));
      await tester.pumpAndSettle();
      expect(find.text('Queue · 0'), findsOneWidget);
      expect(find.text('A track'), findsOneWidget);
      final transport = find.byKey(const ValueKey('full-player-transport'));
      expect(transport, findsOneWidget);
      expect(tester.getRect(transport).bottom, lessThan(844));
      tester.view.physicalSize = const Size(320, 568);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(tester.getRect(transport).bottom, lessThan(568));
      tester.view.physicalSize = const Size(390, 844);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Queue · 0'));
      await tester.pumpAndSettle();
      expect(find.text('Queue'), findsOneWidget);
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(find.text('Playlists'), findsOneWidget);
      expect(tester.takeException(), isNull);
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      await p.close();
      await tester.pumpAndSettle();
      expect(find.text('Unsent draft'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      input.dispose();
    },
  );
}

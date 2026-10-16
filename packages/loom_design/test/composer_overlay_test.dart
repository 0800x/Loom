import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loom_design/loom_design.dart';

void main() {
  for (final direction in TextDirection.values) {
    for (final entry in {'light': LoomTheme.light(), 'dark': LoomTheme.dark(), 'oled': LoomTheme.oled()}.entries) {
      final theme = entry.value;
      testWidgets('history continues under composer $direction ${entry.key}', (tester) async {
        final height = ValueNotifier<double>(72);
        addTearDown(height.dispose);
        final viewport = GlobalKey();
        final history = GlobalKey();
        final footer = GlobalKey();
        final latest = GlobalKey();
        Future<void> show(double availableHeight) async {
          await tester.pumpWidget(MaterialApp(
            theme: theme,
            home: Scaffold(body: Directionality(
              textDirection: direction,
              child: Align(
                alignment: Alignment.topCenter,
                child: SizedBox(
                  key: viewport,
                  width: 390,
                  height: availableHeight,
                  child: LoomComposerOverlay(
                    historyBuilder: (context, extent) => ListView.builder(
                      key: history,
                      reverse: true,
                      padding: EdgeInsets.only(bottom: extent + 12),
                      itemCount: 30,
                      itemBuilder: (context, index) => SizedBox(
                        key: index == 0 ? latest : null,
                        height: 40,
                        child: Text('Message $index'),
                      ),
                    ),
                    composer: ValueListenableBuilder<double>(
                      valueListenable: height,
                      builder: (context, value, child) => SizedBox(
                        key: footer,
                        height: value,
                        child: const ColoredBox(color: Color(0x88111318)),
                      ),
                    ),
                  ),
                ),
              ),
            )),
          ));
          await tester.pumpAndSettle();
        }
        void verify() {
          expect(tester.getRect(find.byKey(history)).bottom, tester.getRect(find.byKey(viewport)).bottom);
          expect(tester.getRect(find.byKey(footer)).bottom, tester.getRect(find.byKey(viewport)).bottom);
          expect(tester.getRect(find.byKey(latest)).bottom,
              lessThanOrEqualTo(tester.getRect(find.byKey(footer)).top - 11));
          expect(tester.takeException(), isNull);
        }
        await show(600);
        verify();
        // Reply, multiline draft or recording preview expands the overlay.
        height.value = 160;
        await tester.pumpAndSettle();
        verify();
        // Keyboard/player reduces available viewport, not the history overlay.
        await show(300);
        verify();
        height.value = 72;
        await tester.pumpAndSettle();
        verify();
      });
    }
  }
}

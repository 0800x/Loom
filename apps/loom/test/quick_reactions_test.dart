import 'package:loom_design/loom_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget host(Widget child) => MaterialApp(
  theme: LoomTheme.dark(),
  home: Scaffold(body: Center(child: child)),
);

void main() {
  testWidgets('double tap reports two and bursts the heart', (tester) async {
    final taps = <int>[];
    await tester.pumpWidget(
      host(
        LoomMessageBubble(
          text: 'body',
          time: '12:00',
          mine: false,
          onActions: () {},
          onQuickTaps: taps.add,
          quickReactionEmoji: (count) => count >= 3 ? '👍' : '❤️',
        ),
      ),
    );
    await tester.tap(find.text('body'));
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tap(find.text('body'));
    // The double-tap window is 300ms; step past it without settling the
    // 700ms burst so the test stays deterministic.
    await tester.pump(const Duration(milliseconds: 340));
    expect(taps, [2]);
    expect(find.text('❤️'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('❤️'), findsNothing);
  });

  testWidgets('triple tap reports three immediately', (tester) async {
    final taps = <int>[];
    await tester.pumpWidget(
      host(
        LoomMessageBubble(
          text: 'body',
          time: '12:00',
          mine: false,
          onActions: () {},
          onQuickTaps: taps.add,
          quickReactionEmoji: (count) => count >= 3 ? '👍' : '❤️',
        ),
      ),
    );
    for (var i = 0; i < 3; i++) {
      await tester.tap(find.text('body'));
      await tester.pump(const Duration(milliseconds: 80));
    }
    expect(taps, [3]);
    expect(find.text('👍'), findsOneWidget);
    await tester.pumpAndSettle();
  });

  testWidgets('a slow single tap reports nothing', (tester) async {
    final taps = <int>[];
    await tester.pumpWidget(
      host(
        LoomMessageBubble(
          text: 'body',
          time: '12:00',
          mine: false,
          onActions: () {},
          onQuickTaps: taps.add,
          quickReactionEmoji: (count) => '❤️',
        ),
      ),
    );
    await tester.tap(find.text('body'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(taps, isEmpty);
  });

  testWidgets('long-press actions still work alongside quick taps', (
    tester,
  ) async {
    var actions = 0;
    final taps = <int>[];
    await tester.pumpWidget(
      host(
        LoomMessageBubble(
          text: 'body',
          time: '12:00',
          mine: false,
          onActions: () => actions++,
          onQuickTaps: taps.add,
          quickReactionEmoji: (count) => '❤️',
        ),
      ),
    );
    await tester.longPress(find.text('body'));
    await tester.pumpAndSettle();
    expect(actions, 1);
    expect(taps, isEmpty);
  });
}

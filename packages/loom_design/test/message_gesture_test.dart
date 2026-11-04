import 'package:loom_design/loom_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget surface(TextDirection direction, Widget child) => MaterialApp(
  theme: LoomTheme.dark(),
  home: Scaffold(
    body: Directionality(
      textDirection: direction,
      child: Center(child: child),
    ),
  ),
);

void main() {
  for (final direction in TextDirection.values) {
    final sign = direction == TextDirection.rtl ? -1.0 : 1.0;
    testWidgets('$direction reply counts total displacement and fires once', (
      tester,
    ) async {
      var replies = 0;
      await tester.pumpWidget(
        surface(
          direction,
          LoomSwipeToReply(
            onReply: () => replies++,
            child: const SizedBox(width: 200, height: 80),
          ),
        ),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(LoomSwipeToReply)),
      );
      await gesture.moveBy(Offset(60 * sign, 0));
      await tester.pump();
      expect(replies, 0);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(replies, 1);
      final moved = tester.widget<AnimatedContainer>(
        find.byType(AnimatedContainer),
      );
      expect(moved.transform!.getTranslation().x, 0);
    });
    testWidgets('$direction small, reversed and vertical drags do not reply', (
      tester,
    ) async {
      var replies = 0;
      await tester.pumpWidget(
        surface(
          direction,
          LoomSwipeToReply(
            onReply: () => replies++,
            child: const SizedBox(width: 200, height: 80),
          ),
        ),
      );
      for (final distance in [
        Offset(30 * sign, 0),
        Offset(-70 * sign, 0),
        const Offset(0, 80),
      ]) {
        final gesture = await tester.startGesture(
          tester.getCenter(find.byType(LoomSwipeToReply)),
        );
        await gesture.moveBy(distance);
        await gesture.up();
        await tester.pumpAndSettle();
      }
      expect(replies, 0);
    });
    testWidgets('$direction inner audio seek wins the reply arena', (
      tester,
    ) async {
      var replies = 0, seeks = 0;
      await tester.pumpWidget(
        surface(
          direction,
          LoomSwipeToReply(
            onReply: () => replies++,
            child: GestureDetector(
              // Match the production seek track, including its transparent
              // padding. A bare SizedBox is not otherwise a hit-test target.
              behavior: HitTestBehavior.opaque,
              onHorizontalDragStart: (_) {},
              onHorizontalDragUpdate: (_) => seeks++,
              child: const SizedBox(width: 200, height: 80),
            ),
          ),
        ),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(LoomSwipeToReply)),
      );
      // The first move resolves the arena and starts the drag; a subsequent
      // move delivers the seek update, as continuous pointer movement does.
      await gesture.moveBy(Offset(40 * sign, 0));
      await tester.pump();
      await gesture.moveBy(Offset(40 * sign, 0));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(seeks, greaterThan(0));
      expect(replies, 0);
    });
  }
  testWidgets('RTL keeps outgoing messages physically right', (tester) async {
    await tester.pumpWidget(
      surface(
        TextDirection.rtl,
        const SizedBox(
          width: 400,
          child: LoomMessageBubble(text: 'سلام', time: '12:00', mine: true),
        ),
      ),
    );
    expect(
      tester.getCenter(find.text('سلام')).dx,
      greaterThan(tester.getCenter(find.byType(LoomMessageBubble)).dx),
    );
  });
}

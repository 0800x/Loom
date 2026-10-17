import 'package:loom_design/loom_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget host(Widget child, TextDirection direction) => MaterialApp(
  theme: LoomTheme.dark(),
  home: Directionality(
    textDirection: direction,
    child: Scaffold(body: child),
  ),
);
void main() {
  for (final direction in TextDirection.values) {
    for (final withActions in [false, true]) {
      testWidgets(
        'swipe replies once and returns bubble in $direction (actions=$withActions)',
        (tester) async {
          var replies = 0;
          await tester.pumpWidget(
            host(
              LoomMessageBubble(
                text: 'body',
                time: '12:00',
                mine: false,
                onReply: () => replies++,
                onActions: withActions ? () {} : null,
              ),
              direction,
            ),
          );
          final offset = direction == TextDirection.ltr
              ? const Offset(90, 0)
              : const Offset(-90, 0);
          await tester.drag(find.text('body'), offset);
          await tester.pumpAndSettle();
          expect(replies, 1);
          expect(find.text('body'), findsOneWidget);
          expect(find.byType(SelectableText), findsNothing);
          await tester.drag(find.text('body'), -offset);
          await tester.pumpAndSettle();
          expect(replies, 1);
        },
      );
    }
    testWidgets('short or vertical motion does not reply in $direction', (
      tester,
    ) async {
      var replies = 0;
      await tester.pumpWidget(
        host(
          ListView(
            children: [
              LoomMessageBubble(
                text: 'body',
                time: '12:00',
                mine: false,
                onReply: () => replies++,
              ),
              const SizedBox(height: 1800),
            ],
          ),
          direction,
        ),
      );
      await tester.drag(
        find.text('body'),
        Offset(direction == TextDirection.ltr ? 20 : -20, 0),
      );
      await tester.pumpAndSettle();
      expect(replies, 0);
      await tester.drag(find.text('body'), const Offset(0, -120));
      await tester.pumpAndSettle();
      expect(replies, 0);
    });
  }
  testWidgets('quote has author and route uses an icon without repeated text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      host(
        LoomMessageBubble(
          text: 'reply',
          time: '12:00',
          mine: true,
          quotedText: 'original',
          quotedAuthor: 'Alice',
          transportLabel: 'Nearby',
          delivery: LoomDeliveryState.read,
          deliveryLabel: 'Read',
          onActions: () {},
        ),
        TextDirection.ltr,
      ),
    );
    expect(find.text('original'), findsOneWidget);
    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('Nearby'), findsNothing);
    expect(find.byTooltip('Nearby'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

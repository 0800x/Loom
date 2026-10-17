import 'package:loom_next/features/home/presentation/swipe_navigation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget host(Widget child, TextDirection direction) => MaterialApp(
  home: Directionality(
    textDirection: direction,
    child: Scaffold(body: child),
  ),
);
void main() {
  for (final direction in TextDirection.values) {
    final forward = direction == TextDirection.ltr ? -1.0 : 1.0;
    testWidgets(
      'section gestures move once, mirror, ignore short and vertical: $direction',
      (tester) async {
        var next = 0;
        var previous = 0;
        await tester.pumpWidget(
          host(
            LoomSectionSwipe(
              onNext: () => next++,
              onPrevious: () => previous++,
              child: ListView(
                children: const [
                  SizedBox(height: 200, child: Center(child: Text('target'))),
                  SizedBox(height: 2000),
                ],
              ),
            ),
            direction,
          ),
        );
        await tester.drag(find.text('target'), Offset(120 * forward, 0));
        await tester.pumpAndSettle();
        expect(next, 1);
        await tester.drag(find.text('target'), Offset(-120 * forward, 0));
        await tester.pumpAndSettle();
        expect(previous, 1);
        await tester.drag(find.text('target'), Offset(20 * forward, 0));
        await tester.drag(find.text('target'), const Offset(0, -90));
        await tester.pumpAndSettle();
        expect(next, 1);
        expect(previous, 1);
      },
    );
    testWidgets(
      'folder pager consumes swipe before handing off its last edge: $direction',
      (tester) async {
        final controller = PageController();
        addTearDown(controller.dispose);
        var next = 0;
        var folder = 0;
        await tester.pumpWidget(
          host(
            LoomFolderSwipeBoundary(
              onNext: () => next++,
              child: PageView(
                controller: controller,
                physics: const ClampingScrollPhysics(),
                onPageChanged: (value) => folder = value,
                children: const [
                  Center(child: Text('all')),
                  Center(child: Text('personal')),
                ],
              ),
            ),
            direction,
          ),
        );
        await tester.drag(find.text('all'), Offset(600 * forward, 0));
        await tester.pumpAndSettle();
        expect(folder, 1);
        expect(next, 0);
        await tester.drag(find.text('personal'), Offset(180 * forward, 0));
        await tester.pumpAndSettle();
        expect(next, 1);
        await tester.drag(find.text('personal'), Offset(-600 * forward, 0));
        await tester.pumpAndSettle();
        expect(folder, 0);
        expect(next, 1);
      },
    );
    testWidgets('conversation disables section swipes: $direction', (
      tester,
    ) async {
      var next = 0;
      await tester.pumpWidget(
        host(
          LoomSectionSwipe(
            enabled: false,
            onNext: () => next++,
            child: const Center(child: Text('conversation')),
          ),
          direction,
        ),
      );
      await tester.drag(find.text('conversation'), Offset(180 * forward, 0));
      await tester.pumpAndSettle();
      expect(next, 0);
    });
  }
}

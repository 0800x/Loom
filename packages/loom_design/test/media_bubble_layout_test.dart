import 'package:loom_design/loom_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final width in [320.0, 390.0]) {
    for (final direction in [TextDirection.ltr, TextDirection.rtl]) {
      testWidgets('media stays inside $width viewport in $direction', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 760);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            theme: LoomTheme.dark(),
            home: LoomGlassScope(
              quality: LoomGlassQuality.disabled,
              child: Directionality(
                textDirection: direction,
                child: const Scaffold(
                  body: Padding(
                    padding: EdgeInsets.all(12),
                    child: LoomMessageBubble(
                      text: '',
                      time: '3:36 PM',
                      mine: true,
                      presentation: LoomMessagePresentation.photo,
                      delivery: LoomDeliveryState.sent,
                      deliveryLabel: 'Sent',
                      content: AspectRatio(
                        aspectRatio: 1.3,
                        child: ColoredBox(
                          key: ValueKey('photo-content'),
                          color: Colors.blue,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        final media = tester.getRect(
          find.byKey(const ValueKey('photo-content')),
        );
        final stamp = tester.getRect(find.text('3:36 PM'));
        expect(media.left, greaterThanOrEqualTo(0));
        expect(media.right, lessThanOrEqualTo(width));
        expect(media.contains(stamp.center), isTrue);
        expect(find.byIcon(LoomIcons.check_rounded), findsOneWidget);
        expect(find.byIcon(LoomIcons.done_all_rounded), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
  }
  testWidgets('caption and live location metadata use a separate footer', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: LoomTheme.light(),
        home: const Scaffold(
          body: LoomMessageBubble(
            text: 'Caption',
            time: '12:30',
            mine: false,
            presentation: LoomMessagePresentation.liveLocation,
            content: SizedBox(
              width: 260,
              height: 190,
              key: ValueKey('map-content'),
            ),
          ),
        ),
      ),
    );
    final map = tester.getRect(find.byKey(const ValueKey('map-content')));
    final caption = tester.getRect(find.text('Caption'));
    final stamp = tester.getRect(find.text('12:30'));
    expect(caption.top, greaterThanOrEqualTo(map.bottom));
    expect(stamp.top, greaterThanOrEqualTo(caption.bottom));
    expect(tester.takeException(), isNull);
  });
}

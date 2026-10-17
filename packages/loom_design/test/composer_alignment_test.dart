import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loom_design/loom_design.dart';

void main() {
  for (final (name, theme) in [('light', LoomTheme.light()), ('dark', LoomTheme.dark()), ('oled', LoomTheme.oled())]) {
    for (final direction in TextDirection.values) {
      testWidgets('composer input and send button align in $direction / $name', (tester) async {
        tester.view.physicalSize = const Size(320, 700);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final controller = TextEditingController(text: 'سلام');
        addTearDown(controller.dispose);
        await tester.pumpWidget(MaterialApp(theme: theme, home: Directionality(
          textDirection: direction,
          child: Scaffold(body: Align(alignment: Alignment.bottomCenter,
            child: LoomGlassComposer(controller: controller,
              hintText: 'پیام', attachTooltip: 'پیوست', voiceTooltip: 'صدا', sendTooltip: 'ارسال',
              onSend: () {}, onAttach: () {},
            ),
          )),
        )));
        await tester.pump();
        expect(tester.takeException(), isNull);
        final field = tester.widget<TextField>(find.byType(TextField));
        expect(field.textAlignVertical, TextAlignVertical.center);
        final input = tester.getRect(find.byType(TextField));
        final send = tester.getRect(find.byTooltip('ارسال'));
        expect((input.center.dy - send.center.dy).abs(), lessThanOrEqualTo(2));
      });
    }
  }
  test('route toolbar does not paint a separate rectangular surface', () {
    final bar = LoomGlassAppBar(title: const Text('Contacts'));
    expect(bar.flexibleSpace, isNull);
    expect(bar.backgroundColor, Colors.transparent);
    expect(bar.scrolledUnderElevation, 0);
  });
}

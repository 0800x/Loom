import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loom_design/loom_design.dart';

void main() {
  for (final direction in TextDirection.values) {
    testWidgets('chat transition uses the avatar bounds in $direction',
        (tester) async {
      Rect? origin;
      await tester.pumpWidget(MaterialApp(
        theme: LoomTheme.light(),
        home: Directionality(
            textDirection: direction,
            child: Scaffold(
              body: SizedBox(
                  width: 320,
                  child: LoomChatRow(
                    name: 'Alice',
                    preview: 'Hello',
                    time: '',
                    draftLabel: 'Draft',
                    typingLabel: 'Typing',
                    avatar: const SizedBox(width: 48, height: 48),
                    onTapWithOrigin: (value) => origin = value,
                  )),
            )),
      ));
      await tester.tap(find.text('Alice'));
      expect(origin, isNotNull);
      expect(origin!.size, const Size(48, 48));
      expect(origin!.width,
          lessThan(tester.getSize(find.byType(LoomChatRow)).width));
    });
  }
}

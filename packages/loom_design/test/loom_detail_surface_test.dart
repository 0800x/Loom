import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loom_design/loom_design.dart';

void main() {
  for (final (name, theme) in [
    ('light', LoomTheme.light()),
    ('dark', LoomTheme.dark()),
    ('oled', LoomTheme.oled()),
  ]) {
    for (final direction in TextDirection.values) {
      testWidgets(
        'detail row remains usable at 320px, large text, $name, $direction',
        (tester) async {
          tester.view.physicalSize = const Size(320, 700);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          var selected = false;
          final label = direction == TextDirection.rtl
              ? 'عضویت با تأیید مدیر'
              : 'Administrator approval required';
          await tester.pumpWidget(
            MaterialApp(
              theme: theme,
              home: Directionality(
                textDirection: direction,
                child: MediaQuery(
                  data: const MediaQueryData(
                    size: Size(320, 700),
                    textScaler: TextScaler.linear(2),
                  ),
                  child: Scaffold(
                    body: ListView(
                      children: [
                        LoomDetailTile(
                          leading: const Icon(LoomIcons.people_outline_rounded),
                          title: Text(label),
                          subtitle: const Text('Member / عضو'),
                          onTap: () => selected = true,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pump();
          expect(tester.takeException(), isNull);
          await tester.tap(find.text(label));
          expect(selected, isTrue);
        },
      );
    }
  }
}

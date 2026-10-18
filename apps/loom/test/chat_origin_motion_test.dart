import 'package:loom_design/loom_design.dart';
import 'package:loom_next/features/home/presentation/messenger_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'widget_smoke_test.dart' show host, usePhoneViewport;

void main() {
  for (final locale in [const Locale('en'), const Locale('fa')]) {
    testWidgets(
      'conversation grows from its avatar and preserves draft: $locale',
      (tester) async {
        usePhoneViewport(tester);
        await tester.pumpWidget(
          host(const MessengerShell(preview: true), locale: locale),
        );
        await tester.pumpAndSettle();
        final row = find.byType(LoomChatRow).first;
        final origin = tester.getRect(
          find.descendant(of: row, matching: find.byType(LoomAvatar)).first,
        );
        expect(origin.width, lessThan(tester.getRect(row).width));
        await tester.tap(row);
        await tester.pump();
        final transform = tester.widget<LoomContainerTransform>(
          find.byType(LoomContainerTransform).first,
        );
        expect(transform.origin.width, origin.width);
        expect(transform.origin.height, origin.height);
        expect(transform.destination.height, greaterThan(origin.height));
        await tester.pumpAndSettle();
        final composer = find.byType(TextField).last;
        await tester.enterText(composer, 'Unsent draft');
        await tester.binding.handlePopRoute();
        await tester.pump(const Duration(milliseconds: 80));
        await tester.tap(find.byType(LoomChatRow).first);
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<TextField>(find.byType(TextField).last)
              .controller!
              .text,
          'Unsent draft',
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
    );
  }
}

import 'package:loom_design/loom_design.dart';
import 'package:loom_next/features/calls/presentation/call_error.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'widget_smoke_test.dart' show host;

void main() {
  for (final locale in [const Locale('en'), const Locale('fa')]) {
    testWidgets(
      'call failure persists without a ScaffoldMessenger in $locale',
      (tester) async {
        await tester.pumpWidget(
          host(
            LoomGlassScope(
              quality: LoomGlassQuality.disabled,
              child: Builder(
                builder: (context) => Center(
                  child: TextButton(
                    onPressed: () => showCallFailure(
                      context,
                      const LoomCallSignalingException(
                        'call-1',
                        'call_conversation_not_found',
                      ),
                    ),
                    child: const Text('Start'),
                  ),
                ),
              ),
            ),
            locale: locale,
          ),
        );
        await tester.tap(find.text('Start'));
        await tester.pumpAndSettle();
        expect(find.byType(Dialog), findsOneWidget);
        expect(
          find.textContaining(
            locale.languageCode == 'fa' ? 'همگام نشده' : 'has not synced',
          ),
          findsOneWidget,
        );
        await tester.pump(const Duration(seconds: 10));
        expect(find.byType(Dialog), findsOneWidget);
        await tester.tap(
          find.text(locale.languageCode == 'fa' ? 'بستن' : 'Close'),
        );
        await tester.pumpAndSettle();
        expect(find.byType(Dialog), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
}

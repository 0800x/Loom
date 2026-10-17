import 'dart:async';

import 'package:loom_design/loom_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('selection has one keyboard action and reports checked state', (
    tester,
  ) async {
    var selected = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: LoomTheme.dark(),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, update) => LoomSelectionRow(
              label: 'Long member name',
              detail: '@member:home.test',
              selected: selected,
              onTap: () => update(() => selected = !selected),
            ),
          ),
        ),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(selected, true);
    expect(
      tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
      true,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'async form preserves the value on failure and cannot submit twice',
    (tester) async {
      var submissions = 0;
      var pending = Completer<bool>();
      await tester.pumpWidget(
        MaterialApp(
          theme: LoomTheme.light(),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showDialog<bool>(
                  context: context,
                  barrierDismissible: false,
                  builder: (_) => LoomAsyncTextDialog(
                    title: 'Rename group',
                    label: 'Group name',
                    actionLabel: 'Save',
                    cancelLabel: 'Cancel',
                    failureLabel: 'Try again',
                    validator: (v) =>
                        v == null || v.trim().isEmpty ? 'Required' : null,
                    onSubmit: (_) {
                      submissions++;
                      return pending.future;
                    },
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), 'Keep this name');
      await tester.tap(find.text('Save'));
      await tester.pump();
      await tester.tap(find.text('Save'));
      await tester.pump();
      expect(submissions, 1);
      pending.complete(false);
      await tester.pumpAndSettle();
      expect(find.text('Keep this name'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
      pending = Completer<bool>();
      await tester.tap(find.text('Save'));
      await tester.pump();
      pending.complete(true);
      await tester.pumpAndSettle();
      expect(find.byType(LoomAsyncTextDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'glass dialog content scrolls above a keyboard at large text size',
    (tester) async {
      tester.view.physicalSize = const Size(320, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: LoomTheme.oled(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              viewInsets: const EdgeInsets.only(bottom: 240),
              textScaler: const TextScaler.linear(1.6),
            ),
            child: child!,
          ),
          home: Scaffold(
            body: LoomGlassDialog(
              title: 'Details',
              actions: [
                TextButton(onPressed: () {}, child: const Text('Close')),
              ],
              child: Column(
                children: List.generate(
                  20,
                  (i) => Text('Member $i with a long name'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(tester.getBottomRight(find.text('Close')).dy, lessThan(360));
    },
  );
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loom_design/loom_design.dart';

void main() {
  testWidgets('action sheet ListTile has a visible Material ink surface',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        theme: LoomTheme.light(),
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () => showLoomActionSheet<void>(
                        context: context,
                        title: 'Actions',
                        builder: (_) => ListTile(
                            title: const Text('Reply'),
                            onTap: () => Navigator.pop(context))),
                    child: const Text('Open'))))));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Reply'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Reply'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}

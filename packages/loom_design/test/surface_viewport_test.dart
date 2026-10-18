import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loom_design/loom_design.dart';

void main() {
  testWidgets('surface stays inside a Navigator shortened by a media bar', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const viewportKey = ValueKey('short-navigator');
    const sheetKey = ValueKey('sheet-content');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              height: 450,
              child: Navigator(
                key: const ValueKey('nested-navigator'),
                onGenerateRoute: (settings) => MaterialPageRoute<void>(
                  settings: settings,
                  builder: (context) => SizedBox.expand(
                    key: viewportKey,
                    child: Center(
                      child: TextButton(
                        onPressed: () => showLoomSurface<void>(
                          context: context,
                          builder: (context) =>
                              const SizedBox.expand(key: sheetKey),
                        ),
                        child: const Text('Open'),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final viewport = tester.getRect(find.byKey(viewportKey));
    final sheet = tester.getRect(find.byKey(sheetKey));
    expect(sheet.bottom, lessThanOrEqualTo(viewport.bottom));
    expect(sheet.top, greaterThanOrEqualTo(viewport.top));
    expect(sheet.height, greaterThan(0));
  });
}

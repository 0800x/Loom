import 'package:loom_design/loom_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('glass app bar preserves toolbar and bottom sizing', () {
    final bar = LoomGlassAppBar(
      title: const Text('Settings'),
      bottom: const PreferredSize(preferredSize: Size.fromHeight(24), child: SizedBox(height: 24)),
    );
    expect(bar.preferredSize.height, kToolbarHeight + 24);
    expect(bar.backgroundColor, Colors.transparent);
    expect(bar.automaticallyImplyLeading, isTrue);
  });

  test('explicit media viewer colours remain intact', () {
    final bar = LoomGlassAppBar(backgroundColor: Colors.black, foregroundColor: Colors.white);
    expect(bar.backgroundColor, Colors.black);
    expect(bar.foregroundColor, Colors.white);
    expect(bar.flexibleSpace, isNull);
  });

  testWidgets('disabled glass quality does not allocate backdrop filters', (tester) async {
    await tester.pumpWidget(LoomGlassScope(
      quality: LoomGlassQuality.disabled,
      child: MaterialApp(theme: LoomTheme.light(), home: Scaffold(
        appBar: LoomGlassAppBar(title: const Text('Settings')),
        body: const LoomTopGlassFade(height: 120),
      )),
    ));
    expect(find.byType(BackdropFilter), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

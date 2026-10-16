import 'dart:math' as math;

import 'package:loom_design/loom_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('iOS routes preserve the SDK native swipe-back gesture', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: LoomTheme.light().copyWith(platform: TargetPlatform.iOS),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (_) => const Scaffold(
                      body: Center(child: Text('Detail page')),
                    ),
                  ),
                ),
                child: const Text('Open detail'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open detail'));
    await tester.pumpAndSettle();
    expect(find.text('Detail page'), findsOneWidget);

    final viewport = tester.getSize(find.byType(MaterialApp));
    await tester.dragFrom(
      Offset(1, viewport.height / 2),
      Offset(viewport.width * .8, 0),
    );
    await tester.pumpAndSettle();
    expect(find.text('Detail page'), findsNothing);
    expect(find.text('Open detail'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('primary button labels have readable contrast in all themes', () {
    for (final theme in [
      LoomTheme.light(),
      LoomTheme.dark(),
      LoomTheme.oled(),
    ]) {
      final background = theme.colorScheme.primary.computeLuminance();
      final foreground = theme.colorScheme.onPrimary.computeLuminance();
      final ratio = (math.max(background, foreground) + .05) /
          (math.min(background, foreground) + .05);
      expect(ratio, greaterThanOrEqualTo(4.5));
    }
  });

  testWidgets(
    'modal actions retain reduced transparency and motion preferences',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: LoomTheme.light(),
          home: LoomAccessibilityScope(
            overrides: const LoomAccessibilityOverrides(
              reduceMotion: true,
              reduceTransparency: true,
            ),
            child: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showLoomActionSheet<void>(
                    context: context,
                    title: 'Actions',
                    builder: (_) => const LoomActionGrid(
                      children: [
                        LoomActionTile(
                          icon: LoomIcons.copy_rounded,
                          label: 'Copy',
                        ),
                      ],
                    ),
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      final context = tester.element(find.text('Copy'));
      expect(LoomAccessibility.fromContext(context).reduceMotion, isTrue);
      expect(
        LoomAccessibility.fromContext(context).reduceTransparency,
        isTrue,
      );
      expect(find.byType(BackdropFilter), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('navigation destinations expose a semantic tap action', (
    tester,
  ) async {
    var selected = 0;
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(
      MaterialApp(
        theme: LoomTheme.light(),
        home: LoomGlassScope(
          quality: LoomGlassQuality.disabled,
          child: Scaffold(
            body: LoomGlassNavigation(
              selectedIndex: 0,
              onSelected: (value) => selected = value,
              destinations: const [
                LoomNavigationDestination(
                  LoomIcons.chat_bubble_rounded,
                  'Chats',
                ),
                LoomNavigationDestination(
                  LoomIcons.settings_outlined,
                  'Settings',
                ),
              ],
            ),
          ),
        ),
      ),
    );
    final node = tester.getSemantics(find.bySemanticsLabel('Settings'));
    expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    await tester.tap(find.text('Settings'));
    expect(selected, 1);
    semantics.dispose();
  });

  testWidgets('reduced motion keeps the connection pulse still', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: LoomTheme.dark(),
        home: const LoomAccessibilityScope(
          overrides: LoomAccessibilityOverrides(reduceMotion: true),
          child: Scaffold(
            body: LoomConnectionPulse(active: true, child: Text('Caller')),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(find.text('Caller'), findsOneWidget);
  });
}

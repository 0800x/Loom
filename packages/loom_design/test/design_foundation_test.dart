import 'package:loom_design/loom_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('responsive breakpoints are explicit and monotonic', () {
    expect(LoomBreakpoints.ofWidth(0), LoomWindowClass.compact);
    expect(LoomBreakpoints.ofWidth(599.9), LoomWindowClass.compact);
    expect(LoomBreakpoints.ofWidth(600), LoomWindowClass.medium);
    expect(LoomBreakpoints.ofWidth(959.9), LoomWindowClass.medium);
    expect(LoomBreakpoints.ofWidth(960), LoomWindowClass.expanded);
    expect(LoomBreakpoints.ofWidth(1439.9), LoomWindowClass.expanded);
    expect(LoomBreakpoints.ofWidth(1440), LoomWindowClass.ultraWide);
  });

  test('pane ranges keep preferred widths inside bounds', () {
    expect(
      LoomPaneSpecs.conversationList.clamp(100),
      LoomPaneSpecs.conversationList.min,
    );
    expect(LoomPaneSpecs.details.clamp(999), LoomPaneSpecs.details.max);
  });

  test('pane controller clamps future resize values', () {
    final controller = LoomPaneController();
    controller.setConversationListWidth(100);
    controller.setDetailsWidth(999);
    expect(
      controller.conversationListWidth,
      LoomPaneSpecs.conversationList.min,
    );
    expect(controller.detailsWidth, LoomPaneSpecs.details.max);
  });

  test('theme accepts a locale-specific bundled font family', () {
    final theme = LoomTheme.dark(fontFamily: 'Vazirmatn');

    expect(theme.textTheme.bodyMedium?.fontFamily, 'Vazirmatn');
    expect(theme.textTheme.titleLarge?.fontFamily, 'Vazirmatn');
  });

  testWidgets('glass disabled mode renders without BackdropFilter', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: LoomTheme.dark(),
        home: const LoomGlassScope(
          quality: LoomGlassQuality.disabled,
          child: Scaffold(body: LoomGlassSurface(child: Text('disabled'))),
        ),
      ),
    );

    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.text('disabled'), findsOneWidget);
  });

  testWidgets('reduce transparency disables backdrop blur', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: LoomTheme.dark(),
        home: const LoomAccessibilityScope(
          overrides: LoomAccessibilityOverrides(reduceTransparency: true),
          child: Scaffold(body: LoomGlassSurface(child: Text('accessible'))),
        ),
      ),
    );

    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets('chat backdrop never blurs the scrolling content', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: LoomTheme.dark(),
        home: const Scaffold(body: LoomChatBackdrop(child: Text('messages'))),
      ),
    );

    expect(find.text('messages'), findsOneWidget);
    expect(find.byType(BackdropFilter), findsNothing);
  });
}

import 'package:loom_design/loom_design.dart';
import 'package:loom_next/features/profile/presentation/profile_screen.dart';
import 'package:loom_next/features/profile/presentation/profile_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('profile has pinned details, scrolls and expands its photo', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: LoomTheme.dark(),
        home: const ProfileScreen(preview: true),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(LoomProfileHeader), findsOneWidget);
    final bar = tester.widget<SliverAppBar>(find.byType(SliverAppBar));
    expect(bar.pinned, isTrue);
    expect(bar.stretch, isTrue);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -500));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final scrollable = tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byType(CustomScrollView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    scrollable.position.jumpTo(0);
    await tester.pumpAndSettle();
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 350));
    await tester.pumpAndSettle();
    expect(
      tester.widget<SliverAppBar>(find.byType(SliverAppBar)).expandedHeight,
      greaterThan(300),
    );
    await tester.tap(find.byTooltip('Collapse photo'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<SliverAppBar>(find.byType(SliverAppBar)).expandedHeight,
      300,
    );
    expect(tester.takeException(), isNull);
  });
}

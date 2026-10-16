import 'package:loom_design/loom_design.dart';
import 'package:loom_next/features/media/application/video_note_geometry.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('large surface curvature settles to the exact destination outline', () {
    const size = Size(300, 500);
    Path outline(double progress, {bool curved = true}) => LoomSurfaceClipper(
      progress: progress,
      radius: Radius.zero,
      curvedStretch: curved,
    ).getClip(size);
    const centerEdge = Offset(2, 250);
    expect(outline(0).contains(centerEdge), isTrue);
    expect(outline(.5).contains(centerEdge), isFalse);
    expect(outline(1).contains(centerEdge), isTrue);
    expect(outline(.5, curved: false).contains(centerEdge), isTrue);
    for (var i = 0; i <= 20; i++) {
      final path = outline(i / 20);
      expect(path.getBounds(), Offset.zero & size);
      expect(path.contains(const Offset(150, 250)), isTrue);
    }
  });
  testWidgets('animation ticks reuse the destination child', (tester) async {
    var builds = 0;
    final clock = AnimationController(
      vsync: tester,
      duration: const Duration(milliseconds: 340),
    );
    addTearDown(clock.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Stack(
          children: [
            LoomContainerTransform(
              animation: clock,
              origin: const Rect.fromLTWH(20, 40, 48, 48),
              destination: const Rect.fromLTWH(0, 0, 300, 500),
              child: Builder(
                builder: (_) {
                  builds++;
                  return const Text('Cached content');
                },
              ),
            ),
          ],
        ),
      ),
    );
    final initial = builds;
    for (var i = 1; i <= 10; i++) {
      clock.value = i / 10;
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(
      builds,
      initial,
      reason: 'Transform frames must not rebuild the payload',
    );
    expect(initial, 1);
    expect(tester.takeException(), isNull);
  });
  test('center crop is symmetric and preserves a landscape 4:3 frame', () {
    for (final size in [
      const Size(1080, 1920),
      const Size(1920, 1080),
      const Size(640, 480),
    ]) {
      final crop = LoomVideoNoteGeometry.centerCrop(size);
      expect(crop.width / crop.height, closeTo(4 / 3, 0.00001));
      expect(crop.center, Offset(size.width / 2, size.height / 2));
      expect(crop.width, lessThanOrEqualTo(size.width));
      expect(crop.height, lessThanOrEqualTo(size.height));
    }
  });
  test('preview fits a narrow or landscape usable viewport', () {
    for (final size in [const Size(280, 500), const Size(700, 160)]) {
      final preview = LoomVideoNoteGeometry.previewSize(size);
      expect(preview.width, lessThanOrEqualTo(size.width));
      expect(preview.height, lessThanOrEqualTo(size.height));
      expect(preview.width / preview.height, closeTo(4 / 3, 0.00001));
    }
  });
  test('spring is monotonic and has exact endpoints without overshoot', () {
    const curve = LoomSpringCurve();
    expect(curve.transform(0), 0);
    expect(curve.transform(1), 1);
    var previous = 0.0;
    for (var i = 1; i <= 100; i++) {
      final value = curve.transform(i / 100);
      expect(value, inInclusiveRange(previous, 1));
      previous = value;
    }
  });
  for (final rtl in [false, true]) {
    testWidgets(
      'anchored route survives double tap, reverse and reopening: rtl=$rtl',
      (tester) async {
        final anchor = GlobalKey();
        final navigator = GlobalKey<NavigatorState>();
        Rect? source;
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navigator,
            home: Builder(
              builder: (context) => Directionality(
                textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
                child: Scaffold(
                  body: Align(
                    alignment: Alignment.bottomRight,
                    child: FilledButton(
                      key: anchor,
                      onPressed: () {
                        source = LoomOrigin.of(anchor.currentContext);
                        showLoomSurface<void>(
                          context: context,
                          origin: source,
                          identity: 'test-panel',
                          builder: (context) => TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('Dismiss panel'),
                          ),
                        );
                      },
                      child: const Text('Open panel'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open panel'));
        await tester.tap(find.text('Open panel'), warnIfMissed: false);
        await tester.pumpAndSettle();
        expect(source, isNotNull);
        expect(find.text('Dismiss panel'), findsOneWidget);
        await tester.tap(find.text('Dismiss panel'));
        await tester.pump(const Duration(milliseconds: 80));
        expect(navigator.currentState!.canPop(), isFalse);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Open panel'));
        await tester.pumpAndSettle();
        expect(find.text('Dismiss panel'), findsOneWidget);
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets('system reduced motion cannot be overridden by full motion', (
    tester,
  ) async {
    bool? reduced;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: LoomAccessibilityScope(
          overrides: const LoomAccessibilityOverrides(reduceMotion: false),
          child: Builder(
            builder: (context) {
              reduced = LoomAccessibility.fromContext(context).reduceMotion;
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    expect(reduced, isTrue);
  });
  testWidgets('header drag follows the finger, settles, and dismisses', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            return Scaffold(
              body: TextButton(
                onPressed: () {
                  showLoomSurface<void>(
                    context: context,
                    identity: 'drag',
                    builder: (_) => const Text('Drag surface'),
                  );
                },
                child: const Text('Open'),
              ),
            );
          },
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    final transform = find.byType(LoomContainerTransform);
    final header = tester.getTopLeft(transform) + const Offset(200, 14);
    final gesture = await tester.startGesture(header);
    await gesture.moveBy(const Offset(0, 20));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 40));
    await tester.pump();
    expect(tester.widget<LoomContainerTransform>(transform).linear, isTrue);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.text('Drag surface'), findsOneWidget);
    expect(tester.widget<LoomContainerTransform>(transform).linear, isFalse);
    await tester.dragFrom(header, const Offset(0, 180));
    await tester.pumpAndSettle();
    expect(find.text('Drag surface'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('full player drag collapses the same transformed surface', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showLoomSurface<void>(
                context: context,
                fullscreen: true,
                identity: 'full-drag',
                builder: (_) => const Scaffold(body: Text('Full surface')),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    final width = tester.view.physicalSize.width / tester.view.devicePixelRatio;
    await tester.dragFrom(Offset(width / 2, 22), const Offset(0, 180));
    await tester.pumpAndSettle();
    expect(find.text('Full surface'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

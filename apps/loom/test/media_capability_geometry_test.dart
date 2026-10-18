import 'package:loom_design/loom_design.dart';
import 'package:loom_next/features/media/application/media_capabilities.dart';
import 'package:loom_next/features/media/application/video_note_geometry.dart';
import 'package:loom_next/features/media/presentation/circular_video_preview.dart';
import 'package:loom_next/features/media/presentation/camera_screen.dart';
import 'package:loom_next/features/people/presentation/contact_qr_scanner_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

void main() {
  test('unsupported camera backends are never advertised', () {
    expect(
      LoomMediaCapabilities.cameraCaptureFor(TargetPlatform.windows),
      isFalse,
    );
    expect(
      LoomMediaCapabilities.cameraCaptureFor(TargetPlatform.linux),
      isFalse,
    );
    expect(
      LoomMediaCapabilities.cameraCaptureFor(TargetPlatform.android),
      isTrue,
    );
    expect(LoomMediaCapabilities.cameraCaptureFor(TargetPlatform.iOS), isTrue);
  });
  test('circular crop fits narrow and landscape available space', () {
    for (final available in [
      const Size(120, 300),
      const Size(600, 200),
      const Size(800, 900),
    ]) {
      final preview = LoomVideoNoteGeometry.circularPreviewSize(available);
      expect(preview.width, preview.height);
      expect(preview.width, lessThanOrEqualTo(available.shortestSide));
      expect(preview.width, lessThanOrEqualTo(320));
    }
  });
  testWidgets(
    'preview clips its texture and preserves determinate recording progress',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: LoomTheme.light(),
          home: const Scaffold(
            body: Center(
              child: LoomCircularVideoPreview(
                diameter: 220,
                progress: .5,
                child: ColoredBox(color: Colors.white),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ClipOval), findsOneWidget);
      expect(
        tester
            .widget<CircularProgressIndicator>(
              find.byType(CircularProgressIndicator),
            )
            .value,
        .5,
      );
      expect(
        tester.getSize(find.byType(LoomCircularVideoPreview)),
        const Size.square(220),
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'Windows capture and QR routes offer truthful fallbacks without starting plugins',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(theme: LoomTheme.light(), home: const LoomCameraScreen()),
      );
      await tester.pumpAndSettle();
      expect(find.text('Choose file'), findsOneWidget);
      expect(
        find.textContaining('Camera capture is unavailable'),
        findsOneWidget,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: LoomTheme.light(),
          home: const LoomContactQrScannerScreen(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(MobileScanner), findsNothing);
      expect(find.text('Back to People'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}

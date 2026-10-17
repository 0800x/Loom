import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:loom_design/loom_design.dart';
import 'package:loom_next/features/home/presentation/messenger_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'widget_smoke_test.dart' show host;

void main() {
  setUpAll(() async {
    final manifest =
        jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
    for (final family in manifest.cast<Map<String, dynamic>>()) {
      final loader = FontLoader(family['family'] as String);
      for (final font
          in (family['fonts'] as List).cast<Map<String, dynamic>>()) {
        loader.addFont(rootBundle.load(font['asset'] as String));
      }
      await loader.load();
    }
  });
  for (final locale in [const Locale('en'), const Locale('fa')]) {
    for (final dark in [false, true]) {
      testWidgets(
        'Windows resize and anchored menu ${locale.languageCode} dark=$dark',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final boundary = GlobalKey();
          tester.view.physicalSize = const Size(1600, 1000);
          await tester.pumpWidget(
            host(
              RepaintBoundary(
                key: boundary,
                child: const LoomGlassScope(
                  quality: LoomGlassQuality.disabled,
                  child: MessengerShell(preview: true),
                ),
              ),
              locale: locale,
              theme: dark
                  ? LoomTheme.dark(fontFamily: 'Vazirmatn')
                  : LoomTheme.light(fontFamily: 'Vazirmatn'),
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text('Maya Brooks').first);
          await tester.pumpAndSettle();
          for (final width in [960.0, 1200.0, 1600.0]) {
            tester.view.physicalSize = Size(width, 1000);
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
          }
          final divider = find.byWidgetPredicate(
            (w) =>
                w is MouseRegion && w.cursor == SystemMouseCursors.resizeColumn,
          );
          expect(divider, findsOneWidget);
          final original = tester.getTopLeft(divider).dx;
          await tester.drag(
            divider,
            Offset(locale.languageCode == 'fa' ? -60 : 60, 0),
          );
          await tester.pumpAndSettle();
          expect(
            (tester.getTopLeft(divider).dx - original).abs(),
            greaterThan(20),
          );
          await tester.tap(
            find.byTooltip(
              locale.languageCode == 'fa' ? 'منوی گفتگو' : 'Conversation menu',
            ),
          );
          await tester.pumpAndSettle();
          expect(find.byType(MenuItemButton), findsWidgets);
          expect(find.byType(LoomActionTile), findsNothing);
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          expect(find.byType(MenuItemButton), findsNothing);
          expect(tester.takeException(), isNull);
          if (const bool.fromEnvironment('LOOM_CAPTURE_UX')) {
            await tester.runAsync(() async {
              final rendered =
                  await (boundary.currentContext!.findRenderObject()
                          as RenderRepaintBoundary)
                      .toImage();
              final png = await rendered.toByteData(
                format: ui.ImageByteFormat.png,
              );
              final dir = Directory('../../docs/ux-evidence');
              await dir.create(recursive: true);
              await File(
                '${dir.path}/windows-${locale.languageCode}-${dark ? 'dark' : 'light'}.png',
              ).writeAsBytes(png!.buffer.asUint8List());
              rendered.dispose();
            });
          }
          await tester.pumpWidget(const SizedBox.shrink());
        },
        variant: TargetPlatformVariant.only(TargetPlatform.windows),
      );
    }
  }
}

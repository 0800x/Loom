import 'dart:typed_data';
import 'package:loom_design/loom_design.dart';
import 'package:loom_next/features/groups/application/groups_controller.dart';
import 'package:loom_next/features/groups/presentation/group_photo_editor.dart';
import 'package:loom_next/features/nodes/application/node_directory_controller.dart';
import 'package:loom_next/features/onboarding/application/onboarding_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loom_crypto_bridge/loom_crypto_bridge.dart';
import 'package:image/image.dart' as img;
import 'support/ux_evidence.dart';

class PhotoGroups extends LoomGroupsController {
  PhotoGroups(superOnboarding, this.photo)
    : super(
        onboarding: superOnboarding,
        trustedDevice: (_) async => throw StateError('No network'),
        devicesForContact: (_) async => [],
      );
  Uint8List photo;
  bool success = false;
  int saves = 0;
  @override
  Uint8List? groupPhoto(String id) => photo;
  @override
  Future<bool> setGroupPhoto(String id, Uint8List? png) async {
    saves++;
    return success;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await LoomAppLock.instance.initialize();
    await loadUxFonts();
  });
  for (final locale in const [Locale('en'), Locale('fa')]) {
    for (final theme in [
      LoomTheme.light(fontFamily: 'Vazirmatn'),
      LoomTheme.dark(fontFamily: 'Vazirmatn'),
      LoomTheme.oled(fontFamily: 'Vazirmatn'),
    ]) {
      testWidgets(
        'photo editor preserves failed removal, confirms discard and saves $locale ${theme.scaffoldBackgroundColor}',
        (tester) async {
          tester.view.physicalSize = const Size(320, 780);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final nodes = LoomNodeDirectoryController();
          final onboarding = LoomOnboardingController(nodes: nodes);
          final groups = PhotoGroups(
            onboarding,
            img.encodePng(
              img.Image(width: 32, height: 32)
                ..clear(img.ColorRgb8(66, 112, 218)),
            ),
          );
          await tester.pumpWidget(
            MaterialApp(
              theme: theme,
              locale: locale,
              supportedLocales: const [Locale('en'), Locale('fa')],
              localizationsDelegates: const [
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              builder: (context, child) => RepaintBoundary(
                child: MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: const TextScaler.linear(1.5)),
                  child: child!,
                ),
              ),
              home: Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (_) => LoomGroupPhotoEditor(
                        groups: groups,
                        groupId: 'g',
                        title: 'Design team · گروه طراحی با نام طولانی',
                      ),
                    ),
                    child: const Text('Launch'),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('Launch'));
          await tester.pumpAndSettle();
          final fa = locale.languageCode == 'fa';
          await tester.ensureVisible(
            find.text(fa ? 'حذف تصویر' : 'Remove photo'),
          );
          await tester.tap(find.text(fa ? 'حذف تصویر' : 'Remove photo'));
          await tester.pumpAndSettle();
          await tester.tap(find.text(fa ? 'ذخیره' : 'Save'));
          await tester.pumpAndSettle();
          expect(groups.saves, 1);
          await tester.ensureVisible(find.byType(LoomFeedbackSurface));
          await tester.pumpAndSettle();
          await captureUxEvidence(
            tester,
            'group-photo-editor-${locale.languageCode}-${theme.scaffoldBackgroundColor.toARGB32()}-error',
          );
          await tester.tap(find.text(fa ? 'لغو' : 'Cancel'));
          await tester.pumpAndSettle();
          await tester.tap(find.text(fa ? 'ادامهٔ ویرایش' : 'Keep editing'));
          await tester.pumpAndSettle();
          expect(find.byType(LoomGroupPhotoEditor), findsOneWidget);
          groups.success = true;
          await tester.tap(find.text(fa ? 'ذخیره' : 'Save'));
          await tester.pumpAndSettle();
          expect(groups.saves, 2);
          expect(find.byType(LoomGroupPhotoEditor), findsNothing);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          groups.dispose();
          onboarding.dispose();
          nodes.dispose();
        },
      );
    }
  }
}

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:loom_design/loom_design.dart';
import 'package:loom_models/loom_models.dart' as models;
import 'package:loom_next/features/home/presentation/messenger_shell.dart';
import 'package:loom_next/features/messaging/application/encrypted_media.dart';
import 'package:loom_next/features/messaging/application/message_content.dart';
import 'package:loom_next/features/messaging/application/messaging_session_controller.dart';
import 'package:loom_next/features/nodes/application/node_directory_controller.dart';
import 'package:loom_next/features/onboarding/application/onboarding_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'widget_smoke_test.dart' show host;

class _TempPaths extends PathProviderPlatform {
  _TempPaths(this.path);
  final String path;
  @override
  Future<String> getTemporaryPath() async => path;
}

class _Messaging extends LoomMessagingSessionController {
  _Messaging({required super.onboarding}) {
    status = LoomMessagingSessionStatus.ready;
    conversations = const [
      models.LoomConversation(
        id: 'saved',
        kind: models.LoomConversationKind.self,
        updatedOrder: 1,
        unreadCount: 0,
        isMuted: false,
        isPinned: false,
      ),
    ];
  }
  @override
  Future<void> open() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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
  for (final scenario in [
    (
      width: 320.0,
      locale: const Locale('en'),
      theme: LoomTheme.light(fontFamily: 'Vazirmatn'),
      name: 'light-en-320',
      platform: TargetPlatform.android,
    ),
    (
      width: 390.0,
      locale: const Locale('fa'),
      theme: LoomTheme.dark(fontFamily: 'Vazirmatn'),
      name: 'dark-fa-390',
      platform: TargetPlatform.android,
    ),
    (
      width: 390.0,
      locale: const Locale('en'),
      theme: LoomTheme.oled(fontFamily: 'Vazirmatn'),
      name: 'oled-en-390',
      platform: TargetPlatform.android,
    ),
    (
      width: 1200.0,
      locale: const Locale('en'),
      theme: LoomTheme.dark(fontFamily: 'Vazirmatn'),
      name: 'desktop-en-1200',
      platform: TargetPlatform.windows,
    ),
  ]) {
    testWidgets('saved photo uses verified local preview in ${scenario.name}', (
      tester,
    ) async {
      final temp = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('loom_render_'),
      ))!;
      final oldPaths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _TempPaths(temp.path);
      addTearDown(() async {
        PathProviderPlatform.instance = oldPaths;
        await temp.delete(recursive: true);
      });
      tester.view.physicalSize = Size(scenario.width, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final nodes = LoomNodeDirectoryController();
      final onboarding = LoomOnboardingController(nodes: nodes)
        ..receipt = const models.LoomRegistrationReceipt(
          accountId: 'test',
          deviceId: 'test',
          address: '@test:home.example',
          homeNode: 'home.example',
        );
      final messaging = _Messaging(onboarding: onboarding);
      addTearDown(nodes.dispose);
      addTearDown(onboarding.dispose);
      addTearDown(messaging.dispose);
      // An original deterministic image fixture exercises the real decoder,
      // authenticated cache and production renderer, without network access.
      final photo = image.Image(width: 300, height: 200);
      for (var y = 0; y < photo.height; y++) {
        for (var x = 0; x < photo.width; x++) {
          photo.setPixelRgb(x, y, 25 + x ~/ 2, 60 + y ~/ 2, 110);
        }
      }
      final clear = image.encodePng(photo);
      final sealed = (await tester.runAsync(
        () => LoomEncryptedMedia.encrypt(clear),
      ))!;
      final media = <String, Object?>{
        'kind': 'image',
        'url': 'https://home.example/api/v1/attachments/att_${'a' * 64}',
        'key': sealed.key,
        'bytes': clear.length,
        'width': 300,
        'height': 200,
      };
      await tester.runAsync(
        () => LoomEncryptedMedia.cacheEncrypted(
          media,
          sealed.bytes,
          'home.example',
        ),
      );
      messaging.visibleMessages = {
        'saved': [
          LoomVisibleMessage(
            record: models.LoomMessageRecord(
              id: 'photo',
              clientId: 'photo',
              conversationId: 'saved',
              senderAddress: '@test:home.example',
              type: models.LoomMessageType.image,
              ciphertext: 'opaque',
              protocolVersion: 'test',
              createdOrder: 1,
              createdAt: DateTime.utc(2026, 10, 4, 12),
              deliveryState: models.LoomDeliveryState.sent,
            ),
            text: LoomMessageContent(
              text: 'Local photo · test fixture',
              attachment: media,
            ).encode(),
            readable: true,
          ),
        ],
      };
      await tester.pumpWidget(
        host(
          RepaintBoundary(
            key: const ValueKey('capture'),
            child: LoomMessagingSessionScope(
              controller: messaging,
              child: const MessengerShell(),
            ),
          ),
          locale: scenario.locale,
          theme: scenario.theme,
        ),
      );
      if (scenario.platform == TargetPlatform.android) {
        await tester.pumpAndSettle();
      } else {
        await tester.pump(const Duration(milliseconds: 350));
      }
      await tester.tap(
        find
            .text(
              scenario.locale.languageCode == 'fa'
                  ? 'پیام‌های ذخیره‌شده'
                  : 'Saved Messages',
            )
            .first,
      );
      // Route animation and real disk I/O use different clocks in a widget
      // test; advance both until the authenticated preview has decoded.
      for (var attempt = 0; attempt < 30; attempt++) {
        await tester.pump(const Duration(milliseconds: 100));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        if (find
            .descendant(
              of: find.byType(LoomMessageBubble),
              matching: find.byType(Image),
            )
            .evaluate()
            .isNotEmpty) {
          break;
        }
      }
      await tester.pump(const Duration(milliseconds: 350));
      final bubble = tester.widget<LoomMessageBubble>(
        find.byType(LoomMessageBubble),
      );
      expect(bubble.presentation, LoomMessagePresentation.photo);
      expect(bubble.mine, isTrue);
      final photoWidget = find.descendant(
        of: find.byType(LoomMessageBubble),
        matching: find.byType(Image),
      );
      expect(photoWidget, findsOneWidget);
      // The app header also renders its raster brand mark. The authenticated
      // message preview above must still contain exactly one decoded image.
      expect(find.byIcon(LoomIcons.bookmark_border_rounded), findsOneWidget);
      expect(find.text('0.0 MB'), findsNothing);
      expect(tester.takeException(), isNull);
      if (scenario.platform == TargetPlatform.windows) {
        await tester.tap(photoWidget);
        for (var attempt = 0; attempt < 30; attempt++) {
          await tester.pump(const Duration(milliseconds: 100));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 30)),
          );
          if (find.byType(InteractiveViewer).evaluate().isNotEmpty) break;
        }
        await tester.pumpAndSettle();
        expect(find.byTooltip('Fit to window'), findsOneWidget);
        final viewer = tester.widget<InteractiveViewer>(
          find.byType(InteractiveViewer),
        );
        await tester.tap(find.byTooltip('Zoom in'));
        await tester.pumpAndSettle();
        expect(
          viewer.transformationController!.value.getMaxScaleOnAxis(),
          greaterThan(1),
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.digit0);
        await tester.pumpAndSettle();
        expect(viewer.transformationController!.value.getMaxScaleOnAxis(), 1);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
        await tester.pumpAndSettle();
        expect(find.byTooltip('Fit to window'), findsNothing);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byTooltip('Fit to window'), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byType(LoomMessageBubble), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      if (Platform.environment['LOOM_CAPTURE_WIDGETS'] == '1') {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('capture')),
        );
        await tester.runAsync(() async {
          final rendered = await boundary.toImage();
          final png = await rendered.toByteData(format: ui.ImageByteFormat.png);
          await Directory('../../docs/ux-evidence').create(recursive: true);
          await File(
            '../../docs/ux-evidence/${scenario.platform == TargetPlatform.windows ? 'windows-media-chat' : 'android-conversation'}-${scenario.name}.png',
          ).writeAsBytes(png!.buffer.asUint8List());
          rendered.dispose();
        });
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }, variant: TargetPlatformVariant.only(scenario.platform));
  }
}

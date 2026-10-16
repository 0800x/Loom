import 'dart:io';

import 'package:loom_models/loom_models.dart';
import 'package:loom_next/features/nodes/application/node_directory_controller.dart';
import 'package:loom_next/features/nodes/data/node_directory_repository.dart';
import 'package:loom_design/loom_design.dart';
import 'package:loom_next/app/chat_wallpaper.dart';
import 'package:loom_next/features/nodes/application/node_share_link.dart';
import 'package:loom_next/features/settings/presentation/settings_detail_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class NodeRepository extends LoomNodeDirectoryRepository {
  int liveCalls = 0, limit = 4 * 1024 * 1024;
  @override
  Future<LoomWellKnownNode> discoverDomain(String domain) async =>
      LoomWellKnownNode(
        protocol: 'loom-federation-v1',
        endpoint: Uri.parse('https://node.example'),
        nodeId: 'node:A',
        publicKey: 'verified-artifact-key',
        signature: 'verified-artifact-signature',
        fingerprint: 'ABCD',
      );
  @override
  Future<LoomNodeLiveInfo> liveInfo(Uri endpoint) async {
    liveCalls++;
    return LoomNodeLiveInfo(
      nodeId: 'node:A',
      serverVersion: 'test',
      protocolVersion: 'loom-node-v1',
      registration: 'open',
      federationMode: 'disabled',
      capabilities: const [],
      maxMediaBytes: limit,
    );
  }
}

void main() {
  test('QR pin is checked before selection and refreshed policy replaces stale limits', () async {
    final repo = NodeRepository();
    final controller = LoomNodeDirectoryController(repository: repo);
    await controller.discoverAndSelectDomain(
      'node.example',
      expectedFingerprint: 'WRONG',
    );
    expect(controller.selectedNodeVerified, false);
    expect(controller.selectedEndpoint, isNull);
    expect(repo.liveCalls, 0);
    await controller.discoverAndSelectDomain(
      'node.example',
      expectedFingerprint: 'ABCD',
      expectedNodeId: 'node:A',
    );
    expect(controller.selectedNodeVerified, true);
    expect(controller.selectedLiveInfo!.maxMediaBytes, 4 * 1024 * 1024);
    repo.limit = 8 * 1024 * 1024;
    await controller.refreshMediaPolicy();
    expect(controller.selectedLiveInfo!.maxMediaBytes, 8 * 1024 * 1024);
    controller.dispose();
  });
  TestWidgetsFlutterBinding.ensureInitialized();
  test('QR round-trip retains HTTPS endpoint, port and fingerprint', () {
    final link = LoomNodeShareLink(
      Uri.parse('https://node.example:8443'),
      'node:${List.filled(43, 'A').join()}',
      List.filled(16, 'ABCD').join(' '),
    );
    final parsed = LoomNodeShareLink.parse(link.encoded);
    expect(parsed.endpoint, link.endpoint);
    expect(parsed.fingerprint, link.fingerprint);
    expect(parsed.nodeId, link.nodeId);
    for (final bad in [
      link.encoded.replaceFirst('https:', 'http:'),
      '${link.encoded}&nodeId=duplicate',
      link.encoded.replaceFirst('node.example', 'user:pass@node.example'),
      '${link.encoded}#fragment',
      'javascript:alert(1)',
      link.encoded.replaceFirst('ABCD', 'ZZZZ'),
    ]) {
      expect(() => LoomNodeShareLink.parse(bad), throwsFormatException);
    }
  });
  test('chat wallpaper persists as a hashed override and reset inherits global choice', () async {
    final dir = await Directory.systemTemp.createTemp('wallpaper_test_');
    try {
      final key = (await LoomWallpaperStore.chatKey(
        'identity:private-conversation',
      ))!;
      final store = LoomWallpaperStore(directory: () async => dir);
      await store.set(null, const LoomWallpaper(style: 'sage', dim: .2));
      await store.set(key, const LoomWallpaper(style: 'dusk', dim: .4));
      final restored = LoomWallpaperStore(directory: () async => dir);
      await restored.load();
      expect(restored.selection(key).style, 'dusk');
      expect(restored.selection(null).style, 'sage');
      expect(
        await File('${dir.path}/loom-wallpapers/preferences.json')
            .readAsString(),
        isNot(contains('private-conversation')),
      );
      await restored.set(key, null);
      expect(restored.selection(key).style, 'sage');
      expect(restored.hasOverride(key), false);
      expect(
        () => LoomWallpaper.fromJson({
          'style': 'photo',
          'image': '../secret.jpg',
          'dim': .2,
          'blur': false,
        }),
        throwsFormatException,
      );
      expect(
        () =>
            LoomWallpaper.fromJson({'style': 'plain', 'dim': 2, 'blur': false}),
        throwsFormatException,
      );
      store.dispose();
      restored.dispose();
    } finally {
      await dir.delete(recursive: true);
    }
  });
  testWidgets('Appearance preview and theme controls fit a narrow phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    LoomThemeMode? selected;
    await tester.pumpWidget(
      MaterialApp(
        theme: LoomTheme.light(),
        home: LoomSettingsDetailScreen(
          section: LoomSettingsSection.appearance,
          themeMode: LoomThemeMode.light,
          glassQuality: LoomGlassQuality.high,
          locale: const Locale('en'),
          onThemeChanged: (v) => selected = v,
          onGlassQualityChanged: (_) {},
          onLocaleChanged: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Theme'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();
    expect(selected, LoomThemeMode.dark);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

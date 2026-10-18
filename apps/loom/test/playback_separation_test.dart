import 'dart:io';

import 'package:loom_next/app/chat_wallpaper.dart';
import 'package:loom_next/features/media/application/playback_controller.dart';
import 'package:loom_next/features/media/presentation/playback_host.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('closing a voice note preserves the paused music session', () async {
    final music = LoomPlaybackController.instance;
    final voice = LoomPlaybackController.voice;
    music.sourcePath = '/music/song';
    music.sourceId = 'chat:music';
    music.music = true;
    music.title = 'Song title';
    music.subtitle = 'Artist';
    music.position = const Duration(seconds: 37);
    music.duration = const Duration(minutes: 3);
    voice.sourcePath = '/voice/note';
    voice.sourceId = 'chat:voice';
    voice.speed = 2;
    await voice.close();
    expect(music.sourceId, 'chat:music');
    expect(music.title, 'Song title');
    expect(music.position, const Duration(seconds: 37));
    expect(music.speed, 1);
    expect(voice.visible, false);
    await LoomPlaybackController.closeAll();
  });

  testWidgets('progress rebuilds only the active row, not inactive rows', (
    tester,
  ) async {
    final p = LoomPlaybackController.instance;
    p.sourcePath = '/music/active';
    p.sourceId = 'active';
    p.music = true;
    var activeBuilds = 0, inactiveBuilds = 0, stateChanges = 0;
    void stateChanged() => stateChanges++;
    p.addListener(stateChanged);
    await tester.pumpWidget(
      MaterialApp(
        home: Column(
          children: [
            LoomPlaybackProgressBuilder(
              controller: p,
              source: File('/music/active'),
              sourceId: 'active',
              builder: (_) {
                activeBuilds++;
                return Text('Active ${p.position.inSeconds}');
              },
            ),
            LoomPlaybackProgressBuilder(
              controller: p,
              source: File('/music/inactive'),
              sourceId: 'inactive',
              builder: (_) {
                inactiveBuilds++;
                return const Text('Inactive');
              },
            ),
          ],
        ),
      ),
    );
    final initialActive = activeBuilds, initialInactive = inactiveBuilds;
    for (var second = 1; second <= 5; second++) {
      p.position = Duration(seconds: second);
      await tester.pump();
    }
    expect(activeBuilds, initialActive + 5);
    expect(inactiveBuilds, initialInactive);
    expect(stateChanges, 0);
    // Source/state changes must still refresh inactive controls.
    p.setExpanded(true);
    await tester.pump();
    expect(inactiveBuilds, initialInactive + 1);
    await tester.pumpWidget(const SizedBox.shrink());
    p.removeListener(stateChanged);
    p.setExpanded(false);
    await tester.runAsync(LoomPlaybackController.closeAll);
  });

  test('reopening a chat has its cached wallpaper key immediately', () async {
    const raw = 'test-identity:test-conversation';
    final first = LoomWallpaperStore.chatKey(raw);
    final second = LoomWallpaperStore.chatKey(raw);
    expect(identical(first, second), true);
    final key = await first;
    expect(LoomWallpaperStore.cachedChatKey(raw), key);
    expect(await LoomWallpaperStore.chatKey(raw), key);
    expect(key, matches(RegExp(r'^[a-f0-9]{64}$')));
  });
}

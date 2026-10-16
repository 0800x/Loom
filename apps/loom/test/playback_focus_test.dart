import 'dart:async';

import 'package:loom_next/features/media/application/playback_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'video replacement and recording pause share the same focus owner',
    () async {
      final controller = LoomPlaybackController.instance;
      var firstPaused = 0, secondPaused = 0;
      Future<void> first() async {
        firstPaused++;
      }

      Future<void> second() async {
        secondPaused++;
      }

      expect(await controller.claimVideo(first), isTrue);
      expect(await controller.claimVideo(second), isTrue);
      expect(firstPaused, 1);
      expect(secondPaused, 0);
      // Voice/camera preparation calls this same public pause operation.
      await controller.pause();
      expect(secondPaused, 1);
      // Resuming existing audio must also stop the current video.
      await controller.toggle();
      expect(secondPaused, 2);
      controller.releaseVideo(second);
      await controller.close();
    },
  );
  test('a superseded async video claim cannot resume playback', () async {
    final controller = LoomPlaybackController.instance;
    final barrier = Completer<void>();
    Future<void> original() => barrier.future;
    Future<void> second() async {}
    Future<void> third() async {}
    expect(await controller.claimVideo(original), isTrue);
    final pending = controller.claimVideo(second);
    expect(await controller.claimVideo(third), isTrue);
    barrier.complete();
    expect(await pending, isFalse);
    controller.releaseVideo(third);
    await controller.close();
  });
}

import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_media_kit/video_player_media_kit.dart';

// Real Android/iOS device, with camera/microphone permission granted.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('in-app native camera produces a playable clip', (tester) async {
    MediaKit.ensureInitialized();
    VideoPlayerMediaKit.ensureInitialized(android: true, iOS: true);
    final devices = await availableCameras();
    expect(devices, isNotEmpty);
    final camera = CameraController(
      devices.first,
      ResolutionPreset.medium,
      enableAudio: true,
    );
    VideoPlayerController? player;
    final files = <File>[];
    try {
      await camera.initialize();
      final photo = await camera.takePicture();
      files.add(File(photo.path));
      expect(await files.last.length(), greaterThan(100));
      await camera.startVideoRecording();
      await Future<void>.delayed(const Duration(seconds: 2));
      final clip = await camera.stopVideoRecording();
      files.add(File(clip.path));
      player = VideoPlayerController.file(files.last);
      await player.initialize();
      expect(player.value.duration, greaterThan(Duration.zero));
      expect(player.value.size.width, greaterThan(0));
    } finally {
      await player?.dispose();
      await camera.dispose();
      for (final file in files) {
        if (await file.exists()) await file.delete();
      }
    }
  });
}

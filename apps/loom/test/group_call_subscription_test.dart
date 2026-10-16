import 'package:loom_next/features/groups/application/group_call_subscription.dart';
import 'package:loom_next/features/groups/application/group_call_media.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

class Track extends Fake implements lk.RemoteTrackPublication {
  @override
  String get sid => 'track';
  @override
  bool subscriptionAllowed = false;
  @override
  bool subscribed = false;
  int requests = 0, cancellations = 0;
  bool fail = false;
  @override
  Future<void> subscribe() async {
    requests++;
    if (fail) throw StateError('Temporary failure');
  }

  @override
  Future<void> unsubscribe() async {
    cancellations++;
    subscribed = false;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'zero-grant join can later subscribe, retry, revoke and reauthorize',
    () async {
      final track = Track(), requested = <String>{};
      await syncLoomGroupTrack(track, requested, authorized: true);
      expect(track.requests, 0);
      expect(requested, isEmpty);
      track.subscriptionAllowed = true;
      track.fail = true;
      await expectLater(
        syncLoomGroupTrack(track, requested, authorized: true),
        throwsStateError,
      );
      expect(requested, isEmpty);
      track.fail = false;
      await syncLoomGroupTrack(track, requested, authorized: true);
      await syncLoomGroupTrack(track, requested, authorized: true);
      expect(
        track.requests,
        2,
        reason: 'One failed request and one successful retry; no duplicate',
      );
      track.subscribed = true;
      await syncLoomGroupTrack(track, requested, authorized: false);
      expect(track.cancellations, 1);
      expect(requested, isEmpty);
      await syncLoomGroupTrack(track, requested, authorized: true);
      expect(track.requests, 3);
    },
  );
  for (final platform in [
    TargetPlatform.windows,
    TargetPlatform.linux,
    TargetPlatform.macOS,
  ]) {
    test(
      'desktop output routing never invokes the missing mobile method: $platform',
      () async {
        debugDefaultTargetPlatformOverride = platform;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        var commands = 0;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('FlutterWebRTC.Method'),
              (_) async {
                commands++;
                throw MissingPluginException();
              },
            );
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(
                const MethodChannel('FlutterWebRTC.Method'),
                null,
              ),
        );
        final media = LoomLiveKitGroupCallMedia();
        expect(media.supportsSpeakerphone, isFalse);
        await media.speakerphone(true);
        expect(commands, 0);
        expect(media.microphoneEnabled, isFalse);
        expect(media.cameraEnabled, isFalse);
        await media.close();
        media.dispose();
      },
    );
  }
}

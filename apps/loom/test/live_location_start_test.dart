import 'dart:async';
import 'package:loom_crypto_bridge/loom_crypto_bridge.dart';
import 'package:loom_next/features/messaging/application/message_content.dart';
import 'package:loom_next/features/messaging/application/messaging_session_controller.dart';
import 'package:loom_next/features/nodes/application/node_directory_controller.dart';
import 'package:loom_next/features/onboarding/application/onboarding_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';

class LiveMessaging extends LoomMessagingSessionController {
  LiveMessaging(superOnboarding) : super(onboarding: superOnboarding);
  final fix = Completer<Position>();
  final sent = <LoomMessageContent>[];
  int fixes = 0;
  @override
  Future<Position> currentPosition() {
    fixes++;
    return fix.future;
  }

  @override
  Future<bool> sendText(
    String id,
    String text, {
    String? replyToMessageId,
    LoomVisibleMessage? reply,
    LoomMessageContent? content,
  }) async {
    sent.add(content!);
    return true;
  }
}

Position point() => Position(
  latitude: 35.7,
  longitude: 51.4,
  timestamp: DateTime.now(),
  accuracy: 3,
  altitude: 0,
  altitudeAccuracy: 0,
  heading: 0,
  headingAccuracy: 0,
  speed: 0,
  speedAccuracy: 0,
);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => LoomAppLock.instance.initialize());
  test(
    'concurrent starts emit one session, and stopping emits one terminal update',
    () async {
      final nodes = LoomNodeDirectoryController();
      final onboarding = LoomOnboardingController(nodes: nodes);
      final messaging = LiveMessaging(onboarding);
      final starting = messaging.startLiveLocation(
        'group',
        const Duration(minutes: 15),
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        await messaging.startLiveLocation('group', const Duration(minutes: 15)),
        isFalse,
      );
      messaging.fix.complete(point());
      expect(await starting, isTrue);
      expect(messaging.fixes, 1);
      expect(messaging.sent.length, 1);
      final session = messaging.liveSessionId;
      await messaging.stopLiveLocation();
      await messaging.stopLiveLocation();
      expect(messaging.sent.length, 2);
      expect(messaging.sent.last.location!['session'], session);
      expect(messaging.sent.last.location!['stopped'], true);
      messaging.dispose();
      onboarding.dispose();
      nodes.dispose();
    },
  );
  test(
    'the freshly confirmed map position does not trigger another GPS request',
    () async {
      final nodes = LoomNodeDirectoryController();
      final onboarding = LoomOnboardingController(nodes: nodes);
      final messaging = LiveMessaging(onboarding);
      expect(
        await messaging.startLiveLocation(
          'chat',
          const Duration(minutes: 15),
          initialPosition: point(),
        ),
        isTrue,
      );
      expect(messaging.fixes, 0);
      expect(messaging.sent.length, 1);
      await messaging.stopLiveLocation();
      messaging.dispose();
      onboarding.dispose();
      nodes.dispose();
    },
  );
}

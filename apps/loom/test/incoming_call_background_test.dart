import 'package:loom_calls/loom_calls.dart';
import 'package:loom_crypto_bridge/loom_crypto_bridge.dart';
import 'package:loom_design/loom_design.dart';
import 'package:loom_models/loom_models.dart';
import 'package:loom_next/features/calls/application/call_platform_bridge.dart';
import 'package:loom_next/features/calls/application/call_session_controller.dart';
import 'package:loom_next/features/calls/presentation/call_surfaces.dart';
import 'package:loom_next/features/messaging/application/messaging_session_controller.dart';
import 'package:loom_next/features/nodes/application/node_directory_controller.dart';
import 'package:loom_next/features/onboarding/application/onboarding_controller.dart';
import 'package:loom_next/features/security/presentation/app_lock_gate.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _Calls extends LoomCallSessionController {
  _Calls({required super.onboarding, required super.messaging});

  final testEngine = _Engine();

  @override
  LoomCallEngine get engine => testEngine;

  void publishState(LoomCallSnapshot state) {
    testEngine.state = state;
    notifyListeners();
  }

  void publish(LoomPendingCall? pending) {
    incomingCall = pending;
    incomingPeer = pending == null
        ? null
        : const LoomCallPeer(
            conversationId: 'conversation',
            address: '@alice:node.example',
            displayName: 'Private caller name',
            identityId: 'chn:alice',
            devices: [],
          );
    notifyListeners();
  }
}

class _Engine implements LoomCallEngine {
  @override
  LoomCallSnapshot state = const LoomCallSnapshot();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('loom/calls');
  setUpAll(() => LoomAppLock.instance.initialize());

  test(
    'native launch action is consumed after Dart installs its handler',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => call.method == 'prepare'
            ? {'action': 'accept', 'callId': 'pending-on-launch'}
            : null,
      );
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final accepted = <String>[];
      await LoomCallPlatformBridge().initialize(
        onAccept: (id) async {
          accepted.add(id);
        },
        onDecline: (_) async {},
      );
      expect(accepted, ['pending-on-launch']);
    },
  );

  for (final kind in LoomCallKind.values) {
    testWidgets(
      '$kind rings and clears natively while App Lock hides the navigator, without a frame',
      (tester) async {
        final nodes = LoomNodeDirectoryController();
        final onboarding = LoomOnboardingController(nodes: nodes);
        final messaging = LoomMessagingSessionController(
          onboarding: onboarding,
        );
        final calls = _Calls(onboarding: onboarding, messaging: messaging);
        final observer = LoomCallRouteObserver();
        final navigator = GlobalKey<NavigatorState>();
        final lock = LoomAppLock.instance;
        lock.enabled = true;
        lock.locked = true;
        final native = <MethodCall>[];
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(channel, (call) async {
          native.add(call);
          return null;
        });
        addTearDown(() {
          messenger.setMockMethodCallHandler(channel, null);
          lock.enabled = false;
          lock.locked = false;
          calls.dispose();
          messaging.dispose();
          onboarding.dispose();
          nodes.dispose();
          observer.activeCallVisible.dispose();
          binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        });
        var lockTransitions = 0;
        await tester.pumpWidget(
          LoomCallSessionScope(
            controller: calls,
            child: MaterialApp(
              navigatorKey: navigator,
              theme: LoomTheme.dark(),
              home: const Scaffold(body: Text('Private conversations')),
              builder: (context, child) => LoomGlassScope(
                quality: LoomGlassQuality.disabled,
                child: LoomCallOverlayHost(
                  navigatorKey: navigator,
                  routeObserver: observer,
                  child: LoomAppLockGate(
                    onLocked: () {
                      lockTransitions++;
                    },
                    onUnlocked: () {},
                    child: child!,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        final transitionsBeforeCall = lockTransitions;
        await tester.runAsync(() async {
          calls.publish(
            LoomPendingCall(
              callId: 'background-${kind.name}',
              conversationId: 'conversation',
              callerIdentityId: 'chn:alice',
              kind: kind,
              createdAt: DateTime.now().toUtc(),
              expiresAt: DateTime.now().toUtc().add(
                const Duration(seconds: 45),
              ),
              offerSdp: 'v=0\r\ns=-\r\n',
            ),
          );
          await pumpEventQueue();
        });
        // No pump/frame between receiving the offer and showing native UI.
        final incoming = native
            .where((call) => call.method == 'showIncoming')
            .single;
        expect((incoming.arguments as Map)['callerName'], 'Loom');
        expect((incoming.arguments as Map)['callerAddress'], '');
        expect(
          (incoming.arguments as Map)['video'],
          kind == LoomCallKind.video,
        );
        await tester.pump();
        expect(find.text('Private caller name'), findsNothing);
        expect(find.text('Private conversations'), findsNothing);
        expect(
          lockTransitions,
          transitionsBeforeCall,
          reason: 'call updates must not recreate the lock gate',
        );
        await tester.runAsync(() async {
          calls.publish(null);
          await pumpEventQueue();
        });
        expect(
          native.where((call) => call.method == 'clearIncoming'),
          hasLength(1),
        );
        await tester.pumpWidget(const SizedBox.shrink());
        expect(
          native.lastWhere((call) => call.method == 'setRingback').arguments,
          {'playing': false},
        );
      },
    );
  }

  for (final kind in LoomCallKind.values) {
    testWidgets('$kind outgoing ringback stops before media and on teardown', (
      tester,
    ) async {
      final nodes = LoomNodeDirectoryController();
      final onboarding = LoomOnboardingController(nodes: nodes);
      final messaging = LoomMessagingSessionController(
        onboarding: onboarding,
      );
      final calls = _Calls(onboarding: onboarding, messaging: messaging);
      final observer = LoomCallRouteObserver();
      final native = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        native.add(call);
        return null;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(channel, null);
        calls.dispose();
        messaging.dispose();
        onboarding.dispose();
        nodes.dispose();
        observer.activeCallVisible.dispose();
      });
      await tester.pumpWidget(
        LoomCallSessionScope(
          controller: calls,
          child: MaterialApp(
            theme: LoomTheme.dark(),
            home: const Scaffold(body: SizedBox.expand()),
            builder: (context, child) => LoomGlassScope(
              quality: LoomGlassQuality.disabled,
              child: LoomCallOverlayHost(
                navigatorKey: GlobalKey<NavigatorState>(),
                routeObserver: observer,
                child: child!,
              ),
            ),
          ),
        ),
      );
      Future<void> state(
        LoomCallLifecycle lifecycle, [
        LoomCallDirection direction = LoomCallDirection.outgoing,
      ]) async {
        await tester.runAsync(() async {
          calls.publishState(
            LoomCallSnapshot(
              callId: 'ringback-test',
              kind: kind,
              lifecycle: lifecycle,
              direction: direction,
            ),
          );
          await pumpEventQueue();
        });
      }

      List<bool> playback() => native
          .where((call) => call.method == 'setRingback')
          .map((call) => (call.arguments as Map)['playing'] as bool)
          .toList();
      await state(LoomCallLifecycle.preparing);
      expect(playback(), isEmpty);
      await state(LoomCallLifecycle.ringing);
      // Rebuilds must not restart sound.
      await state(LoomCallLifecycle.ringing);
      expect(playback(), [true]);
      await state(LoomCallLifecycle.connecting);
      expect(playback(), [true, false]);
      await state(LoomCallLifecycle.connected);
      await state(LoomCallLifecycle.reconnecting);
      await state(LoomCallLifecycle.ended);
      await state(LoomCallLifecycle.ringing, LoomCallDirection.incoming);
      expect(playback(), [true, false]);
      await state(LoomCallLifecycle.ringing);
      await state(LoomCallLifecycle.failed);
      expect(playback(), [true, false, true, false]);
      await state(LoomCallLifecycle.ringing);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(playback().last, false);
    });
  }
}

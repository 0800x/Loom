import 'package:loom_design/loom_design.dart';
import 'package:loom_models/loom_models.dart';
import 'package:loom_next/features/calls/application/call_session_controller.dart';
import 'package:loom_next/features/calls/presentation/call_surfaces.dart';
import 'package:loom_next/features/home/presentation/messenger_shell.dart';
import 'package:loom_next/features/messaging/application/messaging_session_controller.dart';
import 'package:loom_next/features/nodes/application/node_directory_controller.dart';
import 'package:loom_next/features/onboarding/application/onboarding_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child, {Locale locale = const Locale('en')}) => MaterialApp(
  theme: LoomTheme.light(),
  locale: locale,
  supportedLocales: const [Locale('en'), Locale('fa')],
  localizationsDelegates: const [
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  home: LoomGlassScope(quality: LoomGlassQuality.disabled, child: child),
);

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets('conversation call chooser exposes audio and video options', (
    tester,
  ) async {
    _phone(tester);
    await tester.pumpWidget(_host(const MessengerShell(preview: true)));
    await tester.tap(find.text('Maya Brooks').first);
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Conversation menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Call'));
    await tester.pumpAndSettle();
    expect(find.text('Audio call'), findsOneWidget);
    expect(find.text('Video call'), findsOneWidget);
    expect(find.byIcon(LoomIcons.call_outlined), findsWidgets);
    expect(find.byIcon(LoomIcons.videocam_outlined), findsOneWidget);
  });

  testWidgets(
    'incoming call surface shows verified peer identity and actions',
    (tester) async {
      final nodes = LoomNodeDirectoryController();
      final onboarding = LoomOnboardingController(nodes: nodes);
      final messaging = LoomMessagingSessionController(onboarding: onboarding);
      final calls = LoomCallSessionController(
        onboarding: onboarding,
        messaging: messaging,
      );
      calls.incomingCall = LoomPendingCall(
        callId: 'call-incoming',
        conversationId: 'conv-incoming',
        callerIdentityId: 'chn:alice',
        kind: LoomCallKind.video,
        createdAt: DateTime.now().toUtc(),
        expiresAt: DateTime.now().toUtc().add(const Duration(seconds: 45)),
        offerSdp: 'v=0',
      );
      calls.incomingPeer = const LoomCallPeer(
        conversationId: 'conv-incoming',
        address: '@alice:node.example',
        displayName: 'Alice Example',
        identityId: 'chn:alice',
        devices: <LoomDeviceKeyBundle>[],
      );
      final routeObserver = LoomCallRouteObserver();
      final navigatorKey = GlobalKey<NavigatorState>();
      addTearDown(routeObserver.activeCallVisible.dispose);
      addTearDown(calls.dispose);
      addTearDown(messaging.dispose);
      addTearDown(onboarding.dispose);
      addTearDown(nodes.dispose);

      await tester.pumpWidget(
        LoomCallSessionScope(
          controller: calls,
          child: _host(
            LoomCallOverlayHost(
              navigatorKey: navigatorKey,
              routeObserver: routeObserver,
              child: const Scaffold(body: SizedBox.expand()),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Alice Example'), findsOneWidget);
      expect(find.text('@alice:node.example'), findsOneWidget);
      expect(find.text('Incoming video call'), findsOneWidget);
      expect(find.text('Accept'), findsOneWidget);
      expect(find.text('Decline'), findsOneWidget);
    },
  );

  testWidgets('incoming call surface localizes to Persian and preserves RTL', (
    tester,
  ) async {
    final nodes = LoomNodeDirectoryController();
    final onboarding = LoomOnboardingController(nodes: nodes);
    final messaging = LoomMessagingSessionController(onboarding: onboarding);
    final calls = LoomCallSessionController(
      onboarding: onboarding,
      messaging: messaging,
    );
    calls.incomingCall = LoomPendingCall(
      callId: 'call-fa',
      conversationId: 'conv-fa',
      callerIdentityId: 'chn:alice',
      kind: LoomCallKind.audio,
      createdAt: DateTime.now().toUtc(),
      expiresAt: DateTime.now().toUtc().add(const Duration(seconds: 45)),
      offerSdp: 'v=0',
    );
    final routeObserver = LoomCallRouteObserver();
    addTearDown(routeObserver.activeCallVisible.dispose);
    addTearDown(calls.dispose);
    addTearDown(messaging.dispose);
    addTearDown(onboarding.dispose);
    addTearDown(nodes.dispose);

    await tester.pumpWidget(
      LoomCallSessionScope(
        controller: calls,
        child: _host(
          LoomCallOverlayHost(
            navigatorKey: GlobalKey<NavigatorState>(),
            routeObserver: routeObserver,
            child: const Scaffold(body: SizedBox.expand()),
          ),
          locale: const Locale('fa'),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('تماس صوتی ورودی'), findsOneWidget);
    expect(find.text('پذیرش'), findsOneWidget);
    expect(find.text('رد تماس'), findsOneWidget);
    expect(
      Directionality.of(tester.element(find.byType(LoomCallOverlayHost))),
      TextDirection.rtl,
    );
  });
}

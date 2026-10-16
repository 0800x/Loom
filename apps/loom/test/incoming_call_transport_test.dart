import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:loom_crypto_bridge/loom_crypto_bridge.dart';
import 'package:loom_design/loom_design.dart';
import 'package:loom_models/loom_models.dart';
import 'package:loom_next/features/calls/application/call_session_controller.dart';
import 'package:loom_next/features/calls/presentation/call_surfaces.dart';
import 'package:loom_next/features/messaging/application/messaging_session_controller.dart';
import 'package:loom_next/features/nodes/application/node_directory_controller.dart';
import 'package:loom_next/features/onboarding/application/onboarding_controller.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _Onboarding extends LoomOnboardingController {
  _Onboarding({required super.nodes});

  @override
  Future<LoomDeviceRequestProofProvider> deviceRequestProofProvider() async =>
      LoomDeviceRequestProofProvider(
        deviceId: receipt!.deviceId,
        signer: (_) async => List<int>.filled(64, 0),
      );
}

class _Messaging extends LoomMessagingSessionController {
  _Messaging({required super.onboarding});

  @override
  Future<void> open() async {}

  @override
  Future<void> synchronize() async {}
}

class _RealHttpOverrides extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Initialize the process singleton outside each widget test's FakeAsync
  // zone: a cached Future from an earlier test otherwise cannot complete here.
  setUpAll(() => LoomAppLock.instance.initialize());
  for (final kind in LoomCallKind.values) {
    for (final socketAvailable in [true, false]) {
      testWidgets(
        '${kind.name} incoming overlay receives ${socketAvailable ? 'an immediate WebSocket offer' : 'a pending HTTP offer without WebSocket'}',
        (tester) async {
          final lock = LoomAppLock.instance;
          lock.enabled = false;
          lock.locked = false;
          final nodes = LoomNodeDirectoryController();
          final onboarding = _Onboarding(nodes: nodes);
          final messaging = _Messaging(onboarding: onboarding);
          final calls = LoomCallSessionController(
            onboarding: onboarding,
            messaging: messaging,
          );
          final observer = LoomCallRouteObserver();
          final navigator = GlobalKey<NavigatorState>();
          final sockets = <WebSocket>[];
          final signalReaders = <StreamSubscription<dynamic>>[];
          final received = <Map<String, dynamic>>[];
          late Completer<Map<String, dynamic>> ringingReceived;
          late HttpServer server;
          late Directory support;
          final messenger =
              TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
          const paths = MethodChannel('plugins.flutter.io/path_provider');
          const native = MethodChannel('loom/calls');
          messenger.setMockMethodCallHandler(native, (_) async => null);
          await tester.runAsync(() async {
            // The Future must belong to the real async zone too. A completer
            // created in the widget test's fake zone can receive the frame but
            // leave its completion microtask frozen while runAsync awaits it.
            ringingReceived = Completer<Map<String, dynamic>>();
            support = await Directory.systemTemp.createTemp('loom-incoming-');
            server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          });
          messenger.setMockMethodCallHandler(paths, (_) async => support.path);
          nodes.selectedEndpoint = Uri.parse('http://127.0.0.1:${server.port}');
          onboarding.committedIdentity = LoomIdentityPublic(
            identityId: 'chn:bob',
            publicKey: 'test-public-key',
            fingerprint: 'test-fingerprint',
            createdAt: DateTime.now().toUtc(),
          );
          onboarding.receipt = const LoomRegistrationReceipt(
            accountId: 'bob',
            deviceId: 'dev_00000000-0000-0000-0000-000000000001',
            address: '@bob:node.test',
            homeNode: 'node.test',
          );
          onboarding.status = LoomOnboardingStatus.complete;
          onboarding.accessToken = 'test-token';
          onboarding.accessTokenExpiresAt = DateTime.now().add(
            const Duration(hours: 1),
          );
          final now = DateTime.now().toUtc();
          const sdp = 'v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\n';
          final offer = <String, Object?>{
            'kind': 'call.offer',
            'callId': 'incoming-${kind.name}',
            'conversationId': 'receiver-conversation',
            'senderIdentityId': 'chn:alice',
            'targetIdentityId': 'chn:bob',
            'sequence': 1,
            'mediaKind': kind.name,
            'sdp': sdp,
            'sdpType': 'offer',
            'createdAt': now.toIso8601String(),
          };
          final pending = <String, Object?>{
            'callId': offer['callId'],
            'conversationId': offer['conversationId'],
            'callerIdentityId': offer['senderIdentityId'],
            'kind': kind.name,
            'createdAt': now.toIso8601String(),
            'expiresAt': now.add(const Duration(seconds: 45)).toIso8601String(),
            'offerSdp': sdp,
          };
          await tester.runAsync(() async {
            server.listen((request) async {
              if (request.uri.path == '/realtime/v1' && socketAvailable) {
                final socket = await WebSocketTransformer.upgrade(request);
                sockets.add(socket);
                final reader = socket.listen((data) {
                  final signal =
                      jsonDecode(data as String) as Map<String, dynamic>;
                  received.add(signal);
                  if (signal['kind'] == 'call.ringing' &&
                      signal['callId'] == offer['callId'] &&
                      !ringingReceived.isCompleted) {
                    ringingReceived.complete(signal);
                  }
                });
                // Defer server reads until the overlay is visible and the
                // real-time wait has started, exercising late frame delivery.
                reader.pause();
                signalReaders.add(reader);
                // Replay on upgrade, before controller.open() has completed.
                socket.add(jsonEncode(offer));
                return;
              }
              request.response.headers.contentType = ContentType.json;
              if (request.uri.path == '/api/v1/calls/pending') {
                request.response.write(
                  jsonEncode({
                    'calls': socketAvailable ? [] : [pending],
                  }),
                );
              } else {
                request.response.statusCode = HttpStatus.serviceUnavailable;
                request.response.write(
                  jsonEncode({'error': 'test_socket_unavailable'}),
                );
              }
              await request.response.close();
            });
          });
          var cleaned = false;
          Future<void> cleanup() async {
            if (cleaned) return;
            cleaned = true;
            messenger.setMockMethodCallHandler(paths, null);
            messenger.setMockMethodCallHandler(native, null);
            for (final reader in signalReaders) {
              if (reader.isPaused) {
                reader.resume();
              }
            }
            // Finish the server handshake while the client still consumes its
            // socket, before controller disposal cancels that subscription.
            for (final socket in sockets) {
              await socket.close();
            }
            calls.dispose();
            messaging.dispose();
            onboarding.dispose();
            nodes.dispose();
            observer.activeCallVisible.dispose();
            await server.close(force: true);
            await support.delete(recursive: true);
          }

          addTearDown(() => tester.runAsync(cleanup));
          await tester.pumpWidget(
            LoomCallSessionScope(
              controller: calls,
              child: MaterialApp(
                navigatorKey: navigator,
                theme: LoomTheme.dark(),
                builder: (_, child) => LoomGlassScope(
                  quality: LoomGlassQuality.disabled,
                  child: LoomCallOverlayHost(
                    navigatorKey: navigator,
                    routeObserver: observer,
                    child: child!,
                  ),
                ),
                home: const Scaffold(body: Text('Receiver already open')),
              ),
            ),
          );
          await tester.runAsync(() async {
            await HttpOverrides.runWithHttpOverrides(() async {
              await calls.open();
              expect(calls.ready, isTrue, reason: calls.errorMessage);
              if (socketAvailable) {
                expect(sockets, hasLength(1), reason: calls.connectionError);
              }
              for (
                var attempt = 0;
                calls.incomingCall == null && attempt < 100;
                attempt++
              ) {
                await Future<void>.delayed(const Duration(milliseconds: 10));
              }
              expect(calls.incomingCall, isNotNull);
            }, _RealHttpOverrides());
          });
          expect(calls.incomingCall?.kind, kind);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          expect(find.text('Incoming ${kind.name} call'), findsOneWidget);
          expect(find.text('Accept'), findsOneWidget);
          expect(find.text('Decline'), findsOneWidget);
          if (socketAvailable) {
            // Widget pumps advance fake time, not the loopback socket's I/O.
            // Wait in real time for the server to receive this call's hint.
            expect(received, isEmpty);
            await tester.runAsync(() async {
              final ringingFuture = ringingReceived.future.timeout(
                const Duration(seconds: 5),
                onTimeout: () => throw TestFailure(
                  'No call.ringing received for ${offer['callId']}; '
                  'received: $received; connection: ${calls.connectionError}',
                ),
              );
              for (final reader in signalReaders) {
                reader.resume();
              }
              final ringing = await ringingFuture;
              expect(ringing['targetIdentityId'], 'chn:alice');
              expect(ringing['conversationId'], offer['conversationId']);
              expect(ringing['mediaKind'], kind.name);
              expect(ringing['reason'], 'presented');
            });
          }
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(cleanup);
        },
      );
    }
  }
}

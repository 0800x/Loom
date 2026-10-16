import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:loom_models/loom_models.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:test/test.dart';

const sdp = 'v=0\r\no=- 1234 2 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\n'
    'm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=ice-ufrag:test\r\n';

LoomDeviceRequestProofProvider proof() => LoomDeviceRequestProofProvider(
      deviceId: 'dev_00000000-0000-4000-8000-000000000001',
      signer: (_) async => List<int>.filled(64, 0),
    );

void main() {
  for (final kind in LoomCallKind.values) {
    test(
      '${kind.name} WebSocket preserves multiline offer and answer SDP',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final peer = Completer<WebSocket>();
        server.listen((request) async {
          final socket = await WebSocketTransformer.upgrade(request);
          socket.listen((_) {});
          peer.complete(socket);
        });
        final stages = <String>[];
        final connection = LoomCallSignalingConnection(
          baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
          accessTokenProvider: () async => 'test-token',
          deviceProofProvider: proof(),
          trace: stages.add,
        );
        final received = <LoomCallSignal>[];
        final complete = Completer<void>();
        final subscription = connection.signals.listen((signal) {
          received.add(signal);
          if (received.length == 2) complete.complete();
        });
        addTearDown(() async {
          await subscription.cancel();
          await connection.dispose();
          await server.close(force: true);
        });
        await connection.connect();
        final socket = await peer.future;
        final frame = <String, Object?>{
          'kind': 'call.offer',
          'callId': 'call-1',
          'conversationId': 'conv',
          'senderIdentityId': 'peer',
          'targetIdentityId': 'self',
          'sequence': 1,
          'createdAt': DateTime.now().toUtc().toIso8601String(),
          'mediaKind': kind.name,
          'sdp': sdp,
          'sdpType': 'offer',
        };
        socket.add(jsonEncode({...frame, 'callId': 'bad\nidentity'}));
        socket.add(jsonEncode({...frame, 'sdp': 'v=0\u0000'}));
        socket.add(
          jsonEncode({
            ...frame,
            'createdAt': DateTime.now()
                .toUtc()
                .add(const Duration(minutes: 2))
                .toIso8601String(),
          }),
        );
        socket.add(jsonEncode(frame));
        socket.add(
          jsonEncode({
            ...frame,
            'kind': 'call.answer',
            'sdpType': 'answer',
            'sequence': 2,
          }),
        );
        await complete.future.timeout(const Duration(seconds: 2));
        expect(received.map((s) => s.kind), ['call.offer', 'call.answer']);
        expect(received.map((s) => s.sdp), [sdp, sdp]);
        expect(received.first.mediaKind, kind);
        expect(
          stages,
          containsAll([
            'offer_rejected:fields',
            'offer_rejected:sdp',
            'offer_rejected:clock_future',
            'offer_parsed:${kind.name}',
          ]),
        );
        final trace = stages.join('\n');
        for (final privateValue in [
          'test-token',
          'call-1',
          'bad\nidentity',
          sdp,
        ]) {
          expect(trace, isNot(contains(privateValue)));
        }
      },
    );
  }

  test(
    'pending-call recovery accepts multiline SDP and ignores corrupt offers',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final http = HttpClient();
      addTearDown(() async {
        http.close(force: true);
        await server.close(force: true);
      });
      server.listen((request) async {
        final call = {
          'callId': 'call-1',
          'conversationId': 'conv',
          'callerIdentityId': 'peer',
          'createdAt': DateTime.now().toUtc().toIso8601String(),
          'expiresAt': DateTime.now()
              .toUtc()
              .add(const Duration(seconds: 45))
              .toIso8601String(),
          'kind': 'video',
          'offerSdp': sdp,
        };
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'calls': [
              {...call, 'offerSdp': 'v=0\u0000'},
              {
                ...call,
                'expiresAt': DateTime.now()
                    .toUtc()
                    .subtract(const Duration(seconds: 1))
                    .toIso8601String(),
              },
              call,
            ],
          }),
        );
        await request.response.close();
      });
      final stages = <String>[];
      final api = LoomCallClient(
        baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
        accessTokenProvider: () async => 'test-token',
        deviceProofProvider: proof(),
        trace: stages.add,
        httpClient: http,
      );
      final pending = await api.fetchPendingCalls();
      expect(pending, hasLength(1));
      expect(pending.single.offerSdp, sdp);
      expect(pending.single.kind, LoomCallKind.video);
      expect(
        stages,
        containsAll([
          'pending_rejected:sdp',
          'pending_rejected:expired',
          'pending_http_ok:1',
        ]),
      );
      final trace = stages.join('\n');
      for (final privateValue in ['test-token', 'call-1', sdp]) {
        expect(trace, isNot(contains(privateValue)));
      }
    },
  );
}

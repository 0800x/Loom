import 'dart:convert';
import 'dart:io';

import 'package:loom_models/loom_models.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:test/test.dart';

void main() {
  test(
    'RTC configuration recovers from a stale token without a sign-in loop',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final http = HttpClient();
      addTearDown(() async {
        http.close(force: true);
        await server.close(force: true);
      });
      var token = 'stale';
      var requests = 0;
      server.listen((request) async {
        await request.drain<void>();
        requests++;
        final accepted =
            request.headers.value(HttpHeaders.authorizationHeader) ==
            'Bearer renewed';
        request.response.statusCode = accepted ? 200 : 401;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode(
            accepted
                ? {
                    'iceServers': [
                      {
                        'urls': ['stun:example.org:3478'],
                      },
                    ],
                    'expiresAt': DateTime.now()
                        .toUtc()
                        .add(const Duration(minutes: 5))
                        .toIso8601String(),
                  }
                : {'error': 'unauthorized'},
          ),
        );
        await request.response.close();
      });
      final client = LoomCallClient(
        baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
        httpClient: http,
        accessTokenProvider: () async => token,
        deviceProofProvider: LoomDeviceRequestProofProvider(
          deviceId: 'dev_00000000-0000-0000-0000-000000000001',
          signer: (_) async => List<int>.filled(64, 7),
        ),
        refreshRejectedToken: (rejected) async {
          expect(rejected, 'stale');
          token = 'renewed';
          return true;
        },
      );
      expect((await client.fetchRtcConfiguration()).iceServers, hasLength(1));
      expect(requests, 2);
    },
  );

  for (final acceptRetry in [true, false]) {
    test(
      '401 retries with a fresh signed proof once (accepted: $acceptRetry)',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final http = HttpClient();
        addTearDown(() async {
          http.close(force: true);
          await server.close(force: true);
        });
        final bodies = <String>[];
        final nonces = <String?>[];
        final tokens = <String?>[];
        server.listen((request) async {
          bodies.add(await utf8.decoder.bind(request).join());
          nonces.add(request.headers.value('X-Loom-Request-Nonce'));
          tokens.add(request.headers.value(HttpHeaders.authorizationHeader));
          final ok = acceptRetry && tokens.last == 'Bearer fresh-token';
          request.response.statusCode = ok ? 201 : 401;
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode(
              ok
                  ? {
                      'messageId': 'server-1',
                      'clientId': 'stable-id',
                      'serverOrder': 1,
                      'createdAt': DateTime.utc(2026, 9, 26).toIso8601String(),
                    }
                  : {'error': 'unauthorized'},
            ),
          );
          await request.response.close();
        });
        var token = 'expired-token';
        var refreshes = 0;
        final client = LoomMessagingClient(
          baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
          httpClient: http,
          accessTokenProvider: () async => token,
          deviceProofProvider: LoomDeviceRequestProofProvider(
            deviceId: 'dev_00000000-0000-0000-0000-000000000001',
            signer: (_) async => List<int>.filled(64, 7),
          ),
          refreshRejectedToken: (rejected) async {
            expect(rejected, 'expired-token');
            refreshes++;
            token = 'fresh-token';
            return true;
          },
        );
        final send = client.sendOpaqueMessage(
          conversationId: 'chat',
          clientId: 'stable-id',
          type: LoomMessageType.text,
          ciphertext: 'same-ciphertext',
          protocolVersion: 'test-v1',
        );
        if (acceptRetry) {
          expect((await send).clientId, 'stable-id');
        } else {
          await expectLater(
            send,
            throwsA(
              isA<LoomHttpStatusException>().having(
                (e) => e.statusCode,
                'status',
                401,
              ),
            ),
          );
        }
        expect(refreshes, 1);
        expect(bodies.length, 2);
        expect(
          bodies.first,
          bodies.last,
          reason: 'retry must preserve ciphertext and idempotency key',
        );
        expect(tokens, ['Bearer expired-token', 'Bearer fresh-token']);
        expect(nonces.first, isNotNull);
        expect(nonces.first, isNot(nonces.last));
      },
    );
  }
}

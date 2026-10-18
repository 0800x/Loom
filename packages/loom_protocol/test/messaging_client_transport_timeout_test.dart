import 'dart:async';
import 'dart:io';

import 'package:loom_models/loom_models.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:test/test.dart';

void main() {
  LoomDeviceRequestProofProvider proofProvider() =>
      LoomDeviceRequestProofProvider(
        deviceId: 'dev_00000000-0000-0000-0000-000000000001',
        signer: (_) async => List<int>.filled(64, 7),
      );

  Future<({HttpServer server, Completer<void> release})> stallingServer({
    int statusCode = HttpStatus.ok,
  }) async {
    final release = Completer<void>();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      await request.drain<void>();
      request.response.statusCode = statusCode;
      request.response.headers.contentType = ContentType.json;
      request.response.headers.contentLength = 512;
      request.response.write('{"partial":');
      await request.response.flush();
      await release.future;
      try {
        await request.response.close();
      } catch (_) {
        // The client is expected to abort the request on its own deadline.
      }
    });
    return (server: server, release: release);
  }

  Future<void> expectTransportTimeout(Future<Object?> future) async {
    await expectLater(
      future.timeout(
        const Duration(seconds: 2),
        onTimeout: () => throw StateError(
          'request remained pending beyond the transport failure window',
        ),
      ),
      throwsA(isA<TimeoutException>()),
    );
  }

  test('messaging send times out after headers when body stalls', () async {
    final stalled = await stallingServer(statusCode: HttpStatus.created);
    addTearDown(() async {
      if (!stalled.release.isCompleted) stalled.release.complete();
      await stalled.server.close(force: true);
    });

    final client = LoomMessagingClient(
      baseUri: Uri.parse('http://127.0.0.1:${stalled.server.port}'),
      accessTokenProvider: () async => 'test-access-token',
      deviceProofProvider: proofProvider(),
      connectTimeout: const Duration(seconds: 1),
      responseHeaderTimeout: const Duration(seconds: 1),
      responseBodyTimeout: const Duration(milliseconds: 120),
    );

    await expectTransportTimeout(
      client.sendOpaqueMessage(
        conversationId: 'conversation-1',
        clientId: 'client-1',
        type: LoomMessageType.text,
        ciphertext: 'opaque-ciphertext',
        protocolVersion: 'test-v1',
      ),
    );
  });

  test('Node discovery times out after headers when body stalls', () async {
    final stalled = await stallingServer();
    addTearDown(() async {
      if (!stalled.release.isCompleted) stalled.release.complete();
      await stalled.server.close(force: true);
    });

    final client = LoomNodeClient(
      connectTimeout: const Duration(seconds: 1),
      responseHeaderTimeout: const Duration(seconds: 1),
      responseBodyTimeout: const Duration(milliseconds: 120),
    );

    await expectTransportTimeout(
      client.discoverDomain('127.0.0.1:${stalled.server.port}'),
    );
  });

  test(
    'Home-Node peer security lookup has the same bounded body deadline',
    () async {
      final stalled = await stallingServer();
      addTearDown(() async {
        if (!stalled.release.isCompleted) stalled.release.complete();
        await stalled.server.close(force: true);
      });

      final client = LoomUserSecurityClient(
        connectTimeout: const Duration(seconds: 1),
        responseHeaderTimeout: const Duration(seconds: 1),
        responseBodyTimeout: const Duration(milliseconds: 120),
      );

      await expectTransportTimeout(
        client.resolve(
          baseUri: Uri.parse('http://127.0.0.1:${stalled.server.port}'),
          accessToken: 'test-access-token',
          address: '@alice:example.com',
          deviceProofProvider: proofProvider(),
        ),
      );
    },
  );
}

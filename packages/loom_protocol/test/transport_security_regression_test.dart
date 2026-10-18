import 'dart:convert';
import 'dart:io';

import 'package:loom_protocol/loom_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('one transport policy protects LAN, public and loopback endpoints', () {
    for (final host in ['localhost', '127.0.0.1', '[::1]']) {
      expect(
        () => requireLoomTransport(Uri.parse('http://$host:7483')),
        returnsNormally,
      );
    }
    for (final host in [
      '10.1.2.3',
      '172.16.1.1',
      '192.168.1.2',
      '169.254.1.2',
      'example.org',
      '[fd00::1]',
    ]) {
      expect(
        () => requireLoomTransport(Uri.parse('http://$host')),
        throwsA(isA<LoomProtocolException>()),
      );
      expect(
        () => requireLoomTransport(Uri.parse('https://$host')),
        returnsNormally,
      );
    }
    for (final endpoint in [
      'https://user:password@example.org',
      'https://example.org/#fragment',
      'https://example.org/?query=1',
    ]) {
      expect(
        () => requireLoomTransport(Uri.parse(endpoint)),
        throwsA(isA<LoomProtocolException>()),
      );
    }
  });
  test('login, challenge, bundles, messaging and link all refuse plaintext LAN before sending', () async {
    final endpoint = Uri.parse('http://192.168.1.2:7483');
    final proof = LoomDeviceRequestProofProvider(
      deviceId: 'dev_11111111-1111-1111-1111-111111111111',
      signer: (_) async => List.filled(64, 0),
    );
    await expectLater(
      LoomNodeClient().login(
        baseUri: endpoint,
        username: 'alice',
        password: 'private',
      ),
      throwsA(isA<LoomProtocolException>()),
    );
    await expectLater(
      LoomPinnedNodeVerifier().verify(
        baseUri: endpoint,
        expectedNodeId: 'node:test',
        expectedPublicKey: base64Encode(List.filled(32, 0)),
      ),
      throwsA(isA<LoomProtocolException>()),
    );
    await expectLater(
      LoomSecurityClient().listIdentityDevices(
        baseUri: endpoint,
        accessToken: 'private',
        identityId: 'identity',
        identityPublicKey: 'key',
        deviceProofProvider: proof,
      ),
      throwsA(isA<LoomProtocolException>()),
    );
    await expectLater(
      LoomDeviceLinkClient().redeem(
        baseUri: endpoint,
        accessToken: 'private',
        linkId: 'link',
        token: 'token',
      ),
      throwsA(isA<LoomProtocolException>()),
    );
    await expectLater(
      LoomMessagingClient(
        baseUri: endpoint,
        accessTokenProvider: () async => 'private',
        deviceProofProvider: proof,
      ).sync(),
      throwsA(isA<LoomProtocolException>()),
    );
  });
  test(
    'redeem sends exactly authorization fields and never QR encryption secret',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final received = <String, Object?>{};
      server.listen((request) async {
        received.addAll(
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, Object?>,
        );
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'linkId': 'link',
            'payload': 'opaque',
            'identityId': 'identity',
            'sourceDeviceId': 'source',
            'expiresAt': DateTime.now()
                .toUtc()
                .add(const Duration(minutes: 5))
                .toIso8601String(),
          }),
        );
        await request.response.close();
      });
      final result = await LoomDeviceLinkClient().redeem(
        baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
        accessToken: 'authenticated',
        linkId: 'link',
        token: 'authorization-only',
      );
      expect(result.payload, 'opaque');
      expect(received, {'linkId': 'link', 'token': 'authorization-only'});
    },
  );
}

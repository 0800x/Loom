import 'dart:convert';
import 'dart:io';

import 'package:loom_models/loom_models.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:cryptography/cryptography.dart';
import 'package:test/test.dart';

Future<String> nodeIdFor(List<int> publicKey) async {
  final digest = await Sha256().hash(publicKey);
  return 'node:${base64UrlEncode(digest.bytes).replaceAll('=', '')}';
}

void main() {
  test(
    'discovers and verifies an Easy Mode Node on localhost with a port',
    () async {
      final algorithm = Ed25519();
      final keyPair = await algorithm.newKeyPair();
      final publicKey = await keyPair.extractPublicKey();
      final nodeId = await nodeIdFor(publicKey.bytes);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final authority = 'localhost:${server.port}';
      final endpoint = 'http://$authority';

      server.listen((request) async {
        request.response.headers.contentType = ContentType.json;
        if (request.uri.path == '/.well-known/loom/server') {
          const protocol = 'loom-federation-v1';
          final encodedKey = base64Encode(publicKey.bytes);
          final signature = await algorithm.sign(
            utf8.encode(
              '$authority\n$protocol\n$endpoint\n$nodeId\n$encodedKey',
            ),
            keyPair: keyPair,
          );
          request.response.write(
            jsonEncode({
              'endpoint': endpoint,
              'nodeId': nodeId,
              'protocol': protocol,
              'publicKey': encodedKey,
              'signature': base64Encode(signature.bytes),
            }),
          );
        } else if (request.uri.path == '/api/v1/server/info') {
          request.response.write(
            jsonEncode({
              'nodeId': nodeId,
              'serverVersion': '0.8.0',
              'protocolVersion': 'loom-node-v1',
              'registration': 'open',
              'federationMode': 'disabled',
              'capabilities': ['identity-registration'],
            }),
          );
        } else if (request.uri.path == '/api/v1/auth/register') {
          request.response.statusCode = HttpStatus.created;
          request.response.write(
            jsonEncode({
              'accountId': 'account-1',
              'deviceId': 'device-1',
              'address': '@tester:$authority',
              'accessToken': 'access-token',
              'refreshToken': 'refresh-token',
              'accessTokenExpiresInSeconds': 3600,
            }),
          );
        } else if (request.uri.path == '/api/v1/auth/refresh') {
          request.response.write(
            jsonEncode({
              'accountId': 'account-1',
              'deviceId': 'device-1',
              'address': '@tester:$authority',
              'accessToken': 'refreshed-access-token',
              'refreshToken': 'refresh-token',
              'accessTokenExpiresInSeconds': 3600,
            }),
          );
        } else if (request.uri.path == '/api/v1/auth/login') {
          request.response.write(
            jsonEncode({
              'accountId': 'account-1',
              'deviceId': 'device-1',
              'identityId': 'chn:test-identity',
              'address': '@tester:$authority',
              'accessToken': 'login-access-token',
              'refreshToken': 'login-refresh-token',
              'accessTokenExpiresInSeconds': 3600,
            }),
          );
        } else {
          request.response.statusCode = HttpStatus.notFound;
        }
        await request.response.close();
      });

      try {
        final client = LoomNodeClient();
        final discovered = await client.discoverDomain(authority);
        expect(discovered.endpoint, Uri.parse(endpoint));
        expect(discovered.nodeId, nodeId);

        final info = await client.fetchLiveInfo(discovered.endpoint);
        expect(info.serverVersion, '0.8.0');

        final registration = await client.registerIdentity(
          baseUri: discovered.endpoint,
          username: 'tester',
          displayName: 'Test User',
          password: 'correct horse battery staple',
          identity: LoomIdentityPublic(
            identityId: 'chn:test-identity',
            publicKey: base64Encode(List<int>.filled(32, 1)),
            fingerprint: 'TEST',
            createdAt: DateTime.utc(2026, 9, 2),
          ),
          deviceName: 'Test Device',
        );
        expect(registration.receipt.address, '@tester:$authority');
        expect(registration.receipt.homeNode, authority);

        final refreshed = await client.refreshSession(
          baseUri: discovered.endpoint,
          refreshToken: registration.refreshToken,
        );
        expect(refreshed.receipt.accountId, registration.receipt.accountId);
        expect(refreshed.receipt.deviceId, registration.receipt.deviceId);
        expect(refreshed.accessToken, 'refreshed-access-token');

        final login = await client.login(
          baseUri: discovered.endpoint,
          username: 'tester',
          password: 'correct horse battery staple',
        );
        expect(login.identityId, 'chn:test-identity');
        expect(login.receipt.address, '@tester:$authority');
      } finally {
        await server.close(force: true);
      }
    },
  );

  test('rejects a signed discovery document with a mismatched Node ID',
      () async {
    final algorithm = Ed25519();
    final keyPair = await algorithm.newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final authority = 'localhost:${server.port}';
    final endpoint = 'http://$authority';
    const forgedNodeId = 'node:not-derived-from-key';

    server.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      const protocol = 'loom-federation-v1';
      final encodedKey = base64Encode(publicKey.bytes);
      final signature = await algorithm.sign(
        utf8.encode(
          '$authority\n$protocol\n$endpoint\n$forgedNodeId\n$encodedKey',
        ),
        keyPair: keyPair,
      );
      request.response.write(jsonEncode({
        'endpoint': endpoint,
        'nodeId': forgedNodeId,
        'protocol': protocol,
        'publicKey': encodedKey,
        'signature': base64Encode(signature.bytes),
      }));
      await request.response.close();
    });

    try {
      final client = LoomNodeClient();
      await expectLater(
        client.discoverDomain(authority),
        throwsA(isA<LoomProtocolException>().having(
          (error) => error.message,
          'message',
          contains('Node ID'),
        )),
      );
    } finally {
      await server.close(force: true);
    }
  });

  test('rejects a signed discovery endpoint on a different authority',
      () async {
    final algorithm = Ed25519();
    final keyPair = await algorithm.newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    final nodeId = await nodeIdFor(publicKey.bytes);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final authority = 'localhost:${server.port}';
    final endpoint = 'http://127.0.0.1:${server.port}';

    server.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      const protocol = 'loom-federation-v1';
      final encodedKey = base64Encode(publicKey.bytes);
      final signature = await algorithm.sign(
        utf8.encode('$authority\n$protocol\n$endpoint\n$nodeId\n$encodedKey'),
        keyPair: keyPair,
      );
      request.response.write(jsonEncode({
        'endpoint': endpoint,
        'nodeId': nodeId,
        'protocol': protocol,
        'publicKey': encodedKey,
        'signature': base64Encode(signature.bytes),
      }));
      await request.response.close();
    });

    try {
      final client = LoomNodeClient();
      await expectLater(
        client.discoverDomain(authority),
        throwsA(isA<LoomProtocolException>().having(
          (error) => error.message,
          'message',
          contains('requested domain'),
        )),
      );
    } finally {
      await server.close(force: true);
    }
  });

  test('rejects cleartext endpoints on the public Internet', () async {
    final client = LoomNodeClient();
    await expectLater(
      client.discoverDomain('http://example.org:7483'),
      throwsA(
        isA<LoomProtocolException>().having(
          (error) => error.message,
          'message',
          contains('HTTPS'),
        ),
      ),
    );
  });
}

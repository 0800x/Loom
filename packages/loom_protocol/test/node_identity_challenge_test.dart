import 'dart:convert';
import 'dart:io';

import 'package:loom_protocol/loom_protocol.dart';
import 'package:cryptography/cryptography.dart';
import 'package:test/test.dart';

Future<String> _nodeId(List<int> publicKey) async {
  final digest = await Sha256().hash(publicKey);
  return 'node:${base64UrlEncode(digest.bytes).replaceAll('=', '')}';
}

void main() {
  test(
    'pinned Node challenge proves possession of the discovery key',
    () async {
      final algorithm = Ed25519();
      final keyPair = await algorithm.newKeyPair();
      final publicKey = await keyPair.extractPublicKey();
      final nodeId = await _nodeId(publicKey.bytes);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);

      server.listen((request) async {
        final decoded = jsonDecode(
          await utf8.decoder.bind(request).join(),
        ) as Map<String, dynamic>;
        final challenge = decoded['challenge'] as String;
        final signature = await algorithm.sign(
          utf8.encode('loom-node-challenge-v1\n$challenge'),
          keyPair: keyPair,
        );
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'nodeId': nodeId,
            'challenge': challenge,
            'signature': base64Encode(signature.bytes),
          }),
        );
        await request.response.close();
      });

      try {
        await LoomPinnedNodeVerifier().verify(
          baseUri: Uri.parse('http://localhost:${server.port}'),
          expectedNodeId: nodeId,
          expectedPublicKey: base64Encode(publicKey.bytes),
        );
      } finally {
        await server.close(force: true);
      }
    },
  );

  test(
    'pinned Node challenge rejects a response signed by another key',
    () async {
      final pinnedAlgorithm = Ed25519();
      final pinnedPair = await pinnedAlgorithm.newKeyPair();
      final pinnedPublic = await pinnedPair.extractPublicKey();
      final pinnedNodeId = await _nodeId(pinnedPublic.bytes);
      final attackerAlgorithm = Ed25519();
      final attackerPair = await attackerAlgorithm.newKeyPair();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);

      server.listen((request) async {
        final decoded = jsonDecode(
          await utf8.decoder.bind(request).join(),
        ) as Map<String, dynamic>;
        final challenge = decoded['challenge'] as String;
        final signature = await attackerAlgorithm.sign(
          utf8.encode('loom-node-challenge-v1\n$challenge'),
          keyPair: attackerPair,
        );
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'nodeId': pinnedNodeId,
            'challenge': challenge,
            'signature': base64Encode(signature.bytes),
          }),
        );
        await request.response.close();
      });

      try {
        await expectLater(
          LoomPinnedNodeVerifier().verify(
            baseUri: Uri.parse('http://localhost:${server.port}'),
            expectedNodeId: pinnedNodeId,
            expectedPublicKey: base64Encode(pinnedPublic.bytes),
          ),
          throwsA(
            isA<LoomProtocolException>().having(
              (error) => error.message,
              'message',
              contains('signature is invalid'),
            ),
          ),
        );
      } finally {
        await server.close(force: true);
      }
    },
  );

  test(
    'pinned Node challenge refuses cleartext non-loopback endpoints',
    () async {
      final algorithm = Ed25519();
      final keyPair = await algorithm.newKeyPair();
      final publicKey = await keyPair.extractPublicKey();
      final nodeId = await _nodeId(publicKey.bytes);
      await expectLater(
        LoomPinnedNodeVerifier().verify(
          baseUri: Uri.parse('http://192.168.1.5:7483'),
          expectedNodeId: nodeId,
          expectedPublicKey: base64Encode(publicKey.bytes),
        ),
        throwsA(
          isA<LoomProtocolException>().having(
            (error) => error.message,
            'message',
            contains('HTTPS'),
          ),
        ),
      );
    },
  );
}

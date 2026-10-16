import 'dart:convert';

import 'package:loom_protocol/loom_protocol.dart';
import 'package:cryptography/cryptography.dart';
import 'package:test/test.dart';

void main() {
  test('accepts a correctly signed registry manifest', () async {
    final algorithm = Ed25519();
    final keyPair = await algorithm.newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    final manifestBytes = utf8.encode(
      jsonEncode({
        'schemaVersion': 1,
        'generatedAt': '2026-09-01T00:00:00Z',
        'nodes': [
          {
            'nodeId': 'chn:test-node',
            'name': 'Test Node',
            'domain': 'chat.example.org',
            'country': 'IR',
            'networkLocation': 'DE',
            'registration': 'open',
            'federation': true,
            'protocol': ['loom-federation-v1'],
            'publicKey': base64Encode(publicKey.bytes),
            'fingerprint': 'TEST',
            'capabilities': ['messaging'],
            'lastVerified': '2026-09-01T00:00:00Z',
          },
        ],
      }),
    );
    final signature = await algorithm.sign(manifestBytes, keyPair: keyPair);
    final verifier = LoomRegistryVerifier(signingPublicKey: publicKey.bytes);

    final result = await verifier.verify(
      manifestBytes: manifestBytes,
      detachedSignatureBase64: base64Encode(signature.bytes),
    );

    expect(result.nodes, hasLength(1));
    expect(result.nodes.single.domain, 'chat.example.org');
  });

  test('rejects a modified registry manifest', () async {
    final algorithm = Ed25519();
    final keyPair = await algorithm.newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    final original = utf8.encode(
      '{"schemaVersion":1,"generatedAt":"2026-09-01T00:00:00Z","nodes":[]}',
    );
    final signature = await algorithm.sign(original, keyPair: keyPair);
    final verifier = LoomRegistryVerifier(signingPublicKey: publicKey.bytes);

    expect(
      () => verifier.verify(
        manifestBytes: utf8.encode(
          '{"schemaVersion":1,"generatedAt":"2026-09-02T00:00:00Z","nodes":[]}',
        ),
        detachedSignatureBase64: base64Encode(signature.bytes),
      ),
      throwsA(isA<FormatException>()),
    );
  });
}

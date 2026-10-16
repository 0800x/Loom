import 'dart:convert';

import 'package:loom_models/loom_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('registry parser rejects duplicate node domains', () {
    final entry = {
      'nodeId': 'chn:one',
      'name': 'One',
      'domain': 'one.example.org',
      'country': 'IR',
      'networkLocation': 'IR',
      'registration': 'open',
      'federation': true,
      'protocol': ['loom-federation-v1'],
      'publicKey': 'key',
      'fingerprint': 'fingerprint',
      'capabilities': ['messaging'],
    };
    final second = Map<String, Object?>.from(entry)..['nodeId'] = 'chn:two';
    final bytes = utf8.encode(
      jsonEncode({
        'schemaVersion': 1,
        'generatedAt': '2026-09-01T00:00:00Z',
        'nodes': [entry, second],
      }),
    );
    expect(() => LoomRegistryManifest.fromBytes(bytes), throwsFormatException);
  });
}

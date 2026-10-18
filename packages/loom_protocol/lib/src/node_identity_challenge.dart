import 'transport_security.dart';

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

import 'node_client.dart';

/// Re-authenticates a previously pinned Loom Node before the client sends
/// password/session material. TLS authenticates the hostname; this challenge
/// additionally proves possession of the exact Ed25519 Node key the client
/// pinned earlier.
class LoomPinnedNodeVerifier {
  LoomPinnedNodeVerifier({HttpClient? httpClient})
    : _http = httpClient ?? HttpClient();

  final HttpClient _http;
  final Ed25519 _ed25519 = Ed25519();
  final Sha256 _sha256 = Sha256();

  Future<void> verify({
    required Uri baseUri,
    required String expectedNodeId,
    required String expectedPublicKey,
  }) async {
    _requireSafeBaseUri(baseUri);
    final publicKey = _decodePublicKey(expectedPublicKey);
    final derived = await _sha256.hash(publicKey);
    final derivedNodeId =
        'node:${base64UrlEncode(derived.bytes).replaceAll('=', '')}';
    if (expectedNodeId != derivedNodeId) {
      throw const LoomProtocolException(
        'Pinned Node ID does not match its public key',
      );
    }

    final random = Random.secure();
    final challengeBytes = List<int>.generate(32, (_) => random.nextInt(256));
    final challenge = base64UrlEncode(challengeBytes).replaceAll('=', '');
    try {
      final uri = baseUri.resolve('/api/v1/server/challenge');
      final request = await _http
          .postUrl(uri)
          .timeout(const Duration(seconds: 8));
      request.followRedirects = false;
      request.headers.contentType = ContentType.json;
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.write(jsonEncode({'challenge': challenge}));
      final response = await request.close().timeout(
        const Duration(seconds: 10),
      );
      final bytes = await _readLimited(response, 64 * 1024);
      if (response.statusCode != HttpStatus.ok) {
        throw LoomProtocolException(
          'Node identity challenge failed with HTTP ${response.statusCode}',
        );
      }
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, Object?>) {
        throw const LoomProtocolException(
          'Invalid Node identity challenge response',
        );
      }
      final nodeId = decoded['nodeId'];
      final echoed = decoded['challenge'];
      final signature = decoded['signature'];
      if (nodeId != expectedNodeId ||
          echoed != challenge ||
          signature is! String ||
          signature.isEmpty) {
        throw const LoomProtocolException(
          'Node identity challenge binding mismatch',
        );
      }
      final signatureBytes = base64Decode(signature);
      if (signatureBytes.length != 64) {
        throw const LoomProtocolException(
          'Malformed Node identity challenge signature',
        );
      }
      final valid = await _ed25519.verify(
        utf8.encode('loom-node-challenge-v1\n$challenge'),
        signature: Signature(
          signatureBytes,
          publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519),
        ),
      );
      if (!valid) {
        throw const LoomProtocolException(
          'Node identity challenge signature is invalid',
        );
      }
    } on FormatException {
      throw const LoomProtocolException(
        'Malformed Node identity challenge material',
      );
    } finally {
      challengeBytes.fillRange(0, challengeBytes.length, 0);
    }
  }

  List<int> _decodePublicKey(String encoded) {
    try {
      final bytes = base64Decode(encoded);
      if (bytes.length != 32) {
        throw const FormatException('invalid Ed25519 public key length');
      }
      return bytes;
    } on FormatException {
      throw const LoomProtocolException('Malformed pinned Node public key');
    }
  }

  Future<List<int>> _readLimited(
    HttpClientResponse response,
    int maxBytes,
  ) async {
    if (response.contentLength > maxBytes) {
      await response.drain<void>();
      throw const LoomProtocolException(
        'Node identity response exceeds maximum allowed size',
      );
    }
    final bytes = <int>[];
    await for (final chunk in response) {
      bytes.addAll(chunk);
      if (bytes.length > maxBytes) {
        throw const LoomProtocolException(
          'Node identity response exceeds maximum allowed size',
        );
      }
    }
    return bytes;
  }

  void _requireSafeBaseUri(Uri uri) => requireLoomTransport(uri);
}

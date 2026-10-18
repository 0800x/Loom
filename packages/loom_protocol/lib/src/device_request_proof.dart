import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

import 'node_client.dart';

typedef LoomDevicePayloadSigner = Future<List<int>> Function(List<int> payload);

class LoomDeviceRequestProofProvider {
  LoomDeviceRequestProofProvider({
    required this.deviceId,
    required this.signer,
  });

  final String deviceId;
  final LoomDevicePayloadSigner signer;
  final Random _random = Random.secure();
  final Sha256 _sha256 = Sha256();

  Future<Map<String, String>> headers({
    required String method,
    required Uri uri,
    required String credential,
    List<int> bodyBytes = const <int>[],
  }) async {
    final digest = await _sha256.hash(bodyBytes);
    return headersForBodyHash(
      method: method,
      uri: uri,
      credential: credential,
      bodySha256: _hex(digest.bytes),
    );
  }

  Future<Map<String, String>> headersForBodyHash({
    required String method,
    required Uri uri,
    required String credential,
    required String bodySha256,
  }) async {
    if (!RegExp(
      r'^dev_[0-9a-f-]{36}$',
      caseSensitive: false,
    ).hasMatch(deviceId)) {
      throw const LoomProtocolException('Invalid local device identifier');
    }
    if (credential.isEmpty ||
        credential.length > 8192 ||
        credential.contains(RegExp(r'[\r\n]'))) {
      throw const LoomProtocolException('Invalid request credential');
    }
    final normalizedHash = bodySha256.toLowerCase();
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(normalizedHash)) {
      throw const LoomProtocolException('Invalid request body hash');
    }
    final timestamp = DateTime.now().toUtc().millisecondsSinceEpoch.toString();
    final nonceBytes = List<int>.generate(24, (_) => _random.nextInt(256));
    final nonce = base64UrlEncode(nonceBytes).replaceAll('=', '');
    final credentialDigest = await _sha256.hash(utf8.encode(credential));
    final target = uri.path.isEmpty
        ? '/${uri.hasQuery ? '?${uri.query}' : ''}'
        : '${uri.path}${uri.hasQuery ? '?${uri.query}' : ''}';
    final canonical = <String>[
      'Loom-Device-Request-v1',
      method.toUpperCase(),
      target,
      normalizedHash,
      timestamp,
      nonce,
      deviceId,
      _hex(credentialDigest.bytes),
    ].join('\n');
    final signature = await signer(utf8.encode(canonical));
    if (signature.length != 64) {
      throw const LoomProtocolException('Invalid local device signature');
    }
    return <String, String>{
      'X-Loom-Device-Id': deviceId,
      'X-Loom-Request-Timestamp': timestamp,
      'X-Loom-Request-Nonce': nonce,
      'X-Loom-Content-SHA256': normalizedHash,
      'X-Loom-Request-Signature': base64Encode(signature),
    };
  }

  String _hex(List<int> bytes) =>
      bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();
}

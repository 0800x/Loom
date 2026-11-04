import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';

import 'package:loom_models/loom_models.dart';
import 'package:cryptography/cryptography.dart';

import 'node_client.dart';

class LoomRegistryVerifier {
  LoomRegistryVerifier({required List<int> signingPublicKey})
    : _publicKey = SimplePublicKey(
        Uint8List.fromList(signingPublicKey),
        type: KeyPairType.ed25519,
      );

  final SimplePublicKey _publicKey;
  final Ed25519 _algorithm = Ed25519();

  Future<LoomRegistryManifest> verify({
    required List<int> manifestBytes,
    required String detachedSignatureBase64,
  }) async {
    final signatureBytes = base64Decode(detachedSignatureBase64.trim());
    if (signatureBytes.length != 64) {
      throw const FormatException(
        'Registry signature must be a 64-byte Ed25519 signature',
      );
    }
    final valid = await _algorithm.verify(
      manifestBytes,
      signature: Signature(signatureBytes, publicKey: _publicKey),
    );
    if (!valid)
      throw const FormatException('Registry signature verification failed');
    return LoomRegistryManifest.fromBytes(manifestBytes);
  }
}

class LoomVerifiedRegistryArtifact {
  const LoomVerifiedRegistryArtifact({
    required this.manifest,
    required this.manifestBytes,
    required this.detachedSignatureBase64,
  });
  final LoomRegistryManifest manifest;
  final List<int> manifestBytes;
  final String detachedSignatureBase64;
}

class LoomRegistryClient {
  LoomRegistryClient({HttpClient? httpClient})
    : _http = httpClient ?? HttpClient();
  final HttpClient _http;

  Future<LoomRegistryManifest> fetchAndVerify({
    required Uri manifestUri,
    required Uri signatureUri,
    required LoomRegistryVerifier verifier,
  }) async => (await fetchAndVerifyArtifact(
    manifestUri: manifestUri,
    signatureUri: signatureUri,
    verifier: verifier,
  )).manifest;

  Future<LoomVerifiedRegistryArtifact> fetchAndVerifyArtifact({
    required Uri manifestUri,
    required Uri signatureUri,
    required LoomRegistryVerifier verifier,
  }) async {
    _requireHttps(manifestUri);
    _requireHttps(signatureUri);
    final manifestBytes = await _getBytes(manifestUri, 2 * 1024 * 1024);
    final signatureBytes = await _getBytes(signatureUri, 4096);
    final signature = utf8.decode(signatureBytes).trim();
    final manifest = await verifier.verify(
      manifestBytes: manifestBytes,
      detachedSignatureBase64: signature,
    );
    return LoomVerifiedRegistryArtifact(
      manifest: manifest,
      manifestBytes: List<int>.unmodifiable(manifestBytes),
      detachedSignatureBase64: signature,
    );
  }

  Future<List<int>> _getBytes(Uri uri, int maxBytes) async {
    final request = await _http.getUrl(uri).timeout(const Duration(seconds: 8));
    request.headers.set(
      HttpHeaders.acceptHeader,
      'application/octet-stream, application/json, text/plain',
    );
    request.followRedirects = false;
    final response = await request.close().timeout(const Duration(seconds: 10));
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      throw LoomProtocolException(
        'HTTP ${response.statusCode} from ${uri.host}',
      );
    }
    if (response.contentLength > maxBytes) {
      await response.drain<void>();
      throw const LoomProtocolException('Registry response exceeds size limit');
    }
    final bytes = <int>[];
    await for (final chunk in response) {
      bytes.addAll(chunk);
      if (bytes.length > maxBytes)
        throw const LoomProtocolException(
          'Registry response exceeds size limit',
        );
    }
    return bytes;
  }

  void _requireHttps(Uri uri) {
    if (uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment) {
      throw const LoomProtocolException('Registry endpoints must be HTTPS');
    }
  }
}

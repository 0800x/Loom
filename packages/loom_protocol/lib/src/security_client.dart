import 'transport_security.dart';

import 'dart:convert';
import 'dart:io';

import 'package:loom_models/loom_models.dart';

import 'device_bundle_verifier.dart';
import 'device_request_proof.dart';
import 'node_client.dart';

class LoomSecurityClient {
  LoomSecurityClient({
    HttpClient? httpClient,
    LoomDeviceBundleVerifier? bundleVerifier,
  }) : _http = httpClient ?? HttpClient(),
       _bundleVerifier = bundleVerifier ?? LoomDeviceBundleVerifier();

  final HttpClient _http;
  final LoomDeviceBundleVerifier _bundleVerifier;

  Future<void> publishDeviceBundle({
    required Uri baseUri,
    required String accessToken,
    required LoomDeviceKeyBundle bundle,
    LoomDeviceRequestProofProvider? deviceProofProvider,
  }) async {
    _requireSafeBaseUri(baseUri);
    _requireBearer(accessToken);
    final uri = baseUri.resolve(
      '/api/v1/devices/${Uri.encodeComponent(bundle.deviceId)}/key-bundle',
    );
    final bodyBytes = utf8.encode(jsonEncode(bundle.toJson()));
    final request = await _http.putUrl(uri).timeout(const Duration(seconds: 8));
    request.followRedirects = false;
    request.headers.contentType = ContentType.json;
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $accessToken');
    if (deviceProofProvider != null) {
      final proofHeaders = await deviceProofProvider.headers(
        method: 'PUT',
        uri: uri,
        credential: accessToken,
        bodyBytes: bodyBytes,
      );
      for (final entry in proofHeaders.entries) {
        request.headers.set(entry.key, entry.value);
      }
    }
    request.add(bodyBytes);
    final response = await request.close().timeout(const Duration(seconds: 12));
    if (response.statusCode != HttpStatus.ok &&
        response.statusCode != HttpStatus.noContent) {
      final detail = await _readError(response);
      throw LoomProtocolException(detail);
    }
    await response.drain<void>();
  }

  Future<List<LoomDeviceKeyBundle>> listIdentityDevices({
    required Uri baseUri,
    required String accessToken,
    required String identityId,
    required String identityPublicKey,
    required LoomDeviceRequestProofProvider deviceProofProvider,
  }) async {
    _requireSafeBaseUri(baseUri);
    _requireBearer(accessToken);
    if (identityId.trim().isEmpty || identityId.length > 512) {
      throw const LoomProtocolException('Invalid identityId');
    }
    final uri = baseUri.resolve(
      '/api/v1/identities/${Uri.encodeComponent(identityId)}/devices',
    );
    final proofHeaders = await deviceProofProvider.headers(
      method: 'GET',
      uri: uri,
      credential: accessToken,
    );
    final request = await _http.getUrl(uri).timeout(const Duration(seconds: 8));
    request.followRedirects = false;
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $accessToken');
    for (final entry in proofHeaders.entries) {
      request.headers.set(entry.key, entry.value);
    }
    final response = await request.close().timeout(const Duration(seconds: 12));
    if (response.statusCode != HttpStatus.ok) {
      final detail = await _readError(response);
      throw LoomProtocolException(detail);
    }
    final body = await _readLimited(response, 512 * 1024);
    final decoded = jsonDecode(utf8.decode(body));
    if (decoded is! Map<String, Object?> || decoded['devices'] is! List) {
      throw const LoomProtocolException('Invalid device-list response');
    }
    final devices = <LoomDeviceKeyBundle>[];
    for (final item in decoded['devices']! as List) {
      if (item is! Map<String, Object?>) {
        throw const LoomProtocolException('Invalid device bundle entry');
      }
      final bundle = LoomDeviceKeyBundle.fromJson(item);
      devices.add(
        await _bundleVerifier.verify(
          bundle: bundle,
          identityId: identityId,
          identityPublicKey: identityPublicKey,
        ),
      );
    }
    if (devices.length > 256) {
      throw const LoomProtocolException('Device list exceeds supported limit');
    }
    return List<LoomDeviceKeyBundle>.unmodifiable(devices);
  }

  Future<void> revokeDevice({
    required Uri baseUri,
    required String accessToken,
    required String deviceId,
    required LoomDeviceRequestProofProvider deviceProofProvider,
  }) async {
    _requireSafeBaseUri(baseUri);
    _requireBearer(accessToken);
    if (deviceId.trim().isEmpty || deviceId.length > 256) {
      throw const LoomProtocolException('Invalid deviceId');
    }
    final uri = baseUri.resolve(
      '/api/v1/devices/${Uri.encodeComponent(deviceId)}/revoke',
    );
    final proofHeaders = await deviceProofProvider.headers(
      method: 'POST',
      uri: uri,
      credential: accessToken,
    );
    final request = await _http
        .postUrl(uri)
        .timeout(const Duration(seconds: 8));
    request.followRedirects = false;
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $accessToken');
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    for (final entry in proofHeaders.entries) {
      request.headers.set(entry.key, entry.value);
    }
    final response = await request.close().timeout(const Duration(seconds: 12));
    if (response.statusCode != HttpStatus.ok &&
        response.statusCode != HttpStatus.noContent) {
      final detail = await _readError(response);
      throw LoomProtocolException(detail);
    }
    await response.drain<void>();
  }

  Future<String> _readError(HttpClientResponse response) async {
    final bytes = await _readLimited(response, 64 * 1024);
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is Map<String, Object?> && decoded['error'] is String) {
        return decoded['error'] as String;
      }
    } catch (_) {}
    return 'Security API request failed with HTTP ${response.statusCode}';
  }

  Future<List<int>> _readLimited(
    HttpClientResponse response,
    int maxBytes,
  ) async {
    if (response.contentLength > maxBytes) {
      await response.drain<void>();
      throw const LoomProtocolException(
        'Response exceeds maximum allowed size',
      );
    }
    final bytes = <int>[];
    await for (final chunk in response) {
      bytes.addAll(chunk);
      if (bytes.length > maxBytes) {
        throw const LoomProtocolException(
          'Response exceeds maximum allowed size',
        );
      }
    }
    return bytes;
  }

  void _requireBearer(String token) {
    if (token.trim().isEmpty ||
        token.length > 8192 ||
        token.contains(RegExp(r'[\r\n]'))) {
      throw const LoomProtocolException('Invalid access token');
    }
  }

  void _requireSafeBaseUri(Uri uri) => requireLoomTransport(uri);
}

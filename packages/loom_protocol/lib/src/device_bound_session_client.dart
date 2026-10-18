import 'transport_security.dart';

import 'dart:convert';
import 'dart:io';

import 'package:loom_models/loom_models.dart';

import 'device_request_proof.dart';
import 'node_client.dart';

class LoomDeviceBoundSessionClient {
  LoomDeviceBoundSessionClient({HttpClient? httpClient})
    : _http = httpClient ?? HttpClient();

  final HttpClient _http;

  Future<LoomRegistrationResult> refreshSession({
    required Uri baseUri,
    required String refreshToken,
    required LoomDeviceRequestProofProvider deviceProofProvider,
  }) async {
    _requireSafeBaseUri(baseUri);
    if (refreshToken.isEmpty ||
        refreshToken.length > 1024 ||
        refreshToken.contains(RegExp(r'[\r\n]'))) {
      throw const LoomProtocolException('Invalid refresh token');
    }
    final uri = baseUri.resolve('/api/v1/auth/refresh');
    final bodyBytes = utf8.encode(jsonEncode({'refreshToken': refreshToken}));
    final proofHeaders = await deviceProofProvider.headers(
      method: 'POST',
      uri: uri,
      credential: refreshToken,
      bodyBytes: bodyBytes,
    );
    final request = await _http
        .postUrl(uri)
        .timeout(const Duration(seconds: 8));
    request.headers.contentType = ContentType.json;
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    request.followRedirects = false;
    for (final entry in proofHeaders.entries) {
      request.headers.set(entry.key, entry.value);
    }
    request.add(bodyBytes);
    final response = await request.close().timeout(const Duration(seconds: 12));
    final bytes = <int>[];
    await for (final chunk in response) {
      bytes.addAll(chunk);
      if (bytes.length > 128 * 1024) {
        throw const LoomProtocolException(
          'Session response exceeds size limit',
        );
      }
    }
    if (response.statusCode != HttpStatus.ok) {
      String detail = 'Session refresh failed with HTTP ${response.statusCode}';
      try {
        final body = jsonDecode(utf8.decode(bytes));
        if (body is Map<String, Object?> && body['error'] is String) {
          detail = body['error'] as String;
        }
      } catch (_) {}
      throw LoomProtocolException(detail);
    }
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, Object?>) {
      throw const LoomProtocolException('Invalid session response');
    }
    final expires = decoded['accessTokenExpiresInSeconds'];
    if (expires is! int || expires <= 0 || expires > 86400) {
      throw const LoomProtocolException('Invalid access token lifetime');
    }
    final address = _requiredString(decoded, 'address');
    if (!address.toLowerCase().endsWith(
      ':${baseUri.authority.toLowerCase()}',
    )) {
      throw const LoomProtocolException(
        'Node returned an unexpected identity address',
      );
    }
    return LoomRegistrationResult(
      receipt: LoomRegistrationReceipt(
        accountId: _requiredString(decoded, 'accountId'),
        deviceId: _requiredString(decoded, 'deviceId'),
        address: address,
        homeNode: baseUri.authority.toLowerCase(),
      ),
      accessToken: _requiredString(decoded, 'accessToken'),
      refreshToken: _requiredString(decoded, 'refreshToken'),
      accessTokenExpiresInSeconds: expires,
    );
  }

  String _requiredString(Map<String, Object?> json, String key) {
    final value = json[key];
    if (value is! String || value.trim().isEmpty) {
      throw LoomProtocolException('Missing or invalid $key');
    }
    return value.trim();
  }

  void _requireSafeBaseUri(Uri uri) => requireLoomTransport(uri);
}

import 'transport_security.dart';
import 'dart:convert';
import 'dart:io';

import 'device_request_proof.dart';
import 'node_client.dart';

class LoomDeviceLinkInvitation {
  const LoomDeviceLinkInvitation({
    required this.linkId,
    required this.expiresAt,
    required this.sourceDeviceId,
  });

  final String linkId;
  final DateTime expiresAt;
  final String sourceDeviceId;
}

class LoomDeviceLinkRedemption {
  const LoomDeviceLinkRedemption({
    required this.linkId,
    required this.payload,
    required this.identityId,
    required this.sourceDeviceId,
    required this.expiresAt,
  });

  final String linkId;
  final String payload;
  final String identityId;
  final String sourceDeviceId;
  final DateTime expiresAt;
}

class LoomDeviceLinkClient {
  LoomDeviceLinkClient({HttpClient? httpClient})
      : _http = httpClient ?? HttpClient();

  final HttpClient _http;

  Future<LoomDeviceLinkInvitation> createInvitation({
    required Uri baseUri,
    required String accessToken,
    required String linkId,
    required String tokenHash,
    required String payload,
    required LoomDeviceRequestProofProvider deviceProofProvider,
  }) async {
    _requireSafeBaseUri(baseUri);
    _requireBearer(accessToken);
    final uri = baseUri.resolve('/api/v1/device-links/invitations');
    final bodyBytes = utf8.encode(jsonEncode(<String, Object?>{
      'linkId': linkId,
      'tokenHash': tokenHash,
      'payload': payload,
    }));
    final proofHeaders = await deviceProofProvider.headers(
      method: 'POST',
      uri: uri,
      credential: accessToken,
      bodyBytes: bodyBytes,
    );
    final response = await _post(
      uri: uri,
      accessToken: accessToken,
      bodyBytes: bodyBytes,
      proofHeaders: proofHeaders,
    );
    if (response.statusCode != HttpStatus.created) {
      throw LoomProtocolException(await _readError(response));
    }
    final decoded = await _readJson(response, 64 * 1024);
    final returnedLinkId = decoded['linkId'];
    final expiresAt = decoded['expiresAt'];
    final sourceDeviceId = decoded['sourceDeviceId'];
    if (returnedLinkId != linkId ||
        expiresAt is! String ||
        sourceDeviceId is! String) {
      throw const LoomProtocolException(
          'Invalid device-link invitation response');
    }
    final expiry = DateTime.tryParse(expiresAt)?.toUtc();
    if (expiry == null || expiry.isBefore(DateTime.now().toUtc())) {
      throw const LoomProtocolException(
          'Invalid device-link invitation expiry');
    }
    return LoomDeviceLinkInvitation(
      linkId: linkId,
      expiresAt: expiry,
      sourceDeviceId: sourceDeviceId,
    );
  }

  /// Redeeming intentionally requires the password-authenticated bearer session
  /// but not a device proof: this is the one bootstrap step before the new
  /// device owns an identity-bound signing key.
  Future<LoomDeviceLinkRedemption> redeem({
    required Uri baseUri,
    required String accessToken,
    required String linkId,
    required String token,
  }) async {
    _requireSafeBaseUri(baseUri);
    _requireBearer(accessToken);
    final uri = baseUri.resolve('/api/v1/device-links/redeem');
    final bodyBytes = utf8.encode(jsonEncode(<String, Object?>{
      'linkId': linkId,
      'token': token,
    }));
    final response = await _post(
      uri: uri,
      accessToken: accessToken,
      bodyBytes: bodyBytes,
    );
    if (response.statusCode != HttpStatus.ok) {
      throw LoomProtocolException(await _readError(response));
    }
    final decoded = await _readJson(response, 128 * 1024);
    final returnedLinkId = decoded['linkId'];
    final payload = decoded['payload'];
    final identityId = decoded['identityId'];
    final sourceDeviceId = decoded['sourceDeviceId'];
    final expiresAt = decoded['expiresAt'];
    if (returnedLinkId != linkId ||
        payload is! String ||
        payload.isEmpty ||
        utf8.encode(payload).length > 96 * 1024 ||
        identityId is! String ||
        identityId.isEmpty ||
        sourceDeviceId is! String ||
        sourceDeviceId.isEmpty ||
        expiresAt is! String) {
      throw const LoomProtocolException(
          'Invalid device-link redemption response');
    }
    final expiry = DateTime.tryParse(expiresAt)?.toUtc();
    if (expiry == null || expiry.isBefore(DateTime.now().toUtc())) {
      throw const LoomProtocolException('Device-link invitation expired');
    }
    return LoomDeviceLinkRedemption(
      linkId: linkId,
      payload: payload,
      identityId: identityId,
      sourceDeviceId: sourceDeviceId,
      expiresAt: expiry,
    );
  }

  Future<void> complete({
    required Uri baseUri,
    required String accessToken,
    required String linkId,
    required LoomDeviceRequestProofProvider deviceProofProvider,
  }) async {
    _requireSafeBaseUri(baseUri);
    _requireBearer(accessToken);
    final uri = baseUri.resolve('/api/v1/device-links/complete');
    final bodyBytes =
        utf8.encode(jsonEncode(<String, Object?>{'linkId': linkId}));
    final proofHeaders = await deviceProofProvider.headers(
      method: 'POST',
      uri: uri,
      credential: accessToken,
      bodyBytes: bodyBytes,
    );
    final response = await _post(
      uri: uri,
      accessToken: accessToken,
      bodyBytes: bodyBytes,
      proofHeaders: proofHeaders,
    );
    if (response.statusCode != HttpStatus.noContent &&
        response.statusCode != HttpStatus.ok) {
      throw LoomProtocolException(await _readError(response));
    }
    await response.drain<void>();
  }

  Future<HttpClientResponse> _post({
    required Uri uri,
    required String accessToken,
    required List<int> bodyBytes,
    Map<String, String>? proofHeaders,
  }) async {
    final request =
        await _http.postUrl(uri).timeout(const Duration(seconds: 8));
    request.followRedirects = false;
    request.headers.contentType = ContentType.json;
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $accessToken');
    for (final entry
        in proofHeaders?.entries ?? const <MapEntry<String, String>>[]) {
      request.headers.set(entry.key, entry.value);
    }
    request.add(bodyBytes);
    return request.close().timeout(const Duration(seconds: 12));
  }

  Future<Map<String, Object?>> _readJson(
    HttpClientResponse response,
    int maxBytes,
  ) async {
    final bytes = await _readLimited(response, maxBytes);
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, Object?>) {
      throw const LoomProtocolException('Invalid device-link response');
    }
    return decoded;
  }

  Future<String> _readError(HttpClientResponse response) async {
    final bytes = await _readLimited(response, 64 * 1024);
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is Map<String, Object?> && decoded['error'] is String) {
        return decoded['error'] as String;
      }
    } catch (_) {}
    return 'Device-link request failed with HTTP ${response.statusCode}';
  }

  Future<List<int>> _readLimited(
    HttpClientResponse response,
    int maxBytes,
  ) async {
    if (response.contentLength > maxBytes) {
      await response.drain<void>();
      throw const LoomProtocolException(
          'Response exceeds maximum allowed size');
    }
    final bytes = <int>[];
    await for (final chunk in response) {
      bytes.addAll(chunk);
      if (bytes.length > maxBytes) {
        throw const LoomProtocolException(
            'Response exceeds maximum allowed size');
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

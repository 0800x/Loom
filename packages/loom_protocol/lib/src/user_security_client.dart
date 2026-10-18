import 'transport_security.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:loom_models/loom_models.dart';
import 'package:cryptography/cryptography.dart';

import 'device_bundle_verifier.dart';
import 'device_request_proof.dart';
import 'node_client.dart';
import 'public_avatar.dart';

class LoomResolvedUserSecurity {
  const LoomResolvedUserSecurity({
    required this.address,
    required this.displayName,
    required this.identityId,
    required this.identityPublicKey,
    required this.identityFingerprint,
    required this.devices,
    this.avatar,
  });

  final String address;
  final String displayName;
  final String identityId;
  final String identityPublicKey;
  final String identityFingerprint;
  final List<LoomDeviceKeyBundle> devices;
  final LoomPublicAvatar? avatar;
}

/// Reads peer identity/device material only through the authenticated Home Node.
///
/// The Home Node is responsible for Node-to-Node discovery and signature
/// validation. This client independently validates the returned user identity
/// and every device's user-identity binding before exposing the material to the
/// encryption layer.
class LoomUserSecurityClient {
  LoomUserSecurityClient({
    HttpClient? httpClient,
    LoomDeviceBundleVerifier? bundleVerifier,
    this.connectTimeout = const Duration(seconds: 8),
    this.responseHeaderTimeout = const Duration(seconds: 15),
    this.responseBodyTimeout = const Duration(seconds: 15),
  })  : _http = httpClient ?? HttpClient(),
        _bundleVerifier = bundleVerifier ?? LoomDeviceBundleVerifier() {
    _http.connectionTimeout = connectTimeout;
  }

  final HttpClient _http;
  final LoomDeviceBundleVerifier _bundleVerifier;
  final Duration connectTimeout;
  final Duration responseHeaderTimeout;
  final Duration responseBodyTimeout;
  final Sha256 _sha256 = Sha256();

  Future<LoomResolvedUserSecurity> resolve({
    required Uri baseUri,
    required String accessToken,
    required String address,
    required LoomDeviceRequestProofProvider deviceProofProvider,
  }) async {
    final normalizedAddress = _validateAddress(address);
    final json = await _requestJson(
      baseUri: baseUri,
      accessToken: accessToken,
      method: 'POST',
      path: '/api/v1/users/resolve',
      body: <String, Object?>{'address': normalizedAddress},
      deviceProofProvider: deviceProofProvider,
    );
    final returnedAddress = _requiredString(json, 'address', max: 512);
    if (returnedAddress.toLowerCase() != normalizedAddress.toLowerCase()) {
      throw const LoomProtocolException(
        'Resolved user address changed unexpectedly',
      );
    }
    final displayName = _requiredString(json, 'displayName', max: 80);
    final identityRaw = json['identity'];
    final devicesRaw = json['devices'];
    if (identityRaw is! Map<String, Object?> || devicesRaw is! List) {
      throw const LoomProtocolException(
        'Resolved user security payload is incomplete',
      );
    }
    if (devicesRaw.length > 64) {
      throw const LoomProtocolException(
        'Resolved user has too many active devices',
      );
    }
    final identityId = _requiredString(identityRaw, 'identityId', max: 128);
    final publicKey = _requiredString(identityRaw, 'publicKey', max: 128);
    final fingerprint = _requiredString(
      identityRaw,
      'fingerprint',
      max: 128,
    ).toUpperCase();
    final publicKeyBytes = base64Decode(publicKey);
    if (publicKeyBytes.length != 32) {
      throw const LoomProtocolException(
        'Resolved identity public key is invalid',
      );
    }
    final digest = await _sha256.hash(publicKeyBytes);
    final derivedIdentityId =
        'chn:${base64UrlEncode(digest.bytes).replaceAll('=', '')}';
    if (derivedIdentityId != identityId ||
        _formatFingerprint(digest.bytes) != fingerprint) {
      throw const LoomProtocolException('Resolved identity binding is invalid');
    }

    final devices = <LoomDeviceKeyBundle>[];
    final seen = <String>{};
    for (final value in devicesRaw) {
      if (value is! Map<String, Object?>) {
        throw const LoomProtocolException('Malformed resolved device bundle');
      }
      final bundle = LoomDeviceKeyBundle.fromJson(value);
      if (!seen.add(bundle.deviceId)) {
        throw const LoomProtocolException('Duplicate resolved device bundle');
      }
      devices.add(
        await _bundleVerifier.verify(
          bundle: bundle,
          identityId: identityId,
          identityPublicKey: publicKey,
        ),
      );
    }
    return LoomResolvedUserSecurity(
      avatar: LoomPublicAvatar.parseOptional(json['avatar']),
      address: returnedAddress,
      displayName: displayName,
      identityId: identityId,
      identityPublicKey: publicKey,
      identityFingerprint: fingerprint,
      devices: List<LoomDeviceKeyBundle>.unmodifiable(devices),
    );
  }

  Future<LoomConversation> createDirectConversation({
    required Uri baseUri,
    required String accessToken,
    required String address,
    required LoomDeviceRequestProofProvider deviceProofProvider,
  }) async {
    final normalizedAddress = _validateAddress(address);
    final json = await _requestJson(
      baseUri: baseUri,
      accessToken: accessToken,
      method: 'POST',
      path: '/api/v1/conversations',
      body: <String, Object?>{'address': normalizedAddress},
      deviceProofProvider: deviceProofProvider,
      acceptedStatusCodes: const <int>{200, 201},
    );
    final peerAddress = _requiredString(json, 'peerAddress', max: 512);
    if (peerAddress.toLowerCase() != normalizedAddress.toLowerCase()) {
      throw const LoomProtocolException('Conversation peer address mismatch');
    }
    return LoomConversation(
      id: _requiredString(json, 'conversationId', max: 256),
      kind: LoomConversationKind.direct,
      peerAddress: peerAddress,
      updatedOrder: 0,
      unreadCount: 0,
      isMuted: false,
      isPinned: false,
    );
  }

  Future<Map<String, Object?>> _requestJson({
    required Uri baseUri,
    required String accessToken,
    required String method,
    required String path,
    required Map<String, Object?> body,
    required LoomDeviceRequestProofProvider deviceProofProvider,
    Set<int> acceptedStatusCodes = const <int>{200},
  }) async {
    _requireSafeBaseUri(baseUri);
    _requireBearer(accessToken);
    final uri = baseUri.resolve(path);
    final bodyBytes = utf8.encode(jsonEncode(body));
    final proofHeaders = await deviceProofProvider.headers(
      method: method,
      uri: uri,
      credential: accessToken,
      bodyBytes: bodyBytes,
    );
    final request = await _http.openUrl(method, uri).timeout(connectTimeout);
    request.followRedirects = false;
    request.headers.contentType = ContentType.json;
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $accessToken');
    for (final entry in proofHeaders.entries) {
      request.headers.set(entry.key, entry.value);
    }
    request.add(bodyBytes);
    late final HttpClientResponse response;
    try {
      response = await request.close().timeout(responseHeaderTimeout);
    } on TimeoutException catch (error, stackTrace) {
      request.abort(error, stackTrace);
      rethrow;
    }
    final responseBytes = <int>[];
    final bodyRead = () async {
      await for (final chunk in response) {
        responseBytes.addAll(chunk);
        if (responseBytes.length > 1024 * 1024) {
          throw const LoomProtocolException(
            'User-security response exceeds size limit',
          );
        }
      }
    }();
    try {
      await bodyRead.timeout(responseBodyTimeout);
    } on TimeoutException catch (error, stackTrace) {
      request.abort(error, stackTrace);
      rethrow;
    }
    if (!acceptedStatusCodes.contains(response.statusCode)) {
      String detail =
          'User-security request failed with HTTP ${response.statusCode}';
      try {
        final decoded = jsonDecode(utf8.decode(responseBytes));
        if (decoded is Map<String, Object?> && decoded['error'] is String) {
          detail = decoded['error'] as String;
        }
      } catch (_) {}
      throw LoomProtocolException(detail);
    }
    final decoded = jsonDecode(utf8.decode(responseBytes));
    if (decoded is! Map<String, Object?>) {
      throw const LoomProtocolException('Invalid user-security JSON response');
    }
    return decoded;
  }

  String _validateAddress(String value) {
    final address = value.trim();
    if (address.length < 5 ||
        address.length > 512 ||
        !address.startsWith('@') ||
        address.indexOf(':', 1) < 2 ||
        address.contains(RegExp(r'[\r\n\s]'))) {
      throw const LoomProtocolException('Invalid Loom address');
    }
    return address;
  }

  String _requiredString(
    Map<String, Object?> json,
    String key, {
    int max = 512,
  }) {
    final value = json[key];
    if (value is! String ||
        value.trim().isEmpty ||
        value.length > max ||
        value.contains(RegExp(r'[\r\n]'))) {
      throw LoomProtocolException('Missing or invalid $key');
    }
    return value.trim();
  }

  void _requireBearer(String token) {
    if (token.trim().isEmpty ||
        token.length > 8192 ||
        token.contains(RegExp(r'[\r\n]'))) {
      throw const LoomProtocolException('Invalid access token');
    }
  }

  void _requireSafeBaseUri(Uri uri) => requireLoomTransport(uri);

  String _formatFingerprint(List<int> bytes) {
    final hex = bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join()
        .toUpperCase();
    return <String>[
      for (var index = 0; index < hex.length; index += 4)
        hex.substring(index, index + 4),
    ].join(' ');
  }
}

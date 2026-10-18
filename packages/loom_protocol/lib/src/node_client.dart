import 'transport_security.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:loom_models/loom_models.dart';
import 'package:cryptography/cryptography.dart';

class LoomProtocolException implements Exception {
  const LoomProtocolException(this.message);
  final String message;
  @override
  String toString() => 'LoomProtocolException: $message';
}

class LoomNodeClient {
  LoomNodeClient({
    HttpClient? httpClient,
    this.connectTimeout = const Duration(seconds: 8),
    this.responseHeaderTimeout = const Duration(seconds: 12),
    this.responseBodyTimeout = const Duration(seconds: 12),
  }) : _http = httpClient ?? HttpClient() {
    _http.connectionTimeout = connectTimeout;
  }

  final HttpClient _http;
  final Duration connectTimeout;
  final Duration responseHeaderTimeout;
  final Duration responseBodyTimeout;

  Future<LoomWellKnownNode> discoverDomain(String domain) async {
    final target = _parseDiscoveryTarget(domain);
    final normalized = target.domain;
    final uri = target.baseUri.resolve('/.well-known/loom/server');
    final response = await _getJson(uri, maxBytes: 64 * 1024);
    final protocol = _requiredString(response, 'protocol');
    final endpoint = Uri.tryParse(_requiredString(response, 'endpoint'));
    if (endpoint == null) {
      throw const LoomProtocolException('Invalid discovery endpoint');
    }
    _requireSafeBaseUri(endpoint);
    if (endpoint.authority.toLowerCase() != normalized) {
      throw const LoomProtocolException(
        'Node discovery endpoint does not match the requested domain',
      );
    }
    final nodeId = _requiredString(response, 'nodeId');
    final publicKey = _requiredString(response, 'publicKey');
    final signature = _requiredString(response, 'signature');
    if (protocol != 'loom-federation-v1') {
      throw LoomProtocolException(
        'Unsupported Node discovery protocol: $protocol',
      );
    }
    await _verifyWellKnownSignature(
      domain: normalized,
      protocol: protocol,
      endpoint: endpoint,
      nodeId: nodeId,
      publicKeyBase64: publicKey,
      signatureBase64: signature,
    );
    final keyBytes = base64Decode(publicKey);
    final digest = await Sha256().hash(keyBytes);
    final derivedNodeId =
        'node:${base64UrlEncode(digest.bytes).replaceAll('=', '')}';
    if (nodeId != derivedNodeId) {
      throw const LoomProtocolException(
        'Node ID does not match the discovery public key',
      );
    }
    return LoomWellKnownNode(
      protocol: protocol,
      endpoint: endpoint,
      nodeId: nodeId,
      publicKey: publicKey,
      signature: signature,
      fingerprint: _formatFingerprint(digest.bytes),
    );
  }

  Future<LoomNodeLiveInfo> fetchLiveInfo(Uri baseUri) async {
    _requireSafeBaseUri(baseUri);
    final uri = baseUri.resolve('/api/v1/server/info');
    final json = await _getJson(uri, maxBytes: 128 * 1024);
    final capsRaw = json['capabilities'];
    if (capsRaw is! List || capsRaw.any((e) => e is! String)) {
      throw const LoomProtocolException('Invalid capabilities');
    }
    int? optionalInt(String key) => json[key] is int ? json[key] as int : null;
    return LoomNodeLiveInfo(
      nodeId: _requiredString(json, 'nodeId'),
      serverVersion: _requiredString(json, 'serverVersion'),
      protocolVersion: _requiredString(json, 'protocolVersion'),
      registration: _requiredString(json, 'registration'),
      federationMode: _requiredString(json, 'federationMode'),
      capabilities: capsRaw.cast<String>().toList(growable: false),
      maxMediaBytes: _mediaLimit(json['limits']),
      capacityUsed: optionalInt('capacityUsed'),
      capacityLimit: optionalInt('capacityLimit'),
    );
  }

  Future<LoomRegistrationResult> registerIdentity({
    required Uri baseUri,
    required String username,
    required String displayName,
    required String password,
    required LoomIdentityPublic identity,
    required String deviceName,
  }) async {
    _requireSafeBaseUri(baseUri);
    if (!RegExp(r'^[a-z0-9_][a-z0-9_.-]{2,31}$').hasMatch(username)) {
      throw const LoomProtocolException('Username format is invalid');
    }
    if (displayName.trim().isEmpty || displayName.trim().length > 80) {
      throw const LoomProtocolException('Display name is invalid');
    }
    if (password.length < 12 || password.length > 256) {
      throw const LoomProtocolException('Password length is invalid');
    }
    final uri = baseUri.resolve('/api/v1/auth/register');
    final request = await _http.postUrl(uri).timeout(connectTimeout);
    request.headers.contentType = ContentType.json;
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    request.followRedirects = false;
    request.write(
      jsonEncode({
        'username': username,
        'displayName': displayName.trim(),
        'password': password,
        'deviceName': deviceName.trim(),
        'identity': {
          'identityId': identity.identityId,
          'publicKey': identity.publicKey,
          'fingerprint': identity.fingerprint,
        },
        'protocolVersion': 'Loom-Identity-v1',
      }),
    );
    final response = await _close(request);
    final bytes = await _readBody(
      request: request,
      response: response,
      maxBytes: 128 * 1024,
      tooLargeMessage: 'Registration response exceeds size limit',
    );
    if (response.statusCode != HttpStatus.created &&
        response.statusCode != HttpStatus.ok) {
      String detail = 'Registration failed with HTTP ${response.statusCode}';
      try {
        final body = jsonDecode(utf8.decode(bytes));
        if (body is Map<String, Object?> && body['error'] is String)
          detail = body['error'] as String;
      } catch (_) {}
      throw LoomProtocolException(detail);
    }
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, Object?>)
      throw const LoomProtocolException('Invalid registration response');
    final address = _requiredString(decoded, 'address');
    final nodeAuthority = baseUri.authority.toLowerCase();
    final expectedAddress = '@$username:$nodeAuthority';
    if (address.toLowerCase() != expectedAddress.toLowerCase()) {
      throw const LoomProtocolException(
        'Node returned an unexpected identity address',
      );
    }
    final expires = decoded['accessTokenExpiresInSeconds'];
    if (expires is! int || expires <= 0 || expires > 86400) {
      throw const LoomProtocolException('Invalid access token lifetime');
    }
    return LoomRegistrationResult(
      receipt: LoomRegistrationReceipt(
        accountId: _requiredString(decoded, 'accountId'),
        deviceId: _requiredString(decoded, 'deviceId'),
        address: address,
        homeNode: nodeAuthority,
      ),
      accessToken: _requiredString(decoded, 'accessToken'),
      refreshToken: _requiredString(decoded, 'refreshToken'),
      accessTokenExpiresInSeconds: expires,
    );
  }

  Future<LoomRegistrationResult> refreshSession({
    required Uri baseUri,
    required String refreshToken,
  }) async {
    _requireSafeBaseUri(baseUri);
    if (refreshToken.isEmpty || refreshToken.length > 1024) {
      throw const LoomProtocolException('Invalid refresh token');
    }
    final uri = baseUri.resolve('/api/v1/auth/refresh');
    final request = await _http.postUrl(uri).timeout(connectTimeout);
    request.headers.contentType = ContentType.json;
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    request.followRedirects = false;
    request.write(jsonEncode({'refreshToken': refreshToken}));
    final response = await _close(request);
    final bytes = await _readBody(
      request: request,
      response: response,
      maxBytes: 128 * 1024,
      tooLargeMessage: 'Session response exceeds size limit',
    );
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

  Future<LoomLoginResult> login({
    required Uri baseUri,
    required String username,
    required String password,
  }) async {
    _requireSafeBaseUri(baseUri);
    final normalized = username.trim().toLowerCase();
    if (!RegExp(r'^[a-z0-9_][a-z0-9_.-]{2,31}$').hasMatch(normalized)) {
      throw const LoomProtocolException('Username format is invalid');
    }
    if (password.length < 10 || password.length > 512) {
      throw const LoomProtocolException('Password length is invalid');
    }
    final uri = baseUri.resolve('/api/v1/auth/login');
    final request = await _http.postUrl(uri).timeout(connectTimeout);
    request.headers.contentType = ContentType.json;
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    request.followRedirects = false;
    request.write(jsonEncode({'username': normalized, 'password': password}));
    final response = await _close(request);
    final bytes = await _readBody(
      request: request,
      response: response,
      maxBytes: 128 * 1024,
      tooLargeMessage: 'Login response exceeds size limit',
    );
    if (response.statusCode != HttpStatus.ok) {
      String detail = 'Login failed with HTTP ${response.statusCode}';
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
      throw const LoomProtocolException('Invalid login response');
    }
    final expires = decoded['accessTokenExpiresInSeconds'];
    if (expires is! int || expires <= 0 || expires > 86400) {
      throw const LoomProtocolException('Invalid access token lifetime');
    }
    final address = _requiredString(decoded, 'address');
    final expectedAddress = '@$normalized:${baseUri.authority}';
    if (address.toLowerCase() != expectedAddress.toLowerCase()) {
      throw const LoomProtocolException(
        'Node returned an unexpected identity address',
      );
    }
    return LoomLoginResult(
      receipt: LoomRegistrationReceipt(
        accountId: _requiredString(decoded, 'accountId'),
        deviceId: _requiredString(decoded, 'deviceId'),
        address: address,
        homeNode: baseUri.authority.toLowerCase(),
      ),
      identityId: _requiredString(decoded, 'identityId'),
      accessToken: _requiredString(decoded, 'accessToken'),
      refreshToken: _requiredString(decoded, 'refreshToken'),
      accessTokenExpiresInSeconds: expires,
    );
  }

  Future<Map<String, Object?>> _getJson(
    Uri uri, {
    required int maxBytes,
  }) async {
    final request = await _http.getUrl(uri).timeout(connectTimeout);
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    request.followRedirects = false;
    final response = await _close(request);
    final contentLength = response.contentLength;
    if (contentLength > maxBytes) {
      request.abort();
      throw const LoomProtocolException(
        'Response exceeds maximum allowed size',
      );
    }
    final bytes = await _readBody(
      request: request,
      response: response,
      maxBytes: maxBytes,
      tooLargeMessage: 'Response exceeds maximum allowed size',
    );
    if (response.statusCode != HttpStatus.ok) {
      throw LoomProtocolException(
        'HTTP ${response.statusCode} from ${uri.host}',
      );
    }
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, Object?>)
      throw const LoomProtocolException('Expected JSON object');
    return decoded;
  }

  Future<HttpClientResponse> _close(HttpClientRequest request) async {
    try {
      return await request.close().timeout(responseHeaderTimeout);
    } on TimeoutException catch (error, stackTrace) {
      request.abort(error, stackTrace);
      rethrow;
    }
  }

  Future<List<int>> _readBody({
    required HttpClientRequest request,
    required HttpClientResponse response,
    required int maxBytes,
    required String tooLargeMessage,
  }) async {
    final bytes = <int>[];
    final bodyRead = () async {
      await for (final chunk in response) {
        bytes.addAll(chunk);
        if (bytes.length > maxBytes) {
          throw LoomProtocolException(tooLargeMessage);
        }
      }
    }();
    try {
      await bodyRead.timeout(responseBodyTimeout);
    } on TimeoutException catch (error, stackTrace) {
      request.abort(error, stackTrace);
      rethrow;
    }
    return bytes;
  }

  Future<void> _verifyWellKnownSignature({
    required String domain,
    required String protocol,
    required Uri endpoint,
    required String nodeId,
    required String publicKeyBase64,
    required String signatureBase64,
  }) async {
    try {
      final keyBytes = base64Decode(publicKeyBase64);
      final signatureBytes = base64Decode(signatureBase64);
      if (keyBytes.length != 32 || signatureBytes.length != 64) {
        throw const FormatException('Invalid Ed25519 material length');
      }
      final payload = utf8.encode(
        '$domain\n$protocol\n${endpoint.toString()}\n$nodeId\n$publicKeyBase64',
      );
      final valid = await Ed25519().verify(
        payload,
        signature: Signature(
          signatureBytes,
          publicKey: SimplePublicKey(keyBytes, type: KeyPairType.ed25519),
        ),
      );
      if (!valid)
        throw const LoomProtocolException('Invalid Node discovery signature');
    } on FormatException catch (_) {
      throw const LoomProtocolException('Malformed Node discovery signature');
    }
  }

  void _requireSafeBaseUri(Uri uri) => requireLoomTransport(uri);

  String _requiredString(Map<String, Object?> json, String key) {
    final value = json[key];
    if (value is! String || value.trim().isEmpty) {
      throw LoomProtocolException('Missing or invalid $key');
    }
    return value.trim();
  }

  String _formatFingerprint(List<int> bytes) {
    final hex = bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join()
        .toUpperCase();
    return [for (var i = 0; i < hex.length; i += 4) hex.substring(i, i + 4)]
        .join(' ');
  }

  _DiscoveryTarget _parseDiscoveryTarget(String input) {
    final value = input.trim().toLowerCase();
    if (value.isEmpty ||
        value.length > 512 ||
        value.contains(RegExp(r'[\r\n]'))) {
      throw const LoomProtocolException('Invalid Node domain');
    }

    Uri? uri;
    if (value.contains('://')) {
      uri = Uri.tryParse(value);
    } else {
      final authority = Uri.tryParse('//$value');
      if (authority != null && authority.host.isNotEmpty) {
        final scheme = loomIsDevelopmentLoopback(authority.host)
            ? 'http'
            : 'https';
        uri = Uri.tryParse('$scheme://$value');
      }
    }
    if (uri == null ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        !_validHost(uri.host)) {
      throw const LoomProtocolException('Invalid Node domain');
    }
    _requireSafeBaseUri(uri);
    return _DiscoveryTarget(
      domain: uri.authority.toLowerCase(),
      baseUri: uri.replace(path: '', query: null, fragment: null),
    );
  }

  bool _validHost(String host) {
    if (_isLocalOrPrivateHost(host) || InternetAddress.tryParse(host) != null) {
      return true;
    }
    if (host.length > 253) return false;
    final labels = host.split('.');
    return labels.length >= 2 &&
        labels.every((label) {
          if (label.isEmpty ||
              label.length > 63 ||
              label.startsWith('-') ||
              label.endsWith('-'))
            return false;
          return RegExp(r'^[a-z0-9-]+$').hasMatch(label);
        });
  }

  bool _isLocalOrPrivateHost(String host) {
    final normalized = host.toLowerCase();
    if (normalized == 'localhost') return true;
    final address = InternetAddress.tryParse(normalized);
    if (address == null) return false;
    if (address.isLoopback) return true;
    if (address.type == InternetAddressType.IPv4) {
      final bytes = address.rawAddress;
      return bytes[0] == 10 ||
          (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
          (bytes[0] == 192 && bytes[1] == 168) ||
          (bytes[0] == 169 && bytes[1] == 254);
    }
    final first = address.rawAddress.first;
    final second = address.rawAddress[1];
    return (first & 0xfe) == 0xfc || (first == 0xfe && (second & 0xc0) == 0x80);
  }
}

class _DiscoveryTarget {
  const _DiscoveryTarget({required this.domain, required this.baseUri});

  final String domain;
  final Uri baseUri;
}

int? _mediaLimit(Object? value) {
  if (value == null) return null;
  if (value is! Map ||
      value['maxMediaBytes'] is! int ||
      (value['maxMediaBytes'] as int) < 1 ||
      (value['maxMediaBytes'] as int) > 2 * 1024 * 1024 * 1024) {
    throw const LoomProtocolException('Invalid server media limit');
  }
  return value['maxMediaBytes'] as int;
}

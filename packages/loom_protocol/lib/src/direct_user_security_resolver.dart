import 'dart:async';

import 'public_avatar.dart';

import 'dart:convert';
import 'dart:io';

import 'package:loom_models/loom_models.dart';
import 'package:cryptography/cryptography.dart';

import 'loom_address.dart';
import 'device_bundle_verifier.dart';
import 'device_request_proof.dart';
import 'node_client.dart';
import 'user_security_client.dart';

/// Resolves a remote Loom user directly at that user's Home Node first.
///
/// The destination Node is discovered through the signed Loom well-known
/// document. The returned exact-address profile is itself Node-signed, then the
/// user identity and every device bundle are independently verified before the
/// result is exposed to messaging. The requester's Home Node remains an
/// availability/compatibility fallback, not a mandatory reverse-network hop.
final class LoomDirectFirstUserSecurityResolver {
  LoomDirectFirstUserSecurityResolver({
    LoomNodeClient? nodeClient,
    LoomUserSecurityClient? legacyClient,
    LoomDeviceBundleVerifier? bundleVerifier,
    HttpClient? httpClient,
  })  : _nodes = nodeClient ?? LoomNodeClient(),
        _legacy = legacyClient ?? LoomUserSecurityClient(),
        _bundleVerifier = bundleVerifier ?? LoomDeviceBundleVerifier(),
        _http = httpClient ?? HttpClient();

  final LoomNodeClient _nodes;
  final LoomUserSecurityClient _legacy;
  final LoomDeviceBundleVerifier _bundleVerifier;
  final HttpClient _http;
  final Sha256 _sha256 = Sha256();

  Future<LoomResolvedUserSecurity> resolve({
    required Uri baseUri,
    required String accessToken,
    required String address,
    required LoomDeviceRequestProofProvider deviceProofProvider,
  }) async {
    final normalized = _validateAddress(address);
    final parsed = LoomAddress.parseCanonical(normalized);
    final localAuthority = baseUri.authority.toLowerCase();

    // Same-Node lookup keeps the authenticated local route. It is cheaper and
    // does not expose an otherwise-private exact lookup to the public endpoint.
    if (parsed.homeNode.toLowerCase() == localAuthority) {
      return _legacy.resolve(
        baseUri: baseUri,
        accessToken: accessToken,
        address: normalized,
        deviceProofProvider: deviceProofProvider,
      );
    }

    try {
      return await _resolveDirect(
        normalizedAddress: normalized,
        targetDomain: parsed.homeNode,
        homeBaseUri: baseUri,
        accessToken: accessToken,
        deviceProofProvider: deviceProofProvider,
      );
    } on SocketException {
      // Availability fallback only. Cryptographic validation errors below are
      // intentionally not downgraded to the Home-Node path.
    } on HandshakeException {
      // TLS/path failure: allow the already-authenticated Home Node to try.
    } on TimeoutException {
      // Destination path unavailable from this client.
    } on LoomProtocolException catch (error) {
      if (error.message == 'user_not_found') {
        rethrow;
      }
      if (!_fallbackEligible(error.message)) {
        rethrow;
      }
    }

    return _legacy.resolve(
      baseUri: baseUri,
      accessToken: accessToken,
      address: normalized,
      deviceProofProvider: deviceProofProvider,
    );
  }

  Future<LoomResolvedUserSecurity> _resolveDirect({
    required String normalizedAddress,
    required String targetDomain,
    required Uri homeBaseUri,
    required String accessToken,
    required LoomDeviceRequestProofProvider deviceProofProvider,
  }) async {
    final node = await _nodes.discoverDomain(targetDomain);
    final uri = node.endpoint.resolve('/api/v2/users/resolve');
    final request =
        await _http.postUrl(uri).timeout(const Duration(seconds: 8));
    request.followRedirects = false;
    request.headers.contentType = ContentType.json;
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    request.write(jsonEncode(<String, Object?>{'address': normalizedAddress}));
    final response = await request.close().timeout(const Duration(seconds: 12));
    final bytes = <int>[];
    await for (final chunk in response.timeout(const Duration(seconds: 12))) {
      bytes.addAll(chunk);
      if (bytes.length > 1024 * 1024) {
        throw const LoomProtocolException(
          'Direct user-security response exceeds size limit',
        );
      }
    }

    Map<String, Object?>? decoded;
    if (bytes.isNotEmpty) {
      try {
        final value = jsonDecode(utf8.decode(bytes));
        if (value is Map<String, Object?>) {
          decoded = value;
        }
      } catch (_) {
        throw const LoomProtocolException(
          'Invalid direct user-security JSON response',
        );
      }
    }

    if (response.statusCode == HttpStatus.notFound) {
      final code = decoded?['error'];
      if (code == 'user_not_found') {
        throw const LoomProtocolException('user_not_found');
      }
      throw const LoomProtocolException('direct_user_resolution_unsupported');
    }
    if (response.statusCode >= 500) {
      throw const LoomProtocolException('direct_user_resolution_unavailable');
    }
    if (response.statusCode != HttpStatus.ok || decoded == null) {
      throw LoomProtocolException(
        'Direct user resolution failed with HTTP ${response.statusCode}',
      );
    }

    await _verifyNodeSignedProfile(
      json: decoded,
      expectedAddress: normalizedAddress,
      expectedDomain: targetDomain,
      expectedNodeId: node.nodeId,
      nodePublicKey: node.publicKey,
    );
    final security = await _parseVerifiedSecurity(decoded, normalizedAddress);

    // Seed the exact verified binding into this client's own Home Node. The
    // Home Node re-verifies both signatures and stores only a short-lived
    // federation cache entry. This makes the existing conversation bootstrap
    // independent from a synchronous HomeNode -> DestinationNode round trip.
    await _cacheVerifiedAtHomeNode(
      homeBaseUri: homeBaseUri,
      accessToken: accessToken,
      deviceProofProvider: deviceProofProvider,
      node: node,
      signedProfile: decoded,
    );
    return security;
  }

  Future<void> _cacheVerifiedAtHomeNode({
    required Uri homeBaseUri,
    required String accessToken,
    required LoomDeviceRequestProofProvider deviceProofProvider,
    required LoomWellKnownNode node,
    required Map<String, Object?> signedProfile,
  }) async {
    final uri = homeBaseUri.resolve('/api/v2/users/cache-verified');
    final body = <String, Object?>{
      'discovery': <String, Object?>{
        'endpoint': node.endpoint.toString().replaceFirst(RegExp(r'/$'), ''),
        'nodeId': node.nodeId,
        'protocol': node.protocol,
        'publicKey': node.publicKey,
        'signature': node.signature,
      },
      'profile': signedProfile,
    };
    final bodyBytes = utf8.encode(jsonEncode(body));
    final proofHeaders = await deviceProofProvider.headers(
      method: 'POST',
      uri: uri,
      credential: accessToken,
      bodyBytes: bodyBytes,
    );
    final request =
        await _http.postUrl(uri).timeout(const Duration(seconds: 8));
    request.followRedirects = false;
    request.headers.contentType = ContentType.json;
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $accessToken');
    for (final entry in proofHeaders.entries) {
      request.headers.set(entry.key, entry.value);
    }
    request.add(bodyBytes);
    final response = await request.close().timeout(const Duration(seconds: 12));
    final responseBytes = <int>[];
    await for (final chunk in response.timeout(const Duration(seconds: 12))) {
      responseBytes.addAll(chunk);
      if (responseBytes.length > 128 * 1024) {
        throw const LoomProtocolException(
          'Verified user cache response exceeds size limit',
        );
      }
    }
    if (response.statusCode == HttpStatus.notFound) {
      throw const LoomProtocolException('direct_user_cache_unsupported');
    }
    if (response.statusCode >= 500) {
      throw const LoomProtocolException('direct_user_cache_unavailable');
    }
    if (response.statusCode != HttpStatus.ok) {
      String detail =
          'Verified user cache failed with HTTP ${response.statusCode}';
      try {
        final decoded = jsonDecode(utf8.decode(responseBytes));
        if (decoded is Map<String, Object?> && decoded['error'] is String) {
          detail = decoded['error'] as String;
        }
      } catch (_) {}
      throw LoomProtocolException(detail);
    }
  }

  Future<void> _verifyNodeSignedProfile({
    required Map<String, Object?> json,
    required String expectedAddress,
    required String expectedDomain,
    required String expectedNodeId,
    required String nodePublicKey,
  }) async {
    final protocol = _requiredString(json, 'protocol', max: 64);
    if (protocol != 'loom-federation-v1') {
      throw const LoomProtocolException(
        'Unsupported direct user profile protocol',
      );
    }
    final returnedAddress = _requiredString(json, 'address', max: 512);
    if (returnedAddress.toLowerCase() != expectedAddress.toLowerCase()) {
      throw const LoomProtocolException('Direct resolved address mismatch');
    }
    final homeNodeRaw = json['homeNode'];
    final identityRaw = json['identity'];
    final devicesRaw = json['devices'];
    if (homeNodeRaw is! Map<String, Object?> ||
        identityRaw is! Map<String, Object?> ||
        devicesRaw is! List) {
      throw const LoomProtocolException('Direct user profile is incomplete');
    }
    final homeNodeId = _requiredString(homeNodeRaw, 'nodeId', max: 256);
    final homeNodeDomain = _requiredString(
      homeNodeRaw,
      'domain',
      max: 512,
    ).toLowerCase();
    if (homeNodeId != expectedNodeId ||
        homeNodeDomain != expectedDomain.toLowerCase()) {
      throw const LoomProtocolException(
        'Direct user profile Home Node mismatch',
      );
    }
    if (devicesRaw.length > 64 ||
        devicesRaw.any((value) => value is! Map<String, Object?>)) {
      throw const LoomProtocolException('Invalid direct user device list');
    }
    final sortedDevices =
        devicesRaw.cast<Map<String, Object?>>().toList(growable: false)
          ..sort((left, right) {
            final a = left['deviceId'];
            final b = right['deviceId'];
            if (a is! String || b is! String) {
              throw const LoomProtocolException('Invalid direct device id');
            }
            return a.compareTo(b);
          });

    final updatedAtText = _requiredString(json, 'updatedAt', max: 64);
    final updatedAt = DateTime.tryParse(updatedAtText)?.toUtc();
    if (updatedAt == null) {
      throw const LoomProtocolException('Invalid direct profile timestamp');
    }
    final canonical = <String, Object?>{
      'protocol': protocol,
      'address': LoomAddress.parseCanonical(returnedAddress).canonical,
      'displayName': _requiredString(json, 'displayName', max: 80),
      if (json.containsKey('avatar'))
        'avatar': LoomPublicAvatar.parseOptional(json['avatar'])?.toJson(),
      'identity': identityRaw,
      'devices': sortedDevices,
      'homeNode': <String, Object?>{
        'nodeId': homeNodeId,
        'domain': homeNodeDomain,
      },
      'version': _requiredString(json, 'version', max: 128),
      'updatedAt': updatedAt.toIso8601String(),
    };

    final signatureText = _requiredString(json, 'signature', max: 256);
    try {
      final publicKeyBytes = base64Decode(nodePublicKey);
      final signatureBytes = base64Decode(signatureText);
      if (publicKeyBytes.length != 32 || signatureBytes.length != 64) {
        throw const FormatException('Invalid Ed25519 material length');
      }
      final valid = await Ed25519().verify(
        utf8.encode(jsonEncode(canonical)),
        signature: Signature(
          signatureBytes,
          publicKey: SimplePublicKey(publicKeyBytes, type: KeyPairType.ed25519),
        ),
      );
      if (!valid) {
        throw const LoomProtocolException(
          'Invalid direct user profile signature',
        );
      }
    } on FormatException {
      throw const LoomProtocolException(
        'Malformed direct user profile signature',
      );
    }
  }

  Future<LoomResolvedUserSecurity> _parseVerifiedSecurity(
    Map<String, Object?> json,
    String normalizedAddress,
  ) async {
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

  bool _fallbackEligible(String message) {
    return message == 'direct_user_resolution_unsupported' ||
        message == 'direct_user_resolution_unavailable' ||
        message == 'direct_user_cache_unsupported' ||
        message == 'direct_user_cache_unavailable' ||
        message.startsWith('HTTP 5') ||
        message.contains('timed out');
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
    return LoomAddress.parseCanonical(address).canonical;
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

/// Drop-in user-security client for existing product controllers. Only remote
/// resolution changes: destination-node direct verification is attempted first;
/// conversation creation and same-node behavior remain backward compatible.
final class LoomDirectFirstUserSecurityClient extends LoomUserSecurityClient {
  LoomDirectFirstUserSecurityClient({
    LoomDirectFirstUserSecurityResolver? resolver,
  }) : _resolver = resolver ?? LoomDirectFirstUserSecurityResolver();

  final LoomDirectFirstUserSecurityResolver _resolver;

  @override
  Future<LoomResolvedUserSecurity> resolve({
    required Uri baseUri,
    required String accessToken,
    required String address,
    required LoomDeviceRequestProofProvider deviceProofProvider,
  }) =>
      _resolver.resolve(
        baseUri: baseUri,
        accessToken: accessToken,
        address: address,
        deviceProofProvider: deviceProofProvider,
      );
}

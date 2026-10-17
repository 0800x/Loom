import 'dart:convert';
import 'dart:io';

import 'package:loom_models/loom_models.dart';
import 'package:cryptography/cryptography.dart';

import 'device_request_proof.dart';
import 'node_client.dart';
import 'transport_security.dart';

class LoomGroupProtocolException implements Exception {
  const LoomGroupProtocolException(this.status, this.code);
  final int status;
  final String code;
  @override
  String toString() => 'Group request failed ($status): $code';
}

/// Uses the signed-in Home Node only. Group federation is not negotiated yet.
class LoomGroupClient {
  LoomGroupClient({
    required this.baseUri,
    required this.accessTokenProvider,
    required this.deviceProof,
    HttpClient? httpClient,
  }) : _http = httpClient ?? HttpClient();
  final Uri baseUri;
  final Future<String> Function() accessTokenProvider;
  final LoomDeviceRequestProofProvider deviceProof;
  final HttpClient _http;
  void close() => _http.close(force: true);
  Future<Map<String, Object?>> request(
    String method,
    String path, [
    Map<String, Object?>? body,
  ]) async {
    requireLoomTransport(baseUri);
    if (!path.startsWith('/api/v1/groups'))
      throw ArgumentError('Invalid group path');
    final uri = baseUri.resolve(path), token = await accessTokenProvider();
    final bytes = body == null ? <int>[] : utf8.encode(jsonEncode(body));
    final proof = await deviceProof.headers(
      method: method,
      uri: uri,
      credential: token,
      bodyBytes: bytes,
    );
    final request =
        await _http.openUrl(method, uri).timeout(const Duration(seconds: 8));
    request.followRedirects = false;
    request.headers.contentType = ContentType.json;
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    proof.forEach((key, value) => request.headers.set(key, value));
    if (bytes.isNotEmpty) request.add(bytes);
    final response = await request.close().timeout(const Duration(seconds: 15));
    final collected = <int>[];
    await for (final part in response.timeout(const Duration(seconds: 15))) {
      collected.addAll(part);
      if (collected.length > 8 * 1024 * 1024) {
        throw const LoomProtocolException('Group response too large');
      }
    }
    Map<String, Object?> json;
    try {
      json =
          Map<String, Object?>.from(jsonDecode(utf8.decode(collected)) as Map);
    } catch (_) {
      if (response.statusCode < 200 || response.statusCode > 299) {
        throw LoomGroupProtocolException(
            response.statusCode,
            response.statusCode == 404
                ? 'not_found'
                : 'invalid_group_response');
      }
      throw const LoomProtocolException('Invalid group response');
    }
    if (response.statusCode < 200 || response.statusCode > 299) {
      throw LoomGroupProtocolException(
        response.statusCode,
        json['error'] as String? ?? 'group_error',
      );
    }
    return json;
  }

  String _group(String id) => '/api/v1/groups/${Uri.encodeComponent(id)}';
  Future<Map<String, Object?>> memberProfile(String deviceId) => request(
        'GET',
        '/api/v1/groups/devices/${Uri.encodeComponent(deviceId)}/profile',
      );
  Future<Map<String, Object?>> createInvite(String id, String mode) =>
      request('POST', '${_group(id)}/invites', {'mode': mode});
  Future<void> revokeInvites(String id) async {
    await request('DELETE', '${_group(id)}/invites');
  }

  Future<Map<String, Object?>> previewInvite(String token) =>
      request('GET', '/api/v1/groups/invites/${Uri.encodeComponent(token)}');
  Future<Map<String, Object?>> requestJoin(String token) => request(
        'POST',
        '/api/v1/groups/invites/${Uri.encodeComponent(token)}/join',
        {},
      );
  Future<List<Map<String, Object?>>> joinRequests(String id) async =>
      ((await request('GET', '${_group(id)}/join-requests'))['requests']
              as List)
          .map((r) => Map<String, Object?>.from(r as Map))
          .toList();
  Future<void> decideJoin(String id, String deviceId, bool approve) async {
    await request(
      'POST',
      '${_group(id)}/join-requests/${Uri.encodeComponent(deviceId)}',
      {'approve': approve},
    );
  }

  Future<void> publishCredential(LoomGroupMember member) async {
    await request(
      'POST',
      '/api/v1/groups/devices/${Uri.encodeComponent(member.deviceId)}/credential',
      member.toJson(),
    );
  }

  Future<LoomGroupMember> credential(String deviceId) async =>
      LoomGroupMember.fromJson(
        await request(
          'GET',
          '/api/v1/groups/devices/${Uri.encodeComponent(deviceId)}/credential',
        ),
      );
  Future<List<String>> list() async =>
      ((await request('GET', '/api/v1/groups'))['groupIds'] as List)
          .cast<String>();
  Future<int> availableKeyPackages() async {
    final count = (await request(
      'GET',
      '/api/v1/groups/key-packages',
    ))['available'];
    if (count is! int || count < 0) {
      throw const LoomProtocolException('Invalid key package stock');
    }
    return count;
  }

  Future<LoomGroupState> get(String id) async =>
      LoomGroupState.fromJson(await request('GET', _group(id)));
  Future<LoomGroupState> create(String id, Map<String, Object?> body) async =>
      LoomGroupState.fromJson(await request('POST', _group(id), body));
  Future<LoomGroupState> commit(String id, Map<String, Object?> body) async =>
      LoomGroupState.fromJson(
        await request('POST', '${_group(id)}/commits', body),
      );
  Future<Map<String, Object?>> send(String id, Map<String, Object?> body) =>
      request('POST', '${_group(id)}/messages', body);
  Future<Map<String, Object?>> inbox(String id, int after) =>
      request('GET', '${_group(id)}/inbox?after=$after');
  Future<Map<String, Object?>> claim(String deviceId) => request(
        'POST',
        '/api/v1/groups/key-packages/${Uri.encodeComponent(deviceId)}/claim',
        {},
      );
  Future<void> publish(Map<String, Object?> package) async {
    await request('POST', '/api/v1/groups/key-packages', package);
  }
}

/// The bundle passed here MUST already be verified against a locally trusted
/// account root. A public key supplied by an invitation cannot establish trust.
Future<void> verifyLoomGroupMember(
  LoomGroupMember member,
  LoomDeviceKeyBundle trustedDevice,
) async {
  if (member.deviceId != trustedDevice.deviceId ||
      member.identityId != trustedDevice.identityId ||
      base64Decode(member.mlsSignatureKey).length != 32 ||
      !await Ed25519().verify(
        member.binding,
        signature: Signature(
          base64Decode(member.mlsSignature),
          publicKey: SimplePublicKey(
            base64Decode(trustedDevice.signingPublicKey),
            type: KeyPairType.ed25519,
          ),
        ),
      )) {
    throw const LoomProtocolException('Untrusted MLS device credential');
  }
}

Future<List<int>> loomKeyPackageBinding({
  required String identityId,
  required String deviceId,
  required String id,
  required List<int> serialized,
  required String expiresAt,
}) async {
  final hash = await Sha256().hash(serialized);
  return utf8.encode(
    jsonEncode({
      'protocol': loomGroupProtocol,
      'identityId': identityId,
      'deviceId': deviceId,
      'id': id,
      'sha256':
          hash.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
      'expiresAt': expiresAt,
    }),
  );
}

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:loom_dtn/loom_dtn.dart';

const _directProofDomain = 'loom-direct-node-v1';

String _base64UrlNoPadding(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

String _millisecondIso(DateTime value) => DateTime.fromMillisecondsSinceEpoch(
      value.toUtc().millisecondsSinceEpoch,
      isUtc: true,
    ).toIso8601String();

bool _bytesEqual(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  var different = 0;
  for (var i = 0; i < left.length; i++) {
    different |= left[i] ^ right[i];
  }
  return different == 0;
}

/// Non-exporting signing boundary for the direct-node transport identity.
///
/// Production implementations should reuse the authorized Loom device
/// signing key and keep its private material behind platform secure storage.
/// The 32-byte Ed25519 public key is safe to expose and is hashed by the
/// destination node into a self-certifying transport fingerprint.
abstract interface class LoomDirectTransportSigner {
  Future<Uint8List> ed25519PublicKey();

  Future<Uint8List> sign(Uint8List canonicalBytes);
}

final class LoomDirectNodeTarget {
  LoomDirectNodeTarget({
    required this.nodeId,
    required this.endpoint,
    required Uint8List mailboxToken,
    required this.identityVerified,
  }) : mailboxToken = Uint8List.fromList(mailboxToken) {
    if (nodeId.trim() != nodeId || nodeId.length < 8 || nodeId.length > 256) {
      throw const FormatException('Invalid direct destination node id');
    }
    if (this.mailboxToken.length < 16 || this.mailboxToken.length > 128) {
      throw const FormatException('Invalid direct destination mailbox token');
    }
    if (!_allowedEndpoint(endpoint)) {
      throw const FormatException('Unsafe direct destination endpoint');
    }
  }

  final String nodeId;
  final Uri endpoint;
  final Uint8List mailboxToken;
  final bool identityVerified;

  Uri get directIngressUri {
    final basePath = endpoint.path.isEmpty
        ? '/'
        : endpoint.path.endsWith('/')
            ? endpoint.path
            : '${endpoint.path}/';
    return endpoint.replace(
      path: '${basePath}api/v2/packets/direct',
      query: null,
      fragment: null,
    );
  }

  static bool _allowedEndpoint(Uri value) {
    if (value.userInfo.isNotEmpty ||
        value.fragment.isNotEmpty ||
        value.query.isNotEmpty) {
      return false;
    }
    if (value.scheme == 'https') return true;
    if (value.scheme != 'http') return false;
    final host = value.host.toLowerCase();
    if (host == 'localhost') return true;
    final address = InternetAddress.tryParse(host);
    return address?.isLoopback ?? false;
  }
}

final class LoomDirectHttpResponse {
  const LoomDirectHttpResponse({required this.statusCode, required this.body});

  final int statusCode;
  final Map<String, Object?>? body;
}

abstract interface class LoomDirectHttpPoster {
  Future<LoomDirectHttpResponse> postJson(Uri uri, Map<String, Object?> body);
}

/// Strict HTTPS JSON poster used by the direct destination-node sender.
///
/// One poster owns one reusable [HttpClient]. Callers should keep the poster (or
/// a sender containing it) pooled for a destination node rather than creating a
/// new one for every message. Dart's HttpClient then reuses keep-alive sockets
/// and bounds idle connections automatically.
final class LoomIoDirectHttpPoster implements LoomDirectHttpPoster {
  LoomIoDirectHttpPoster({
    this.connectTimeout = const Duration(seconds: 5),
    this.requestTimeout = const Duration(seconds: 10),
    this.idleTimeout = const Duration(seconds: 15),
    this.maxResponseBytes = 64 * 1024,
  }) : _client = HttpClient() {
    _client.connectionTimeout = connectTimeout;
    _client.idleTimeout = idleTimeout;
  }

  final Duration connectTimeout;
  final Duration requestTimeout;
  final Duration idleTimeout;
  final int maxResponseBytes;
  final HttpClient _client;
  bool _closed = false;

  @override
  Future<LoomDirectHttpResponse> postJson(
    Uri uri,
    Map<String, Object?> body,
  ) async {
    if (_closed) throw StateError('Direct-node HTTP poster is closed');
    final request = await _client.postUrl(uri).timeout(requestTimeout);
    request.followRedirects = false;
    request.headers.contentType = ContentType.json;
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    request.write(jsonEncode(body));
    final response = await request.close().timeout(requestTimeout);
    final bytes = <int>[];
    await for (final chunk in response.timeout(requestTimeout)) {
      bytes.addAll(chunk);
      if (bytes.length > maxResponseBytes) {
        throw const FormatException('Direct-node response is too large');
      }
    }
    Map<String, Object?>? decoded;
    if (bytes.isNotEmpty) {
      final value = jsonDecode(utf8.decode(bytes));
      if (value is! Map) {
        throw const FormatException('Direct-node response must be an object');
      }
      decoded = value.map(
        (key, value) => MapEntry(key.toString(), value as Object?),
      );
    }
    return LoomDirectHttpResponse(
      statusCode: response.statusCode,
      body: decoded,
    );
  }

  void close({bool force = false}) {
    if (_closed) return;
    _closed = true;
    _client.close(force: force);
  }
}

/// Sends one already-durable opaque DTN transfer directly to the recipient's
/// destination node, bypassing the sender's Home Node.
///
/// This transport proof is not end-to-end user identity. The opaque payload
/// still carries the normal Architecture-v2 E2EE/session identity evidence.
final class LoomDirectNodeTransferSender implements LoomDtnTransferSender {
  LoomDirectNodeTransferSender({
    required this.packetStore,
    required this.target,
    required this.signer,
    LoomDirectHttpPoster? poster,
    DateTime Function()? clock,
    Uint8List Function()? nonceFactory,
  })  : poster = poster ?? LoomIoDirectHttpPoster(),
        _clock = clock ?? DateTime.now,
        _nonceFactory = nonceFactory ?? _secureNonce;

  final LoomPacketStore packetStore;
  final LoomDirectNodeTarget target;
  final LoomDirectTransportSigner signer;
  final LoomDirectHttpPoster poster;
  final DateTime Function() _clock;
  final Uint8List Function() _nonceFactory;

  @override
  Future<LoomDtnSendResult> sendPrepared(LoomStoredDtnTransfer transfer) async {
    final completedAt = _clock().toUtc();
    if (!target.identityVerified) {
      return LoomDtnSendFailed(
        completedAt: completedAt,
        errorCode: 'direct-target-unverified',
      );
    }
    if (transfer.reason != LoomDtnTransferReason.destinationNode) {
      return LoomDtnSendFailed(
        completedAt: completedAt,
        errorCode: 'direct-route-mismatch',
      );
    }
    final packet = packetStore.read(transfer.packetId);
    if (packet == null) {
      return LoomDtnSendFailed(
        completedAt: completedAt,
        errorCode: 'direct-packet-missing',
      );
    }
    if (!_bytesEqual(packet.mailboxToken, target.mailboxToken)) {
      return LoomDtnSendFailed(
        completedAt: completedAt,
        errorCode: 'direct-mailbox-mismatch',
      );
    }
    final publicKey = await signer.ed25519PublicKey();
    if (publicKey.length != 32) {
      return LoomDtnSendFailed(
        completedAt: completedAt,
        errorCode: 'direct-key-invalid',
      );
    }

    final issuedAt = _millisecondIso(completedAt);
    final nonce = _nonceFactory();
    if (nonce.length < 16 || nonce.length > 64) {
      return LoomDtnSendFailed(
        completedAt: completedAt,
        errorCode: 'direct-nonce-invalid',
      );
    }
    final devicePublicKey = _base64UrlNoPadding(publicKey);
    final body = <String, Object?>{
      'packetId': transfer.packetId,
      'mailboxToken': _base64UrlNoPadding(target.mailboxToken),
      'envelopeBase64': _base64UrlNoPadding(transfer.wireBytes),
      'expiresAt': _millisecondIso(packet.expiresAt),
      'priority': packet.priority.name,
    };
    final unsignedProof = <String, Object?>{
      'devicePublicKey': devicePublicKey,
      'issuedAt': issuedAt,
      'nonce': _base64UrlNoPadding(nonce),
    };
    final canonical = Uint8List.fromList(
      utf8.encode(
        jsonEncode(<Object?>[
          _directProofDomain,
          issuedAt,
          unsignedProof['nonce'],
          devicePublicKey,
          body['packetId'],
          body['mailboxToken'],
          body['envelopeBase64'],
          body['expiresAt'],
          body['priority'],
        ]),
      ),
    );
    final signature = await signer.sign(canonical);
    if (signature.length != 64) {
      return LoomDtnSendFailed(
        completedAt: _clock().toUtc(),
        errorCode: 'direct-signature-invalid',
      );
    }
    body['transportProof'] = <String, Object?>{
      ...unsignedProof,
      'signature': _base64UrlNoPadding(signature),
    };

    try {
      final response = await poster.postJson(target.directIngressUri, body);
      if (response.statusCode != 200 && response.statusCode != 202) {
        return LoomDtnSendFailed(
          completedAt: _clock().toUtc(),
          errorCode: 'direct-http-${response.statusCode}',
        );
      }
      final responseBody = response.body;
      if (responseBody == null ||
          responseBody['accepted'] != true ||
          responseBody['packetId'] != transfer.packetId) {
        return LoomDtnSendFailed(
          completedAt: _clock().toUtc(),
          errorCode: 'direct-response-invalid',
        );
      }
      final acceptedAtValue = responseBody['acceptedAt'];
      final acceptedAt = acceptedAtValue is String
          ? DateTime.tryParse(acceptedAtValue)?.toUtc()
          : null;
      if (acceptedAt == null) {
        return LoomDtnSendFailed(
          completedAt: _clock().toUtc(),
          errorCode: 'direct-response-invalid',
        );
      }
      return LoomDtnSendAccepted(
        LoomDtnHopAck(
          transmissionId: transfer.transmissionId,
          packetId: transfer.packetId,
          acceptedAt: acceptedAt,
          duplicate: responseBody['idempotent'] == true,
        ),
      );
    } catch (_) {
      return LoomDtnSendFailed(
        completedAt: _clock().toUtc(),
        errorCode: 'direct-transport-failed',
      );
    }
  }

  static Uint8List _secureNonce() {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(24, (_) => random.nextInt(256)),
    );
  }
}

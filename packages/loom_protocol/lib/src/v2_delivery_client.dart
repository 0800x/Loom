import 'transport_security.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'device_request_proof.dart';
import 'messaging_client.dart' show LoomAccessTokenProvider;
import 'node_client.dart' show LoomProtocolException;

String _b64u(List<int> bytes) => base64UrlEncode(bytes).replaceAll('=', '');

/// Opaque Architecture-v2 mailbox packet returned by a Home Node.
///
/// The Node can see only the routable outer envelope. Message metadata and the
/// legacy production E2EE envelope, when used by the compatibility bridge, stay
/// inside [envelopeBytes].
final class LoomV2MailboxPacket {
  LoomV2MailboxPacket({
    required this.packetId,
    required Uint8List mailboxToken,
    required Uint8List envelopeBytes,
    required this.expiresAt,
    required this.priority,
    required this.acceptedAt,
  })  : mailboxToken = Uint8List.fromList(mailboxToken),
        envelopeBytes = Uint8List.fromList(envelopeBytes);

  final String packetId;
  final Uint8List mailboxToken;
  final Uint8List envelopeBytes;
  final DateTime expiresAt;
  final String priority;
  final DateTime acceptedAt;

  factory LoomV2MailboxPacket.fromJson(Map<String, Object?> json) {
    String text(String key, {int max = 2 * 1024 * 1024}) {
      final value = json[key];
      if (value is! String ||
          value.isEmpty ||
          value.length > max ||
          value.contains(RegExp(r'[\r\n\x00]'))) {
        throw LoomProtocolException('Invalid V2 mailbox packet $key');
      }
      return value;
    }

    Uint8List decodeBase64Url(
      String key, {
      required int minBytes,
      required int maxBytes,
    }) {
      final encoded = text(key, max: ((maxBytes * 4) ~/ 3) + 16);
      if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(encoded)) {
        throw LoomProtocolException('Invalid V2 mailbox packet $key');
      }
      final bytes = base64Url.decode(base64Url.normalize(encoded));
      if (bytes.length < minBytes ||
          bytes.length > maxBytes ||
          _b64u(bytes) != encoded) {
        throw LoomProtocolException('Invalid V2 mailbox packet $key');
      }
      return Uint8List.fromList(bytes);
    }

    final expiresAt = DateTime.tryParse(text('expiresAt', max: 64))?.toUtc();
    final acceptedAt = DateTime.tryParse(text('acceptedAt', max: 64))?.toUtc();
    final priority = text('priority', max: 16);
    if (expiresAt == null ||
        acceptedAt == null ||
        (priority != 'normal' && priority != 'urgent')) {
      throw const LoomProtocolException('Invalid V2 mailbox packet metadata');
    }
    return LoomV2MailboxPacket(
      packetId: text('packetId', max: 128),
      mailboxToken: decodeBase64Url(
        'mailboxToken',
        minBytes: 16,
        maxBytes: 128,
      ),
      envelopeBytes: decodeBase64Url(
        'envelopeBase64',
        minBytes: 1,
        maxBytes: 1024 * 1024 + 4096,
      ),
      expiresAt: expiresAt,
      priority: priority,
      acceptedAt: acceptedAt,
    );
  }
}

/// Authenticated client for the opaque Architecture-v2 mailbox surface.
///
/// It deliberately shares the same bearer token + device-bound request proof
/// contract as ordinary messaging. It does not know message plaintext or
/// session-provider state.
final class LoomV2DeliveryClient {
  LoomV2DeliveryClient({
    required this.baseUri,
    required this.accessTokenProvider,
    required this.deviceProofProvider,
    HttpClient? httpClient,
  }) : _http = httpClient ?? HttpClient();

  final Uri baseUri;
  final LoomAccessTokenProvider accessTokenProvider;
  final LoomDeviceRequestProofProvider deviceProofProvider;
  final HttpClient _http;
  bool _closed = false;

  Future<DateTime> registerMailbox({
    required Uint8List mailboxToken,
    required DateTime expiresAt,
  }) async {
    if (mailboxToken.length < 16 || mailboxToken.length > 128) {
      throw const LoomProtocolException('Invalid V2 mailbox token');
    }
    final expiry = expiresAt.toUtc();
    if (!expiry.isAfter(DateTime.now().toUtc())) {
      throw const LoomProtocolException(
          'V2 mailbox expiry must be in the future');
    }
    final json = await _requestJson(
      'PUT',
      '/api/v2/mailboxes',
      body: <String, Object?>{
        'mailboxToken': _b64u(mailboxToken),
        'expiresAt': expiry.toIso8601String(),
      },
    );
    final returnedToken = json['mailboxToken'];
    final returnedExpiry = json['expiresAt'];
    if (returnedToken != _b64u(mailboxToken) || returnedExpiry is! String) {
      throw const LoomProtocolException(
          'Invalid V2 mailbox registration receipt');
    }
    final parsed = DateTime.tryParse(returnedExpiry)?.toUtc();
    if (parsed == null) {
      throw const LoomProtocolException('Invalid V2 mailbox expiry receipt');
    }
    return parsed;
  }

  Future<List<LoomV2MailboxPacket>> pullPackets({
    required Uint8List mailboxToken,
    int limit = 50,
  }) async {
    if (mailboxToken.length < 16 || mailboxToken.length > 128) {
      throw const LoomProtocolException('Invalid V2 mailbox token');
    }
    if (limit < 1 || limit > 50) {
      throw ArgumentError.value(limit, 'limit');
    }
    final json = await _requestJson(
      'POST',
      '/api/v2/packets/pull',
      body: <String, Object?>{
        'mailboxToken': _b64u(mailboxToken),
        'limit': limit,
      },
    );
    final packets = json['packets'];
    if (packets is! List) {
      throw const LoomProtocolException('Invalid V2 mailbox pull response');
    }
    return packets.map((value) {
      if (value is! Map) {
        throw const LoomProtocolException('Invalid V2 mailbox packet');
      }
      return LoomV2MailboxPacket.fromJson(
        value.map((key, value) => MapEntry(key.toString(), value as Object?)),
      );
    }).toList(growable: false);
  }

  Future<void> acknowledgePacket(String packetId) async {
    if (packetId.trim() != packetId ||
        packetId.length < 8 ||
        packetId.length > 128 ||
        packetId.contains(RegExp(r'[\r\n\x00/]'))) {
      throw const LoomProtocolException('Invalid V2 packet id');
    }
    final encoded = Uri.encodeComponent(packetId);
    final json = await _requestJson(
      'POST',
      '/api/v2/packets/$encoded/ack',
      body: const <String, Object?>{},
    );
    if (json['packetId'] != packetId || json['acknowledged'] != true) {
      throw const LoomProtocolException('Invalid V2 mailbox acknowledgement');
    }
  }

  Future<Map<String, Object?>> _requestJson(
    String method,
    String path, {
    Map<String, Object?>? body,
  }) async {
    if (_closed) throw StateError('V2 delivery client is closed');
    final uri = baseUri.resolve(path);
    _requireSafeUri(uri);
    final token = await accessTokenProvider();
    final bodyBytes =
        body == null ? const <int>[] : utf8.encode(jsonEncode(body));
    final proofHeaders = await deviceProofProvider.headers(
      method: method,
      uri: uri,
      credential: token,
      bodyBytes: bodyBytes,
    );
    final request =
        await _http.openUrl(method, uri).timeout(const Duration(seconds: 8));
    request.followRedirects = false;
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    for (final entry in proofHeaders.entries) {
      request.headers.set(entry.key, entry.value);
    }
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.add(bodyBytes);
    }
    final response = await request.close().timeout(const Duration(seconds: 15));
    final bytes = <int>[];
    await for (final chunk in response) {
      bytes.addAll(chunk);
      if (bytes.length > 4 * 1024 * 1024) {
        throw const LoomProtocolException('V2 delivery response is too large');
      }
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      String detail = 'HTTP ${response.statusCode} from ${uri.host}';
      try {
        final decoded = jsonDecode(utf8.decode(bytes));
        if (decoded is Map && decoded['error'] is String) {
          detail = decoded['error'] as String;
        }
      } catch (_) {}
      throw LoomProtocolException(detail);
    }
    if (bytes.isEmpty) return const <String, Object?>{};
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map) {
      throw const LoomProtocolException('Expected V2 delivery JSON object');
    }
    return decoded.map(
      (key, value) => MapEntry(key.toString(), value as Object?),
    );
  }

  void close({bool force = false}) {
    if (_closed) return;
    _closed = true;
    _http.close(force: force);
  }

  static void _requireSafeUri(Uri uri) =>
      requireLoomTransport(uri, baseEndpoint: false);
}

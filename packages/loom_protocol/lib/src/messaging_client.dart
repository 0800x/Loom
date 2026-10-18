import 'transport_security.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:loom_models/loom_models.dart';
import 'package:cryptography/cryptography.dart';

import 'device_request_proof.dart';
import 'node_client.dart';

typedef LoomAccessTokenProvider = Future<String> Function();

/// Protocol failure backed by an actual HTTP response from a Loom endpoint.
///
/// Keeping the status code separate from the server-safe error text lets route
/// and DTN policy distinguish a temporary transport/server outage from a
/// definitive authorization, validation, or quota rejection. In particular,
/// callers must not turn a 4xx response into an offline-delivery bypass.
class LoomHttpStatusException extends LoomProtocolException {
  const LoomHttpStatusException({
    required this.statusCode,
    required String message,
  }) : super(message);

  final int statusCode;

  bool get retryableOnAlternateRoute =>
      statusCode == HttpStatus.requestTimeout ||
      statusCode == 425 ||
      (statusCode >= 500 && statusCode <= 599);

  @override
  String toString() => 'LoomHttpStatusException($statusCode): $message';
}

abstract interface class LoomMessagingApi {
  Future<List<LoomConversation>> fetchConversations();
  Future<LoomSendReceipt> sendOpaqueMessage({
    required String conversationId,
    required String clientId,
    required LoomMessageType type,
    required String ciphertext,
    required String protocolVersion,
    String? replyToMessageId,
    Map<String, Object?> metadata = const {},
  });
  Future<LoomSyncPage> sync({String? cursor, int limit = 200});
  Future<void> markRead({
    required String conversationId,
    required int throughOrder,
  });
  Future<LoomAttachmentReceipt> uploadEncryptedAttachment({
    required String conversationId,
    required File encryptedFile,
    required String contentType,
  });
}

class LoomMessagingClient implements LoomMessagingApi {
  LoomMessagingClient({
    required this.baseUri,
    required this.accessTokenProvider,
    required this.deviceProofProvider,
    this.refreshRejectedToken,
    this.connectTimeout = const Duration(seconds: 8),
    this.responseHeaderTimeout = const Duration(seconds: 15),
    this.responseBodyTimeout = const Duration(seconds: 15),
    HttpClient? httpClient,
  }) : _http = httpClient ?? HttpClient() {
    // Future.timeout does not cancel a pending socket connect. Configure the
    // underlying HttpClient too so network switches/dead routes cannot leave a
    // connect attempt alive after the application-level deadline has fired.
    _http.connectionTimeout = connectTimeout;
  }

  final Uri baseUri;
  final LoomAccessTokenProvider accessTokenProvider;
  final LoomDeviceRequestProofProvider deviceProofProvider;
  final Future<bool> Function(String rejectedToken)? refreshRejectedToken;
  final Duration connectTimeout;
  final Duration responseHeaderTimeout;
  final Duration responseBodyTimeout;
  final HttpClient _http;

  Future<Map<String, Object?>> fetchOwnProfile() =>
      _requestJson('GET', '/api/v1/profile');

  Future<Map<String, Object?>> updateOwnProfile(Map<String, Object?> profile) =>
      _requestJson('PUT', '/api/v1/profile', body: profile);

  Future<Map<String, Object?>> fetchConversationPresence(
    String conversationId,
  ) =>
      _requestJson(
        'GET',
        '/api/v1/conversations/${Uri.encodeComponent(conversationId)}/presence',
      );

  Future<void> acknowledgeReceived(List<String> clientIds) async {
    if (clientIds.isEmpty) {
      return;
    }
    await _requestJson(
      'POST',
      '/api/v1/messages/received',
      body: {'clientIds': clientIds},
    );
  }

  Future<List<LoomConversation>> fetchConversations() async {
    final json = await _requestJson('GET', '/api/v1/conversations');
    final raw = json['conversations'];
    if (raw is! List) {
      throw const LoomProtocolException('Invalid conversations payload');
    }
    return raw
        .where(
      (value) =>
          value is! Map<String, Object?> ||
          value['kind'] is! String ||
          LoomConversationKind.values.any(
            (k) => k.name == (value['kind'] as String).toLowerCase(),
          ),
    )
        .map((value) {
      if (value is! Map<String, Object?>) {
        throw const LoomProtocolException('Invalid conversation');
      }
      return _conversation(value);
    }).toList(growable: false);
  }

  Future<LoomSendReceipt> sendOpaqueMessage({
    required String conversationId,
    required String clientId,
    required LoomMessageType type,
    required String ciphertext,
    required String protocolVersion,
    String? replyToMessageId,
    Map<String, Object?> metadata = const {},
  }) async {
    if (ciphertext.isEmpty || ciphertext.length > 2 * 1024 * 1024) {
      throw const LoomProtocolException(
        'Opaque message envelope is empty or too large',
      );
    }
    final json = await _requestJson(
      'POST',
      '/api/v1/messages',
      body: {
        'conversationId': conversationId,
        'clientId': clientId,
        'type': type.name.toUpperCase(),
        'ciphertext': ciphertext,
        'protocolVersion': protocolVersion,
        if (replyToMessageId != null) 'replyToMessageId': replyToMessageId,
        'metadata': metadata,
      },
      acceptedStatusCodes: const {200, 201},
    );
    final order = json['serverOrder'];
    final createdAt = json['createdAt'];
    if (order is! int ||
        order < 0 ||
        createdAt is! String ||
        DateTime.tryParse(createdAt) == null) {
      throw const LoomProtocolException('Invalid send receipt');
    }
    return LoomSendReceipt(
      messageId: _requiredString(json, 'messageId'),
      clientId: _requiredString(json, 'clientId'),
      serverOrder: order,
      createdAt: DateTime.parse(createdAt).toUtc(),
    );
  }

  Future<LoomSyncPage> sync({String? cursor, int limit = 200}) async {
    if (limit < 1 || limit > 500) {
      throw ArgumentError.value(limit, 'limit');
    }
    final query = <String, String>{'limit': '$limit'};
    if (cursor != null && cursor.isNotEmpty) {
      query['cursor'] = cursor;
    }
    final uri = baseUri.resolve('/api/v1/sync').replace(queryParameters: query);
    final json = await _requestAbsoluteJson('GET', uri);
    final eventsRaw = json['events'];
    if (eventsRaw is! List) {
      throw const LoomProtocolException('Invalid sync events');
    }
    final events = eventsRaw.map((raw) {
      if (raw is! Map<String, Object?>) {
        throw const LoomProtocolException('Invalid sync event');
      }
      final order = raw['order'];
      final payload = raw['payload'];
      if (order is! int || order < 0 || payload is! Map<String, Object?>) {
        throw const LoomProtocolException('Invalid sync event fields');
      }
      return LoomSyncEvent(
        eventId: _requiredString(raw, 'eventId'),
        kind: _requiredString(raw, 'kind'),
        order: order,
        payload: payload,
      );
    }).toList(growable: false);
    final nextCursor = json['nextCursor'];
    final hasMore = json['hasMore'];
    if (nextCursor != null && nextCursor is! String) {
      throw const LoomProtocolException('Invalid sync cursor');
    }
    if (hasMore is! bool) {
      throw const LoomProtocolException('Invalid sync hasMore');
    }
    return LoomSyncPage(
      events: events,
      nextCursor: nextCursor as String?,
      hasMore: hasMore,
    );
  }

  Future<void> markRead({
    required String conversationId,
    required int throughOrder,
  }) async {
    if (throughOrder < 0) {
      throw ArgumentError.value(throughOrder, 'throughOrder');
    }
    await _requestJson(
      'POST',
      '/api/v1/conversations/$conversationId/read',
      body: {'throughOrder': throughOrder},
      acceptedStatusCodes: const {200, 204},
      allowEmpty: true,
    );
  }

  @override
  Future<LoomAttachmentReceipt> uploadEncryptedAttachment({
    required String conversationId,
    required File encryptedFile,
    required String contentType,
  }) async {
    final length = await encryptedFile.length();
    if (length <= 0 || length > 512 * 1024 * 1024) {
      throw const LoomProtocolException(
        'Encrypted attachment size is outside Phase 3 limits',
      );
    }
    if (contentType.trim().isEmpty || contentType.length > 128) {
      throw const LoomProtocolException('Invalid attachment content type');
    }
    final uri = baseUri.resolve('/api/v1/attachments');
    _requireSafeUri(uri);
    final accessToken = await accessTokenProvider();
    final hashSink = Sha256().newHashSink();
    await for (final chunk in encryptedFile.openRead()) {
      hashSink.add(chunk);
    }
    hashSink.close();
    final fileHash = await hashSink.hash();
    final bodyHash = fileHash.bytes
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
    final proofHeaders = await deviceProofProvider.headersForBodyHash(
      method: 'POST',
      uri: uri,
      credential: accessToken,
      bodySha256: bodyHash,
    );
    final request = await _http.postUrl(uri).timeout(connectTimeout);
    request.followRedirects = false;
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $accessToken');
    for (final entry in proofHeaders.entries) {
      request.headers.set(entry.key, entry.value);
    }
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    request.headers.set('X-Loom-Conversation', conversationId);
    request.headers.set(
      HttpHeaders.contentTypeHeader,
      'application/octet-stream',
    );
    request.headers.set('X-Loom-Encrypted-Content-Type', contentType);
    request.contentLength = length;
    await request.addStream(encryptedFile.openRead());
    late final HttpClientResponse response;
    try {
      response = await request.close().timeout(const Duration(minutes: 5));
    } on TimeoutException catch (error, stackTrace) {
      request.abort(error, stackTrace);
      rethrow;
    }
    final bytes = <int>[];
    final bodyRead = () async {
      await for (final chunk in response) {
        bytes.addAll(chunk);
        if (bytes.length > 128 * 1024) {
          throw const LoomProtocolException(
            'Attachment response exceeds size limit',
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
    if (response.statusCode != 200 && response.statusCode != 201) {
      throw LoomHttpStatusException(
        statusCode: response.statusCode,
        message: 'Attachment upload failed with HTTP ${response.statusCode}',
      );
    }
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, Object?>) {
      throw const LoomProtocolException('Invalid attachment receipt');
    }
    final size = decoded['sizeBytes'];
    if (size is! int || size != length) {
      throw const LoomProtocolException('Attachment size receipt mismatch');
    }
    return LoomAttachmentReceipt(
      attachmentId: _requiredString(decoded, 'attachmentId'),
      sizeBytes: size,
      contentType: _requiredString(decoded, 'contentType'),
    );
  }

  LoomRealtimeConnection realtime({String? cursor}) => LoomRealtimeConnection(
        baseUri: baseUri,
        accessTokenProvider: accessTokenProvider,
        deviceProofProvider: deviceProofProvider,
        cursor: cursor,
      );

  Future<Map<String, Object?>> _requestJson(
    String method,
    String path, {
    Map<String, Object?>? body,
    Set<int> acceptedStatusCodes = const {200},
    bool allowEmpty = false,
  }) =>
      _requestAbsoluteJson(
        method,
        baseUri.resolve(path),
        body: body,
        acceptedStatusCodes: acceptedStatusCodes,
        allowEmpty: allowEmpty,
      );

  Future<Map<String, Object?>> _requestAbsoluteJson(
    String method,
    Uri uri, {
    Map<String, Object?>? body,
    Set<int> acceptedStatusCodes = const {200},
    bool allowEmpty = false,
    bool retryAuthentication = true,
  }) async {
    _requireSafeUri(uri);
    late final String accessToken;
    try {
      accessToken = await accessTokenProvider();
    } on LoomProtocolException catch (error) {
      // The app-level token provider uses this exact local error when no usable
      // online session can be refreshed. That is transport unavailability for
      // an already-created E2EE message, not an HTTP authorization response.
      // Convert only this sentinel so the resilience layer may use durable DTN;
      // real server 4xx responses remain LoomHttpStatusException below and
      // are never turned into an authorization bypass.
      if (error.message != 'Access token unavailable') {
        rethrow;
      }
      throw const SocketException(
        'Loom online session is unavailable for this request',
      );
    }
    final bodyBytes =
        body == null ? const <int>[] : utf8.encode(jsonEncode(body));
    final proofHeaders = await deviceProofProvider.headers(
      method: method,
      uri: uri,
      credential: accessToken,
      bodyBytes: bodyBytes,
    );
    final request = await _http.openUrl(method, uri).timeout(connectTimeout);
    request.followRedirects = false;
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $accessToken');
    for (final entry in proofHeaders.entries) {
      request.headers.set(entry.key, entry.value);
    }
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.add(bodyBytes);
    }
    late final HttpClientResponse response;
    try {
      response = await request.close().timeout(responseHeaderTimeout);
    } on TimeoutException catch (error, stackTrace) {
      request.abort(error, stackTrace);
      rethrow;
    }
    final bytes = <int>[];
    final bodyRead = () async {
      await for (final chunk in response) {
        bytes.addAll(chunk);
        if (bytes.length > 4 * 1024 * 1024) {
          throw const LoomProtocolException('Response exceeds maximum size');
        }
      }
    }();
    try {
      // A socket can survive a Wi-Fi/default-network switch long enough for
      // headers to arrive and then stop making progress. Bound the whole body,
      // not merely inter-chunk idle time, so Send always reaches a terminal
      // transport result and DTN policy gets a TimeoutException to classify.
      await bodyRead.timeout(responseBodyTimeout);
    } on TimeoutException catch (error, stackTrace) {
      request.abort(error, stackTrace);
      rethrow;
    }
    if (response.statusCode == 401 &&
        retryAuthentication &&
        refreshRejectedToken != null &&
        await refreshRejectedToken!(accessToken)) {
      // Rebuild the device proof (nonce and credential hash) on retry. Keep the
      // same message clientId so an ambiguous POST remains idempotent.
      return _requestAbsoluteJson(
        method,
        uri,
        body: body,
        acceptedStatusCodes: acceptedStatusCodes,
        allowEmpty: allowEmpty,
        retryAuthentication: false,
      );
    }
    if (!acceptedStatusCodes.contains(response.statusCode)) {
      String detail = 'HTTP ${response.statusCode} from ${uri.host}';
      try {
        final decoded = jsonDecode(utf8.decode(bytes));
        if (decoded is Map<String, Object?> && decoded['error'] is String) {
          detail = decoded['error'] as String;
        }
      } catch (_) {}
      throw LoomHttpStatusException(
        statusCode: response.statusCode,
        message: detail,
      );
    }
    if (bytes.isEmpty && allowEmpty) {
      return const {};
    }
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, Object?>) {
      throw const LoomProtocolException('Expected JSON object');
    }
    return decoded;
  }

  LoomConversation _conversation(Map<String, Object?> json) {
    final kindRaw = _requiredString(json, 'kind').toLowerCase();
    final order = json['updatedOrder'];
    final unread = json['unreadCount'];
    if (order is! int || unread is! int) {
      throw const LoomProtocolException('Invalid conversation counters');
    }
    return LoomConversation(
      id: _requiredString(json, 'id'),
      kind: LoomConversationKind.values.byName(kindRaw),
      title: json['title'] as String?,
      peerAddress: json['peerAddress'] as String?,
      updatedOrder: order,
      unreadCount: unread,
      isMuted: json['isMuted'] == true,
      isPinned: json['isPinned'] == true,
    );
  }

  String _requiredString(Map<String, Object?> json, String key) {
    final value = json[key];
    if (value is! String || value.trim().isEmpty) {
      throw LoomProtocolException('Missing or invalid $key');
    }
    return value.trim();
  }

  void _requireSafeUri(Uri uri) =>
      requireLoomTransport(uri, baseEndpoint: false);
}

class LoomRealtimeConnection {
  LoomRealtimeConnection({
    required this.baseUri,
    required this.accessTokenProvider,
    required this.deviceProofProvider,
    this.cursor,
  });
  final Uri baseUri;
  final LoomAccessTokenProvider accessTokenProvider;
  final LoomDeviceRequestProofProvider deviceProofProvider;
  final String? cursor;
  WebSocket? _socket;
  final _events = StreamController<LoomSyncEvent>.broadcast();
  Stream<LoomSyncEvent> get events => _events.stream;

  Future<void> connect() async {
    await close();
    final token = await accessTokenProvider();
    requireLoomTransport(baseUri);
    final scheme = baseUri.scheme == 'https' ? 'wss' : 'ws';
    final uri = baseUri.replace(
      scheme: scheme,
      path: '/realtime/v1',
      queryParameters: {
        'stream': 'messages',
        if (cursor != null) 'cursor': cursor!,
      },
      fragment: null,
    );
    final proofHeaders = await deviceProofProvider.headers(
      method: 'GET',
      uri: uri,
      credential: token,
    );
    final socket = await WebSocket.connect(
      uri.toString(),
      headers: {
        HttpHeaders.authorizationHeader: 'Bearer $token',
        ...proofHeaders,
      },
    ).timeout(const Duration(seconds: 10));
    _socket = socket;
    socket.listen(
      _onData,
      onError: (Object error, StackTrace stackTrace) {
        if (!_events.isClosed) {
          _events.addError(error, stackTrace);
        }
      },
      onDone: () {
        if (!identical(_socket, socket)) {
          return;
        }
        _socket = null;
        if (!_events.isClosed) {
          _events.addError(
            const LoomProtocolException(
              'Realtime connection closed unexpectedly',
            ),
          );
        }
      },
      cancelOnError: false,
    );
  }

  void _onData(dynamic data) {
    if (data is! String || data.length > 512 * 1024) {
      return;
    }
    try {
      final raw = jsonDecode(data);
      if (raw is! Map<String, Object?>) {
        return;
      }
      final eventId = raw['eventId'];
      final kind = raw['kind'];
      final order = raw['order'];
      final payload = raw['payload'];
      if (eventId is String &&
          kind is String &&
          order is int &&
          payload is Map<String, Object?>) {
        _events.add(
          LoomSyncEvent(
            eventId: eventId,
            kind: kind,
            order: order,
            payload: payload,
          ),
        );
      }
    } catch (_) {
      // Malformed realtime frames are ignored; cursor sync is authoritative.
    }
  }

  Future<void> close() async {
    final socket = _socket;
    _socket = null;
    if (socket != null) {
      await socket.close(WebSocketStatus.normalClosure);
    }
  }

  Future<void> dispose() async {
    await close();
    await _events.close();
  }
}
